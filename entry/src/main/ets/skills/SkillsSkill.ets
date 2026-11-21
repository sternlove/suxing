/**
 * 元技能：说出自己会哪些技能。
 *
 * 有它的意义：技能是运行时注册的，用户（和开发者）需要一个入口知道现在装了什么。
 * 注册表是外部注入的，所以这里用工厂函数拿 names()，不反向依赖 Index。
 */
import { Skill, SkillEnv, SkillResult } from '../common/Skill';

export function makeSkillsSkill(namesProvider: () => string[]): Skill {
  return {
    id: 'skills',
    name: '技能清单',
    triggers: ['你会什么', '有什么技能', '能做什么', '会哪些功能'],
    run: async (input: string, env: SkillEnv): Promise<SkillResult> => {
      const names: string[] = namesProvider();
      if (names.length === 0) {
        return { handled: true, reply: '先生，目前没有装载技能。' };
      }
      let body: string = '先生，我会这些：';
      for (let i = 0; i < names.length; i++) {
        body += (i === 0 ? '' : '、') + names[i];
      }
      return { handled: true, reply: body + '。' };
    }
  };
}
