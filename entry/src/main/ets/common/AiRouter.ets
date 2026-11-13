import { connection } from '@kit.NetworkKit';
import { CloudError } from './CloudApi';

/**
 * 端云双模路由。和 Android 版保持同一套优先级，
 * 两个版本的对话行为必须一致，否则用户会困惑。
 *
 * 降级链（单向、逐档、可观测）：
 *   云端 CLOUD → 本地 LOCAL → 词库 FALLBACK
 * 上一档因任何错误（含超时）失败都必须落到下一档，不允许吞掉异常返回空。
 */
export enum RouteMode {
  CLOUD = 'cloud',
  LOCAL = 'local',
  FALLBACK = 'fallback'
}

export class AiRouter {
  static async isOnline(): Promise<boolean> {
    try {
      const net = await connection.getDefaultNet();
      if (net.netId === 0) {
        return false;
      }
      const caps = await connection.getNetCapabilities(net);
      return caps !== undefined && caps.bearerTypes.length > 0;
    } catch (e) {
      return false;
    }
  }

  static async decide(cloudReady: boolean, localReady: boolean): Promise<RouteMode> {
    if (cloudReady) {
      const online = await AiRouter.isOnline();
      if (online) {
        return RouteMode.CLOUD;
      }
    }
    if (localReady) {
      return RouteMode.LOCAL;
    }
    return RouteMode.FALLBACK;
  }

  /** 失败后应继续走的那一档：CLOUD→LOCAL(本地就绪时)→FALLBACK */
  static nextMode(current: RouteMode, localReady: boolean): RouteMode {
    if (current === RouteMode.CLOUD && localReady) {
      return RouteMode.LOCAL;
    }
    return RouteMode.FALLBACK;
  }

  static modeName(mode: RouteMode): string {
    if (mode === RouteMode.CLOUD) {
      return '云端';
    }
    if (mode === RouteMode.LOCAL) {
      return '本地';
    }
    return '词库';
  }

  static icon(mode: RouteMode): string {
    if (mode === RouteMode.CLOUD) {
      return '☁️';
    }
    if (mode === RouteMode.LOCAL) {
      return '📱';
    }
    return '📴';
  }

  static label(mode: RouteMode): string {
    return AiRouter.icon(mode) + ' ' + AiRouter.modeName(mode);
  }

  /** 降级提示：让用户一眼看出「现在是谁在回答」，不静默切换 */
  static degradeNote(from: RouteMode, to: RouteMode, reason: string): string {
    const tail: string = reason === '' ? '' : '（' + reason + '）';
    return AiRouter.icon(from) + '→' + AiRouter.icon(to) + ' 已回落' + AiRouter.modeName(to) + tail;
  }

  /** 任意异常 → 一句可展示的原因（超时/网络/HTTP/解析四类可区分） */
  static reasonOf(e: Error): string {
    if (e instanceof CloudError) {
      return e.toReason();
    }
    const msg: string = e.message;
    return (msg === undefined || msg === '') ? '未知错误' : msg;
  }

  /** 最后一档：本地词库应答（零网络、零依赖） */
  static lexiconReply(userText: string): string {
    if (userText.indexOf('累') >= 0 || userText.indexOf('疲') >= 0) {
      return '先喘口气：把现在最压着你的那一件事写下来，只写一件，其余的放到明天。';
    }
    if (userText.indexOf('失眠') >= 0 || userText.indexOf('睡不着') >= 0) {
      return '放下屏幕，做 4-7-8 呼吸：吸 4 秒、屏 7 秒、呼 8 秒，重复四轮。';
    }
    if (userText.indexOf('焦虑') >= 0 || userText.indexOf('慌') >= 0) {
      return '把担心写成一句话，再问自己：这件事三天后还重要吗？把答案写下来。';
    }
    return '我在（本地词库应答）。云端和本地模型这会儿都用不上，你可以先把想说的写下来，链路恢复我再接着聊。';
  }
}
