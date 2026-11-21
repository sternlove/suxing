/**
 * MCP（Model Context Protocol）客户端。
 *
 * 方向：苏兴作为 **Client**，连接外部 MCP server 使用它们的工具。
 *   （Jarvis 的 mcp_server.py 是反向：把自身能力暴露出去。手机上做 server 意义不大，
 *     没有子进程、也难被外部访问，所以这里只做 client。）
 *
 * 传输：只支持 HTTP POST（JSON-RPC 2.0 over HTTP）。
 *   不实现 stdio —— 鸿蒙应用起不了子进程。
 *   响应兼容两种：纯 JSON，以及 SSE（text/event-stream 里找 data: 行）。
 *
 * 协议流程（MCP 规范）：
 *   1. initialize                       握手，交换协议版本与能力
 *   2. notifications/initialized        单向通知，无 id
 *   3. tools/list                       拿工具清单
 *   4. tools/call {name, arguments}     调用
 *
 * 设计取舍：错误一律返回结构化结果而不是抛异常，因为「一个 MCP server 挂了」
 * 不应该让整个技能系统崩掉。
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';

/** 当前实现的协议版本；握手时按 server 返回的版本为准 */
const PROTOCOL_VERSION: string = '2024-11-05';
const CLIENT_NAME: string = 'suxing';
const CLIENT_VERSION: string = '1.0.0';
const REQ_TIMEOUT_MS: number = 15000;

/** MCP 工具描述（tools/list 的返回项） */
export interface McpTool {
  name: string;
  description: string;
  /** JSON Schema；本实现只做透传，不做校验 */
  inputSchema: string;
}

export interface McpCallResult {
  ok: boolean;
  /** 成功时是文本内容；失败时是错误说明 */
  text: string;
}

/** initialize 的 clientInfo */
interface McpClientInfo {
  name: string;
  version: string;
}

/** initialize 参数（ArkTS 要求字面量有显式类型） */
interface McpInitParams {
  protocolVersion: string;
  capabilities: Object;
  clientInfo: McpClientInfo;
}

/** tools/call 参数 */
interface McpCallParams {
  name: string;
  arguments: Object;
}

/** 无参数占位（tools/list 之类） */
class McpEmptyParams {
}

/** JSON-RPC 请求体 */
interface RpcRequest {
  jsonrpc: string;
  id: number;
  method: string;
  params: string;
}

export class McpClient {
  readonly label: string;
  private endpoint: string;
  private nextId: number = 1;
  private ready: boolean = false;
  private tools: McpTool[] = [];
  private serverName: string = '';

  constructor(label: string, endpoint: string) {
    this.label = label;
    this.endpoint = endpoint;
  }

  isReady(): boolean {
    return this.ready;
  }

  toolCount(): number {
    return this.tools.length;
  }

  listTools(): McpTool[] {
    return this.tools;
  }

  /**
   * 发一条 JSON-RPC 请求。
   * 返回 server 的 result 文本（未解析）；失败返回空串并在日志说明原因。
   */
  private async rpc(method: string, params: Object): Promise<string> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const body: string = JSON.stringify({
        jsonrpc: '2.0',
        id: this.nextId++,
        method: method,
        params: params
      } as RpcRequest);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'mcp -> %{public}s %{public}s', this.label, method);
      const resp: http.HttpResponse = await req.request(this.endpoint, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Accept': 'application/json, text/event-stream'
        },
        extraData: body,
        connectTimeout: REQ_TIMEOUT_MS,
        readTimeout: REQ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const code: number = resp.responseCode;
      let raw: string = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
      if (code < 200 || code >= 300) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'mcp http %{public}d %{public}s code=%{public}d',
          code, this.label, method);
        return '';
      }
      // SSE 响应：逐行找 data: 前缀，取最后一条完整 JSON
      if (raw.indexOf('data:') >= 0) {
        const lines: string[] = raw.split('\n');
        let picked: string = '';
        for (let i = 0; i < lines.length; i++) {
          const ln: string = lines[i].trim();
          if (ln.startsWith('data:')) {
            const payload: string = ln.substring(5).trim();
            if (payload !== '' && payload !== '[DONE]') {
              picked = payload;
            }
          }
        }
        if (picked !== '') {
          raw = picked;
        }
      }
      return raw;
    } catch (e) {
      const err: Error = e as Error;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'mcp request failed %{public}s %{public}s: %{public}s',
        this.label, method, err.message);
      return '';
    } finally {
      req.destroy();
    }
  }

  /** 从 JSON-RPC 响应里取 result 字段的文本形式 */
  private static pickResult(raw: string): string {
    if (raw === '') {
      return '';
    }
    try {
      const obj: Object = JSON.parse(raw) as Object;
      const rec: Record<string, Object> = obj as Record<string, Object>;
      if (rec.error !== undefined) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'mcp rpc error: %{public}s', JSON.stringify(rec.error).substring(0, 120));
        return '';
      }
      const result: Object | undefined = rec.result as Object;
      if (result === undefined) {
        return '';
      }
      return JSON.stringify(result);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'mcp parse failed: %{public}s', (e as Error).message);
      return '';
    }
  }

  /** 握手 + 拉工具清单。成功返回 true */
  async connect(): Promise<boolean> {
    const info: McpClientInfo = { name: CLIENT_NAME, version: CLIENT_VERSION };
    const initParams: McpInitParams = {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: new McpEmptyParams(),
      clientInfo: info
    };
    const raw: string = await this.rpc('initialize', initParams);
    const res: string = McpClient.pickResult(raw);
    if (res === '') {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'mcp initialize failed %{public}s', this.label);
      return false;
    }
    try {
      const info: Record<string, Object> = JSON.parse(res) as Record<string, Object>;
      const si: Object | undefined = info.serverInfo as Object;
      if (si !== undefined) {
        const s: Record<string, Object> = si as Record<string, Object>;
        this.serverName = (s.name as string) ?? this.label;
      }
    } catch (e) {
      // serverInfo 缺失不算失败
    }

    // 规范要求发送 initialized 通知（无 id、不期待响应）
    const nt: http.HttpRequest = http.createHttp();
    try {
      await nt.request(this.endpoint, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }),
        connectTimeout: REQ_TIMEOUT_MS,
        readTimeout: REQ_TIMEOUT_MS
      });
    } catch (e) {
      // 通知失败不阻断
    } finally {
      nt.destroy();
    }

    const okTools: boolean = await this.refreshTools();
    this.ready = okTools;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'mcp connected %{public}s server=[%{public}s] tools=%{public}d',
      this.label, this.serverName, this.tools.length);
    return okTools;
  }

  /** 拉取/刷新工具清单 */
  async refreshTools(): Promise<boolean> {
    const raw: string = await this.rpc('tools/list', new McpEmptyParams());
    const res: string = McpClient.pickResult(raw);
    if (res === '') {
      return false;
    }
    try {
      const obj: Record<string, Object> = JSON.parse(res) as Record<string, Object>;
      const arr: Object[] = (obj.tools as Object[]) ?? [];
      const out: McpTool[] = [];
      for (let i = 0; i < arr.length; i++) {
        const t: Record<string, Object> = arr[i] as Record<string, Object>;
        const name: string = (t.name as string) ?? '';
        if (name === '') {
          continue;
        }
        out.push({
          name: name,
          description: (t.description as string) ?? '',
          inputSchema: JSON.stringify(t.inputSchema ?? {})
        });
      }
      this.tools = out;
      return true;
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'mcp tools/list parse failed: %{public}s', (e as Error).message);
      return false;
    }
  }

  /**
   * 调用一个工具。
   * arguments 传 JSON 文本（由调用方按 inputSchema 组好）。
   */
  async callTool(name: string, argsJson: string): Promise<McpCallResult> {
    if (!this.ready) {
      return { ok: false, text: 'MCP server「' + this.label + '」尚未连接' };
    }
    let args: Object = new McpEmptyParams();
    try {
      args = JSON.parse(argsJson === '' ? '{}' : argsJson) as Object;
    } catch (e) {
      return { ok: false, text: '参数不是合法 JSON' };
    }
    const callParams: McpCallParams = { name: name, arguments: args };
    const raw: string = await this.rpc('tools/call', callParams);
    const res: string = McpClient.pickResult(raw);
    if (res === '') {
      return { ok: false, text: 'MCP 调用失败（server 无响应或返回错误）' };
    }
    // MCP 的 content 是数组：[{type:"text", text:"..."}]
    try {
      const obj: Record<string, Object> = JSON.parse(res) as Record<string, Object>;
      const content: Object[] = (obj.content as Object[]) ?? [];
      const parts: string[] = [];
      for (let i = 0; i < content.length; i++) {
        const c: Record<string, Object> = content[i] as Record<string, Object>;
        const t: string = c.text as string;
        if (t !== undefined && t !== '') {
          parts.push(t);
        }
      }
      if (parts.length > 0) {
        return { ok: true, text: parts.join('\n') };
      }
      return { ok: true, text: res.substring(0, 500) };
    } catch (e) {
      return { ok: true, text: res.substring(0, 500) };
    }
  }
}
