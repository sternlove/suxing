import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
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

/** 会话：一条会话 = 一个互不串味的消息池 */
export interface SessionRow {
  id: number;
  title: string;
  createdTs: number;
  updatedTs: number;
  /** 该会话的消息条数 */
  count: number;
}

export const DB_NAME: string = 'cybertwin_memory.db';
export const TABLE_NAME: string = 'messages';
/** 会话表：messages.session_id 指向它的 id */
export const TABLE_SESSIONS: string = 'sessions';
/** 老库升级时回填历史消息的那个会话的名字 */
export const DEFAULT_SESSION_TITLE: string = '默认会话';
/** 新建但还没说话 / 没改名的会话用这个名字，收到第一句 user 消息自动改成那句话 */
export const NEW_SESSION_TITLE: string = '新会话';
/** 会话标题自动生成时最多取多少字 */
export const AUTO_TITLE_CHARS: number = 16;
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
  + 'mode TEXT NOT NULL, '
  + 'session_id INTEGER NOT NULL DEFAULT 0)';
const SQL_INDEX: string = 'CREATE INDEX IF NOT EXISTS idx_messages_ts ON ' + TABLE_NAME + ' (ts)';
const SQL_INDEX_SESSION: string =
  'CREATE INDEX IF NOT EXISTS idx_messages_session ON ' + TABLE_NAME + ' (session_id, ts)';
const SQL_CREATE_SESSIONS: string = 'CREATE TABLE IF NOT EXISTS ' + TABLE_SESSIONS + ' ('
  + 'id INTEGER PRIMARY KEY AUTOINCREMENT, '
  + 'title TEXT NOT NULL, '
  + 'created_ts INTEGER NOT NULL, '
  + 'updated_ts INTEGER NOT NULL)';
/**
 * 迁移语句：老库（没 session_id 列）靠它补列，已有该列的库会抛 duplicate column name，
 * 由 migrateSessions 吞掉当「已迁移」处理 —— 比 PRAGMA 探测稳，不依赖 RDB 是否支持 pragma 查询。
 */
const SQL_MIGRATE_SESSION_COL: string =
  'ALTER TABLE ' + TABLE_NAME + ' ADD COLUMN session_id INTEGER NOT NULL DEFAULT 0';

export class ChatMemory {
  private store: relationalStore.RdbStore | undefined = undefined;
  private dbDir: string = '';
  /** 最近一次检索真正回捞进 BM25 的候选行数（面板显示「候选 M 条」，M = min(库内总数, RAG_CANDIDATES)） */
  private pool: number = 0;
  /** 当前会话 id：append / loadRecent / search 默认都只碰这个会话 */
  private cur: number = 0;
  /** 全库检索开关（跨会话）；默认关，避免话题串味 */
  private allScope: boolean = false;
  /** 本次启动迁移了多少条老消息到默认会话（面板/日志要报） */
  private migrated: number = 0;

  isReady(): boolean {
    return this.store !== undefined;
  }

  /** 当前会话 id（0 = 还没定下来） */
  currentSessionId(): number {
    return this.cur;
  }

  /**
   * 切会话：只改存库/检索的落点，不动 UI。
   * 顺手把 updated_ts 顶到最新 —— 会话列表按它排序，重启后也据此恢复到上次用的那个。
   */
  async setCurrentSession(id: number): Promise<boolean> {
    if (id <= 0) {
      return false;
    }
    this.cur = id;
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return false;
    }
    try {
      const args: Array<relationalStore.ValueType> = [Date.now(), id];
      await st.executeSql('UPDATE ' + TABLE_SESSIONS + ' SET updated_ts = ? WHERE id = ?', args);
      hilog.info(MEM_DOMAIN, MEM_TAG, 'session switch id=%{public}d', id);
      return true;
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'session switch failed: %{public}s', (e as Error).message);
      return false;
    }
  }

  /** 全库检索开关：开 = 跨会话，关 = 只当前会话（默认） */
  setGlobalSearch(on: boolean): void {
    this.allScope = on;
    hilog.info(MEM_DOMAIN, MEM_TAG, 'session scope=%{public}s', on ? 'all' : 'session');
  }

  globalSearch(): boolean {
    return this.allScope;
  }

  /** 本次启动迁移的旧消息条数 */
  migratedRows(): number {
    return this.migrated;
  }

  /** 全部会话，最近有动静的在前 */
  async listSessions(): Promise<SessionRow[]> {
    const out: SessionRow[] = [];
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return out;
    }
    try {
      const rs: relationalStore.ResultSet = await st.querySql(
        'SELECT s.id AS id, s.title AS title, s.created_ts AS created_ts, s.updated_ts AS updated_ts, '
          + '(SELECT COUNT(*) FROM ' + TABLE_NAME + ' m WHERE m.session_id = s.id) AS cnt '
          + 'FROM ' + TABLE_SESSIONS + ' s ORDER BY s.updated_ts DESC, s.id DESC');
      try {
        const ciId: number = rs.getColumnIndex('id');
        const ciTitle: number = rs.getColumnIndex('title');
        const ciCreated: number = rs.getColumnIndex('created_ts');
        const ciUpdated: number = rs.getColumnIndex('updated_ts');
        const ciCnt: number = rs.getColumnIndex('cnt');
        while (rs.goToNextRow()) {
          const row: SessionRow = {
            id: rs.getLong(ciId),
            title: rs.getString(ciTitle),
            createdTs: rs.getLong(ciCreated),
            updatedTs: rs.getLong(ciUpdated),
            count: rs.getLong(ciCnt)
          };
          out.push(row);
        }
      } finally {
        rs.close();
      }
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'session list failed: %{public}s', (e as Error).message);
    }
    return out;
  }

  async countSessions(): Promise<number> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet =
        await st.querySql('SELECT COUNT(*) AS c FROM ' + TABLE_SESSIONS);
      try {
        if (rs.goToFirstRow()) {
          return rs.getLong(rs.getColumnIndex('c'));
        }
      } finally {
        rs.close();
      }
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'session count failed: %{public}s', (e as Error).message);
    }
    return 0;
  }

  /** 新建会话，返回新 id（0 = 失败） */
  async createSession(title: string): Promise<number> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return 0;
    }
    const t: string = title.trim() === '' ? NEW_SESSION_TITLE : title.trim();
    const now: number = Date.now();
    try {
      const vb: relationalStore.ValuesBucket = {
        'title': t,
        'created_ts': now,
        'updated_ts': now
      };
      const id: number = await st.insert(TABLE_SESSIONS, vb);
      hilog.info(MEM_DOMAIN, MEM_TAG, 'session create id=%{public}d title=[%{public}s]', id, t);
      return id;
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'session create failed: %{public}s', (e as Error).message);
      return 0;
    }
  }

  async renameSession(id: number, title: string): Promise<boolean> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined || id <= 0) {
      return false;
    }
    const t: string = title.trim();
    if (t === '') {
      hilog.warn(MEM_DOMAIN, MEM_TAG, 'session rename refused reason=empty id=%{public}d', id);
      return false;
    }
    try {
      const vb: relationalStore.ValuesBucket = { 'title': t };
      const pred: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_SESSIONS);
      pred.equalTo('id', id);
      const rows: number = await st.update(vb, pred);
      hilog.info(MEM_DOMAIN, MEM_TAG, 'session rename id=%{public}d rows=%{public}d title=[%{public}s]',
        id, rows, t);
      return rows > 0;
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'session rename failed: %{public}s', (e as Error).message);
      return false;
    }
  }

  /**
   * 删会话：连同它的消息一起删。
   * 至少保留一个会话 —— 删到只剩一个时直接拒绝（UI 也会先挡一次，这里是第二道闸）。
   */
  async deleteSession(id: number): Promise<boolean> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined || id <= 0) {
      return false;
    }
    const total: number = await this.countSessions();
    if (total <= 1) {
      hilog.warn(MEM_DOMAIN, MEM_TAG, 'session delete refused reason=keep-one total=%{public}d', total);
      return false;
    }
    try {
      const pMsg: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_NAME);
      pMsg.equalTo('session_id', id);
      const msgRows: number = await st.delete(pMsg);
      const pSes: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_SESSIONS);
      pSes.equalTo('id', id);
      const rows: number = await st.delete(pSes);
      if (this.cur === id) {
        const rest: SessionRow[] = await this.listSessions();
        this.cur = rest.length > 0 ? rest[0].id : 0;
      }
      hilog.info(MEM_DOMAIN, MEM_TAG,
        'session delete id=%{public}d rows=%{public}d messages=%{public}d current=%{public}d',
        id, rows, msgRows, this.cur);
      return rows > 0;
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'session delete failed: %{public}s', (e as Error).message);
      return false;
    }
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
      await st.executeSql(SQL_CREATE_SESSIONS);
      this.store = st;
      // 顺序死规矩：先补 session_id 列（migrateSessions），再建带该列的索引 ——
      // 老库上先建索引会以 no such column 失败，整条 init 就废了（已真机踩到）
      await this.migrateSessions(st);
      await st.executeSql(SQL_INDEX_SESSION);
      const rows: number = await this.count();
      const ses: number = await this.countSessions();
      hilog.info(MEM_DOMAIN, MEM_TAG,
        'memory ready path=%{public}s table=%{public}s rows=%{public}d sessions=%{public}d current=%{public}d migrated=%{public}d',
        this.dbPath(), TABLE_NAME, rows, ses, this.cur, this.migrated);
      return true;
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'memory init failed: %{public}s', (e as Error).message);
      return false;
    }
  }

  /**
   * 追加一条到当前会话。role=user 的 mode 记 user，assistant 的记实际应答档位。
   * 写入同时把会话的 updated_ts 顶新，并在会话还是「新会话」时用这句话当标题。
   */
  async append(role: string, text: string, mode: string): Promise<boolean> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined || text === '') {
      return false;
    }
    const sid: number = this.cur;
    const now: number = Date.now();
    try {
      const args: Array<relationalStore.ValueType> = [role, text, now, mode, sid];
      await st.executeSql(
        'INSERT INTO ' + TABLE_NAME + ' (role, text, ts, mode, session_id) VALUES (?, ?, ?, ?, ?)', args);
      const args2: Array<relationalStore.ValueType> = [now, sid];
      await st.executeSql('UPDATE ' + TABLE_SESSIONS + ' SET updated_ts = ? WHERE id = ?', args2);
      if (role === 'user') {
        await this.autoTitle(sid, text);
      }
      return true;
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'memory append failed: %{public}s', (e as Error).message);
      return false;
    }
  }

  /** 会话还叫「新会话」时，拿第一句用户消息当标题；手改过的名字一律不动 */
  private async autoTitle(sid: number, text: string): Promise<void> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined || sid <= 0) {
      return;
    }
    try {
      const args: Array<relationalStore.ValueType> = [sid];
      const rs: relationalStore.ResultSet = await st.querySql(
        'SELECT title FROM ' + TABLE_SESSIONS + ' WHERE id = ?', args);
      let title: string = '';
      try {
        if (rs.goToFirstRow()) {
          title = rs.getString(rs.getColumnIndex('title'));
        }
      } finally {
        rs.close();
      }
      if (title !== NEW_SESSION_TITLE) {
        return;
      }
      let flat: string = text.split('\n').join(' ').split('\r').join(' ').trim();
      if (flat.length > AUTO_TITLE_CHARS) {
        flat = flat.substring(0, AUTO_TITLE_CHARS);
      }
      if (flat === '') {
        return;
      }
      await this.renameSession(sid, flat);
      hilog.info(MEM_DOMAIN, MEM_TAG, 'session auto title id=%{public}d title=[%{public}s]', sid, flat);
    } catch (e) {
      hilog.warn(MEM_DOMAIN, MEM_TAG, 'session auto title failed: %{public}s', (e as Error).message);
    }
  }

  /**
   * 建库后的会话迁移：补 session_id 列 → 至少一个会话 → 把 session_id=0 的老消息归进默认会话。
   * 绝不删老数据：老行只是被填上默认会话的 id。
   */
  private async migrateSessions(st: relationalStore.RdbStore): Promise<void> {
    let added: boolean = false;
    try {
      await st.executeSql(SQL_MIGRATE_SESSION_COL);
      added = true;
    } catch (e) {
      // 列已存在：SQLite 抛 duplicate column name，这是「已迁移过」的正常路径
      hilog.info(MEM_DOMAIN, MEM_TAG, 'session column already present: %{public}s',
        (e as Error).message);
    }
    let total: number = await this.countSessions();
    if (total === 0) {
      const id: number = await this.createSession(DEFAULT_SESSION_TITLE);
      hilog.info(MEM_DOMAIN, MEM_TAG, 'session default created id=%{public}d', id);
      total = await this.countSessions();
    }
    const defId: number = await this.firstSessionId();
    let legacy: number = 0;
    try {
      const rs: relationalStore.ResultSet = await st.querySql(
        'SELECT COUNT(*) AS c FROM ' + TABLE_NAME + ' WHERE session_id = 0 OR session_id IS NULL');
      try {
        if (rs.goToFirstRow()) {
          legacy = rs.getLong(rs.getColumnIndex('c'));
        }
      } finally {
        rs.close();
      }
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'session legacy count failed: %{public}s', (e as Error).message);
    }
    if (legacy > 0 && defId > 0) {
      const args: Array<relationalStore.ValueType> = [defId];
      await st.executeSql(
        'UPDATE ' + TABLE_NAME + ' SET session_id = ? WHERE session_id = 0 OR session_id IS NULL', args);
    }
    this.migrated = legacy;
    this.cur = await this.latestSessionId();
    if (this.cur <= 0) {
      this.cur = defId;
    }
    hilog.info(MEM_DOMAIN, MEM_TAG,
      'session migrate addedColumn=%{public}s legacyRows=%{public}d sessions=%{public}d default=%{public}d current=%{public}d',
      '' + added, legacy, total, defId, this.cur);
  }

  /** 最早建的那个会话（老消息的归属，也是「默认会话」） */
  private async firstSessionId(): Promise<number> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet =
        await st.querySql('SELECT MIN(id) AS m FROM ' + TABLE_SESSIONS);
      try {
        if (rs.goToFirstRow()) {
          return rs.getLong(rs.getColumnIndex('m'));
        }
      } finally {
        rs.close();
      }
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'session first failed: %{public}s', (e as Error).message);
    }
    return 0;
  }

  /** 上次动过的会话（重启后接着用） */
  private async latestSessionId(): Promise<number> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = await st.querySql(
        'SELECT id FROM ' + TABLE_SESSIONS + ' ORDER BY updated_ts DESC, id DESC LIMIT 1');
      try {
        if (rs.goToFirstRow()) {
          return rs.getLong(rs.getColumnIndex('id'));
        }
      } finally {
        rs.close();
      }
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'session latest failed: %{public}s', (e as Error).message);
    }
    return 0;
  }

  /** 当前会话的最近 limit 条，按时间正序返回（旧 → 新，直接喂 List） */
  async loadRecent(limit: number): Promise<MemRow[]> {
    const rows: MemRow[] = [];
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return rows;
    }
    try {
      const args: Array<relationalStore.ValueType> = [this.cur, limit];
      const rs: relationalStore.ResultSet = await st.querySql(
        'SELECT id, role, text, ts, mode FROM ' + TABLE_NAME
          + ' WHERE session_id = ? ORDER BY id DESC LIMIT ?', args);
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

  /**
   * 回捞检索候选集（最近 limit 条，时间正序）。
   * 默认只回捞当前会话的行：跨会话检索会让「会话 A 说的口味」跑进会话 B 的 prompt。
   */
  private async loadDocs(limit: number): Promise<RagDoc[]> {
    const docs: RagDoc[] = [];
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return docs;
    }
    try {
      const args: Array<relationalStore.ValueType> = this.allScope
        ? [limit] : [this.cur, limit];
      const sql: string = this.allScope
        ? 'SELECT id, role, text, ts FROM ' + TABLE_NAME + ' ORDER BY id DESC LIMIT ?'
        : 'SELECT id, role, text, ts FROM ' + TABLE_NAME
          + ' WHERE session_id = ? ORDER BY id DESC LIMIT ?';
      const rs: relationalStore.ResultSet = await st.querySql(sql, args);
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
      'memory search query=[%{public}s] scope=%{public}s session=%{public}d candidates=%{public}d pool=%{public}d hits=%{public}d',
      q.substring(0, 30), this.allScope ? 'all' : 'session', this.cur, this.pool, pool.length, hits.length);
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

  /** 当前会话的全部消息，按时间正序（导出用；limit 只是防呆上限） */
  async loadAll(limit: number): Promise<MemRow[]> {
    const rows: MemRow[] = [];
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      return rows;
    }
    try {
      const args: Array<relationalStore.ValueType> = [this.cur, limit];
      const rs: relationalStore.ResultSet = await st.querySql(
        'SELECT id, role, text, ts, mode FROM ' + TABLE_NAME
          + ' WHERE session_id = ? ORDER BY id ASC LIMIT ?', args);
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
    } catch (e) {
      hilog.error(MEM_DOMAIN, MEM_TAG, 'memory loadAll failed: %{public}s', (e as Error).message);
    }
    return rows;
  }

  /**
   * 整库备份：用 RDB 自带的 backup() 出一份一致性快照（边写边拷贝可能拷到半个事务），
   * 再把快照复制到调用方给的路径（沙箱内可分享位置）。失败一律抛错，不静默。
   */
  async backupDatabase(destPath: string): Promise<string> {
    const st: relationalStore.RdbStore | undefined = this.store;
    if (st === undefined) {
      throw new Error('数据库未就绪（init 失败或还没跑）');
    }
    const snapName: string = 'cybertwin_backup.db';
    await st.backup(snapName);
    const src: string = (this.dbDir === '' ? '.' : this.dbDir) + '/' + snapName;
    if (!fs.accessSync(src)) {
      throw new Error('备份快照没生成：' + src);
    }
    fs.copyFileSync(src, destPath);
    const size: number = fs.statSync(destPath).size;
    if (size <= 0) {
      throw new Error('备份文件是空的：' + destPath);
    }
    hilog.info(MEM_DOMAIN, MEM_TAG, 'memory backup src=%{public}s dest=%{public}s bytes=%{public}d',
      src, destPath, size);
    return destPath;
  }

  /** 清空全部记录（保留表结构与自增序列，避免 id 复用干扰排序）；会话本身保留 */
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

function two(n: number): string {
  return n < 10 ? '0' + n : '' + n;
}

/** 日志/文件名用时间戳：2026-11-17 21:36:05 */
export function formatStamp(ts: number): string {
  const d: Date = new Date(ts);
  return d.getFullYear() + '-' + two(d.getMonth() + 1) + '-' + two(d.getDate()) + ' '
    + two(d.getHours()) + ':' + two(d.getMinutes()) + ':' + two(d.getSeconds());
}

/** 会话列表用短时间：11-17 21:36 */
export function formatShort(ts: number): string {
  const d: Date = new Date(ts);
  return two(d.getMonth() + 1) + '-' + two(d.getDate()) + ' ' + two(d.getHours()) + ':' + two(d.getMinutes());
}

/** 文件名安全化：去掉路径分隔符与 Windows/手机都不吃的字符 */
export function safeFileStem(title: string): string {
  const raw: string = title.trim() === '' ? 'session' : title.trim();
  let out: string = '';
  for (let i: number = 0; i < raw.length && out.length < 24; i++) {
    const ch: string = raw.charAt(i);
    if ('/\\:*?"<>| '.indexOf(ch) >= 0) {
      continue;
    }
    out += ch;
  }
  return out === '' ? 'session' : out;
}

/**
 * 会话导出成 Markdown：一级标题是会话名，正文按时间顺序一行一句，
 * 用户侧署名「先生」、分身侧署名「苏兴」（与人格底线一致）。
 */
export function buildSessionMarkdown(title: string, rows: MemRow[], exportedTs: number): string {
  const head: string = title.trim() === '' ? '苏兴会话' : title.trim();
  const out: string[] = ['# ' + head, ''];
  let used: number = 0;
  for (const r of rows) {
    const body: string = r.text.split('\r').join('');
    if (body.trim() === '') {
      continue;
    }
    out.push((r.role === 'user' ? '**先生：** ' : '**苏兴：** ') + body);
    out.push('');
    used++;
  }
  out.push('---');
  out.push('由苏兴导出 · ' + formatStamp(exportedTs) + ' · 共 ' + used + ' 条');
  return out.join('\n');
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
