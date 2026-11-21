/**
 * 剪贴板技能：读当前剪贴板内容并在对话里展示。
 *
 * 这是从 Index.ets 里搬出来的（原本 readClipboard/fillFromClipboard 混在主文件里）。
 * 搬出来的好处：新增类似能力时不必再改 3200 行的 Index。
 */
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Skill, SkillEnv, SkillResult } from '../common/Skill';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';
/** 剪贴板可能很长，喂给模型/界面都截断 */
const MAX_CHARS: number = 2000;

export const clipboardSkill: Skill = {
  id: 'clipboard',
  name: '读剪贴板',
  triggers: ['剪贴板', '看看复制', '看看我的报错', '分析这段', '粘贴板'],
  run: async (input: string, env: SkillEnv): Promise<SkillResult> => {
    try {
      const data: pasteboard.PasteData = await pasteboard.getSystemPasteboard().getData();
      const text: string = data.getPrimaryText();
      if (text === undefined || text.trim() === '') {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'skill clipboard empty');
        return { handled: true, reply: '先生，剪贴板是空的。' };
      }
      let body: string = text.trim();
      let cut: boolean = false;
      if (body.length > MAX_CHARS) {
        body = body.substring(0, MAX_CHARS);
        cut = true;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'skill clipboard read chars=%{public}d cut=%{public}s',
        body.length, '' + cut);
      const head: string = '先生，剪贴板里有 ' + body.length + ' 字：\n' + body + (cut ? '\n…已截断' : '');
      return { handled: true, reply: head };
    } catch (e) {
      const err: Error = e as Error;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'skill clipboard failed: %{public}s', err.message);
      return { handled: true, reply: '先生，读剪贴板失败：' + err.message };
    }
  }
};
