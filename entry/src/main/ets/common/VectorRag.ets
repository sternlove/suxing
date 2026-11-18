/**
 * 向量库 + 混合检索融合。
 *
 * 分工：
 *   Rag.ets        BM25（字面匹配，专有名词准）
 *   本文件          向量（语义匹配，换说法也能找到）
 *   两者用 RRF 融合，见 fuse()。
 *
 * 为什么用 RRF（Reciprocal Rank Fusion）而不是加权和：
 *   BM25 分数没有固定量纲（随语料规模漂移），向量余弦是 0~1，
 *   直接加权需要归一化，而归一化本身又会随语料变化。RRF 只用「排名」，
 *   天然免疫量纲问题，且对两路各自的分数分布不敏感 —— 更适合这种混合场景。
 */
import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cosine } from './Embedder';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';

const VEC_TABLE: string = 'message_vectors';

/** RRF 的平滑常数，原论文取 60；越大则排名差异影响越小 */
const RRF_K: number = 60;

export interface VecRow {
  msgId: number;
  vec: Float32Array;
}

export interface VecHit {
  msgId: number;
  score: number;
}

export interface FusedHit {
  msgId: number;
  score: number;
  /** 命中来源：bm25 / vec / both，便于日志与调参 */
  from: string;
}

export class VectorStore {
  private store: relationalStore.RdbStore | undefined = undefined;
  private ready: boolean = false;

  /** 建表（幂等）。失败只打日志，调用方降级为纯 BM25 */
  async init(store: relationalStore.RdbStore): Promise<boolean> {
    if (this.ready) {
      return true;
    }
    this.store = store;
    try {
      await store.executeSql(
        'CREATE TABLE IF NOT EXISTS ' + VEC_TABLE + ' (' +
        'msg_id INTEGER PRIMARY KEY, ' +
        'session_id INTEGER, ' +
        'vec BLOB NOT NULL, ' +
        'dim INTEGER NOT NULL, ' +
        'ts INTEGER NOT NULL)');
      this.ready = true;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'vector table ready');
      return true;
    } catch (e) {
      const err: Error = e as Error;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'vector table create failed: %{public}s', err.message);
      return false;
    }
  }

  isReady(): boolean {
    return this.ready;
  }

  /** 写入/覆盖一条向量。Float32Array → BLOB（按字节存） */
  async put(msgId: number, sessionId: number, vec: Float32Array): Promise<boolean> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined || !this.ready) {
      return false;
    }
    try {
      const bytes: Uint8Array = new Uint8Array(vec.buffer.slice(0));
      const args: Array<relationalStore.ValueType> = [msgId, sessionId, bytes, vec.length, Date.now()];
      await st.executeSql(
        'INSERT OR REPLACE INTO ' + VEC_TABLE + ' (msg_id, session_id, vec, dim, ts) VALUES (?, ?, ?, ?, ?)',
        args);
      return true;
    } catch (e) {
      const err: Error = e as Error;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'vector put failed msgId=%{public}d: %{public}s', msgId, err.message);
      return false;
    }
  }

  /**
   * 加载候选向量。sessionId < 0 表示不限会话。
   * limit 用于给候选池封顶，避免库大了以后每次全量读。
   */
  async load(sessionId: number, limit: number): Promise<VecRow[]> {
    const st: relationalStore.RdbStore | undefined = this.store;
    const out: VecRow[] = [];
    if (st === undefined || !this.ready) {
      return out;
    }
    try {
      const sql: string = sessionId >= 0
        ? 'SELECT msg_id, vec FROM ' + VEC_TABLE + ' WHERE session_id = ? ORDER BY ts DESC LIMIT ?'
        : 'SELECT msg_id, vec FROM ' + VEC_TABLE + ' ORDER BY ts DESC LIMIT ?';
      const args: Array<relationalStore.ValueType> = sessionId >= 0 ? [sessionId, limit] : [limit];
      const rs: relationalStore.ResultSet = await st.querySql(sql, args);
      try {
        while (rs.goToNextRow()) {
          const id: number = rs.getLong(rs.getColumnIndex('msg_id'));
          const blob: Uint8Array = rs.getBlob(rs.getColumnIndex('vec'));
          if (blob.length < 4) {
            continue;
          }
          // BLOB → Float32Array：必须按字节复制，直接强转在 ArkTS 里拿不到正确的对齐
          const copy: ArrayBuffer = blob.buffer.slice(blob.byteOffset, blob.byteOffset + blob.byteLength);
          out.push({ msgId: id, vec: new Float32Array(copy) });
        }
      } finally {
        rs.close();
      }
    } catch (e) {
      const err: Error = e as Error;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'vector load failed: %{public}s', err.message);
    }
    return out;
  }

  /** 按余弦相似度取 topK（两个向量都已归一化，等价于点积） */
  search(query: Float32Array, rows: VecRow[], topK: number): VecHit[] {
    const scored: VecHit[] = [];
    for (let i = 0; i < rows.length; i++) {
      const r: VecRow = rows[i];
      if (r.vec.length !== query.length) {
        continue;
      }
      scored.push({ msgId: r.msgId, score: cosine(query, r.vec) });
    }
    scored.sort((a: VecHit, b: VecHit) => b.score - a.score);
    return scored.slice(0, topK);
  }

  async count(): Promise<number> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined || !this.ready) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = await st.querySql('SELECT COUNT(*) AS n FROM ' + VEC_TABLE, []);
      try {
        if (rs.goToFirstRow()) {
          return rs.getLong(rs.getColumnIndex('n'));
        }
      } finally {
        rs.close();
      }
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'vector count failed: %{public}s', (e as Error).message);
    }
    return 0;
  }

  async clear(): Promise<void> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined || !this.ready) {
      return;
    }
    try {
      await st.executeSql('DELETE FROM ' + VEC_TABLE, []);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'vector clear failed: %{public}s', (e as Error).message);
    }
  }
}

/**
 * RRF 融合两路结果。
 * bm25: 已按分数降序的消息 id 列表
 * vec : 已按相似度降序的消息 id 列表
 * 返回按融合分降序的结果；from 标出命中来源，方便判断哪一路在起作用。
 */
export function fuse(bm25: number[], vec: number[], topK: number): FusedHit[] {
  const acc: Map<number, FusedHit> = new Map<number, FusedHit>();
  const add = (id: number, rank: number, src: string): void => {
    const cur: FusedHit | undefined = acc.get(id);
    const gain: number = 1 / (RRF_K + rank);
    if (cur === undefined) {
      acc.set(id, { msgId: id, score: gain, from: src });
    } else {
      cur.score += gain;
      cur.from = cur.from === src ? src : 'both';
    }
  };
  for (let i = 0; i < bm25.length; i++) {
    add(bm25[i], i + 1, 'bm25');
  }
  for (let i = 0; i < vec.length; i++) {
    add(vec[i], i + 1, 'vec');
  }
  const out: FusedHit[] = Array.from(acc.values());
  out.sort((a: FusedHit, b: FusedHit) => b.score - a.score);
  return out.slice(0, topK);
}
