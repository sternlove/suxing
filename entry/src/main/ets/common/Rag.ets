/**
 * RAG 历史检索：纯文本 BM25（零依赖，不引入 embedding / 向量库）。
 *
 * 为什么不用向量检索：本项目 llama.cpp 只编了推理，没有 sentence-embedding，
 * 也没有向量库依赖；再引一套模型会超出「不引入第三方依赖」的边界。
 *
 * 算法（BM25 简化版）：
 *   ① 分词：中文没有空格 → 按字切二元组(bigram) + 单字兜底；英文/数字按词切；
 *   ② 统计：候选集内算 TF（带权）、DF、平均文档长度；
 *   ③ 打分：score = Σ qw × idf × (tf×(k1+1)) / (tf + k1×(1-b+b×dl/avgdl))，k1=1.2 b=0.75；
 *   ④ 过滤：低于绝对阈值 RAG_MIN_SCORE、或低于第一名 RAG_REL_KEEP 倍的碎片丢弃。
 *
 * 单字权重低于二元组：中文单字（我/是/不）噪声极大，只当兜底召回用。
 */

/** 一条检索命中 */
export interface MemoryHit {
  id: number;
  role: string;
  text: string;
  ts: number;
  score: number;
}

/** 参与打分的文档（就是库里的一行消息） */
export interface RagDoc {
  id: number;
  role: string;
  text: string;
  ts: number;
}

/** 分词单元：t 是词面，w 是权重（二元组 1.0 / 英文词 1.0 / 单字 0.12） */
export interface RagToken {
  t: string;
  w: number;
}

/** 注入 prompt 的片段条数上限（3 → 2 → 1 → 0 依次砍） */
export const RAG_TOPK: number = 3;
/** 单条片段裁切字符数：一条长回复会把 n_ctx=2048 直接吃掉 */
export const RAG_FRAG_CHARS: number = 48;
/**
 * 低于这个分认为是噪声，不返回。
 * 上一轮实测 1.0 太低：「美女你你」这种碎片行也能过线，2.0 起才只剩真命中。
 */
export const RAG_MIN_SCORE: number = 2.0;

const BM25_K1: number = 1.2;
const BM25_B: number = 0.75;
/** 相对阈值：不到第一名这个比例的命中直接丢 */
const RAG_REL_KEEP: number = 0.30;
/**
 * 单字权重压到 0.12：中文单字（我/是/不/美）区分度极低，
 * 权重远低于二元组后，只有单字命中的行几乎不可能单独越过 RAG_MIN_SCORE，
 * 单字只保留「和二元组同时命中时的一点加权」这一个作用。
 */
const W_UNI: number = 0.12;
const W_WORD: number = 1.0;
const W_BI: number = 1.0;

/** 中文单字停用表（这些字做单字 token 时没有区分度） */
const STOP_CHARS: string =
  '的了着过是在有我你他她它这那就都也吧啊呀吗呢哦嘛和与跟被把给让对从向为以之其而并且但或如' +
  '果没不要会有能可去来到说个上下一中大小多少么什怎哪谁时得地还再又才只很太更最些没';

/** 整词停用表：疑问词/口头语/人格自称，出现频率高但没有检索价值 */
const STOP_WORDS: string[] = [
  '什么', '怎么', '这个', '那个', '我们', '你们', '他们', '现在', '可以', '就是', '还是',
  '但是', '因为', '所以', '怎样', '时候', '一个', '没有', '不是', '知道', '告诉', '一下',
  '先生', '然后', '其实', '应该', '已经', '觉得', '感觉', '如果', '这样', '那样', '一些',
  '东西', '事情', 'the', 'and', 'you', 'for', 'are', 'was', 'with', 'that', 'this',
  'have', 'what', 'your', 'from', 'not', 'but', 'how', 'why', 'can'
];

function isCjkCode(c: number): boolean {
  return (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF);
}

function isAsciiAlnum(c: number): boolean {
  return (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A);
}

function isStopToken(t: string): boolean {
  if (t.length === 0) {
    return true;
  }
  if (STOP_WORDS.indexOf(t) >= 0) {
    return true;
  }
  if (t.length === 1) {
    const c: number = t.charCodeAt(0);
    if (isCjkCode(c) && STOP_CHARS.indexOf(t) >= 0) {
      return true;
    }
    // 单个英文/数字没有检索意义
    if (isAsciiAlnum(c)) {
      return true;
    }
  }
  return false;
}

function pushToken(out: RagToken[], t: string, w: number): void {
  if (isStopToken(t)) {
    return;
  }
  out.push({ t: t, w: w });
}

/**
 * 分词：
 *   "今天天气不错" → 今天 天 天天 气 天气 不 气不 错 不错 …
 *   "hello world" → hello / world
 * 停用字与停用词在入列时就丢掉，后面统计不再判。
 */
export function tokenize(text: string): RagToken[] {
  const out: RagToken[] = [];
  if (text === '') {
    return out;
  }
  const s: string = text.toLowerCase();
  let i: number = 0;
  while (i < s.length) {
    const c: number = s.charCodeAt(i);
    if (isCjkCode(c)) {
      let j: number = i;
      while (j < s.length && isCjkCode(s.charCodeAt(j))) {
        j++;
      }
      const run: string = s.substring(i, j);
      for (let k: number = 0; k < run.length; k++) {
        if (k + 1 < run.length) {
          pushToken(out, run.substring(k, k + 2), W_BI);
        }
        pushToken(out, run.charAt(k), W_UNI);
      }
      i = j;
    } else if (isAsciiAlnum(c)) {
      let j: number = i;
      while (j < s.length && isAsciiAlnum(s.charCodeAt(j))) {
        j++;
      }
      pushToken(out, s.substring(i, j), W_WORD);
      i = j;
    } else {
      i++;
    }
  }
  return out;
}

/**
 * BM25 打分，返回按分降序的前 topK 条。
 * query 为空 / 全是停用词时返回空数组（调用方据此不注入）。
 */
export function scoreDocs(query: string, docs: RagDoc[], topK: number): MemoryHit[] {
  const hits: MemoryHit[] = [];
  if (query === '' || docs.length === 0 || topK <= 0) {
    return hits;
  }
  const qTok: RagToken[] = tokenize(query);
  if (qTok.length === 0) {
    return hits;
  }
  // query 侧同一 token 只算一次，权重取出现过的最大值
  const qKeys: string[] = [];
  const qW: number[] = [];
  for (const t of qTok) {
    const at: number = qKeys.indexOf(t.t);
    if (at < 0) {
      qKeys.push(t.t);
      qW.push(t.w);
    } else if (t.w > qW[at]) {
      qW[at] = t.w;
    }
  }
  const n: number = docs.length;
  const tfs: Array<Map<string, number>> = [];
  const dls: number[] = [];
  let sumDl: number = 0;
  for (const d of docs) {
    const toks: RagToken[] = tokenize(d.text);
    const m: Map<string, number> = new Map<string, number>();
    let dl: number = 0;
    for (const t of toks) {
      const old: number | undefined = m.get(t.t);
      m.set(t.t, (old === undefined ? 0 : old) + t.w);
      dl = dl + t.w;
    }
    tfs.push(m);
    dls.push(dl);
    sumDl = sumDl + dl;
  }
  const avgdl: number = sumDl > 0 ? sumDl / n : 1;
  const idf: number[] = [];
  for (const k of qKeys) {
    let df: number = 0;
    for (const m of tfs) {
      if (m.has(k)) {
        df++;
      }
    }
    idf.push(Math.log(1 + (n - df + 0.5) / (df + 0.5)));
  }
  let best: number = 0;
  const scored: MemoryHit[] = [];
  for (let i: number = 0; i < n; i++) {
    const m: Map<string, number> = tfs[i];
    const dl: number = dls[i];
    const norm: number = 1 - BM25_B + BM25_B * (dl / avgdl);
    let s: number = 0;
    for (let q: number = 0; q < qKeys.length; q++) {
      const tf: number | undefined = m.get(qKeys[q]);
      if (tf === undefined || tf <= 0) {
        continue;
      }
      s = s + qW[q] * idf[q] * (tf * (BM25_K1 + 1)) / (tf + BM25_K1 * norm);
    }
    if (s > 0) {
      const d: RagDoc = docs[i];
      scored.push({ id: d.id, role: d.role, text: d.text, ts: d.ts, score: s });
      if (s > best) {
        best = s;
      }
    }
  }
  const floor: number = Math.max(RAG_MIN_SCORE, best * RAG_REL_KEEP);
  for (const h of scored) {
    if (h.score >= floor) {
      hits.push(h);
    }
  }
  hits.sort((a: MemoryHit, b: MemoryHit) => b.score - a.score);
  return hits.length > topK ? hits.slice(0, topK) : hits;
}

/** 压成一行并裁到 maxChars（注入 prompt 的片段一律单行，避免吃掉预算） */
export function oneLine(text: string, maxChars: number): string {
  let t: string = text.split('\r').join(' ').split('\n').join(' ').trim();
  while (t.indexOf('  ') >= 0) {
    t = t.split('  ').join(' ');
  }
  if (t.length > maxChars) {
    t = t.substring(0, maxChars) + '…';
  }
  return t;
}

function normText(t: string): string {
  return t.split('\r').join('').split('\n').join('').split(' ').join('').trim();
}

/**
 * 注入块：命中为空时返回空串（调用方据此决定「不写任何东西」，
 * 不要写「没有相关记录」这种废话）。
 */
export function buildRagBlock(lines: string[]): string {
  const parts: string[] = [];
  for (const l of lines) {
    const t: string = oneLine(l, RAG_FRAG_CHARS);
    if (t !== '') {
      parts.push('- ' + t);
    }
  }
  if (parts.length === 0) {
    return '';
  }
  return '以下是先生以前提过的相关内容：\n' + parts.join('\n') + '\n';
}

/**
 * 剔除已经躺在「最近几轮」里的命中（重复注入只会浪费预算），
 * 以及和当前这句一模一样的行（user 消息先落库再检索，否则它自己永远第一）。
 */
export function pickFresh(hits: MemoryHit[], recentTexts: string[], query: string,
                         topK: number): MemoryHit[] {
  const out: MemoryHit[] = [];
  const q: string = normText(query);
  const rec: string[] = [];
  for (const r of recentTexts) {
    rec.push(normText(r));
  }
  for (const h of hits) {
    if (out.length >= topK) {
      break;
    }
    const k: string = normText(h.text);
    if (k === '' || k === q) {
      continue;
    }
    let dup: boolean = false;
    for (const r of rec) {
      if (r === k || (k.length >= 6 && r.indexOf(k) >= 0)) {
        dup = true;
        break;
      }
    }
    if (dup) {
      continue;
    }
    let used: boolean = false;
    for (const o of out) {
      if (normText(o.text) === k) {
        used = true;
        break;
      }
    }
    if (used) {
      continue;
    }
    out.push(h);
  }
  return out;
}

/** 日志用：裁到 maxChars 并压成一行 */
export function brief(text: string, maxChars: number): string {
  const t: string = oneLine(text, maxChars);
  return t;
}
