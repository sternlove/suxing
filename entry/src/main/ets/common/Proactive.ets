/**
 * 主动搭话：久没聊天时由分身先开口。
 *
 * 本文件只放「纯逻辑」——闸门判定、模板、prompt 拼装、回复清洗。
 * 定时器、UI 气泡、TTS、落库都在页面侧，这里不碰任何 Kit，
 * 这样每条规则都能被日志逐条证明，也便于单独推敲参数。
 *
 * 规则（用户已定）：
 *   静默触发   距最后一次交互 ≥ PROACTIVE_IDLE_MS
 *   频率上限   每小时最多 PROACTIVE_MAX_PER_HOUR 次
 *   深夜静默   PROACTIVE_QUIET_FROM 点到次日 PROACTIVE_QUIET_TO 点不主动
 *   冷却       上次搭话后用户没回应，不连续再搭
 *   去重       不重复最近 PROACTIVE_RECENT_KEEP 次搭话内容
 */

/** 检查间隔：30 秒一次（够准，又不会把定时器压得太密） */
export const PROACTIVE_TICK_MS: number = 30000;
/** 静默触发阈值：10 分钟 */
export const PROACTIVE_IDLE_MS: number = 10 * 60 * 1000;
/** 每小时最多主动 2 次 */
export const PROACTIVE_MAX_PER_HOUR: number = 2;
/** 深夜静默起点（含）：23 点 */
export const PROACTIVE_QUIET_FROM: number = 23;
/** 深夜静默终点（不含）：7 点 */
export const PROACTIVE_QUIET_TO: number = 7;
/** 本地模型生成超时：超过就降级到规则模板，别让用户干等 */
export const PROACTIVE_LLM_TIMEOUT_MS: number = 3000;
/** 去重窗口：最近 3 次搭话内容 */
export const PROACTIVE_RECENT_KEEP: number = 3;
/** 气泡前缀（主动消息一眼可辨） */
export const PROACTIVE_BUBBLE_PREFIX: string = '💭 ';
/** 主动消息正文长度上限（一句话就够，本地模型爱啰嗦） */
export const PROACTIVE_TEXT_MAX: number = 30;
/**
 * 小时注入点：>=0 时用这个值代替真实本地小时判「深夜」，
 * 用于在不能改系统时间的真机上验证 23-7 分支会跳过。
 * 生产值必须是 -1（用真实本地时间）。
 */
export const PROACTIVE_DEBUG_HOUR: number = -1;

/** 当前生效的「现在几点」（0-23）：有注入用注入，否则用本地时间 */
export function effectiveHour(now: number): number {
  if (PROACTIVE_DEBUG_HOUR >= 0 && PROACTIVE_DEBUG_HOUR <= 23) {
    return PROACTIVE_DEBUG_HOUR;
  }
  return new Date(now).getHours();
}

/** 深夜静默：23:00-24:00 与 00:00-07:00 */
export function isQuietHour(hour: number): boolean {
  if (hour < 0 || hour > 23) {
    return false;
  }
  return hour >= PROACTIVE_QUIET_FROM || hour < PROACTIVE_QUIET_TO;
}

/** 时段名：只用于 prompt 里的时间提示与模板分组 */
export function periodName(hour: number): string {
  if (hour >= 23 || hour < 5) {
    return '深夜';
  }
  if (hour < 8) {
    return '清晨';
  }
  if (hour < 11) {
    return '上午';
  }
  if (hour < 13) {
    return '中午';
  }
  if (hour < 18) {
    return '下午';
  }
  return '傍晚';
}

/** 闸门判定结果：reason 直接进日志，失败原因不许含糊 */
export interface ProactiveGate {
  idleSec: number;
  /** 静默时长已经够了（只是可能被其余规则挡住） */
  idleReady: boolean;
  allowed: boolean;
  reason: string;
}

/** 规则模板：按时段问候。深夜/清晨段落在静默窗口内，实际不会触发，留着是为了 prompt 的时段说明不断档。 */
const TPL_DEEP_NIGHT: string[] = [
  '先生，夜深了，早点休息。',
  '先生，这么晚还没睡？',
  '先生，夜里凉，别熬太狠。'
];
const TPL_EARLY: string[] = [
  '先生，早上好。',
  '先生，早，今天也一起。'
];
const TPL_MORNING: string[] = [
  '先生，忙完了？',
  '先生，手头的事还顺利吗？',
  '先生，忙了一阵了，歇口气？'
];
const TPL_NOON: string[] = [
  '先生，该吃午饭了。',
  '先生，中午了，别饿着。'
];
const TPL_AFTERNOON: string[] = [
  '先生，下午好。',
  '先生，忙了一下午，喝口水吧？',
  '先生，还在忙？'
];
const TPL_EVENING: string[] = [
  '先生，忙完了吗？',
  '先生，晚上好，今天累不累？',
  '先生，我在这儿呢。'
];

/** 该时段的模板候选（顺序固定，便于真机复现） */
export function templatesFor(hour: number): string[] {
  if (hour >= 23 || hour < 5) {
    return TPL_DEEP_NIGHT;
  }
  if (hour < 8) {
    return TPL_EARLY;
  }
  if (hour < 11) {
    return TPL_MORNING;
  }
  if (hour < 13) {
    return TPL_NOON;
  }
  if (hour < 18) {
    return TPL_AFTERNOON;
  }
  return TPL_EVENING;
}

function normKey(t: string): string {
  return t.split(' ').join('').split('\n').join('').trim();
}

/**
 * 搭话状态机：只记数字，不发通知、不起定时器、不碰 UI。
 * 每次交互（用户发消息/点输入框/按麦克风）调 touch()，一次搭话成功调 markFired()。
 */
export class ProactiveTracker {
  private lastTs: number = 0;
  private bucket: number = -1;
  private fires: number = 0;
  private dayKey: string = '';
  private today: number = 0;
  private awaiting: boolean = false;
  private recent: string[] = [];

  /** 启动/回到前台：把「最后一次交互」设成现在，避免一进前台就搭话 */
  reset(now: number): void {
    this.lastTs = now;
    this.awaiting = false;
  }

  /** 用户有任何交互：静默计时归零，同时解除上一次搭话的冷却 */
  touch(now: number): void {
    this.lastTs = now;
    this.awaiting = false;
  }

  lastInteraction(): number {
    return this.lastTs;
  }

  /** 上次搭话后用户还没回应 */
  waitingReply(): boolean {
    return this.awaiting;
  }

  private rollHour(now: number): void {
    const b: number = Math.floor(now / 3600000);
    if (b !== this.bucket) {
      this.bucket = b;
      this.fires = 0;
    }
  }

  private rollDay(now: number): void {
    const d: Date = new Date(now);
    const key: string = '' + d.getFullYear() + '-' + (d.getMonth() + 1) + '-' + d.getDate();
    if (key !== this.dayKey) {
      this.dayKey = key;
      this.today = 0;
    }
  }

  /** 本小时已搭话次数 */
  hourCount(now: number): number {
    this.rollHour(now);
    return this.fires;
  }

  /** 今日已搭话次数（日志里的 count） */
  todayCount(now: number): number {
    this.rollDay(now);
    return this.today;
  }

  /** 判定这一次该不该搭话；reason 原样进 hilog */
  check(now: number, hour: number): ProactiveGate {
    const gate: ProactiveGate = {
      idleSec: 0,
      idleReady: false,
      allowed: false,
      reason: 'idle'
    };
    if (this.lastTs <= 0) {
      gate.reason = 'no-touch';
      return gate;
    }
    const idleMs: number = now - this.lastTs;
    gate.idleSec = idleMs > 0 ? Math.floor(idleMs / 1000) : 0;
    if (idleMs < PROACTIVE_IDLE_MS) {
      gate.reason = 'idle';
      return gate;
    }
    gate.idleReady = true;
    this.rollHour(now);
    this.rollDay(now);
    if (isQuietHour(hour)) {
      gate.reason = 'quiet';
      return gate;
    }
    if (this.fires >= PROACTIVE_MAX_PER_HOUR) {
      gate.reason = 'hourly';
      return gate;
    }
    if (this.awaiting) {
      gate.reason = 'cooldown';
      return gate;
    }
    gate.allowed = true;
    gate.reason = 'ok';
    return gate;
  }

  /** 记一次成功搭话：占用本小时次数、置冷却、进去重窗口 */
  markFired(now: number, text: string): void {
    this.rollHour(now);
    this.rollDay(now);
    this.fires = this.fires + 1;
    this.today = this.today + 1;
    this.awaiting = true;
    const key: string = normKey(text);
    this.recent.unshift(key);
    while (this.recent.length > PROACTIVE_RECENT_KEEP) {
      this.recent.pop();
    }
  }

  /** 是否与最近 3 次重复 */
  isDup(text: string): boolean {
    const key: string = normKey(text);
    if (key === '') {
      return true;
    }
    for (const r of this.recent) {
      if (r === key) {
        return true;
      }
    }
    return false;
  }

  /** 该时段模板里第一个没在去重窗口内的（全被挡就返回空串） */
  pickTemplate(hour: number): string {
    const pool: string[] = templatesFor(hour);
    for (const t of pool) {
      if (!this.isDup(t)) {
        return t;
      }
    }
    return '';
  }

  recentTexts(): string[] {
    return this.recent.slice();
  }

  /** 面板/日志用：一眼看清当前计数 */
  debugLine(now: number): string {
    this.rollHour(now);
    this.rollDay(now);
    return 'idle=' + Math.floor((now - this.lastTs) / 1000) + 's hour=' + effectiveHour(now)
      + ' fires/hour=' + this.fires + '/' + PROACTIVE_MAX_PER_HOUR + ' today=' + this.today
      + ' awaiting=' + (this.awaiting ? '1' : '0') + ' dupPool=' + this.recent.length;
  }
}

/**
 * 主动搭话的 ChatML prompt：人格 prompt + 当前时段 + 最近话题 + 静默时长。
 * 以 assistant 开头收尾，模型接着写第一句就是「主动开口」。
 * /no_think 放在最后一条 user 上，压掉 Qwen3 的思考链。
 */
export function buildProactivePrompt(sysPrompt: string, topic: string, idleSec: number,
                                    hour: number): string {
  const mins: number = idleSec / 60 < 1 ? 1 : Math.floor(idleSec / 60);
  const clock: string = (hour < 10 ? '0' + hour : '' + hour) + ':00';
  const hint: string = '现在是' + clock + '（' + periodName(hour) + '），先生已经 ' + mins + ' 分钟没说话了。';
  const sys: string = (sysPrompt === '' ? '' : sysPrompt + '\n')
    + hint + '你要主动先开口对先生说一句。\n'
    + '要求：只说一句中文，不超过 20 个字；不解释、不用括号写动作、不复述先生说过的话。';
  const topicLine: string = topic === ''
    ? '先生最近没聊什么具体的事。'
    : '先生最近提到的是「' + topic + '」。';
  return '<|im_start|>system\n' + sys + '<|im_end|>\n'
    + '<|im_start|>user\n' + topicLine + '你先开个口。/no_think<|im_end|>\n'
    + '<|im_start|>assistant\n';
}

/**
 * 模型回复清洗：压成一行、去掉引号与括号动作、只留第一句、按 PROACTIVE_TEXT_MAX 截断。
 * stripThink 由调用方先做（那是页面侧的既有纯函数），这里不重复实现。
 */
export function cleanProactive(raw: string): string {
  let s: string = raw.split('\r').join('').split('\n').join(' ').trim();
  s = s.replace(/（[^）]*）/g, '');
  s = s.replace(/\([^)]*\)/g, '');
  s = s.replace(/^[\s"'“”‘’「」『』、,，:：]+/, '');
  s = s.replace(/[\s"'“”‘’「」『』、,，:：]+$/, '');
  // 只留第一句：句号/问号/感叹号之后的内容一律不要，但句末标点本身保留
  const stop: RegExp = /[。！？!?]/;
  const m: RegExpMatchArray | null = s.match(stop);
  if (m !== null && m.index !== undefined && m.index > 0) {
    s = s.substring(0, m.index + 1);
  }
  s = s.trim();
  if (s.length > PROACTIVE_TEXT_MAX) {
    s = s.substring(0, PROACTIVE_TEXT_MAX);
  }
  return s;
}
