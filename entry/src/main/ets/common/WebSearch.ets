/**
 * 联网检索：SearXNG 客户端。
 *
 * 为什么选 SearXNG 而不是直接调某个搜索 API：
 *   - 它聚合多个引擎，结果更全，且单个引擎限流也不至于全挂
 *   - 可以自建实例，没有 key、没有配额、不绑定厂商
 *   - 返回标准 JSON
 *
 * 使用前提：实例必须开启 json 格式（settings.yml 里 search.formats 要包含 json），
 * 默认只给 html，不开的话这里会拿到 HTML 而不是 JSON。
 *
 * 接口：GET {base}/search?q=关键词&format=json&language=zh-CN&safesearch=1
 * 返回：{ query, results: [{ url, title, content, engine }] }
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';

/** 一次检索最多取几条：太多会把 prompt 撑爆，太少参考不足 */
const MAX_RESULTS: number = 5;
/** 每条摘要截断长度 */
const SNIPPET_MAX: number = 160;
/**
 * 超时。12s → 9s：SearXNG 聚合多引擎本身就慢，但超过 9 秒还没回，
 * 用户在界面上已经等了十几秒（首字 + 检索），体验崩了。
 * 宁可拿部分结果，也不要让用户干等。
 */
const TIMEOUT_MS: number = 9000;

export interface SearchItem {
  title: string;
  url: string;
  snippet: string;
  engine: string;
  /** 发布时间（部分引擎提供，没有就是空串） */
  published: string;
}

export interface SearchOutcome {
  ok: boolean;
  /** 失败原因 / 成功时的条数说明 */
  message: string;
  items: SearchItem[];
}

export class WebSearch {
  /**
   * 检索。baseUrl 形如 http://192.168.1.5:8080（不带 /search）。
   * timeRange：'day' | 'week' | 'month' | ''，用来压掉陈旧结果
   * （用户反馈「有时出来几天前的」，SearXNG 默认按相关性排序，不按时间）。
   */
  static async query(baseUrl: string, keyword: string, timeRange?: string): Promise<SearchOutcome> {
    const q: string = keyword.trim();
    if (q === '') {
      return { ok: false, message: '关键词为空', items: [] };
    }
    if (baseUrl === '') {
      return { ok: false, message: '没有配置搜索服务地址', items: [] };
    }
    const base: string = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    // 关键：format=json 必须带，否则实例返回 HTML
    const tr: string = timeRange ?? 'week';
    let url: string = base + '/search?q=' + encodeURIComponent(q)
      + '&format=json&language=zh-CN&safesearch=1';
    if (tr !== '') {
      url += '&time_range=' + tr;
    }

    const req: http.HttpRequest = http.createHttp();
    try {
      const t0: number = Date.now();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'search -> %{public}s', url.substring(0, 140));
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'Accept': 'application/json' },
        connectTimeout: TIMEOUT_MS,
        readTimeout: TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const code: number = resp.responseCode;
      const raw: string = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
      if (code < 200 || code >= 300) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'search http %{public}d', code);
        return { ok: false, message: '搜索服务返回 HTTP ' + code + '（实例可能没开 json 格式）', items: [] };
      }
      if (!raw.trim().startsWith('{')) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'search got non-json head=[%{public}s]',
          raw.substring(0, 60));
        return { ok: false, message: '返回的不是 JSON：实例需要开启 json 格式', items: [] };
      }
      const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const arr: Object[] = (obj.results as Object[]) ?? [];
      const items: SearchItem[] = [];
      for (let i = 0; i < arr.length && items.length < MAX_RESULTS; i++) {
        const r: Record<string, Object> = arr[i] as Record<string, Object>;
        const title: string = (r.title as string) ?? '';
        const link: string = (r.url as string) ?? '';
        if (title === '' && link === '') {
          continue;
        }
        let sn: string = (r.content as string) ?? '';
        sn = sn.replace(/\s+/g, ' ').trim();
        if (sn.length > SNIPPET_MAX) {
          sn = sn.substring(0, SNIPPET_MAX) + '…';
        }
        // publishedDate 只有部分引擎给（多为 ISO 时间），截到日期即可
        let pub: string = (r.publishedDate as string) ?? '';
        if (pub.length >= 10) {
          pub = pub.substring(0, 10);
        }
        items.push({
          title: title,
          url: link,
          snippet: sn,
          engine: (r.engine as string) ?? '',
          published: pub
        });
      }
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'search ok q=[%{public}s] range=%{public}s total=%{public}d kept=%{public}d ms=%{public}d',
        q.substring(0, 30), tr, arr.length, items.length, Date.now() - t0);
      return { ok: items.length > 0, message: items.length > 0 ? ('命中 ' + items.length + ' 条') : '没有检索到结果', items: items };
    } catch (e) {
      const err: Error = e as Error;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'search failed: %{public}s', err.message);
      return { ok: false, message: '搜索失败：' + err.message, items: [] };
    } finally {
      req.destroy();
    }
  }

  /** 把结果拼成给模型看的上下文 */
  static buildBlock(items: SearchItem[]): string {
    if (items.length === 0) {
      return '';
    }
    const parts: string[] = [];
    for (let i = 0; i < items.length; i++) {
      const it: SearchItem = items[i];
      const timeTag: string = it.published === '' ? '' : ('（' + it.published + '）');
      parts.push((i + 1) + '. ' + it.title + timeTag + '\n   ' + it.snippet);
    }
    return '以下是从网上检索到的资料（括号里是发布时间，请据此回答；'
      + '资料里没有的内容不要编造，也不要拿旧数据当现在的数据）：\n' + parts.join('\n');
  }

  /** 纯文本结果（用于直接展示给用户，比如技能场景） */
  static buildPlain(items: SearchItem[]): string {
    if (items.length === 0) {
      return '没有检索到结果。';
    }
    const parts: string[] = [];
    for (let i = 0; i < items.length; i++) {
      const it: SearchItem = items[i];
      const timeTag: string = it.published === '' ? '' : ('  ' + it.published);
      parts.push((i + 1) + '. ' + it.title + timeTag + '\n' + it.snippet + (it.url !== '' ? '\n' + it.url : ''));
    }
    return parts.join('\n\n');
  }
}
