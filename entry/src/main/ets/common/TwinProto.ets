import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 无障碍扩展跑在**独立进程**里，UI 进程拿不到 AccessibilityExtensionContext。
 * 所以两个进程只靠应用级沙箱目录下的两个 JSON 文件通信：
 *   twin_cmd.json     UI -> 扩展   一条指令
 *   twin_status.json  扩展 -> UI   进度 / 读屏结果
 * 用 getApplicationContext().filesDir（应用级目录），两个进程拿到的路径必然一致。
 */
export const TWIN_DOMAIN: number = 0xC0DE;
export const TWIN_TAG: string = 'CyberTwin';
export const CMD_FILE: string = 'twin_cmd.json';
export const STATUS_FILE: string = 'twin_status.json';

/** 自动发微信：只允许发给文件传输助手（发给自己），绝不发给别人 */
/** 微信鸿蒙版真实包名（bm dump 实测存在，mainAbility = EntryAbility）；com.tencent.imahm 是腾讯 ima，别再写错 */
export const WECHAT_BUNDLE: string = 'com.tencent.wechat';
export const WECHAT_ENTRY: string = 'EntryAbility';
export const WECHAT_CONTACT: string = '文件传输助手';
export const WECHAT_MSG: string = '这是分身自动发的第一条消息';

/** 对话即指令（旧版微信专用）：保留导出，老引用不报错 */
export interface WechatIntent {
  contact: string;
  message: string;
}

/** 可分享应用：name 是展示名（进正则交替），aliases 是用户口语，bundle 是真机 bm dump 实测包名 */
export interface SendApp {
  name: string;
  bundle: string;
  aliases: string[];
}

/**
 * 顺序敏感：正则交替串按词长降序拼接，但同名开头的短词仍可能抢先命中，
 * 所以「QQ邮箱」必须排在「QQ」之前——否则「给QQ邮箱张三发消息」会被解析成
 * app=QQ、contact=邮箱张三（真机实测过）。
 */
export const SEND_APPS: SendApp[] = [
  { name: '微信', bundle: 'com.tencent.wechat', aliases: ['微信'] },
  { name: '企业微信', bundle: 'com.tencent.wework.hmos', aliases: ['企业微信'] },
  { name: 'QQ邮箱', bundle: 'com.tencent.qqmail.hmos', aliases: ['QQ邮箱', 'qq邮箱'] },
  { name: 'QQ', bundle: 'com.tencent.mqq', aliases: ['QQ', 'qq'] },
  { name: '邮箱', bundle: 'com.huawei.hmos.email', aliases: ['邮件', '邮箱'] },
  { name: '备忘录', bundle: 'com.huawei.hmos.notepad', aliases: ['备忘录', '笔记'] },
  { name: '飞书', bundle: 'com.ss.feishu', aliases: ['飞书'] }
];

/** 一条通用发送意图；app/bundle 为空 = 未指定目标应用（弹分享面板让用户选） */
export interface SendIntent {
  app: string;
  bundle: string;
  contact: string;
  message: string;
}

export function findSendApp(word: string): SendApp | undefined {
  const w: string = word.trim().toLowerCase();
  if (w === '') {
    return undefined;
  }
  for (let i = 0; i < SEND_APPS.length; i++) {
    const a: SendApp = SEND_APPS[i];
    if (a.name.toLowerCase() === w) {
      return a;
    }
    for (let j = 0; j < a.aliases.length; j++) {
      if (a.aliases[j].toLowerCase() === w) {
        return a;
      }
    }
  }
  return undefined;
}

/** 交替串：长词优先，保证「企业微信」「备忘录」先于「微信」「笔记」命中 */
function buildAppAlternation(): string {
  const words: string[] = [];
  for (let i = 0; i < SEND_APPS.length; i++) {
    const a: SendApp = SEND_APPS[i];
    if (words.indexOf(a.name) < 0) {
      words.push(a.name);
    }
    for (let j = 0; j < a.aliases.length; j++) {
      if (words.indexOf(a.aliases[j]) < 0) {
        words.push(a.aliases[j]);
      }
    }
  }
  words.sort((x: string, y: string) => y.length - x.length);
  return words.join('|');
}

const APP: string = buildAppAlternation();
const SEO: string = '[：:，,、\\s]*';
const SEP: string = '[：:，,、\\s]+';

/* 句式表（全部锚定开头，避免普通聊天误命中） */
/* 给微信张三发消息：明天见 */
const RE_GIVE_APP: RegExp = new RegExp('^给(' + APP + ')\\s*(.+?)\\s*(?:发消息|发送消息|发)' + SEO + '(.+)$', 'i');
/* 用QQ发给李四：文件收到了 */
const RE_USE_APP: RegExp = new RegExp('^用(' + APP + ')发给' + SEO + '(.+?)' + SEP + '(.+)$', 'i');
/* 发微信给张三：明天见 */
const RE_SEND_APP_TO: RegExp = new RegExp('^发(' + APP + ')给' + SEO + '(.+?)' + SEP + '(.+)$', 'i');
/* 微信发消息给张三 明天见 */
const RE_APP_MSG_TO: RegExp = new RegExp('^(' + APP + ')发消息给' + SEO + '(.+?)' + SEP + '(.+)$', 'i');
/* 张三微信说明天见 */
const RE_CONTACT_APP_SAY: RegExp = new RegExp('^(.+?)(' + APP + ')说' + SEO + '(.+)$', 'i');
/* 分享到备忘录：今天的想法（无收件人） */
const RE_SHARE_TO: RegExp = new RegExp('^分享到(' + APP + ')' + SEO + '(.+)$', 'i');
/* 把这段发到飞书（无收件人） */
const RE_PUT_TO: RegExp = new RegExp('^把(.+?)发到(' + APP + ')\\s*$', 'i');
/* 发给王五：晚点到（未指定 App）*/
const RE_GIVE_PLAIN: RegExp = new RegExp('^发给\\s*(.+?)\\s*[：:]\\s*(.+)$', 'i');

function buildIntent(raw: string, appWord: string, contactRaw: string, messageRaw: string): SendIntent | undefined {
  const message: string = messageRaw.trim();
  if (message === '') {
    return undefined;
  }
  let app: string = '';
  let bundle: string = '';
  const word: string = appWord === undefined ? '' : appWord.trim();
  if (word !== '') {
    const hit: SendApp | undefined = findSendApp(word);
    if (hit === undefined) {
      return undefined;
    }
    app = hit.name;
    bundle = hit.bundle;
  }
  const contact: string = contactRaw === undefined ? '' : contactRaw.trim();
  const intent: SendIntent = { app: app, bundle: bundle, contact: contact, message: message };
  hilog.info(TWIN_DOMAIN, TWIN_TAG,
    'parseSendCommand hit in=[%{public}s] app=[%{public}s] bundle=[%{public}s] contact=[%{public}s] msg=[%{public}s]',
    raw, intent.app, intent.bundle, intent.contact, intent.message);
  return intent;
}

/**
 * 本地规则解析「对话即指令 · 通用发送」。不依赖模型：0.5B 本地模型做意图识别不稳定，正则更靠得住。
 * 命中返回 SendIntent，未命中返回 undefined（走普通聊天）。
 * 支持（<App> 取自 SEND_APPS，可增删表项即扩展）：
 *   给<App><收件人>发消息：<内容>      给微信张三发消息：明天见
 *   给<App><收件人>发：<内容>          发<App>给<收件人>：<内容>
 *   <App>发消息给<收件人> <内容>        <收件人><App>说<内容>
 *   用<App>发给<收件人>：<内容>         分享到<App>：<内容>（无收件人）
 *   把<内容>发到<App>（无收件人）       发给<收件人>：<内容>（未指定 App）
 * 分隔符：中文/英文冒号、逗号、顿号、空格皆可；内容里的中文标点原样保留。
 */
export function parseSendCommand(text: string): SendIntent | undefined {
  const raw: string = text.trim();
  if (raw === '') {
    return undefined;
  }
  let m: RegExpMatchArray | null = raw.match(RE_GIVE_APP);
  if (m !== null) {
    const a: SendIntent | undefined = buildIntent(raw, m[1], m[2], m[3]);
    if (a !== undefined) {
      return a;
    }
  }
  m = raw.match(RE_USE_APP);
  if (m !== null) {
    const a: SendIntent | undefined = buildIntent(raw, m[1], m[2], m[3]);
    if (a !== undefined) {
      return a;
    }
  }
  m = raw.match(RE_SEND_APP_TO);
  if (m !== null) {
    const a: SendIntent | undefined = buildIntent(raw, m[1], m[2], m[3]);
    if (a !== undefined) {
      return a;
    }
  }
  m = raw.match(RE_APP_MSG_TO);
  if (m !== null) {
    const a: SendIntent | undefined = buildIntent(raw, m[1], m[2], m[3]);
    if (a !== undefined) {
      return a;
    }
  }
  m = raw.match(RE_CONTACT_APP_SAY);
  if (m !== null) {
    const a: SendIntent | undefined = buildIntent(raw, m[2], m[1], m[3]);
    if (a !== undefined) {
      return a;
    }
  }
  m = raw.match(RE_SHARE_TO);
  if (m !== null) {
    const a: SendIntent | undefined = buildIntent(raw, m[1], '', m[2]);
    if (a !== undefined) {
      return a;
    }
  }
  m = raw.match(RE_PUT_TO);
  if (m !== null) {
    const a: SendIntent | undefined = buildIntent(raw, m[2], '', m[1]);
    if (a !== undefined) {
      return a;
    }
  }
  m = raw.match(RE_GIVE_PLAIN);
  if (m !== null) {
    const a: SendIntent | undefined = buildIntent(raw, '', m[1], m[2]);
    if (a !== undefined) {
      return a;
    }
  }
  hilog.info(TWIN_DOMAIN, TWIN_TAG, 'parseSendCommand miss in=[%{public}s]', raw);
  return undefined;
}

/** 旧接口：行为不变（只认微信、必须有收件人），内部复用通用解析 */
export function parseWechatCommand(text: string): WechatIntent | undefined {
  const it: SendIntent | undefined = parseSendCommand(text);
  if (it === undefined || it.app !== '微信' || it.contact === '') {
    return undefined;
  }
  const old: WechatIntent = { contact: it.contact, message: it.message };
  return old;
}

export interface TwinCmd {
  id: number;
  op: string;
  text: string;
  msg: string;
}

export interface TwinStatus {
  id: number;
  op: string;
  state: string;
  step: number;
  steps: string[];
  bundle: string;
  texts: string[];
  ts: number;
}

export function emptyStatus(): TwinStatus {
  const st: TwinStatus = {
    id: -1,
    op: '',
    state: 'idle',
    step: 0,
    steps: [],
    bundle: '',
    texts: [],
    ts: 0
  };
  return st;
}

export function joinPath(dir: string, name: string): string {
  return dir + '/' + name;
}

export function fileExists(p: string): boolean {
  try {
    return fs.accessSync(p);
  } catch (e) {
    return false;
  }
}

export function readTextFile(p: string): string {
  try {
    if (!fs.accessSync(p)) {
      return '';
    }
    return fs.readTextSync(p);
  } catch (e) {
    return '';
  }
}

export function writeTextFile(p: string, data: string): void {
  try {
    const f: fs.File = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, data);
    } finally {
      fs.closeSync(f);
    }
  } catch (e) {
    hilog.error(TWIN_DOMAIN, TWIN_TAG, 'writeFile %{public}s failed: %{public}s', p, (e as Error).message);
  }
}

export function removeFile(p: string): void {
  try {
    if (fs.accessSync(p)) {
      fs.unlinkSync(p);
    }
  } catch (e) {
    hilog.error(TWIN_DOMAIN, TWIN_TAG, 'unlink %{public}s failed: %{public}s', p, (e as Error).message);
  }
}

export function parseCmd(raw: string): TwinCmd | undefined {
  if (raw === '') {
    return undefined;
  }
  try {
    const o = JSON.parse(raw) as TwinCmd;
    if (typeof o.id !== 'number') {
      return undefined;
    }
    const cmd: TwinCmd = {
      id: o.id,
      op: typeof o.op === 'string' ? o.op : '',
      text: typeof o.text === 'string' ? o.text : '',
      msg: typeof o.msg === 'string' ? o.msg : ''
    };
    return cmd;
  } catch (e) {
    hilog.error(TWIN_DOMAIN, TWIN_TAG, 'parseCmd failed: %{public}s', (e as Error).message);
    return undefined;
  }
}

export function parseStatus(raw: string): TwinStatus | undefined {
  if (raw === '') {
    return undefined;
  }
  try {
    const o = JSON.parse(raw) as TwinStatus;
    const st = emptyStatus();
    st.id = typeof o.id === 'number' ? o.id : -1;
    st.op = typeof o.op === 'string' ? o.op : '';
    st.state = typeof o.state === 'string' ? o.state : '';
    st.step = typeof o.step === 'number' ? o.step : 0;
    st.bundle = typeof o.bundle === 'string' ? o.bundle : '';
    st.ts = typeof o.ts === 'number' ? o.ts : 0;
    if (Array.isArray(o.steps)) {
      st.steps = o.steps;
    }
    if (Array.isArray(o.texts)) {
      st.texts = o.texts;
    }
    return st;
  } catch (e) {
    return undefined;
  }
}

export function statusToJson(st: TwinStatus): string {
  return JSON.stringify(st);
}