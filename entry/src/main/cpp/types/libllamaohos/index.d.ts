/**
 * libllamaohos.so —— CyberTwin 的 llama.cpp NAPI 桥接层声明。
 *
 * 错误约定：参数类型/范围非法、handle 无效、模型加载失败等一律抛 Error
 * （带 code，例如 ERR_INVALID_ARG_TYPE / ERR_INVALID_HANDLE / ERR_MODEL_LOAD_FAILED）。
 */
export interface LlamaLoadOptions {
  /** 上下文窗口，缺省 2048，允许 128..32768 */
  nCtx?: number;
  /** 批大小，缺省 512，允许 32..2048 */
  nBatch?: number;
  /** 单次最多新生成 token 数，缺省 512，允许 1..8192 且必须小于 nCtx */
  nPredict?: number;
  /** 线程数，缺省按 CPU 核数自动（最多 6），允许 1..16 */
  nThreads?: number;
  /** 采样温度，缺省 0（贪心），允许 0..2；>0 才启用采样链 */
  temperature?: number;
  /** 核采样，缺省 1.0，允许 0..1 */
  topP?: number;
  /** top-k，缺省 0（不限），允许 0..128 */
  topK?: number;
  /** min-p，缺省 0（关闭），允许 0..1 */
  minP?: number;
  /** 随机种子，缺省 0，允许 0..1000000 */
  seed?: number;
}

export interface LlamaParams {
  nCtx: number;
  nBatch: number;
  nPredict: number;
  nThreads: number;
  topK: number;
  seed: number;
  temperature: number;
  topP: number;
  minP: number;
}

export interface LlamaNativeApi {
  /** 创建推理上下文，返回非 0 句柄；失败抛异常 */
  createContext(): number;
  /** 加载 gguf 模型文件，失败抛异常；成功返回 true */
  loadModel(handle: number, path: string, options?: LlamaLoadOptions): boolean;
  /**
   * 流式生成。
   * onToken 收到的是「累计全文」，不是增量。
   * onDone 在 native 生成结束时调用一次：code 0=正常结束 1=被取消 2=出错，text 是最终全文。
   */
  generateStream(handle: number, prompt: string, onToken: (partial: string) => void,
                 onDone?: (code: number, finalText: string) => void): void;
  /** 请求中断当前生成 */
  cancel(handle: number): void;
  /** 释放上下文与模型；已释放时返回 false（幂等） */
  releaseContext(handle: number): boolean;
  /** 回读当前生效的推理参数 */
  getParams(handle: number): LlamaParams;
}

export const createContext: () => number;
export const loadModel: (handle: number, path: string, options?: LlamaLoadOptions) => boolean;
export const generateStream: (handle: number, prompt: string, onToken: (partial: string) => void,
                              onDone?: (code: number, finalText: string) => void) => void;
export const cancel: (handle: number) => void;
export const releaseContext: (handle: number) => boolean;
export const getParams: (handle: number) => LlamaParams;

export const LlamaNative: LlamaNativeApi;