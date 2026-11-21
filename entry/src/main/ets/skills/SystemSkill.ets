/**
 * 系统状态技能：时间、电量。
 *
 * 这个技能是「框架价值」的证据 —— 它完全独立，Index.ets 一行都不用改就能让它生效。
 * 加能力 = 新建文件 + 注册一行。
 */
import { batteryInfo } from '@kit.BasicServicesKit';
import { Skill, SkillEnv, SkillResult } from '../common/Skill';

function pad2(n: number): string {
  return n < 10 ? ('0' + n) : ('' + n);
}

export const systemSkill: Skill = {
  id: 'system',
  name: '时间与电量',
  triggers: ['几点了', '现在几点', '电量', '还有多少电', '什么时候了'],
  run: async (input: string, env: SkillEnv): Promise<SkillResult> => {
    const askTime: boolean = input.indexOf('点') >= 0 || input.indexOf('时候') >= 0;
    const askBattery: boolean = input.indexOf('电') >= 0;

    const parts: string[] = [];
    if (askTime || !askBattery) {
      const d: Date = new Date();
      parts.push(pad2(d.getHours()) + ':' + pad2(d.getMinutes()));
    }
    if (askBattery || !askTime) {
      try {
        const pct: number = batteryInfo.batterySOC;
        const charging: boolean = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE;
        parts.push('电量 ' + pct + '%' + (charging ? '（充电中）' : ''));
      } catch (e) {
        // 个别 ROM 上读不到电量，不当作失败
      }
    }
    if (parts.length === 0) {
      return { handled: false, reply: '' };
    }
    return { handled: true, reply: '先生，现在是 ' + parts.join('，') + '。' };
  }
};
