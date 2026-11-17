import { systemShare } from '@kit.ShareKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { common, Want } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TWIN_DOMAIN, TWIN_TAG, WECHAT_BUNDLE, WECHAT_ENTRY } from './TwinProto';

/**
 * 发微信的两条落地路径（无障碍被 HOS 7.0 封死后的替代方案）。
 *
 * 路径 1：系统分享面板（ShareKit）。不可指定目标 App（ShareControllerOptions 只有
 *   appLaunchTrustInfo，那是企业受限权限），所以只能弹面板让用户点微信。
 * 路径 2：写剪贴板 + startAbility 拉起微信，用户长按粘贴。
 *
 * 所有函数失败一律 throw Error(message 带真实原因)，调用方负责写进气泡，绝不吞错。
 */

/** 纯文本 UTD（@ohos.data.uniformTypeDescriptor UniformDataType.PLAIN_TEXT） */
const UTD_PLAIN_TEXT: string = 'general.plain-text';
/** 文件型文本 UTD：微信 ChatShareAbility 只登记了 file scheme + general.text，纯文本对不上它 */
const UTD_TEXT: string = 'general.text';

function buildData(record: systemShare.SharedRecord): systemShare.SharedData {
  return new systemShare.SharedData(record);
}

/**
 * 弹分享面板。
 *
 * 注意：ShareController 的监听器必须在面板关闭后注销。之前每次分享都注册
 * shareCompleted / dismiss 两个回调却从不 off，反复分享会累积泄漏 controller 与闭包。
 */
async function showPanel(ctx: common.UIAbilityContext, data: systemShare.SharedData, what: string): Promise<void> {
  const controller: systemShare.ShareController = new systemShare.ShareController(data);
  const onDone = (r: systemShare.ShareOperationResult): void => {
    hilog.info(TWIN_DOMAIN, TWIN_TAG, 'share %{public}s completed target=%{public}s', what, r.targetAbilityInfo.name);
  };
  const onDismiss = (): void => {
    hilog.info(TWIN_DOMAIN, TWIN_TAG, 'share %{public}s panel dismissed', what);
  };
  controller.on('shareCompleted', onDone);
  controller.on('dismiss', onDismiss);
  const options: systemShare.ShareControllerOptions = {
    selectionMode: systemShare.SelectionMode.SINGLE,
    previewMode: systemShare.SharePreviewMode.DEFAULT
  };
  try {
    await controller.show(ctx, options);
  } finally {
    controller.off('shareCompleted', onDone);
    controller.off('dismiss', onDismiss);
  }
}

/**
 * 路径 1-a（通用）：把纯文本塞进系统分享面板，标题由调用方给。
 * 目标 App 无法指定（ShareControllerOptions 没有 bundleName/abilityName），面板里由用户点。
 */
export async function shareTextWithTitle(ctx: common.UIAbilityContext, text: string, title: string): Promise<void> {
  const record: systemShare.SharedRecord = {
    utd: UTD_PLAIN_TEXT,
    content: text,
    title: title,
    description: '由苏兴准备'
  };
  await showPanel(ctx, buildData(record), 'text');
  hilog.info(TWIN_DOMAIN, TWIN_TAG, 'share text panel shown title=[%{public}s] chars=%{public}d', title, text.length);
}

/** 路径 1-a：把纯文本塞进系统分享面板（旧签名保留：标题固定「发给<联系人>」） */
export async function sharePlainText(ctx: common.UIAbilityContext, text: string, contact: string): Promise<void> {
  await shareTextWithTitle(ctx, text, '发给' + contact);
}

/** 路径 1-b：把文本落成沙箱 .txt 再分享成文件（微信 ChatShareAbility 只吃 file scheme） */
export async function shareTextAsFile(ctx: common.UIAbilityContext, text: string, contact: string): Promise<string> {
  const dir: string = ctx.filesDir + '/share';
  try {
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir);
    }
  } catch (e) {
    hilog.warn(TWIN_DOMAIN, TWIN_TAG, 'mkdir %{public}s failed: %{public}s', dir, (e as Error).message);
  }
  const path: string = dir + '/wechat_text.txt';
  const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, text);
  } finally {
    fs.closeSync(file);
  }
  const uri: string = fileUri.getUriFromPath(path);
  const record: systemShare.SharedRecord = {
    utd: UTD_TEXT,
    uri: uri,
    title: '发给' + contact + '.txt',
    description: '由苏兴准备'
  };
  await showPanel(ctx, buildData(record), 'file');
  hilog.info(TWIN_DOMAIN, TWIN_TAG, 'share file panel shown uri=%{public}s', uri);
  return uri;
}

/** 路径 2 前半：写系统剪贴板 */
export async function copyText(text: string): Promise<void> {
  const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
  await pasteboard.getSystemPasteboard().setData(data);
  hilog.info(TWIN_DOMAIN, TWIN_TAG, 'pasteboard set chars=%{public}d', text.length);
}

/** 路径 2 后半：拉起微信（EntryAbility 已用 bm dump 实测存在） */
export async function launchWechat(ctx: common.UIAbilityContext): Promise<void> {
  const want: Want = { bundleName: WECHAT_BUNDLE, abilityName: WECHAT_ENTRY };
  await ctx.startAbility(want);
  hilog.info(TWIN_DOMAIN, TWIN_TAG, 'startAbility %{public}s/%{public}s ok', WECHAT_BUNDLE, WECHAT_ENTRY);
}
