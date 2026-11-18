/**
 * 桌面小组件的生命周期入口。
 *
 * 与 UIAbility 不同进程：这里不碰 Memory / Persona / 3D，只做「读文件 → 交给卡片」。
 * 数据由 App 侧通过 CardBridge 写进沙箱文件，本进程每次重新读，没有跨进程缓存问题。
 */
import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CardData, readCardData, bindingOf, registerForm, unregisterForm } from '../common/CardBridge';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';

export default class EntryFormAbility extends FormExtensionAbility {
  /** 卡片被添加到桌面：注册 formId 并把当前数据推过去 */
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = want.parameters?.[formInfo.FormParam.IDENTITY_KEY] as string ?? '';
    const filesDir: string = this.context.filesDir;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'form add id=%{public}s', formId);
    if (formId !== '') {
      registerForm(filesDir, formId);
    }
    const d: CardData = readCardData(filesDir);
    return bindingOf(d);
  }

  /** 系统要求刷新（updateDuration 或 App 侧 updateForm 触发） */
  onUpdateForm(formId: string): void {
    const filesDir: string = this.context.filesDir;
    const d: CardData = readCardData(filesDir);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'form update id=%{public}s snippet=[%{public}s]', formId, d.snippet);
    // 注意：updateForm 在 formProvider 上，不在 FormExtensionContext 上
    formProvider.updateForm(formId, bindingOf(d)).then(() => {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'form update done id=%{public}s', formId);
    }).catch((e: Error) => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'form update failed id=%{public}s: %{public}s', formId, e.message);
    });
  }

  /** 卡片被移除 */
  onRemoveForm(formId: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'form remove id=%{public}s', formId);
    unregisterForm(this.context.filesDir, formId);
  }
}
