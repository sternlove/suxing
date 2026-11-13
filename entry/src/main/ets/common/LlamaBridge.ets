import { LlamaNative, LlamaParams } from 'libllamaohos.so';

/** 推理参数：不传的字段沿用 native 缺省值 2048/512/512/自动 */
export interface LlamaOptions {
  nCtx?: number;
  nBatch?: number;
  nPredict?: number;
  nThreads?: number;
  /** 0（缺省）= 贪心；>0 启用 topK/topP/minP/temperature 采样链 */
  temperature?: number;
  topP?: number;
  topK?: number;
  minP?: number;
  seed?: number;
}

/**
 * llama.cpp 的 OHOS 侧封装。
 *
 * generateStream 的 Promise 只在 native 端真正结束（正常结束 / 取消 / 出错）时
 * 才 settle —— native 侧通过 generateStream 的第 4 个参数 onDone(code, text)
 * 回调，code 0=正常 1=取消 2=出错。
 * 这样 UI 的 generating 标志不会被提前复位。
 */
export class LlamaBridge {
  private handle: number = 0;
  private loaded: boolean = false;
  private generating: boolean = false;
  private lastError: string = '';

  isReady(): boolean {
    return this.loaded;
  }

  /** native 抛出的最后一条错误信息，未出错时为空串 */
  getLastError(): string {
    return this.lastError;
  }

  isGenerating(): boolean {
    return this.generating;
  }

  getHandle(): number {
    return this.handle;
  }

  loadModel(path: string, options?: LlamaOptions): boolean {
    this.lastError = '';
    try {
      if (this.handle === 0) {
        this.handle = LlamaNative.createContext();
      }
      if (this.handle === 0) {
        this.lastError = 'createContext 返回 0';
        return false;
      }
      this.loaded = LlamaNative.loadModel(this.handle, path, options);
      return this.loaded;
    } catch (e) {
      // native 侧用 napi_throw_error 报错，这里接住变成可展示的字符串
      this.loaded = false;
      this.lastError = (e as Error).message;
      return false;
    }
  }

  /**
   * 流式生成。onToken 在 ArkTS 线程被反复触发（参数是累计全文，
   * 不是增量），Promise 只在 native 结束信号到达后 settle。
   */
  generateStream(prompt: string, onToken: (partial: string) => void): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      if (!this.loaded || this.handle === 0) {
        reject(new Error('模型尚未加载'));
        return;
      }
      if (this.generating) {
        reject(new Error('已有生成任务在进行中'));
        return;
      }

      const handle: number = this.handle;
      let settled: boolean = false;
      this.generating = true;

      const finish = (code: number, finalText: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        this.generating = false;
        if (code === 0 || code === 1) {
          // 取消也把已产出的文本交给调用方，UI 不需要区分
          resolve(finalText);
        } else {
          reject(new Error('生成失败（native code ' + code + '）'));
        }
      };

      try {
        LlamaNative.generateStream(handle, prompt, (partial: string) => {
          onToken(partial);
        }, (code: number, finalText: string) => {
          finish(code, finalText);
        });
      } catch (e) {
        this.generating = false;
        if (!settled) {
          settled = true;
          reject(e as Error);
        }
      }
    });
  }

  /** 回读 native 侧当前生效的推理参数 */
  getParams(): LlamaParams | undefined {
    if (this.handle === 0) {
      return undefined;
    }
    try {
      return LlamaNative.getParams(this.handle);
    } catch (e) {
      this.lastError = (e as Error).message;
      return undefined;
    }
  }

  cancel(): void {
    if (this.handle === 0) {
      return;
    }
    try {
      LlamaNative.cancel(this.handle);
    } catch (e) {
      this.lastError = (e as Error).message;
    }
  }

  release(): void {
    if (this.handle === 0) {
      return;
    }
    try {
      LlamaNative.releaseContext(this.handle);
    } catch (e) {
      this.lastError = (e as Error).message;
    }
    this.handle = 0;
    this.loaded = false;
    this.generating = false;
  }
}
