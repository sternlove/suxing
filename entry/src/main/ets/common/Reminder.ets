/**
 * 后台主动搭话：系统级代理提醒。
 *
 * 为什么需要这个文件：
 *   Index.onPageHide() 会停掉前台定时器，App 退到后台后 JS 定时器被系统挂起，
 *   Proactive 的静默判定根本不会跑。想「App 不在前台时也能被苏兴搭话」，
 *   只能借系统的代理提醒（reminderAgentManager）：由系统在指定秒数后弹出通知，
 *   即使 App 已被回收也能触发。
 *
 * 与 Notify.ets 的分工：
 *   Notify.ets    普通通知，用于 App 仍在前台但窗口不可见的场景（当前未接入）。
 *   本文件        代理提醒，用于 App 在后台的场景，是「后台搭话」真正生效的路径。
 *
 * 权限：ohos.permission.PUBLISH_AGENT_REMINDER（已加进 module.json5）。
 *
 * 已知限制：后台跑不了 AI 生成，所以通知正文只能是预设模板（按时段挑一句）。
 *          这不是偷懒，是后台没有推理上下文的必然结果。
 */
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';

const BUNDLE: string = 'com.oviora.cybertwin';
const ABILITY: string = 'EntryAbility';
/** 通知栏里的标题 */
const TITLE: string = '苏兴';
/** 固定 notificationId：同 id 覆盖，不堆一屏 */
const NOTIFY_ID: number = 2001;

/** 后台搭话模板：后台没有上下文，按时段给一句最贴切的 */
interface Slot {
  from: number;
  to: number;
  lines: string[];
}

const SLOTS: Slot[] = [
  { from: 5, to: 9, lines: ['先生，早。今天有什么安排？', '先生，起来了？今天想先做哪件。'] },
  { from: 9, to: 12, lines: ['先生，上午过半了，还顺利吗？', '先生，忙到现在，要不要停一下。'] },
  { from: 12, to: 14, lines: ['先生，中午了，吃了吗？', '先生，该吃饭了。'] },
  { from: 14, to: 18, lines: ['先生，下午容易犯困，喝口水吧。', '先生，进展怎么样？'] },
  { from: 18, to: 23, lines: ['先生，忙完了吗？', '先生，晚上好，今天累不累？', '先生，今天那件事后来怎么样了？'] },
  { from: 23, to: 5, lines: ['先生，夜深了，早点休息。'] }
];

/** 按时段与序号取一句模板；hour 用本地时间 0-23 */
export function pickReminderLine(hour: number, seq: number): string {
  for (let i = 0; i < SLOTS.length; i++) {
    const s: Slot = SLOTS[i];
    const hit: boolean = s.from < s.to
      ? (hour >= s.from && hour < s.to)
      : (hour >= s.from || hour < s.to);
    if (hit && s.lines.length > 0) {
      return s.lines[seq % s.lines.length];
    }
  }
  return '先生，还在吗？';
}

export class ProactiveReminder {
  /** 已发布的提醒 id（-1 表示当前没有） */
  private reminderId: number = -1;
  /** 已预约的次数：只用于给模板轮换，避免每次后台都是同一句 */
  private seq: number = 0;
  /**
   * 平台不支持标记：实测 HOS 7.0 / API 26 上，三方应用即使
   * PUBLISH_AGENT_REMINDER 已授予、当前提醒数 0 条，
   * publishReminder 仍返回 1700002（ANS 日志 limit[0]，即配额为 0）。
   * 判定为平台限制后置位，后续不再重试，也不再刷日志。
   */
  private unavailable: boolean = false;

  has(): boolean {
    return this.reminderId >= 0;
  }

  /**
   * 预约一条代理提醒：delaySec 秒后由系统弹出。
   * 已有预约会先取消，保证同一时刻只有一条。
   */
  async schedule(delaySec: number, hour: number): Promise<boolean> {
    if (this.unavailable) {
      return false;
    }
    if (delaySec < 1) {
      delaySec = 1;
    }
    // 系统对单应用提醒数量有上限（实测超限返回 1700002）。
    // 本应用只有「后台搭话」这一类提醒，全部清掉再发最安全：
    // 既不会误删用户的东西，也保证配额永远只占 1 条。
    // 诊断：清理前后各有多少条，用来区分「配额满」和「清理没生效」
    try {
      const before: reminderAgentManager.ReminderRequest[] = await reminderAgentManager.getValidReminders();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'reminder before-clear count=%{public}d', before.length);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'reminder count failed: %{public}s', (e as BusinessError).message);
    }
    await this.clearAll();
    try {
      const after: reminderAgentManager.ReminderRequest[] = await reminderAgentManager.getValidReminders();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'reminder after-clear count=%{public}d', after.length);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'reminder count2 failed: %{public}s', (e as BusinessError).message);
    }
    const line: string = pickReminderLine(hour, this.seq);
    const req: reminderAgentManager.ReminderRequestTimer = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
      triggerTimeInSeconds: delaySec,
      title: TITLE,
      content: line,
      expiredContent: line,
      notificationId: NOTIFY_ID,
      slotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      wantAgent: { pkgName: BUNDLE, abilityName: ABILITY },
      // 不要铃声、不要重复提醒：它是搭话，不是闹钟
      ringDuration: 0,
      snoozeTimes: 0,
      tapDismissed: true
    };
    try {
      const id: number = await reminderAgentManager.publishReminder(req);
      this.reminderId = id;
      this.seq = (this.seq + 1) % 97;
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'reminder scheduled id=%{public}d in=%{public}ds hour=%{public}d text=[%{public}s]',
        id, delaySec, hour, line);
      return true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      this.reminderId = -1;
      if (err.code === 1700002) {
        // 配额为 0：平台限制，不是我们写错，之后不再尝试也不刷日志
        this.unavailable = true;
        hilog.warn(LOG_DOMAIN, LOG_TAG,
          'reminder unavailable on this platform code=%{public}d (quota=0 for third-party) -> keep bubble-only',
          err.code);
      } else {
        hilog.error(LOG_DOMAIN, LOG_TAG,
          'reminder publish failed code=%{public}d msg=%{public}s',
          err.code, err.message);
      }
      return false;
    }
  }

  /** 清空本应用所有遗留提醒：防止历史测试残留把配额占满（1700002） */
  private async clearAll(): Promise<void> {
    try {
      await reminderAgentManager.cancelAllReminders();
      this.reminderId = -1;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      // 清理失败不阻断发布：下面 publishReminder 失败会给出真实原因
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'reminder clearAll failed code=%{public}d msg=%{public}s',
        err.code, err.message);
    }
  }

  /** 取消当前预约（用户回到前台时调用） */
  async cancel(): Promise<void> {
    if (this.reminderId < 0) {
      return;
    }
    const id: number = this.reminderId;
    this.reminderId = -1;
    try {
      await reminderAgentManager.cancelReminder(id);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'reminder cancelled id=%{public}d', id);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      // 取消失败不影响主流程：提醒最多多弹一次
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'reminder cancel failed id=%{public}d code=%{public}d',
        id, err.code);
    }
  }
}
