/**
 * 本地 embedding：把文本变成向量，给 RAG 提供「语义」这一路。
 *
 * 为什么需要它：
 *   Rag.ets 的 BM25 是纯字面匹配 —— 问「我常喝的那杯」永远搜不到「我最喜欢喝冰美式」。
 *   向量检索按语义相似度算，能跨过说法差异。两路一起用（见 Rag.ets 的融合），
 *   比任何单路都稳：专有名词靠 BM25，同义改写靠向量。
 *
 * 模型：bge-small-zh-v1.5（q8_0 GGUF，约 25 MB，512 维）
 *   不进 hap 包体，由用户在「📦 模型」里导入，和聊天模型一样走沙箱。
 *
 * native 侧：napi_init.cpp 的 Embed()，需要 loadModel 时传 { embedding: 1 }，
 *   此时 context 用 MEAN pooling、窗口固定 512。这个 handle 只能 embed，不能 generate。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LlamaNative, LlamaNativeApi } from 'libllamaohos.so';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';

/** bge-small-zh-v1.5 的向量维度；读不到时用这个兜底 */
const DEFAULT_DIM: number = 512;

export class Embedder {
  private api: LlamaNativeApi = LlamaNative as LlamaNativeApi;
  private handle: number = -1;
  private ready: boolean = false;
  private dim: number = DEFAULT_DIM;
  /** 失败后不再重试，避免每次检索都打一轮错误日志 */
  private failed: boolean = false;

  isReady(): boolean {
    return this.ready;
  }

  dims(): number {
    return this.dim;
  }

  /** 加载 embedding 模型；成功返回 true。失败不抛异常（调用方据此降级到纯 BM25） */
  async load(path: string): Promise<boolean> {
    if (this.ready) {
      return true;
    }
    if (this.failed) {
      return false;
    }
    try {
      const t0: number = Date.now();
      const h: number = this.api.createContext();
      if (h === 0) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'embed createContext returned 0');
        this.failed = true;
        return false;
      }
      const ok: boolean = this.api.loadModel(h, path, {
        embedding: 1,
        nThreads: 4
      });
      if (!ok) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'embed loadModel returned false path=%{public}s', path);
        this.api.releaseContext(h);
        this.failed = true;
        return false;
      }
      this.handle = h;
      this.ready = true;
      // 探测维度：emb 一次极短文本，长度就是 n_embd
      const probe: number[] = this.api.embed(h, '维度探测');
      if (probe.length > 0) {
        this.dim = probe.length;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'embed ready dim=%{public}d cost=%{public}dms path=%{public}s',
        this.dim, Date.now() - t0, path);
      return true;
    } catch (e) {
      const err: Error = e as Error;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'embed load failed: %{public}s', err.message);
      this.failed = true;
      return false;
    }
  }

  /**
   * 文本 → 单位向量（已 L2 归一化，余弦相似度退化成点积，省一次开方）。
   * 未就绪 / 空文本 / 出错都返回 undefined，调用方降级到 BM25。
   */
  embed(text: string): Float32Array | undefined {
    if (!this.ready || this.handle < 0) {
      return undefined;
    }
    const t: string = text.trim();
    if (t === '') {
      return undefined;
    }
    try {
      const raw: number[] = this.api.embed(this.handle, t);
      if (raw.length === 0) {
        return undefined;
      }
      const out: Float32Array = new Float32Array(raw.length);
      let sum: number = 0;
      for (let i = 0; i < raw.length; i++) {
        out[i] = raw[i];
        sum += raw[i] * raw[i];
      }
      const norm: number = Math.sqrt(sum);
      if (norm > 1e-8) {
        for (let i = 0; i < out.length; i++) {
          out[i] = out[i] / norm;
        }
      }
      return out;
    } catch (e) {
      const err: Error = e as Error;
      // 单条失败不把整个功能判死，只记一条
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'embed text failed: %{public}s', err.message);
      return undefined;
    }
  }

  release(): void {
    if (this.handle >= 0) {
      try {
        this.api.releaseContext(this.handle);
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'embed release failed: %{public}s', (e as Error).message);
      }
      this.handle = -1;
    }
    this.ready = false;
  }
}

/** 余弦相似度（两个向量都已 L2 归一化 → 直接点积） */
export function cosine(a: Float32Array, b: Float32Array): number {
  const n: number = Math.min(a.length, b.length);
  let dot: number = 0;
  for (let i = 0; i < n; i++) {
    dot += a[i] * b[i];
  }
  return dot;
}
