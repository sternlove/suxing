import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

export interface ChatMsg {
  role: string;
  content: string;
}

/** 非流式整段返回时的结构（服务端忽略 stream 时的兜底解析用） */
interface ChatChoice {
  message: ChatMsg;
}

interface ChatCompletion {
  choices?: ChatChoice[];
}

/** SSE 增量帧：{"choices":[{"delta":{"content":"…"}}]} */
interface StreamDelta {
  content?: string;
  /** 思考型模型（deepseek-reasoner）会先把思考流出来，content 稍后才到 */
  reasoning_content?: string;
}

interface StreamChoice {
  delta?: StreamDelta;
}

interface StreamChunk {
  choices?: StreamChoice[];
}

/**
 * 云端失败的四类原因，AiRouter / UI 靠它判断要不要降级、怎么提示。
 * 四类：超时 / 网络不可用 / HTTP 4xx-5xx / 解析失败（另加未配置 Key）。
 */
export enum CloudErrorCode {
  NO_KEY = 'no_key',
  TIMEOUT = 'timeout',
  NETWORK = 'network',
  HTTP = 'http',
  PARSE = 'parse'
}

export class CloudError extends Error {
  readonly code: CloudErrorCode;
  /** 原始错误码或细节，仅用于排查 */
  readonly detail: string;

  constructor(code: CloudErrorCode, message: string, detail?: string) {
    super(message);
    this.code = code;
    this.detail = detail === undefined ? '' : detail;
  }

  isTimeout(): boolean {
    return this.code === CloudErrorCode.TIMEOUT;
  }

  /** 给用户看的一句话原因（不含前缀文案） */
  toReason(): string {
    if (this.code === CloudErrorCode.TIMEOUT) {
      return '超时';
    }
    if (this.code === CloudErrorCode.NETWORK) {
      return '网络不可用';
    }
    if (this.code === CloudErrorCode.PARSE) {
      return '响应解析失败';
    }
    if (this.code === CloudErrorCode.NO_KEY) {
      return '未配置 API Key';
    }
    return this.message;
  }
}

/** 连接超时：10s */
export const CONNECT_TIMEOUT_MS: number = 10000;
/** 读取超时：60s */
export const READ_TIMEOUT_MS: number = 60000;
/** 流式空闲上限：30s 没有新 token 就判定挂起 */
export const STREAM_IDLE_MS: number = 30000;

const CLOUD_URL: string = 'https://api.deepseek.com/chat/completions';

/**
 * DeepSeek 云端对话。
 *
 * 超时与降级保护（三层，缺一层都可能永久转圈）：
 * 1. 引擎层：HttpRequestOptions.connectTimeout=10s / readTimeout=60s；
 * 2. 应用层看门狗：收到任何字节都重置 30s 计时，超时自己 destroy() 并抛
 *    CloudError(TIMEOUT) —— 引擎超时对挂死连接并不总生效，这层才是兜底；
 * 3. 错误分类：TIMEOUT / NETWORK / HTTP / PARSE，AiRouter 据此决定降级。
 *
 * 云端默认走 SSE 流式（stream:true），因此「有新 token」可以精确判定；
 * 若服务端忽略 stream 直接回整段 JSON，dataEnd 时退回整段解析，行为不变。
 */
export class CloudApi {
  /**
   * @param onToken 可选；流式增量回调，参数是累计全文（与本地模型一致）。
   */
  static async chat(apiKey: string, model: string, systemPrompt: string,
                    messages: ChatMsg[], onToken?: (partial: string) => void): Promise<string> {
    if (apiKey === '') {
      throw new CloudError(CloudErrorCode.NO_KEY, '还没有配置云端 API Key');
    }
    const arr: ChatMsg[] = [];
    if (systemPrompt !== '') {
      arr.push({ role: 'system', content: systemPrompt });
    }
    for (const m of messages) {
      arr.push(m);
    }
    const payload: string = JSON.stringify({
      model: model === '' ? 'deepseek-chat' : model,
      messages: arr,
      stream: true,
      temperature: 0.8
    });
    return CloudApi.stream(apiKey, payload, onToken);
  }

  private static stream(apiKey: string, payload: string,
                        onToken?: (partial: string) => void): Promise<string> {
    const request = http.createHttp();
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

    let settled: boolean = false;
    let idleTimer: number = -1;
    let connectTimer: number = -1;
    let responseCode: number = 0;
    let pending: string = '';
    let raw: string = '';
    let full: string = '';
    let thinking: string = '';
    let sawSse: boolean = false;

    return new Promise<string>((resolve: (value: string) => void,
                                reject: (reason: CloudError) => void) => {
      const cleanup = (): void => {
        if (idleTimer !== -1) {
          clearTimeout(idleTimer);
          idleTimer = -1;
        }
        if (connectTimer !== -1) {
          clearTimeout(connectTimer);
          connectTimer = -1;
        }
        request.off('dataReceive');
        request.off('dataEnd');
      };
      const finish = (text: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        request.destroy();
        resolve(text);
      };
      const fail = (err: CloudError): void => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        // 主动掐断：挂死的连接不 destroy 会一直占着 socket
        request.destroy();
        reject(err);
      };
      const armIdle = (): void => {
        if (idleTimer !== -1) {
          clearTimeout(idleTimer);
        }
        idleTimer = setTimeout(() => {
          idleTimer = -1;
          fail(new CloudError(CloudErrorCode.TIMEOUT,
            '云端 ' + (STREAM_IDLE_MS / 1000) + 's 没有新 token，已判定挂起'));
        }, STREAM_IDLE_MS);
      };

      const consumeLine = (rawLine: string): void => {
        const line: string = rawLine.trim();
        if (line === '' || !line.startsWith('data:')) {
          return; // 空行、SSE 注释(「: ping」)、event: 行都算心跳之外的噪声
        }
        const data: string = line.substring(5).trim();
        if (data === '[DONE]') {
          finish(full !== '' ? full : thinking);
          return;
        }
        let chunk: StreamChunk;
        try {
          chunk = JSON.parse(data) as StreamChunk;
        } catch (e) {
          fail(new CloudError(CloudErrorCode.PARSE, '云端流式数据不是合法 JSON',
            data.length > 120 ? data.substring(0, 120) : data));
          return;
        }
        sawSse = true;
        const choices: StreamChoice[] | undefined = chunk.choices;
        if (choices === undefined || choices.length === 0) {
          return;
        }
        const delta: StreamDelta | undefined = choices[0].delta;
        if (delta === undefined) {
          return;
        }
        const piece: string | undefined = delta.content;
        if (piece === undefined || piece === '') {
          // 首帧只有 role；思考型模型此阶段只吐 reasoning_content
          const reason: string | undefined = delta.reasoning_content;
          if (reason !== undefined && reason !== '' && full === '') {
            thinking += reason;
          }
          return;
        }
        full += piece;
        if (onToken !== undefined) {
          onToken(full);
        }
      };

      const stopConnectTimer = (): void => {
        if (connectTimer !== -1) {
          clearTimeout(connectTimer);
          connectTimer = -1;
        }
      };

      request.on('dataReceive', (chunk: ArrayBuffer) => {
        if (settled) {
          return;
        }
        stopConnectTimer();
        armIdle(); // 任何字节都算「有新 token」
        const text: string = decoder.decodeToString(new Uint8Array(chunk), { stream: true });
        raw += text;
        pending += text;
        let idx: number = pending.indexOf('\n');
        while (idx >= 0 && !settled) {
          const line: string = pending.substring(0, idx);
          pending = pending.substring(idx + 1);
          consumeLine(line);
          idx = pending.indexOf('\n');
        }
      });

      request.on('dataEnd', () => {
        if (settled) {
          return;
        }
        if (pending.trim() !== '') {
          consumeLine(pending);
          pending = '';
        }
        if (settled) {
          return;
        }
        if (sawSse) {
          finish(full !== '' ? full : thinking);
          return;
        }
        // 服务端没走 SSE：按整段 JSON 解析
        let body: ChatCompletion;
        try {
          body = JSON.parse(raw) as ChatCompletion;
        } catch (e) {
          fail(new CloudError(CloudErrorCode.PARSE, '云端返回内容解析失败'));
          return;
        }
        const choices: ChatChoice[] | undefined = body.choices;
        if (choices === undefined || choices.length === 0) {
          fail(new CloudError(CloudErrorCode.PARSE, '云端没有返回内容'));
          return;
        }
        finish(choices[0].message.content);
      });

      // 连接阶段单独 10s 看门狗：引擎的 connectTimeout 对挂死连接并不总生效
      connectTimer = setTimeout(() => {
        connectTimer = -1;
        if (!settled && responseCode === 0) {
          fail(new CloudError(CloudErrorCode.TIMEOUT,
            '连接云端超时（' + (CONNECT_TIMEOUT_MS / 1000) + 's），已断开'));
        }
      }, CONNECT_TIMEOUT_MS);
      armIdle();
      request.requestInStream(CLOUD_URL, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + apiKey
        },
        extraData: payload,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        maxLimit: 8 * 1024 * 1024
      }).then((code: number) => {
        responseCode = code;
        stopConnectTimer();
        if (code !== 200) {
          fail(new CloudError(CloudErrorCode.HTTP, CloudApi.explain(code), 'HTTP ' + code));
        }
      }).catch((err: BusinessError) => {
        fail(CloudApi.classify(err as Error));
      });
    });
  }

  /** BusinessError → 四类 CloudError */
  private static classify(e: Error): CloudError {
    const be: BusinessError = e as BusinessError;
    const rawCode: number = be.code;
    const msg: string = (e.message === undefined || e.message === '') ? '云端请求失败' : e.message;
    if (rawCode === 2300028) {
      return new CloudError(CloudErrorCode.TIMEOUT, '云端操作超时（' + msg + '）', '2300028');
    }
    if (rawCode === 2300005 || rawCode === 2300006) {
      return new CloudError(CloudErrorCode.NETWORK, '域名解析失败，网络不可用', '' + rawCode);
    }
    if (rawCode === 2300007 || rawCode === 2300052 || rawCode === 2300055 || rawCode === 2300056) {
      return new CloudError(CloudErrorCode.NETWORK, '连不上云端，网络不可用', '' + rawCode);
    }
    return new CloudError(CloudErrorCode.NETWORK, msg, '' + rawCode);
  }

  private static explain(code: number): string {
    if (code === 401) {
      return 'API Key 无效或已过期（401）';
    }
    if (code === 402) {
      return '账户余额不足（402）';
    }
    if (code === 429) {
      return '请求太频繁，被限流了（429）';
    }
    if (code >= 500) {
      return '云端服务异常（' + code + '）';
    }
    if (code >= 400) {
      return '云端拒绝了请求（' + code + '）';
    }
    return '云端返回异常码 ' + code;
  }
}
