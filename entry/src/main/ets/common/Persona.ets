import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 人格内核：底线人格（写死，最高优先级）+ 偏好自演化（traits）+ 简版情绪（emotion）。
 *
 * 为什么单独一个文件：Memory.ets 只管「聊了什么」，本文件只管「苏兴是谁、怎么说」。
 * prompt 预算由 composeSystemPrompt 一处收口，n_ctx=2048 的 0.5B 吃不下长 prompt，
 * 上限 200 字，超出时按「情绪 → 偏好 → 事实」的顺序丢可选项，底线人格永远保留。
 *
 * 称呼是硬约束：任何 composition/回复都不许把用户名字当称呼，一律「先生」。
 */

export const PER_DOMAIN: number = 0xC0DE;
export const PER_TAG: string = 'CyberTwin';

const DB_NAME: string = 'cybertwin_memory.db';
const TRAIT_TABLE: string = 'traits';
const EMO_TABLE: string = 'emotion';

/** system prompt 总长上限（含底线人格 + 事实 + 偏好 + 情绪） */
export const PERSONA_MAX_CHARS: number = 200;
/** 注入 prompt 的偏好条数上限 */
export const PROMPT_TRAITS: number = 3;
export const TRAIT_WEIGHT_INIT: number = 0.5;
export const TRAIT_WEIGHT_STEP: number = 0.2;
export const TRAIT_WEIGHT_CAP: number = 1.0;
export const TOPIC_MAX_CHARS: number = 12;
export const EVIDENCE_MAX_CHARS: number = 30;
/** 每次更新后向 0.5 靠拢的衰减系数 */
export const DECAY: number = 0.02;
const PRAISE_DELTA: number = 0.05;
const COMPLAIN_VALENCE: number = -0.05;
const COMPLAIN_INTIMACY: number = -0.03;
const COMPANY_INTIMACY: number = 0.02;
/** 「连续 5 轮以上对话」的阈值：第 5 轮起每轮加亲密度 */
export const COMPANY_TURNS: number = 5;
const EMO_HIGH: number = 0.65;
const EMO_LOW: number = 0.35;

export const BASE_PERSONA: string = '你是苏兴，称对方「先生」，永远称先生，不叫名字、不叫主人。\n'
  + '回复简短但要有信息量，不用模板句或口头禅（如"说事"），不寒暄不奉承不用感叹号。\n'
  + '结论要有证据（路径/日志/数字），没验证就说"没验证"，不知道就说不知道。\n'
  + '示范：\n'
  + '你好→先生，我在。\n'
  + '今天怎么样→先生，一切正常，您那边呢。\n'
  + '看看报错→先生，把报错内容贴给我。';

/** 偏好：kind 只取 'like' / 'dislike'，weight 决定进 prompt 的优先级 */
export interface Trait {
  kind: string;
  topic: string;
  weight: number;
  evidence: string;
  ts: number;
}

/** 情绪三轴：valence 愉悦 / arousal 唤醒 / intimacy 亲密度，全部 0..1，中枢 0.5 */
export interface EmotionState {
  valence: number;
  arousal: number;
  intimacy: number;
  updatedAt: number;
}

/** 一条正则抽出来的候选偏好（还没入库，没有 id/weight） */
export interface TraitHit {
  kind: string;
  topic: string;
  evidence: string;
}

/** 情绪一步更新：新状态 + 触发原因（写 hilog 用） */
export interface EmotionStep {
  state: EmotionState;
  reason: string;
}

interface PrefixRule {
  prefix: string;
  kind: string;
}

/** 正面：我(很)?喜欢 X / 我爱 X；负面：我(很)?讨厌 X / 我不喜欢 X。长的放前面先匹配 */
const RULES: PrefixRule[] = [
  { prefix: '我特别讨厌', kind: 'dislike' },
  { prefix: '我很不喜欢', kind: 'dislike' },
  { prefix: '我很讨厌', kind: 'dislike' },
  { prefix: '我讨厌', kind: 'dislike' },
  { prefix: '我不喜欢', kind: 'dislike' },
  { prefix: '我受不了', kind: 'dislike' },
  { prefix: '我特别喜欢', kind: 'like' },
  { prefix: '我很喜欢', kind: 'like' },
  { prefix: '我超喜欢', kind: 'like' },
  { prefix: '我喜欢', kind: 'like' },
  { prefix: '我最爱', kind: 'like' },
  { prefix: '我爱', kind: 'like' }
];

const STOP_CHARS: string = "，。,.！!？?；;、:：\n\t 「」“”\"'()（）";
/** 这些当 topic 没意义（问句/代词），直接丢 */
const TOPIC_SKIP: string[] = ['你', '你们', '他', '她', '它', '这', '那', '什么', '啥', '吗', '呢'];

const PRAISE_WORDS: string[] = ['谢谢', '感谢', '辛苦了', '厉害', '很好', '不错', '棒', '牛', '赞', '给力'];
const COMPLAIN_WORDS: string[] = ['不对', '还是不行', '不行', '错了', '没用', '垃圾', '烦', '失望', '算了'];
const GREETINGS: string[] = ['你好', '您好', '嗨', '哈喽', 'hi', 'hello', '在吗', '在不在',
  '早上好', '早', '晚上好'];
/** 回复里不许出现的寒暄片段（底线人格要求不寒暄） */
const FLUFF: string[] = ['很高兴', '很乐意', '我能帮你', '我可以帮你', '有什么可以帮',
  '为你服务', '希望对你', '乐于', '对不起', '抱歉', '我会尽力', '我会尽快', '请您', '希望能帮到'];

export function defaultEmotion(): EmotionState {
  const s: EmotionState = { valence: 0.5, arousal: 0.5, intimacy: 0.5, updatedAt: 0 };
  return s;
}

function clamp01(v: number): number {
  if (v < 0) {
    return 0;
  }
  return v > 1 ? 1 : v;
}

function round2(v: number): number {
  return Math.round(v * 100) / 100;
}

function isStop(ch: string): boolean {
  return STOP_CHARS.indexOf(ch) >= 0;
}

/** 从 start 开始取到标点/句末为止的短语，最长 TOPIC_MAX_CHARS 字 */
function cutTopic(s: string, start: number): string {
  let out: string = '';
  for (let i = start; i < s.length; i++) {
    const ch: string = s.charAt(i);
    if (isStop(ch) || out.length >= TOPIC_MAX_CHARS) {
      break;
    }
    out += ch;
  }
  return out.trim();
}

/** evidence：命中处所在的那一句，压平换行，最长 EVIDENCE_MAX_CHARS 字 */
function cutEvidence(s: string, hitAt: number): string {
  let from: number = hitAt;
  while (from > 0 && !isStop(s.charAt(from - 1))) {
    from--;
  }
  let to: number = hitAt;
  while (to < s.length && !isStop(s.charAt(to))) {
    to++;
  }
  let seg: string = s.substring(from, to).split('\n').join(' ').trim();
  if (seg.length > EVIDENCE_MAX_CHARS) {
    seg = seg.substring(0, EVIDENCE_MAX_CHARS);
  }
  return seg;
}

function skipTopic(topic: string): boolean {
  if (topic === '') {
    return true;
  }
  if (topic.length > TOPIC_MAX_CHARS) {
    return true;
  }
  for (const w of TOPIC_SKIP) {
    if (topic === w) {
      return true;
    }
  }
  return topic.indexOf('什么') >= 0 || topic.indexOf('啥') >= 0;
}

/**
 * 明说提取：只在用户自己那句里找「我喜欢 X」这类显式表达。
 * 不猜、不从助手话里学，宁缺毋滥 —— 这条只服务 prompt 的一句话偏好，不值得做语义推断。
 */
export function extractTraitHits(userText: string, ts: number): TraitHit[] {
  const hits: TraitHit[] = [];
  const seen: string[] = [];
  for (const rule of RULES) {
    let from: number = 0;
    while (from < userText.length) {
      const at: number = userText.indexOf(rule.prefix, from);
      if (at < 0) {
        break;
      }
      const topic: string = cutTopic(userText, at + rule.prefix.length);
      from = at + rule.prefix.length;
      if (skipTopic(topic)) {
        continue;
      }
      const key: string = rule.kind + '|' + topic;
      if (seen.indexOf(key) >= 0) {
        continue;
      }
      seen.push(key);
      const hit: TraitHit = { kind: rule.kind, topic: topic, evidence: cutEvidence(userText, at) };
      hits.push(hit);
    }
  }
  return hits;
}

/**
 * prompt 层强制过滤：任何「用户叫 XX / 你叫 XX」片段、以及已知脏名字一律剔除。
 * 宁可少给模型信息，也不许它叫名字 —— 称呼固定「先生」，与用户是谁无关。
 */
export function sanitizePrompt(text: string, banned: string[]): string {
  let out: string = text;
  for (const nm of banned) {
    if (nm !== '') {
      out = out.split(nm).join('');
    }
  }
  out = out.replace(/(用户|你|对方)(叫|的名字是|名字叫)[^，。；、\n]{0,10}/g, '');
  return out;
}

/** 命中脏名字：这条偏好不许进 prompt（宁可少给信息，也不许叫名字） */
function isDirty(text: string, banned: string[]): boolean {
  for (const nm of banned) {
    if (nm !== '' && text.indexOf(nm) >= 0) {
      return true;
    }
  }
  return false;
}

/** 偏好块：按 weight 取前 3 条，0 条时返回空串（不写「暂无偏好」） */
export function traitsPrompt(traits: Trait[], banned: string[]): string {
  const likes: string[] = [];
  const dislikes: string[] = [];
  for (const t of traits) {
    if (isDirty(t.topic, banned)) {
      continue;
    }
    if (t.kind === 'like' && likes.indexOf(t.topic) < 0) {
      likes.push(t.topic);
    } else if (t.kind === 'dislike' && dislikes.indexOf(t.topic) < 0) {
      dislikes.push(t.topic);
    }
  }
  const parts: string[] = [];
  if (likes.length > 0) {
    parts.push('先生喜欢：' + likes.join('、'));
  }
  if (dislikes.length > 0) {
    parts.push('先生不喜欢：' + dislikes.join('、'));
  }
  return parts.join('\n');
}

/** 情绪只在两句里体现，不参与任何回复逻辑 */
export function emotionLine(emo: EmotionState): string {
  if (emo.valence > EMO_HIGH) {
    return '你现在心情不错。';
  }
  if (emo.valence < EMO_LOW) {
    return '你现在话更少。';
  }
  return '';
}

/**
 * 拼最终 system prompt：底线人格 + 偏好(≤3) + 情绪。
 * 不注入任何用户名字：称呼固定「先生」，与用户是谁无关。
 * 超出 PERSONA_MAX_CHARS 时从后往前丢可选项（情绪 → 偏好），底线人格永远保留。
 */
export function composeSystemPrompt(traits: Trait[], emo: EmotionState, banned: string[]): string {
  const parts: string[] = [BASE_PERSONA];
  const block: string = traitsPrompt(traits, banned);
  if (block !== '') {
    parts.push(block);
  }
  const mood: string = emotionLine(emo);
  if (mood !== '') {
    parts.push(mood);
  }
  let out: string = parts.join('\n');
  while (out.length > PERSONA_MAX_CHARS && parts.length > 1) {
    parts.pop();
    out = parts.join('\n');
  }
  // 最后一道保险：清洗后再压一次长度
  out = sanitizePrompt(out, banned);
  if (out.length > PERSONA_MAX_CHARS) {
    out = out.substring(0, PERSONA_MAX_CHARS);
  }
  return out;
}

function hasAny(text: string, words: string[]): string {
  for (const w of words) {
    if (text.indexOf(w) >= 0) {
      return w;
    }
  }
  return '';
}

/** 每条对话后微调一次：先按文本加减，再整体向 0.5 衰减 */
export function stepEmotion(prev: EmotionState, userText: string, turnSeq: number): EmotionStep {
  let valence: number = prev.valence;
  let arousal: number = prev.arousal;
  let intimacy: number = prev.intimacy;
  const why: string[] = [];
  const bad: string = hasAny(userText, COMPLAIN_WORDS);
  const good: string = bad === '' ? hasAny(userText, PRAISE_WORDS) : '';
  if (bad !== '') {
    valence += COMPLAIN_VALENCE;
    intimacy += COMPLAIN_INTIMACY;
    why.push('complaint=' + bad);
  } else if (good !== '') {
    valence += PRAISE_DELTA;
    why.push('praise=' + good);
  }
  if (turnSeq >= COMPANY_TURNS) {
    intimacy += COMPANY_INTIMACY;
    why.push('company=' + turnSeq);
  }
  valence = valence + (0.5 - valence) * DECAY;
  arousal = arousal + (0.5 - arousal) * DECAY;
  intimacy = intimacy + (0.5 - intimacy) * DECAY;
  const next: EmotionState = {
    valence: round2(clamp01(valence)),
    arousal: round2(clamp01(arousal)),
    intimacy: round2(clamp01(intimacy)),
    updatedAt: Date.now()
  };
  const step: EmotionStep = { state: next, reason: why.join(',') };
  return step;
}

export function emotionFace(valence: number): string {
  if (valence > EMO_HIGH) {
    return '😊';
  }
  if (valence < EMO_LOW) {
    return '😔';
  }
  return '😐';
}

export function emotionLabel(valence: number): string {
  if (valence > EMO_HIGH) {
    return '不错';
  }
  if (valence < EMO_LOW) {
    return '低落';
  }
  return '平稳';
}

/** 「我叫 X」「我的名字是 X」里的 X；问句（我叫什么名字）不算自报名字 */
export function selfIntroName(userText: string): string {
  const heads: string[] = ['我的名字是', '我的名字叫', '我叫'];
  for (const h of heads) {
    const at: number = userText.indexOf(h);
    if (at < 0) {
      continue;
    }
    const cand: string = cutTopic(userText, at + h.length);
    if (cand === '' || cand.indexOf('什么') >= 0 || cand.indexOf('啥') >= 0) {
      continue;
    }
    return cand;
  }
  return '';
}

/** 短句意图表：不同问题必须给不同答案，禁止一句模板打天下 */
interface AnswerRule {
  keys: string[];
  reply: string;
}

const ANSWERS: AnswerRule[] = [
  { keys: ['你是谁', '你叫什么', '你是什么', '介绍一下你自己', '介绍下你自己'], reply: '先生，我是苏兴，您的分身。' },
  { keys: ['今天怎么样', '最近怎么样', '你怎么样', '最近好吗', '过得怎么样'], reply: '先生，一切正常，您那边呢。' },
  { keys: ['你好', '您好', '嗨', '哈喽', 'hi', 'hello', '在吗', '在不在', '早上好', '晚上好'], reply: '先生，我在。' },
  { keys: ['晚安'], reply: '先生，晚安。' },
  { keys: ['谢谢', '谢谢你'], reply: '先生，不客气。' }
];

/** 剪贴板触发词：只有用户明确要看剪贴板/报错时才读，绝不在每次发消息时偷读 */
const CLIP_WORDS: string[] = ['看看剪贴板', '剪贴板', '看看我的报错', '分析这段', '读剪贴板', '看看复制的'];
export const CLIP_MAX_CHARS: number = 2000;

export function wantsClipboard(userText: string): boolean {
  for (const w of CLIP_WORDS) {
    if (userText.indexOf(w) >= 0) {
      return true;
    }
  }
  return false;
}

/** 剪贴板文本：超过 CLIP_MAX_CHARS 保留前 2000 字并标注截断 */
export function clipForPrompt(raw: string): string {
  const s: string = raw.split('\r').join('').trim();
  if (s.length <= CLIP_MAX_CHARS) {
    return s;
  }
  return s.substring(0, CLIP_MAX_CHARS) + '…已截断';
}

function flatOf(userText: string): string {
  return userText.split('！').join('').split('!').join('').split('。').join('')
    .split('，').join('').split(',').join('').split('？').join('').split('?').join('').trim();
}

/**
 * 确定性直答：纯寒暄/自我介绍这种没有信息量的问题不交给 0.5B。
 * 每条对应不同答案 —— 实测 0.5B 会挑一句最短模板反复用，那是本轮要修的病。
 */
export function directAnswer(userText: string): string {
  const t: string = userText.trim();
  if (selfIntroName(t) !== '') {
    return '好的，先生。';
  }
  const flat: string = flatOf(t);
  for (const rule of ANSWERS) {
    for (const k of rule.keys) {
      if (flat === k || (flat.indexOf(k) === 0 && flat.length <= k.length + 3)) {
        return rule.reply;
      }
    }
  }
  return '';
}

/** 开头寒暄词：只在句首删，避免把正文里的「你好」误删 */
const LEADING_FLUFF: string[] = ['你好', '您好', '哈喽', '嗨'];
/** 回复句数上限：底线人格要求简短，这里硬截断兜住 0.5B 的啰嗦 */
const REPLY_SENTENCES: number = 3;

function clampSentences(text: string, max: number): string {
  let out: string = '';
  let count: number = 0;
  for (let i = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    out += ch;
    if (ch === '。' || ch === '！' || ch === '？' || ch === '!' || ch === '?' || ch === '；') {
      count++;
      if (count >= max) {
        break;
      }
    }
  }
  return out.trim();
}

/**
 * 回复守卫：模型偶尔会寒暄、叫「主人」、或不称「先生」。
 * 这里做三件确定性的事 —— 删寒暄、主人→先生、没称先生就补一个「先生，」，再压到三句以内。
 * 这是称呼硬约束的最后一道闸，不依赖 0.5B 听话。
 */
export function guardReply(reply: string, banned: string[]): string {
  let out: string = reply.split('\n').join(' ').trim();
  for (const nm of banned) {
    if (nm !== '') {
      out = out.split(nm).join('');
    }
  }
  out = out.replace(/^(叫|是)[^，。]{1,8}[，,。]?/, '');
  for (const f of FLUFF) {
    out = out.split(f).join('');
  }
  out = out.split('主人').join('先生');
  let head: boolean = true;
  while (head) {
    head = false;
    for (const l of LEADING_FLUFF) {
      if (out.indexOf(l) === 0) {
        out = out.substring(l.length);
        out = out.replace(/^[，,、。！!\s]+/, '');
        head = true;
      }
    }
  }
  out = clampSentences(out, REPLY_SENTENCES).trim();
  if (out === '') {
    return '先生，没答上来。';
  }
  if (out.indexOf('先生') < 0) {
    out = '先生，' + out;
  }
  return out;
}

/**
 * 偏好/情绪落库。用同一份 DB 文件（和 Memory 的 messages 表并列），
 * 这样「清空聊天记录」不会连带删掉人格演化，反之亦然。
 */
export class PersonaStore {
  private store: relationalStore.RdbStore | undefined = undefined;

  isReady(): boolean {
    return this.store !== undefined;
  }

  async init(ctx: common.Context): Promise<boolean> {
    if (this.store !== undefined) {
      return true;
    }
    try {
      const cfg: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const st: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, cfg);
      await st.executeSql('CREATE TABLE IF NOT EXISTS ' + TRAIT_TABLE + ' ('
        + 'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        + 'kind TEXT NOT NULL, '
        + 'topic TEXT NOT NULL, '
        + 'weight REAL NOT NULL, '
        + 'evidence TEXT NOT NULL, '
        + 'ts INTEGER NOT NULL)');
      await st.executeSql('CREATE TABLE IF NOT EXISTS ' + EMO_TABLE + ' ('
        + 'id INTEGER PRIMARY KEY, '
        + 'valence REAL NOT NULL, '
        + 'arousal REAL NOT NULL, '
        + 'intimacy REAL NOT NULL, '
        + 'updated_at INTEGER NOT NULL)');
      this.store = st;
      const n: number = await this.traitCount();
      hilog.info(PER_DOMAIN, PER_TAG, 'persona ready traits=%{public}d emoTable=%{public}s',
        n, EMO_TABLE);
      return true;
    } catch (e) {
      hilog.error(PER_DOMAIN, PER_TAG, 'persona init failed: %{public}s', (e as Error).message);
      return false;
    }
  }

  async traitCount(): Promise<number> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet =
        await st.querySql('SELECT COUNT(*) AS c FROM ' + TRAIT_TABLE);
      try {
        if (rs.goToFirstRow()) {
          return rs.getLong(rs.getColumnIndex('c'));
        }
      } finally {
        rs.close();
      }
    } catch (e) {
      hilog.error(PER_DOMAIN, PER_TAG, 'trait count failed: %{public}s', (e as Error).message);
    }
    return 0;
  }

  /** 按 weight 从高到低取前 limit 条（同分时新学的优先） */
  async topTraits(limit: number): Promise<Trait[]> {
    const out: Trait[] = [];
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return out;
    }
    try {
      const args: Array<relationalStore.ValueType> = [limit];
      const rs: relationalStore.ResultSet = await st.querySql(
        'SELECT kind, topic, weight, evidence, ts FROM ' + TRAIT_TABLE
          + ' ORDER BY weight DESC, ts DESC LIMIT ?', args);
      try {
        const ciKind: number = rs.getColumnIndex('kind');
        const ciTopic: number = rs.getColumnIndex('topic');
        const ciWeight: number = rs.getColumnIndex('weight');
        const ciEv: number = rs.getColumnIndex('evidence');
        const ciTs: number = rs.getColumnIndex('ts');
        while (rs.goToNextRow()) {
          const t: Trait = {
            kind: rs.getString(ciKind),
            topic: rs.getString(ciTopic),
            weight: rs.getDouble(ciWeight),
            evidence: rs.getString(ciEv),
            ts: rs.getLong(ciTs)
          };
          out.push(t);
        }
      } finally {
        rs.close();
      }
    } catch (e) {
      hilog.error(PER_DOMAIN, PER_TAG, 'topTraits failed: %{public}s', (e as Error).message);
    }
    return out;
  }

  /**
   * 一条命中入库：同 kind+topic 累加 weight（+0.2，上限 1.0），否则新建。
   * 返回入库后的那条（weight 以库为准），便于 hilog 打印演化过程。
   */
  async absorb(hit: TraitHit): Promise<Trait | undefined> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return undefined;
    }
    const now: number = Date.now();
    try {
      const q: Array<relationalStore.ValueType> = [hit.kind, hit.topic];
      const rs: relationalStore.ResultSet = await st.querySql(
        'SELECT id, weight FROM ' + TRAIT_TABLE + ' WHERE kind = ? AND topic = ? ORDER BY id DESC LIMIT 1', q);
      let id: number = -1;
      let weight: number = TRAIT_WEIGHT_INIT;
      try {
        if (rs.goToFirstRow()) {
          id = rs.getLong(rs.getColumnIndex('id'));
          weight = rs.getDouble(rs.getColumnIndex('weight'));
        }
      } finally {
        rs.close();
      }
      if (id >= 0) {
        weight = Math.min(TRAIT_WEIGHT_CAP, round2(weight + TRAIT_WEIGHT_STEP));
        const up: Array<relationalStore.ValueType> = [weight, hit.evidence, now, id];
        await st.executeSql('UPDATE ' + TRAIT_TABLE
          + ' SET weight = ?, evidence = ?, ts = ? WHERE id = ?', up);
      } else {
        weight = TRAIT_WEIGHT_INIT;
        const ins: Array<relationalStore.ValueType> = [hit.kind, hit.topic, weight, hit.evidence, now];
        await st.executeSql('INSERT INTO ' + TRAIT_TABLE
          + ' (kind, topic, weight, evidence, ts) VALUES (?, ?, ?, ?, ?)', ins);
      }
      const t: Trait = { kind: hit.kind, topic: hit.topic, weight: weight,
        evidence: hit.evidence, ts: now };
      hilog.info(PER_DOMAIN, PER_TAG,
        'trait stored kind=%{public}s topic=%{public}s weight=%{public}s evidence=[%{public}s] id=%{public}d',
        t.kind, t.topic, '' + t.weight, t.evidence, id);
      return t;
    } catch (e) {
      hilog.error(PER_DOMAIN, PER_TAG, 'trait absorb failed: %{public}s', (e as Error).message);
      return undefined;
    }
  }

  /** 把 topic 里带脏名字的偏好删掉（历史脏数据可能已经被学成偏好） */
  async purgeTraits(banned: string[]): Promise<number> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined || banned.length === 0) {
      return 0;
    }
    let removed: number = 0;
    try {
      for (const nm of banned) {
        if (nm === '') {
          continue;
        }
        const args: Array<relationalStore.ValueType> = ['%' + nm + '%'];
        const rs: relationalStore.ResultSet = await st.querySql(
          'SELECT COUNT(*) AS c FROM ' + TRAIT_TABLE + ' WHERE topic LIKE ?', args);
        try {
          if (rs.goToFirstRow()) {
            removed += rs.getLong(rs.getColumnIndex('c'));
          }
        } finally {
          rs.close();
        }
        await st.executeSql('DELETE FROM ' + TRAIT_TABLE + ' WHERE topic LIKE ?', args);
      }
      if (removed > 0) {
        hilog.info(PER_DOMAIN, PER_TAG, 'traits purged count=%{public}d banned=%{public}s',
          removed, banned.join(','));
      }
    } catch (e) {
      hilog.error(PER_DOMAIN, PER_TAG, 'purgeTraits failed: %{public}s', (e as Error).message);
    }
    return removed;
  }

  /** 只清偏好，不动聊天记录与情绪 */
  async clearTraits(): Promise<boolean> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return false;
    }
    try {
      await st.executeSql('DELETE FROM ' + TRAIT_TABLE);
      hilog.info(PER_DOMAIN, PER_TAG, 'traits cleared');
      return true;
    } catch (e) {
      hilog.error(PER_DOMAIN, PER_TAG, 'clearTraits failed: %{public}s', (e as Error).message);
      return false;
    }
  }

  /** 单行表：没有行就落一行 0.5 基线，保证读到的永远是确定值 */
  async loadEmotion(): Promise<EmotionState> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return defaultEmotion();
    }
    try {
      const rs: relationalStore.ResultSet = await st.querySql(
        'SELECT valence, arousal, intimacy, updated_at FROM ' + EMO_TABLE + ' WHERE id = 1');
      try {
        if (rs.goToFirstRow()) {
          const s: EmotionState = {
            valence: rs.getDouble(rs.getColumnIndex('valence')),
            arousal: rs.getDouble(rs.getColumnIndex('arousal')),
            intimacy: rs.getDouble(rs.getColumnIndex('intimacy')),
            updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
          };
          return s;
        }
      } finally {
        rs.close();
      }
      const base: EmotionState = defaultEmotion();
      await this.saveEmotion(base);
      return base;
    } catch (e) {
      hilog.error(PER_DOMAIN, PER_TAG, 'loadEmotion failed: %{public}s', (e as Error).message);
      return defaultEmotion();
    }
  }

  async saveEmotion(emo: EmotionState): Promise<boolean> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return false;
    }
    try {
      const args: Array<relationalStore.ValueType> = [emo.valence, emo.arousal, emo.intimacy,
        emo.updatedAt === 0 ? Date.now() : emo.updatedAt];
      await st.executeSql('INSERT OR REPLACE INTO ' + EMO_TABLE
        + ' (id, valence, arousal, intimacy, updated_at) VALUES (1, ?, ?, ?, ?)', args);
      return true;
    } catch (e) {
      hilog.error(PER_DOMAIN, PER_TAG, 'saveEmotion failed: %{public}s', (e as Error).message);
      return false;
    }
  }
}
