/**
 * MCP → 技能 的桥接。
 *
 * 一个 MCP 工具 = 一个技能，注册进 SkillRegistry 后就跟内置技能一样工作。
 * 这样「接入 100 个外部工具」也不需要改对话主流程。
 *
 * 触发方式（为什么这么设计）：
 *   本地 1.7B 不支持 function calling，没法让它自己选工具。
 *   所以走两条路：
 *     1. 显式点名：输入里出现工具名就触发（「用 get_weather 查北京」）
 *     2. 参数：输入里能找到 JSON 就用它，否则把工具名之后的文字当唯一参数
 *   这不是最优解（理想是模型自己决定调哪个），但在没有 function calling 的端侧模型上
 *   是能用且可解释的方案。等模型支持工具调用时，这里的 triggers 可以退化成纯 schema。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Skill, SkillEnv, SkillResult } from '../common/Skill';
import { McpClient, McpTool, McpCallResult } from '../common/McpClient';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';

/** 从输入里抽 JSON 对象文本；没有就返回空串 */
function extractJson(input: string): string {
  const start: number = input.indexOf('{');
  const end: number = input.lastIndexOf('}');
  if (start < 0 || end <= start) {
    return '';
  }
  return input.substring(start, end + 1);
}

/** 把工具名之后的剩余文字当参数值（用于单参数工具） */
function tailAfter(input: string, token: string): string {
  const idx: number = input.indexOf(token);
  if (idx < 0) {
    return '';
  }
  return input.substring(idx + token.length).trim();
}

/**
 * 为一个 MCP 工具生成技能。
 * 参数 client 是已连接的客户端，技能执行时直接复用它，不重复握手。
 */
export function makeMcpSkill(client: McpClient, tool: McpTool): Skill {
  const label: string = client.label;
  const toolName: string = tool.name;
  return {
    id: 'mcp:' + label + ':' + toolName,
    name: toolName + '（' + label + '）',
    // 触发器只用工具名：描述里全是英文术语，当中文触发词会把误触发率拉高
    triggers: [toolName],
    run: async (input: string, env: SkillEnv): Promise<SkillResult> => {
      let argsJson: string = extractJson(input);
      if (argsJson === '') {
        // 没有 JSON：把工具名之后的文字当唯一参数
        const tail: string = tailAfter(input, toolName);
        if (tail === '') {
          return {
            handled: true,
            reply: '先生，调用 ' + toolName + ' 需要参数。可以这样：' + toolName + ' {"key":"value"}'
          };
        }
        // 单参数工具最常见的字段名依次尝试
        argsJson = JSON.stringify({ query: tail, input: tail, text: tail });
        hilog.info(LOG_DOMAIN, LOG_TAG, 'mcp skill %{public}s args-from-tail=[%{public}s]',
          toolName, tail.substring(0, 40));
      }
      const r: McpCallResult = await client.callTool(toolName, argsJson);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'mcp skill %{public}s ok=%{public}s chars=%{public}d',
        toolName, '' + r.ok, r.text.length);
      if (!r.ok) {
        return { handled: true, reply: '先生，' + r.text };
      }
      return { handled: true, reply: r.text };
    }
  };
}

/** 一个 server 的全部工具 → 一组技能 */
export function makeMcpSkills(client: McpClient): Skill[] {
  const out: Skill[] = [];
  const tools: McpTool[] = client.listTools();
  for (let i = 0; i < tools.length; i++) {
    out.push(makeMcpSkill(client, tools[i]));
  }
  hilog.info(LOG_DOMAIN, LOG_TAG, 'mcp bridge built label=%{public}s skills=%{public}d',
    client.label, out.length);
  return out;
}
