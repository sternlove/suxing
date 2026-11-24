/**
 * 聊天记录导入 → 说话风格提取。
 *
 * 用途：让某个会话模仿指定对象的语气。不同会话导不同记录，就得到不同人格。
 *
 * 流程：
 *   1) extractPdf   用 PDF Kit 的 PdfPage.getTextContent() 取全文（不需要 OCR）
 *   2) parse        按「X：」前缀切分，统计每个说话人的句数，取非用户的那一方
 *   3) analyze      统计句长/高频词/口头禅/语气词/标点/表情，拼成一段给模型看的描述
 *
 * 为什么是「统计风格」而不是「把原文喂给模型」：
 *   1.7B 的上下文吃不下几百条聊天，而且塞进去只会让它复读。
 *   摘要成 100~200 字的风格描述，才是这个模型能消化的量级。
 */
import { pdfService } from '@kit.PDFKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';

/** 分析用的最大句数，太多没必要（100 句足够看出习惯） */
const MAX_LINES: number = 200;
/** 风格描述的字数上限，给 prompt 留预算 */
const SUMMARY_MAX: number = 220;

export interface ChatStyle {
  /** 分析了几句 */
  samples: number;
  /** 平均每句字数 */
  avgLen: number;
  /** 高频词（2~4 字） */
  topWords: string[];
  /** 反复出现的短句（口头禅） */
  catchphrases: string[];
  /** 语气词 */
  particles: string[];
  /** 标点习惯的一句话描述 */
  punctDesc: string;
  /** 常用 emoji */
  emojis: string[];
  /** 拼好的风格描述（直接进 prompt） */
  summary: string;
}

export interface ParsedChat {
  /** 识别出的说话人（按句数降序） */
  speakers: string[];
  /** 主对象的句子（要模仿的那个人的话） */
  target: string[];
  /** 用户自己的句子 */
  mine: string[];
}

const PARTICLES: string[] = ['啊', '吧', '呢', '哈', '嘛', '呗', '咯', '呀', '哦', '噢', '唉', '诶'];
const EMOJI_RE: RegExp = /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/gu;

export class ChatArchive {
  /** 从 PDF 提取纯文本；失败返回空串 */
  static extractPdf(path: string): string {
    let doc: pdfService.PdfDocument | undefined = undefined;
    try {
      doc = new pdfService.PdfDocument();
      doc.loadDocument(path);
      const n: number = doc.getPageCount();
      if (n <= 0) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'archive pdf page count 0');
        return '';
      }
      let all: string = '';
      for (let i = 0; i < n; i++) {
        const page: pdfService.PdfPage = doc.getPage(i);
        try {
          all += page.getTextContent() + '\n';
        } finally {
          page.release();
        }
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'archive pdf pages=%{public}d chars=%{public}d',
        n, all.length);
      return all;
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'archive pdf failed: %{public}s', (e as Error).message);
      return '';
    } finally {
      if (doc !== undefined) {
        try {
          doc.releaseDocument();
        } catch (e) {
          // 释放失败无需处理
        }
      }
    }
  }

  /**
   * 解析聊天记录。
   * 支持「名字：内容」与「名字: 内容」（中英文冒号）；
   * 无前缀的行归到上一个说话人（处理后换行的情况）。
   */
  static parse(text: string): ParsedChat {
    const out: ParsedChat = { speakers: [], target: [], mine: [] };
    const lines: string[] = text.replace(/\r\n/g, '\n').split('\n');
    const bucket: Map<string, string[]> = new Map<string, string[]>();
    let cur: string = '';

    for (let i = 0; i < lines.length; i++) {
      const raw: string = lines[i].trim();
      if (raw === '') {
        continue;
      }
      // 找第一个冒号（中文或英文），且冒号前不像时间戳（不含数字）
      const ci: number = raw.search(/[：:]/);
      let isHead: boolean = false;
      let who: string = '';
      let body: string = '';
      if (ci > 0 && ci <= 12) {
        const head: string = raw.substring(0, ci).trim();
        // 排除「12:30」这种时间，和包含数字的行
        if (!/[0-9]/.test(head) && head.length > 0) {
          isHead = true;
          who = head;
          body = raw.substring(ci + 1).trim();
        }
      }
      if (isHead) {
        cur = who;
        if (!bucket.has(who)) {
          bucket.set(who, []);
        }
        if (body !== '') {
          (bucket.get(who) as string[]).push(body);
        }
      } else if (cur !== '') {
        const arr: string[] | undefined = bucket.get(cur);
        if (arr !== undefined) {
          arr.push(raw);
        }
      }
    }

    // 说话人按句数降序
    const entries: string[] = Array.from(bucket.keys());
    entries.sort((a: string, b: string) => (bucket.get(b) as string[]).length - (bucket.get(a) as string[]).length);
    out.speakers = entries;
    if (entries.length === 0) {
      // 没有任何前缀：整篇当目标语料
      out.target = lines.filter((l: string) => l.trim() !== '').slice(0, MAX_LINES);
      return out;
    }
    // 第一个说话人当「用户」（记录通常从自己开始），第二个当「要模仿的人」
    const mineName: string = entries.length >= 2 ? entries[0] : '';
    const targetName: string = entries.length >= 2 ? entries[1] : entries[0];
    out.mine = (bucket.get(mineName) ?? []).slice(0, MAX_LINES);
    out.target = (bucket.get(targetName) ?? []).slice(0, MAX_LINES);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'archive parsed speakers=%{public}d target=[%{public}s] lines=%{public}d',
      entries.length, targetName, out.target.length);
    return out;
  }

  /** 统计风格；lines 是要模仿的那个人的句子 */
  static analyze(lines: string[]): ChatStyle {
    const out: ChatStyle = {
      samples: 0,
      avgLen: 0,
      topWords: [],
      catchphrases: [],
      particles: [],
      punctDesc: '',
      emojis: [],
      summary: ''
    };
    const clean: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const t: string = lines[i].trim();
      if (t !== '') {
        clean.push(t);
      }
    }
    out.samples = clean.length;
    if (clean.length === 0) {
      out.summary = '';
      return out;
    }

    // 平均句长
    let total: number = 0;
    for (let i = 0; i < clean.length; i++) {
      total += clean[i].length;
    }
    out.avgLen = Math.round(total / clean.length);

    // 高频词：2~4 字滑窗计数（去掉纯标点）
    const freq: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < clean.length; i++) {
      const t: string = clean[i].replace(/[^\u4e00-\u9fa5a-zA-Z0-9]/g, '');
      for (let w = 2; w <= 4; w++) {
        for (let a = 0; a + w <= t.length; a++) {
          const g: string = t.substring(a, a + w);
          freq.set(g, (freq.get(g) ?? 0) + 1);
        }
      }
    }
    const freqArr: string[] = Array.from(freq.keys());
    freqArr.sort((a: string, b: string) => (freq.get(b) ?? 0) - (freq.get(a) ?? 0));
    out.topWords = freqArr.filter((w: string) => (freq.get(w) ?? 0) >= 2).slice(0, 8);

    // 口头禅：整句重复出现的（同一句出现 2 次以上）
    const lineCount: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < clean.length; i++) {
      if (clean[i].length <= 10) {
        lineCount.set(clean[i], (lineCount.get(clean[i]) ?? 0) + 1);
      }
    }
    const capArr: string[] = Array.from(lineCount.keys());
    capArr.sort((a: string, b: string) => (lineCount.get(b) ?? 0) - (lineCount.get(a) ?? 0));
    out.catchphrases = capArr.filter((c: string) => (lineCount.get(c) ?? 0) >= 2).slice(0, 4);

    // 语气词
    const joined: string = clean.join('\n');
    const ps: string[] = [];
    for (let i = 0; i < PARTICLES.length; i++) {
      let cnt: number = 0;
      for (let a = 0; a < joined.length; a++) {
        if (joined.charAt(a) === PARTICLES[i]) {
          cnt++;
        }
      }
      if (cnt >= 2) {
        ps.push(PARTICLES[i]);
      }
    }
    out.particles = ps.slice(0, 5);

    // 标点习惯
    const dots: number = (joined.match(/。/g) ?? []).length;
    const excls: number = (joined.match(/[!！]/g) ?? []).length;
    const ellip: number = (joined.match(/[.。]{2,}|\.{3}/g) ?? []).length;
    const qs: number = (joined.match(/[?？]/g) ?? []).length;
    const per: number = Math.max(1, clean.length);
    const desc: string[] = [];
    if (dots / per < 0.3) {
      desc.push('很少用句号');
    } else if (dots / per > 0.8) {
      desc.push('句末几乎都带句号');
    }
    if (excls / per > 0.2) {
      desc.push('爱用感叹号');
    }
    if (ellip > 0) {
      desc.push('爱用省略号');
    }
    if (qs / per > 0.2) {
      desc.push('常用疑问语气');
    }
    out.punctDesc = desc.join('、');

    // emoji
    const em: string[] = joined.match(EMOJI_RE) ?? [];
    const emCount: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < em.length; i++) {
      emCount.set(em[i], (emCount.get(em[i]) ?? 0) + 1);
    }
    const emArr: string[] = Array.from(emCount.keys());
    emArr.sort((a: string, b: string) => (emCount.get(b) ?? 0) - (emCount.get(a) ?? 0));
    out.emojis = emArr.slice(0, 4);

    // 拼描述
    let sum: string = '说话习惯（共 ' + out.samples + ' 句样本）：';
    sum += '平均每句 ' + out.avgLen + ' 个字';
    if (out.avgLen <= 10) {
      sum += '，句子很短';
    } else if (out.avgLen >= 25) {
      sum += '，句子偏长';
    }
    if (out.topWords.length > 0) {
      sum += '；常出现这些词：' + out.topWords.join('、');
    }
    if (out.catchphrases.length > 0) {
      sum += '；口头禅：' + out.catchphrases.map((c: string) => '「' + c + '」').join('');
    }
    if (out.particles.length > 0) {
      sum += '；语气词爱用：' + out.particles.join('、');
    }
    if (out.punctDesc !== '') {
      sum += '；' + out.punctDesc;
    }
    if (out.emojis.length > 0) {
      sum += '；常用表情：' + out.emojis.join('');
    }
    if (sum.length > SUMMARY_MAX) {
      sum = sum.substring(0, SUMMARY_MAX);
    }
    out.summary = sum;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'archive style samples=%{public}d avg=%{public}d summaryChars=%{public}d',
      out.samples, out.avgLen, sum.length);
    return out;
  }

  /** 一步到位：文件路径 → 风格 */
  static fromPdf(path: string): ChatStyle {
    const text: string = ChatArchive.extractPdf(path);
    if (text === '') {
      return ChatArchive.analyze([]);
    }
    const parsed: ParsedChat = ChatArchive.parse(text);
    return ChatArchive.analyze(parsed.target);
  }
}
