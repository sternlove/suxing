/**
 * 桌面小组件的数据桥：App 侧写、卡片侧读、App 主动推刷新。
 *
 * 为什么用两个纯文本文件而不是 preferences：
 *   FormExtensionAbility 与 UIAbility 不在同一个进程，preferences 是按进程缓存的实例，
 *   跨进程读到旧值（新增卡片后 App 读不到新 formId）。文件每次重新读，没有缓存问题，
 *   两个进程共享同一个应用沙箱（filesDir），读写都在这一个目录里。
 *
 * 文件格式（故意用行文本，避免 JSON 解析在 ArkTS 严格模式下的类型麻烦）：
 *   card_data.txt   第 1 行 face（表情），第 2 行 snippet（最近消息前 20 字），第 3 行 status（状态行）
 *   card_forms.txt  一行一个 formId（系统分配的卡片实例 id）
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';

export const CARD_DATA_FILE: string = 'card_data.txt';
export const CARD_FORMS_FILE: string = 'card_forms.txt';
/** 卡片正文长度上限：超出截断加省略号 */
export const CARD_SNIPPET_MAX: number = 20;
/** 气泡前缀（💭 ）在卡片上不要重复出现 */
const BUBBLE_PREFIX: string = '💭 ';

export interface CardData {
  face: string;
  snippet: string;
  status: string;
}

/** 默认数据：卡片刚加进桌面、App 还没写过任何东西时的占位 */
export function defaultCardData(): CardData {
  const d: CardData = {
    face: '😐',
    snippet: '还没有对话，点开聊聊',
    status: '💭 主动搭话开启'
  };
  return d;
}

/** 最近一条消息 → 卡片正文：去前缀、压成一行、超 20 字截断加省略号 */
export function cardSnippet(raw: string): string {
  let s: string = raw.split('\r').join('').split('\n').join(' ').trim();
  if (s.indexOf(BUBBLE_PREFIX) === 0) {
    s = s.substring(BUBBLE_PREFIX.length).trim();
  }
  s = s.split(BUBBLE_PREFIX).join('');
  if (s.length <= CARD_SNIPPET_MAX) {
    return s;
  }
  return s.substring(0, CARD_SNIPPET_MAX) + '…';
}

function dataPath(filesDir: string): string {
  return filesDir + '/' + CARD_DATA_FILE;
}

function formsPath(filesDir: string): string {
  return filesDir + '/' + CARD_FORMS_FILE;
}

function readAll(path: string): string {
  try {
    return fs.readTextSync(path);
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'card read miss path=%{public}s code=%{public}d', path, err.code);
    return '';
  }
}

function writeAll(path: string, text: string): boolean {
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, text);
    fs.closeSync(f);
    return true;
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    hilog.error(LOG_DOMAIN, LOG_TAG, 'card write failed path=%{public}s code=%{public}d msg=%{public}s',
      path, err.code, err.message);
    return false;
  }
}

/** 读卡片数据；文件不存在/损坏 → 默认值 */
export function readCardData(filesDir: string): CardData {
  const raw: string = readAll(dataPath(filesDir));
  if (raw === '') {
    return defaultCardData();
  }
  const parts: string[] = raw.split('\n');
  const d: CardData = defaultCardData();
  if (parts.length > 0 && parts[0].trim() !== '') {
    d.face = parts[0].trim();
  }
  if (parts.length > 1 && parts[1].trim() !== '') {
    d.snippet = parts[1].trim();
  }
  if (parts.length > 2 && parts[2].trim() !== '') {
    d.status = parts[2].trim();
  }
  return d;
}

export function writeCardData(filesDir: string, d: CardData): boolean {
  const text: string = d.face + '\n' + d.snippet + '\n' + d.status + '\n';
  return writeAll(dataPath(filesDir), text);
}

/** 已登记的卡片实例 id */
export function readFormIds(filesDir: string): string[] {
  const raw: string = readAll(formsPath(filesDir));
  const out: string[] = [];
  if (raw === '') {
    return out;
  }
  for (const line of raw.split('\n')) {
    const id: string = line.trim();
    if (id !== '' && out.indexOf(id) < 0) {
      out.push(id);
    }
  }
  return out;
}

export function writeFormIds(filesDir: string, ids: string[]): void {
  writeAll(formsPath(filesDir), ids.join('\n') + (ids.length > 0 ? '\n' : ''));
}

/** 卡片被添加到桌面：登记 formId（卡片侧进程调用） */
export function registerForm(filesDir: string, formId: string): void {
  if (formId === '') {
    return;
  }
  const ids: string[] = readFormIds(filesDir);
  if (ids.indexOf(formId) >= 0) {
    return;
  }
  ids.push(formId);
  writeFormIds(filesDir, ids);
  hilog.info(LOG_DOMAIN, LOG_TAG, 'card register formId=%{public}s total=%{public}d', formId,
    ids.length);
}

/** 卡片被移除：注销 formId */
export function unregisterForm(filesDir: string, formId: string): void {
  const ids: string[] = readFormIds(filesDir);
  const next: string[] = [];
  for (const id of ids) {
    if (id !== formId) {
      next.push(id);
    }
  }
  writeFormIds(filesDir, next);
  hilog.info(LOG_DOMAIN, LOG_TAG, 'card unregister formId=%{public}s left=%{public}d', formId,
    next.length);
}

/** CardData → 卡片 LocalStorage 的绑定数据（键名与 Card01.ets 的 @LocalStorageProp 一一对应） */
export function bindingOf(d: CardData): formBindingData.FormBindingData {
  const obj: Record<string, string> = {
    'face': d.face,
    'snippet': d.snippet,
    'status': d.status
  };
  return formBindingData.createFormBindingData(obj);
}

/** App 侧调用：把数据推给所有已登记卡片，返回刷新成功的卡片数 */
export async function pushCard(filesDir: string, d: CardData): Promise<number> {
  const ids: string[] = readFormIds(filesDir);
  if (ids.length === 0) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'card push skipped reason=no-form forms=0');
    return 0;
  }
  let ok: number = 0;
  for (const id of ids) {
    try {
      await formProvider.updateForm(id, bindingOf(d));
      ok++;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'card updateForm ok formId=%{public}s face=%{public}s snippet=[%{public}s]',
        id, d.face, d.snippet);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'card updateForm failed formId=%{public}s code=%{public}d msg=%{public}s', id, err.code,
        err.message);
    }
  }
  return ok;
}
