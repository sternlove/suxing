/**
 * 本地通知：主动搭话在 App 不在前台时投递到通知栏。
 *
 * 分工：
 *   本文件只管「通知」这一件事 —— 授权、wantAgent、publish、失败日志。
 *   什么时候发（前台/后台判定）、发什么内容，都由页面侧决定（Index.fireProactive）。
 *
 * 授权：本地通知不需要在 module.json5 声明 ohos.permission.NOTIFICATION_CONTROLLER
 * （那是系统应用权限），普通应用走 notificationManager.requestEnableNotification 让用户授权。
 * SDK 里已确认：requestEnableNotification(context: UIAbilityContext) 存在（@ohos.notificationManager.d.ts:799），
 * 拒绝时 Promise reject，code 1600004 = 用户未开启通知（我们在 catch 里静默降级并打日志）。
 */
import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent, Want, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';

/** 固定通知 id：同 id 覆盖上一条，不会堆一屏 */
export const NOTIFY_ID: number = 1001;
const BUNDLE_NAME: string = 'com.oviora.cybertwin';
const ABILITY_NAME: string = 'EntryAbility';
const NOTIFY_TITLE: string = '苏兴';

export class NotifyCenter {
  /** 最近一次读到的授权状态 */
  private granted: boolean = false;
  /** 已经读过一次状态（避免反复 isNotificationEnabled） */
  private probed: boolean = false;
  /** 是否已经弹过授权框：弹过就不再骚扰，用户拒绝后只在面板里显示未授权 */
  private asked: boolean = false;
  /** 点击通知拉起 App 的 WantAgent，只建一次（固定 requestCode，无需重建） */
  private agent: WantAgent | undefined = undefined;

  grantedNow(): boolean {
    return this.granted;
  }

  askedAlready(): boolean {
    return this.asked;
  }

  /** 只读授权状态，不弹窗 */
  async refresh(): Promise<boolean> {
    try {
      const on: boolean = await notificationManager.isNotificationEnabled();
      this.probed = true;
      if (on !== this.granted) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'notify enabled changed %{public}s -> %{public}s',
          '' + this.granted, '' + on);
      } else {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'notify enabled=%{public}s', '' + on);
      }
      this.granted = on;
      return on;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'notify isEnabled failed code=%{public}d msg=%{public}s',
        err.code, err.message);
      this.probed = true;
      this.granted = false;
      return false;
    }
  }

  /**
   * 首次发通知前请求授权。已经授权 → 直接 true；
   * 已经弹过框（用户拒过）→ 不再弹，返回当前状态（静默降级，只弹气泡）。
   * 只能在 App 可见时调用：系统授权框需要一个前台 UIAbilityContext。
   */
  async ensure(ctx: common.UIAbilityContext): Promise<boolean> {
    if (!this.probed) {
      await this.refresh();
    }
    if (this.granted) {
      return true;
    }
    if (this.asked) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'notify request skipped reason=already-asked granted=false');
      return false;
    }
    this.asked = true;
    try {
      await notificationManager.requestEnableNotification(ctx);
      this.granted = true;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'notify request granted by user');
      return true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      // 1600004 = 用户拒绝 / 通知未开启：这不是崩溃，降级成只弹气泡
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'notify request denied code=%{public}d msg=%{public}s -> degrade to bubble only',
        err.code, err.message);
      this.granted = false;
      return false;
    }
  }

  /** 点击通知 → 打开 App（wantAgent 指向 EntryAbility） */
  private async ensureAgent(): Promise<WantAgent | undefined> {
    if (this.agent !== undefined) {
      return this.agent;
    }
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: ABILITY_NAME
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      this.agent = await wantAgent.getWantAgent(info);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'notify wantAgent ready bundle=%{public}s ability=%{public}s',
        BUNDLE_NAME, ABILITY_NAME);
      return this.agent;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'notify wantAgent failed code=%{public}d msg=%{public}s',
        err.code, err.message);
      return undefined;
    }
  }

  /**
   * 发一条通知。正文不带 💭 前缀（气泡才带）。
   * 未授权时不再调用 requestEnableNotification（后台弹不出授权框），直接跳过并打日志。
   */
  async publish(body: string): Promise<boolean> {
    if (body === '') {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'notify publish skipped reason=empty-body');
      return false;
    }
    if (!this.probed) {
      await this.refresh();
    }
    if (!this.granted) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'notify publish skipped reason=not-granted chars=%{public}d',
        body.length);
      return false;
    }
    const agent: WantAgent | undefined = await this.ensureAgent();
    const request: notificationManager.NotificationRequest = {
      id: NOTIFY_ID,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: NOTIFY_TITLE,
          text: body
        }
      }
    };
    if (agent !== undefined) {
      request.wantAgent = agent;
    }
    try {
      await notificationManager.publish(request);
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'notify published id=%{public}d title=%{public}s chars=%{public}d tap=%{public}s',
        NOTIFY_ID, NOTIFY_TITLE, body.length, agent === undefined ? 'no-wantAgent' : 'start-ability');
      return true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'notify publish failed id=%{public}d code=%{public}d msg=%{public}s', NOTIFY_ID, err.code,
        err.message);
      return false;
    }
  }

  /** 面板「去开启」：重新走一次系统授权（用户可能在设置里手动开了，先读一次真状态） */
  async requestAgain(ctx: common.UIAbilityContext): Promise<boolean> {
    this.asked = false;
    this.probed = false;
    return await this.ensure(ctx);
  }
}
