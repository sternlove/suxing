/**
 * 技能（Skill）框架 —— 借鉴 GDDXX-Jarvis 的 plugins/provide() 设计。
 *
 * 为什么需要：
 *   Index.ets 已经 3200 行、70 多个方法。每加一个能力都往里塞，长期会失控。
 *   把它拆成「对话循环 + 一堆技能」：新增能力 = 新建一个文件 + 注册一行，
 *   对话主流程不再改动。
 *
 * 与意图解析（TwinProto）的分工：
 *   TwinProto 处理「给微信X发消息」这类结构化指令（参数化，必须精确解析）。
 *   Skill 处理「看看剪贴板」这类**动作型**请求（无需参数或参数就是整句）。
 *   两者都在 send() 里、聊天之前尝试，互不冲突。
 *
 * 执行顺序（send 内）：
 *   1. parseSendCommand  结构化指令
 *   2. skillRegistry.match  技能
 *   3. 正常聊天（云端/本地/词库）
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';

/** 技能能拿到的环境：只暴露它需要的，避免技能反过来依赖 Index 的状态 */
export interface SkillEnv {
  ctx: common.UIAbilityContext;
  /** 应用沙箱根目录（技能要落文件时用） */
  filesDir: string;
  /** 往当前对话追加一条分身消息（技能自己 push 状态，由宿主渲染） */
  say: (text: string) => void;
  /** 状态栏提示 */
  status: (text: string) => void;
}

/** 技能执行结果 */
export interface SkillResult {
  /** false 表示「我没处理」，宿主继续往下走（聊天） */
  handled: boolean;
  /** 给用户的回复；handled 为 true 时会被展示，空串表示由技能自己 say() */
  reply: string;
}

/** 一个技能 */
export interface Skill {
  /** 稳定 id，日志与去重用 */
  id: string;
  /** 面板显示名 */
  name: string;
  /**
   * 触发词：用户输入**包含**任一即视为候选。
   * 故意用「包含」而不是精确匹配 —— 用户会说「帮我看看剪贴板里是啥」。
   */
  triggers: string[];
  /** 执行。抛异常时宿主会兜住并降级为聊天 */
  run: (input: string, env: SkillEnv) => Promise<SkillResult>;
}

/** 注册中心：保持顺序，先注册先匹配 */
export class SkillRegistry {
  private list: Skill[] = [];

  register(s: Skill): void {
    for (let i = 0; i < this.list.length; i++) {
      if (this.list[i].id === s.id) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'skill duplicate id=%{public}s (ignored)', s.id);
        return;
      }
    }
    this.list.push(s);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'skill registered id=%{public}s triggers=%{public}d',
      s.id, s.triggers.length);
  }

  /** 按注册顺序找第一个命中的技能；没有命中返回 undefined */
  match(input: string): Skill | undefined {
    const t: string = input.trim();
    if (t === '') {
      return undefined;
    }
    for (let i = 0; i < this.list.length; i++) {
      const s: Skill = this.list[i];
      for (let j = 0; j < s.triggers.length; j++) {
        if (t.indexOf(s.triggers[j]) >= 0) {
          return s;
        }
      }
    }
    return undefined;
  }

  /** 面板展示用：所有技能名 */
  names(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.list.length; i++) {
      out.push(this.list[i].name);
    }
    return out;
  }

  count(): number {
    return this.list.length;
  }
}
