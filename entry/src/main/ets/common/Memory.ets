import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMsg } from './CloudApi';
import { buildRagBlock, MemoryHit, RagDoc, scoreDocs, RAG_MIN_SCORE, RAG_TOPK } from './Rag';

/**
 * 聊天记忆：SQLite 落库 + 「最近 N 轮」上下文构造。
 *
 * 为什么用关系型而不是 preferences 存 JSON：
 *   ① 每条消息一次 INSERT，不需要整表读改写，进程被 force-stop 也不会丢已写入的行；
 *   ② 以后要做检索（按角色/时间/关键词）直接加 SQL 就行，不用重写存储层。
 *
 * 库文件放在应用沙箱 databaseDir 下（relationalStore 默认位置，无需额外权限）。
 * 本文件只做存储与 prompt 拼装，不碰 UI，便于单独推敲 token 预算。
 */

export const MEM_DOMAIN: number = 0xC0DE;
export const MEM_TAG: string = 'CyberTwin';

/** 内存态的「一行对话」：只有渲染和喂模型需要的两个字段 */
export interface ChatTurn {
  role: string;
  text: string;
}

/** 落库形态：id 自增，mode 记录这条回复是谁答的（user/云端/本地/词库/微信） */
export interface MemRow {
  id: number;
  role: string;
  text: string;
  ts: number;
  mode: string;
}

export const DB_NAME: string = 'cybertwin_memory.db';
export const TABLE_NAME: string = 'messages';
/** 启动时回填到消息列表的条数 */
export const LOAD_LIMIT: number = 100;
/** 送进模型的最近轮数（1 轮 = user + assistant） */
export const HISTORY_ROUNDS: number = 6;
/**
 * 本地模型 n_ctx=2048、native 缺省 nPredict=512，
 * 留给 prompt 的约 1536 token；中文按 1 token≈1.5 字保守折算 → 1500 字符。
 */
export const LOCAL_PROMPT_CHARS: number = 1500;
/** 云端 messages 的字符预算：6 轮对话封顶，别把请求撑大 */
export const CLOUD_PROMPT_CHARS: number = 4000;
/**
 * RAG 候选集：只回捞最近这么多条参与 BM25，避免全表进内存。
 * 500 → 1500：500 条只覆盖最近几天，老记忆永远进不了检索窗口。
 */
export const RAG_CANDIDATES: number = 1500;
/** 检索块最多占用可用 prompt 预算的比例（超过就先砍片段，再砍最近轮数） */
export const RAG_ROOM_RATIO: number = 0.45;

const SQL_CREATE: string = 'CREATE TABLE IF NOT EXISTS ' + TABLE_NAME + ' ('
  + 'id INTEGER PRIMARY KEY AUTOINCREMENT, '
  + 'role TEXT NOT NULL, '
  + 'text TEXT NOT NULL, '
  + 'ts INTEGER NOT NULL, '
  + 'mode TEXT NOT NULL)';
const SQL_INDEX: string = 'CREATE INDEX IF NOT EXISTS idx_messages_ts ON ' + TABLE_NAME + ' (ts)';

export class ChatMemory {
  private store: relationalStore.RdbStore | undefined = undefined;
  private dbDir: string = '';
  /** 最近一次检索真正回捞进 BM25 的候选行数（面板显示「候选 M 条」，M = min(库内总数, RAG_CANDIDATES)） */
  private pool: number = 0;

  isReady(): boolean {
    return this.store !== undefined;
  }

  /** 上一次检索的候选池条数；还没检索过是 0 */
  lastPoolSize(): number {
    return this.pool;
  }

  /** 沙箱内的真实库文件路径（数据库还没建起来时退回文件名，便于日志排查） */
  dbPath(): string {
    return this.dbDir === '' ? DB_NAME : this.dbDir + '/' + DB_NAME;
  }

  async init(ctx: common.Context): Promise<boolean> {
    if (this.store !== undefined) {
      return true;
    }
    try {
      this.dbDir = ctx.databaseDir;
    } catch (e) {
      this.dbDir = '';
      hilog.error(MEM_DOMAIN, MEM_TAG, 'memory databaseDir failed: %{public}s', (e as Error).message);
    }
    try {
      const cfg: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const st: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, cfg);
      await st.executeSql(SQL_CREATE);
      await st.executeSql(SQL_INDEX);
      this.store = st;
      const rows: number = await this.count();
      hilog.info(MEM_DOMAIN, MEM_TAG, 'memory ready path=%{public}s table=%{public}s rows=%{public}d',
        this.dbPath(), TABLE_NAME, rows);
      return true;
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'memory init failed: %{public}s', (e as Error).message);
      return false;
    }
  }

  /** 追加一条。role=user 的 mode 记 user，assistant 的记实际应答档位 */
  async append(role: string, text: string, mode: string): Promise<boolean> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined || text === '') {
      return false;
    }
    try {
      const args: Array<relationalStore.ValueType> = [role, text, Date.now(), mode];
      await st.executeSql(
        'INSERT INTO ' + TABLE_NAME + ' (role, text, ts, mode) VALUES (?, ?, ?, ?)', args);
      return true;
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'memory append failed: %{public}s', (e as Error).message);
      return false;
    }
  }

  /** 最近 limit 条，按时间正序返回（旧 → 新，直接喂 List） */
  async loadRecent(limit: number): Promise<MemRow[]> {
    const rows: MemRow[] = [];
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return rows;
    }
    try {
      const args: Array<relationalStore.ValueType> = [limit];
      const rs: relationalStore.ResultSet = await st.querySql(
        'SELECT id, role, text, ts, mode FROM ' + TABLE_NAME + ' ORDER BY id DESC LIMIT ?', args);
      try {
        const ciId: number = rs.getColumnIndex('id');
        const ciRole: number = rs.getColumnIndex('role');
        const ciText: number = rs.getColumnIndex('text');
        const ciTs: number = rs.getColumnIndex('ts');
        const ciMode: number = rs.getColumnIndex('mode');
        while (rs.goToNextRow()) {
          const row: MemRow = {
            id: rs.getLong(ciId),
            role: rs.getString(ciRole),
            text: rs.getString(ciText),
            ts: rs.getLong(ciTs),
            mode: rs.getString(ciMode)
          };
          rows.push(row);
        }
      } finally {
        rs.close();
      }
      rows.reverse();
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'memory loadRecent failed: %{public}s', (e as Error).message);
    }
    return rows;
  }

  /** 回捞检索候选集（最近 limit 条，时间正序）；库里没有 store 时返回空 */
  private async loadDocs(limit: number): Promise<RagDoc[]> {
    const docs: RagDoc[] = [];
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return docs;
    }
    try {
      const args: Array<relationalStore.ValueType> = [limit];
      const rs: relationalStore.ResultSet = await st.querySql(
        'SELECT id, role, text, ts FROM ' + TABLE_NAME + ' ORDER BY id DESC LIMIT ?', args);
      try {
        const ciId: number = rs.getColumnIndex('id');
        const ciRole: number = rs.getColumnIndex('role');
        const ciText: number = rs.getColumnIndex('text');
        const ciTs: number = rs.getColumnIndex('ts');
        while (rs.goToNextRow()) {
          const doc: RagDoc = {
            id: rs.getLong(ciId),
            role: rs.getString(ciRole),
            text: rs.getString(ciText),
            ts: rs.getLong(ciTs)
          };
          docs.push(doc);
        }
      } finally {
        rs.close();
      }
      docs.reverse();
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'memory loadDocs failed: %{public}s', (e as Error).message);
    }
    return docs;
  }

  /**
   * 历史检索：从最近 RAG_CANDIDATES 条消息里按 BM25 找与 query 最相关的 topK 条。
   * 同步签名做不到（要等 SQLite 查询），所以返回 Promise；打分本身是同步 CPU 活。
   * query 为空 / 全是停用词 / 库没起来 → 空数组，调用方据此不注入任何东西。
   */
  async search(query: string, topK: number): Promise<MemoryHit[]> {
    const q: string = query.trim();
    if (q === '' || topK <= 0 || this.store === undefined) {
      this.pool = 0;
      return [];
    }
    const docs: RagDoc[] = await this.loadDocs(RAG_CANDIDATES);
    // 候选池记的是「SQL 实际回捞的行数」，不是剔掉当前这句之后的条数：
    // 面板上的 M 要和 min(库内总数, RAG_CANDIDATES) 对得上，才说明捞到了整个窗口
    this.pool = docs.length;
    // 当前这句在 send() 里已经先落库，必须剔掉，否则它自己永远拿第一
    const pool: RagDoc[] = [];
    for (const d of docs) {
      if (d.text.trim() !== q) {
        pool.push(d);
      }
    }
    const hits: MemoryHit[] = scoreDocs(q, pool, topK);
    hilog.info(MEM_DOMAIN, MEM_TAG,
      'memory search query=[%{public}s] candidates=%{public}d pool=%{public}d hits=%{public}d',
      q.substring(0, 30), this.pool, pool.length, hits.length);
    let top: number = 0;
    for (const h of hits) {
      if (h.score > top) {
        top = h.score;
      }
    }
    hilog.info(MEM_DOMAIN, MEM_TAG, 'memory score top=%{public}s min=%{public}s',
      top.toFixed(2), RAG_MIN_SCORE.toFixed(2));
    return hits;
  }

  /**
   * 启动清洗：早期测试留下的「我叫某某」「我是某某」这类 user 行会污染上下文，
   * 而 0.5B 会照抄历史口吻把名字当称呼。这里把这类行连同所有含该名字的消息一起删掉，
   * 返回去重后的名字列表（之后由人格层做 prompt/回复过滤）。
   * 正则与任务书一致：^我(叫|是)[中文/字母]{1,8}$
   */
  async purgeNameRows(): Promise<string[]> {
    const names: string[] = [];
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return names;
    }
    const re: RegExp = /^我(叫|是)([\u4e00-\u9fa5A-Za-z]{1,8})$/;
    try {
      const ids: number[] = [];
      const rs: relationalStore.ResultSet = await st.querySql(
        'SELECT id, text FROM ' + TABLE_NAME + " WHERE role = 'user'");
      try {
        const ciId: number = rs.getColumnIndex('id');
        const ciText: number = rs.getColumnIndex('text');
        while (rs.goToNextRow()) {
          const t: string = rs.getString(ciText).trim();
          const m: RegExpMatchArray | null = t.match(re);
          if (m !== null && m[2] !== undefined && m[2] !== '') {
            ids.push(rs.getLong(ciId));
            if (names.indexOf(m[2]) < 0) {
              names.push(m[2]);
            }
          }
        }
      } finally {
        rs.close();
      }
      let removed: number = 0;
      for (const id of ids) {
        const a: Array<relationalStore.ValueType> = [id];
        await st.executeSql('DELETE FROM ' + TABLE_NAME + ' WHERE id = ?', a);
        removed++;
      }
      // 连带删掉所有提到这个名字的消息（user 与 assistant 都删）：历史里留着它，小模型照样会学
      for (const nm of names) {
        const like: string = '%' + nm + '%';
        const a2: Array<relationalStore.ValueType> = [like];
        const rs2: relationalStore.ResultSet = await st.querySql(
          'SELECT COUNT(*) AS c FROM ' + TABLE_NAME + ' WHERE text LIKE ?', a2);
        let hit: number = 0;
        try {
          if (rs2.goToFirstRow()) {
            hit = rs2.getLong(rs2.getColumnIndex('c'));
          }
        } finally {
          rs2.close();
        }
        await st.executeSql('DELETE FROM ' + TABLE_NAME + ' WHERE text LIKE ?', a2);
        removed += hit;
      }
      if (names.length > 0) {
        hilog.info(MEM_DOMAIN, MEM_TAG, 'memory purge dirty names=[%{public}s] rows=%{public}d',
          names.join(','), removed);
      } else {
        hilog.info(MEM_DOMAIN, MEM_TAG, 'memory purge dirty names=[] rows=0');
      }
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'memory purge failed: %{public}s', (e as Error).message);
    }
    return names;
  }

  async count(): Promise<number> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet =
        await st.querySql('SELECT COUNT(*) AS c FROM ' + TABLE_NAME);
      try {
        if (rs.goToFirstRow()) {
          return rs.getLong(rs.getColumnIndex('c'));
        }
      } finally {
        rs.close();
      }
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'memory count failed: %{public}s', (e as Error).message);
    }
    return 0;
  }

  /** 清空全部记录（保留表结构与自增序列，避免 id 复用干扰排序） */
  async clear(): Promise<boolean> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return false;
    }
    try {
      await st.executeSql('DELETE FROM ' + TABLE_NAME);
      hilog.info(MEM_DOMAIN, MEM_TAG, 'memory cleared path=%{public}s', this.dbPath());
      return true;
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'memory clear failed: %{public}s', (e as Error).message);
      return false;
    }
  }
}

/** 只取最近 rounds 轮（2*rounds 条），多传一截也截断 */
export function recentTurns(turns: ChatTurn[], rounds: number): ChatTurn[] {
  const cap: number = rounds * 2;
  if (turns.length <= cap) {
    return turns.slice();
  }
  return turns.slice(turns.length - cap);
}

function roleOf(role: string): string {
  return role === 'user' ? 'user' : 'assistant';
}

function chatLmTurn(turn: ChatTurn): string {
  const body: string = turn.role === 'user' ? turn.text + ' /no_think' : turn.text;
  return '<|im_start|>' + roleOf(turn.role) + '\n' + body + '<|im_end|>\n';
}

/** 拼一版 prompt 的结果：正文 + 实际注入了几条检索片段、占了多少字符（日志要打） */
export interface PromptPack {
  prompt: string;
  ragCount: number;
  ragChars: number;
}

/**
 * 本地模型 prompt（ChatML）：system（+检索块）+ 历史 + 当前输入 + assistant 开头。
 *
 * token 预算顺序：先保证当前输入，再按 3→2→1→0 砍检索片段，最后才**从最旧的开始丢**历史轮数 ——
 * 宁可让模型少记得两轮，也不能让它连现在这句都读不到。
 * 检索块放在 system 消息体内（紧跟人格 prompt 之后、最近对话之前），ChatML 结构保持合法。
 */
export function buildLocalPromptPack(systemPrompt: string, turns: ChatTurn[], userText: string,
                                     maxChars: number, ragLines: string[]): PromptPack {
  const ask: string = userText.length > maxChars ? userText.substring(0, maxChars) : userText;
  const tail: string = '<|im_start|>user\n' + ask + ' /no_think<|im_end|>\n'
    + '<|im_start|>assistant\n';
  // 检索块：最多 RAG_TOPK 条、最多占可用预算 RAG_ROOM_RATIO；塞不下就一条条减到 0
  const room: number = maxChars - tail.length - systemPrompt.length;
  const cap: number = Math.floor((room > 0 ? room : 0) * RAG_ROOM_RATIO);
  let fragCount: number = ragLines.length < RAG_TOPK ? ragLines.length : RAG_TOPK;
  let block: string = '';
  while (fragCount > 0) {
    const b: string = buildRagBlock(ragLines.slice(0, fragCount));
    if (b.length <= cap) {
      block = b;
      break;
    }
    fragCount--;
  }
  const sysBody: string = block === '' ? systemPrompt
    : (systemPrompt === '' ? block : systemPrompt + '\n' + block);
  const sys: string = sysBody === '' ? ''
    : '<|im_start|>system\n' + sysBody + '<|im_end|>\n';
  const budget: number = maxChars - sys.length - tail.length;
  const picked: string[] = [];
  let used: number = 0;
  for (let i = turns.length - 1; i >= 0; i--) {
    const seg: string = chatLmTurn(turns[i]);
    if (used + seg.length > budget) {
      break;
    }
    used += seg.length;
    picked.push(seg);
  }
  picked.reverse();
  const pack: PromptPack = { prompt: sys + picked.join('') + tail, ragCount: block === '' ? 0 : fragCount,
    ragChars: block.length };
  return pack;
}

/** 只要字符串的旧签名（调用方不关心检索统计时用） */
export function buildLocalPrompt(systemPrompt: string, turns: ChatTurn[], userText: string,
                                 maxChars: number, ragLines: string[] = []): string {
  return buildLocalPromptPack(systemPrompt, turns, userText, maxChars, ragLines).prompt;
}

/**
 * 云端 messages：system 由调用方传，这里拼「检索块 + 历史 + 当前输入」，同样从最旧的裁。
 * 检索块作为紧随 system 之后的一条 system 消息给出（DeepSeek 支持多条 system），
 * 位置正好是「人格 prompt 之后、最近对话之前」。
 */
export function buildCloudMessages(turns: ChatTurn[], userText: string, maxChars: number,
                                   ragLines: string[] = []): ChatMsg[] {
  const picked: ChatMsg[] = [];
  let used: number = userText.length;
  const block: string = buildRagBlock(ragLines.slice(0, RAG_TOPK));
  if (block !== '' && block.length < maxChars) {
    const ragMsg: ChatMsg = { role: 'system', content: block };
    picked.push(ragMsg);
    used += block.length;
  }
  for (let i = turns.length - 1; i >= 0; i--) {
    const t: ChatTurn = turns[i];
    if (used + t.text.length > maxChars) {
      break;
    }
    used += t.text.length;
    const msg: ChatMsg = { role: roleOf(t.role), content: t.text };
    picked.push(msg);
  }
  picked.reverse();
  const now: ChatMsg = { role: 'user', content: userText };
  picked.push(now);
  return picked;
}

/** 日志用：把一轮对话压成「user:… / assistant:…」，换行压平，便于 grep */
export function describeTurns(turns: ChatTurn[], maxChars: number): string {
  const parts: string[] = [];
  let used: number = 0;
  for (let i = 0; i < turns.length; i++) {
    const t: ChatTurn = turns[i];
    const flat: string = t.text.split('\n').join(' ');
    const item: string = roleOf(t.role) + ':' + flat;
    if (used + item.length > maxChars) {
      parts.push('…(截断)');
      break;
    }
    used += item.length;
    parts.push(item);
  }
  return parts.join(' | ');
}
