/**
 * 语义动作：用户这句说什么 → 分身做个什么动作。
 *
 * 纯规则匹配（0.5B 判断不可靠），关键词表都在下面，增删改只动这几行。
 * 这里只产出「动作 + 原因」两个编码，不碰任何 3D 对象：
 * 页面把编码压进一个数字（reactionPing）传给 Avatar3D，视觉层自己决定怎么演。
 */

/** 动作类型：与 Avatar3D 里的 RXN_* 必须一致 */
export const RXN_NONE: number = 0;
export const RXN_WAVE: number = 1;
export const RXN_SIT: number = 2;
export const RXN_NOD: number = 3;

/** 触发原因编码：给 hilog 与状态条用 */
export const RSN_UNKNOWN: number = 0;
export const RSN_GREETING: number = 1;
export const RSN_TIRED: number = 2;
export const RSN_HAPPY: number = 3;
export const RSN_CONFUSED: number = 4;

export interface ReactionHit {
  kind: number;
  reason: number;
  word: string;
}

/** 问候类 → 挥手 */
const W_GREETING: string[] = [
  '你好', '您好', '嗨', '哈喽', '哈啰', '早上好', '早安', '中午好', '下午好', '晚上好',
  '在吗', '在不在', 'hello', 'hi', 'yo'
];

/** 疲惫类 → 坐下 */
const W_TIRED: string[] = [
  '累', '困', '睡', '休息', '下班', '乏', '疲惫', '心累', '熬夜', '撑不住', '不想动'
];

/** 负向明确类 → 点头（疑问/受挫） */
const W_NEGATIVE: string[] = [
  '不对', '不好', '不行', '失败', '报错', '错误', '坏了', '卡住', '没通过', '挂了', '崩了'
];

/** 开心类 → 挥手 */
const W_HAPPY: string[] = [
  '好棒', '太好了', '开心', '成功', '搞定', '通过', '漂亮', '厉害', '成了', '完美',
  '不错', '赞', '棒'
];

/** 疑惑类 → 停顿点头 */
const W_CONFUSED: string[] = [
  '为什么', '怎么', '咋', '如何', '啥意思', '不懂', '没懂', '什么情况'
];

function firstHit(text: string, words: string[]): string {
  for (let i = 0; i < words.length; i++) {
    if (text.indexOf(words[i]) >= 0) {
      return words[i];
    }
  }
  return '';
}

function pack(kind: number, reason: number, word: string): ReactionHit {
  const h: ReactionHit = { kind: kind, reason: reason, word: word };
  return h;
}

/**
 * 判定顺序即优先级：问候 > 疲惫 > 明确负向 > 开心 > 疑惑。
 * 「你好」先命中问候，不会被开心类的「好」抢走；「不好」「不对」先命中负向。
 */
export function matchReaction(text: string): ReactionHit | null {
  if (text === '') {
    return null;
  }
  const t: string = text.toLowerCase();
  let w: string = firstHit(t, W_GREETING);
  if (w !== '') {
    return pack(RXN_WAVE, RSN_GREETING, w);
  }
  w = firstHit(t, W_TIRED);
  if (w !== '') {
    return pack(RXN_SIT, RSN_TIRED, w);
  }
  w = firstHit(t, W_NEGATIVE);
  if (w !== '') {
    return pack(RXN_NOD, RSN_CONFUSED, w);
  }
  w = firstHit(t, W_HAPPY);
  if (w !== '') {
    return pack(RXN_WAVE, RSN_HAPPY, w);
  }
  w = firstHit(t, W_CONFUSED);
  if (w !== '') {
    return pack(RXN_NOD, RSN_CONFUSED, w);
  }
  return null;
}

export function rxnTriggerName(kind: number): string {
  if (kind === RXN_WAVE) {
    return 'wave';
  }
  if (kind === RXN_SIT) {
    return 'sit';
  }
  if (kind === RXN_NOD) {
    return 'nod';
  }
  return 'none';
}

export function rxnReasonName(code: number): string {
  if (code === RSN_GREETING) {
    return 'greeting';
  }
  if (code === RSN_TIRED) {
    return 'tired';
  }
  if (code === RSN_HAPPY) {
    return 'happy';
  }
  if (code === RSN_CONFUSED) {
    return 'confused';
  }
  return 'unknown';
}

/** 打包成 Avatar3D 认的单个数字：seq*100 + kind*10 + reason，避免两个 @Prop 的时序不确定 */
export function packReactionPing(seq: number, hit: ReactionHit): number {
  const ping: number = seq * 100 + hit.kind * 10 + hit.reason;
  return ping;
}
