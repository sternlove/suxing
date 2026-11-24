/**
 * 文档技能（Doc Skill）—— 借鉴 homerail / Agent Skills 的 SKILL.md 设计。
 *
 * 与内置技能（Skill.ets 的代码技能）的根本区别：
 *   代码技能  由宿主执行逻辑，能力边界写死在 ArkTS 里，加一个要改代码 + 重新编译。
 *   文档技能  只是一段 Markdown 说明书，运行时读出来拼进 prompt，**由模型自己照着做**。
 *             加技能 = 往沙箱里放一个文件夹，不用编译、不用重启。
 *
 * 目录结构（与 homerail 一致）：
 *   <filesDir>/skills/<skill-id>/SKILL.md
 *
 * SKILL.md 格式（YAML frontmatter + 正文）：
 *   ---
 *   name: 技能名
 *   description: |
 *     这个技能是干什么的。Use to ...（写清楚什么场景该用它，匹配就靠这段）
 *   ---
 *   # 正文：操作步骤、命令、注意事项 —— 会被完整拼进 prompt
 *
 * 匹配策略：
 *   没有向量也没关系，用 description 里的关键词做粗筛（中文按字，英文按词）。
 *   命中就把正文塞进 system prompt，模型读到就知道怎么做。
 *   这比代码技能的「触发词精确包含」更宽松，也更贴合「技能是说明书」的定位。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';

/** 技能正文拼进 prompt 的字数上限：太大把上下文挤爆，太小信息不够 */
const BODY_MAX_CHARS: number = 1500;
/** 一次最多注入几个技能 */
const MAX_INJECT: number = 1;

export interface DocSkill {
  /** 目录名，作为稳定 id */
  id: string;
  /** frontmatter 的 name */
  name: string;
  /** frontmatter 的 description（同时用于匹配） */
  description: string;
  /** 去掉 frontmatter 的正文 */
  body: string;
  /** SKILL.md 绝对路径 */
  path: string;
}

/** 极简 frontmatter 解析：只认 --- 之间、形如 key: value 的行，够用即可 */
function parseFrontmatter(raw: string): DocSkill | undefined {
  const text: string = raw.replace(/\r\n/g, '\n');
  if (!text.startsWith('---')) {
    return undefined;
  }
  const end: number = text.indexOf('\n---', 3);
  if (end < 0) {
    return undefined;
  }
  const head: string = text.substring(3, end);
  const body: string = text.substring(end + 4).trim();

  let name: string = '';
  let description: string = '';
  const lines: string[] = head.split('\n');
  let curKey: string = '';
  for (let i = 0; i < lines.length; i++) {
    const ln: string = lines[i];
    const trimmed: string = ln.trim();
    if (trimmed === '') {
      continue;
    }
    // 形如 "key: value" 或 "key: |"
    const ci: number = trimmed.indexOf(':');
    if (ci > 0 && (ln === trimmed || ln.startsWith('  ') === false)) {
      const k: string = trimmed.substring(0, ci).trim().toLowerCase();
      let v: string = trimmed.substring(ci + 1).trim();
      if (v === '|' || v === '>') {
        v = '';
      }
      curKey = k;
      if (k === 'name') {
        name = v;
      } else if (k === 'description') {
        description = v;
      }
    } else if (curKey === 'description') {
      // 多行 description 的续行
      description += (description === '' ? '' : ' ') + trimmed;
    }
  }
  if (name === '' && description === '') {
    return undefined;
  }
  return { id: '', name: name, description: description, body: body, path: '' };
}

/** 首次启动写进沙箱的示例技能：让用户不用自己造文件也能看到效果 */
const SAMPLE_SKILL: string = `---
name: 翻译
description: |
  把文本翻译成目标语言，只给译文不给解释。
  Use to 翻译、translate、英文、中译英、英译中、这句英文什么意思。
---

# 翻译

1. 判断目标语言：用户没说就按「中文↔英文」互译。
2. 只输出译文，不要输出原文、不要解释、不要加引号。
3. 保留原文的换行与标点风格；专有名词保留原文。
4. 译文不确定时，在译文后用括号补一句简短说明。
`;

export class DocSkillStore {
  private skills: DocSkill[] = [];
  private loaded: boolean = false;

  /**
   * 首次启动写入示例技能（只创建不存在的，绝不覆盖用户自己的）。
   * 没有示例的话，用户不知道 SKILL.md 该长什么样，也不知道去哪放。
   */
  ensureSample(filesDir: string): boolean {
    const dir: string = filesDir + '/skills';
    const sub: string = dir + '/translate';
    const file: string = sub + '/SKILL.md';
    try {
      if (fs.accessSync(file)) {
        return false;
      }
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      if (!fs.accessSync(sub)) {
        fs.mkdirSync(sub);
      }
      const f = fs.openSync(file, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      try {
        fs.writeSync(f.fd, SAMPLE_SKILL);
      } finally {
        fs.closeSync(f);
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'docskill sample written: %{public}s', file);
      return true;
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'docskill sample failed: %{public}s', (e as Error).message);
      return false;
    }
  }

  /** 扫描 <filesDir>/skills/<id>/SKILL.md，解析后缓存在内存 */
  scan(filesDir: string): number {
    this.skills = [];
    const root: string = filesDir + '/skills';
    try {
      if (!fs.accessSync(root)) {
        this.loaded = true;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'docskill root absent, skip: %{public}s', root);
        return 0;
      }
      const dirs: string[] = fs.listFileSync(root);
      for (let i = 0; i < dirs.length; i++) {
        const id: string = dirs[i];
        const p: string = root + '/' + id + '/SKILL.md';
        try {
          if (!fs.accessSync(p)) {
            continue;
          }
          const raw: string = fs.readTextSync(p);
          const parsed: DocSkill | undefined = parseFrontmatter(raw);
          if (parsed === undefined) {
            hilog.warn(LOG_DOMAIN, LOG_TAG, 'docskill bad frontmatter: %{public}s', p);
            continue;
          }
          parsed.id = id;
          parsed.path = p;
          this.skills.push(parsed);
        } catch (e) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'docskill read failed %{public}s: %{public}s',
            p, (e as Error).message);
        }
      }
      this.loaded = true;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'docskill scanned root=%{public}s count=%{public}d',
        root, this.skills.length);
    } catch (e) {
      this.loaded = true;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'docskill scan failed: %{public}s', (e as Error).message);
    }
    return this.skills.length;
  }

  count(): number {
    return this.skills.length;
  }

  names(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.skills.length; i++) {
      out.push(this.skills[i].name);
    }
    return out;
  }

  /**
   * 按用户输入匹配最相关的文档技能。
   * 打分：name 命中 +3，description 里每个命中的二元组 +1。
   * 不追求精确 —— 文档技能是「给模型看的说明书」，宁可多给一份也别漏。
   */
  match(input: string): DocSkill[] {
    const q: string = input.trim().toLowerCase();
    if (q === '' || this.skills.length === 0) {
      return [];
    }
    const scored: DocSkill[] = [];
    const score: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < this.skills.length; i++) {
      const s: DocSkill = this.skills[i];
      let sc: number = 0;
      if (s.name !== '' && q.indexOf(s.name.toLowerCase()) >= 0) {
        sc += 3;
      }
      const desc: string = s.description.toLowerCase();
      // 中文按二元组、英文按词，粗略命中即可
      for (let a = 0; a + 2 <= q.length; a++) {
        const bg: string = q.substring(a, a + 2);
        if (bg.trim().length < 2) {
          continue;
        }
        if (desc.indexOf(bg) >= 0) {
          sc += 1;
        }
      }
      if (sc > 0) {
        score.set(s.id, sc);
        scored.push(s);
      }
    }
    scored.sort((x: DocSkill, y: DocSkill) => (score.get(y.id) ?? 0) - (score.get(x.id) ?? 0));
    return scored.slice(0, MAX_INJECT);
  }

  /**
   * 把技能要求改写进 **user 消息**。
   *
   * 为什么不能只放 system：1.7B 对 system 里的长指令不敏感，实测把
   * 「翻译今天天气不错」当成陈述句复述（回了「先生，今天天气不错。」）。
   * user 消息离生成位置最近，祈使句放这里命中率高得多。
   * system 里的技能正文仍然保留（双保险），但执行指令以 user 这条为准。
   */
  buildUserPrompt(hits: DocSkill[], userInput: string): string {
    if (hits.length === 0) {
      return userInput;
    }
    const s0: DocSkill = hits[0];
    let content: string = userInput.trim();
    const name: string = s0.name;
    if (name !== '' && content.startsWith(name)) {
      content = content.substring(name.length).trim();
    }
    const lead: string[] = ['请用', '帮我', '麻烦', '用'];
    for (let i = 0; i < lead.length; i++) {
      if (content.startsWith(lead[i])) {
        content = content.substring(lead[i].length).trim();
        if (name !== '' && content.startsWith(name)) {
          content = content.substring(name.length).trim();
        }
        break;
      }
    }
    if (content === '') {
      content = userInput.trim();
    }
    // 只把「做什么」写进 user；具体规则仍在 system 里
    return '按「' + name + '」的要求处理下面这段内容，直接给结果，不要重复原文也不要解释：\n' + content;
  }

  /**
   * 拼成 prompt 片段。
   *
   * 措辞很关键：第一版写的是「以下是你掌握的操作技能，需要时照着做」——
   * 那是**描述**，1.7B 读完不知道该不该现在做，实测不会执行（日志能证明注入成功但没照做）。
   * 改成**祈使句 + 明确告知要处理的内容**，并把技能名从内容里剥掉
   * （用户说「翻译今天天气不错」，剥掉「翻译」后模型只需处理「今天天气不错」，负担更小）。
   */
  buildBlock(hits: DocSkill[], userInput: string): string {
    if (hits.length === 0) {
      return '';
    }
    const s0: DocSkill = hits[0];
    let body: string = s0.body;
    let cut: boolean = false;
    if (body.length > BODY_MAX_CHARS) {
      body = body.substring(0, BODY_MAX_CHARS);
      cut = true;
    }
    let content: string = userInput.trim();
    // 剥掉开头的技能名或「用/请/帮我」这类前缀，剩下的才是要处理的内容
    const name: string = s0.name;
    if (name !== '' && content.startsWith(name)) {
      content = content.substring(name.length).trim();
    }
    const lead: string[] = ['请用', '帮我', '麻烦', '用', '帮我用'];
    for (let i = 0; i < lead.length; i++) {
      if (content.startsWith(lead[i])) {
        content = content.substring(lead[i].length).trim();
        if (name !== '' && content.startsWith(name)) {
          content = content.substring(name.length).trim();
        }
        break;
      }
    }
    let block: string = '现在请立刻执行【' + s0.name + '】技能，不要解释你在做什么，直接给结果。\n';
    block += '技能要求：\n' + body + (cut ? '\n…（已截断）' : '') + '\n';
    if (content !== '') {
      block += '要处理的内容：' + content;
    } else {
      block += '要处理的内容：见用户这句话。';
    }
    return block;
  }
}
