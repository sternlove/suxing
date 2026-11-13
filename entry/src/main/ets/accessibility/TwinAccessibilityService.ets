import {
  AccessibilityExtensionAbility,
  AccessibilityExtensionContext,
  AccessibilityElement,
  AccessibilityEvent,
  GesturePath,
  GesturePoint
} from '@kit.AccessibilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  TWIN_DOMAIN,
  TWIN_TAG,
  CMD_FILE,
  STATUS_FILE,
  WECHAT_BUNDLE,
  WECHAT_CONTACT,
  WECHAT_MSG,
  TwinCmd,
  TwinStatus,
  emptyStatus,
  joinPath,
  fileExists,
  readTextFile,
  writeTextFile,
  removeFile,
  parseCmd,
  statusToJson
} from '../common/TwinProto';

/** performAction('setText', …) 的参数体，d.ts 明确要求带 setText 参数 */
interface SetTextParams {
  setText: string;
}

/** 一次读屏抓到的节点（保留原始句柄，点击时直接用它） */
class NodeInfo {
  el: AccessibilityElement | undefined = undefined;
  text: string = '';
  type: string = '';
  clickable: boolean = false;
  editable: boolean = false;
  left: number = 0;
  top: number = 0;
  width: number = 0;
  height: number = 0;
}

class QItem {
  el: AccessibilityElement;
  depth: number;

  constructor(el: AccessibilityElement, depth: number) {
    this.el = el;
    this.depth = depth;
  }
}

/**
 * 苏兴无障碍扩展。
 *
 * 生命周期：系统在无障碍开关打开时拉起本进程并 bind，此后持续收到 onAccessibilityEvent。
 * 指令来源：UI 进程写入 twin_cmd.json → 本类用 setInterval + 事件双通道轮询 → 执行 → 回写 twin_status.json。
 * 之所以不用直接调用：AccessibilityExtensionContext 只存在于本进程。
 */
export default class TwinAccessibilityService extends AccessibilityExtensionAbility {
  private status: TwinStatus = emptyStatus();
  private lastCmdId: number = -1;
  private lastCheckAt: number = 0;
  private busy: boolean = false;
  private timer: number = -1;
  private lastBundle: string = '';
  private lastEventType: string = '';
  private eventCount: number = 0;

  onConnect(): void {
    hilog.info(TWIN_DOMAIN, TWIN_TAG, 'ACC onConnect: 无障碍扩展已连接，dir=%{public}s', this.baseDir());
    this.status = emptyStatus();
    this.logStep('无障碍扩展已连接');
    this.startPoll();
  }

  onDisconnect(): void {
    hilog.info(TWIN_DOMAIN, TWIN_TAG, 'ACC onDisconnect');
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  onAccessibilityEvent(event: AccessibilityEvent): void {
    this.eventCount++;
    this.lastEventType = event.eventType;
    if (this.eventCount <= 5) {
      hilog.info(TWIN_DOMAIN, TWIN_TAG, 'ACC event #%{public}d type=%{public}s', this.eventCount, this.lastEventType);
    }
    // 事件通道：有新指令就立刻执行，不必等定时器
    const now: number = Date.now();
    if (now - this.lastCheckAt > 300) {
      this.lastCheckAt = now;
      this.tick();
    }
  }

  // ---------------------------------------------------------------- 指令通道

  private startPoll(): void {
    if (this.timer !== -1) {
      return;
    }
    this.timer = setInterval(() => {
      this.lastCheckAt = Date.now();
      this.tick();
    }, 500);
    hilog.info(TWIN_DOMAIN, TWIN_TAG, 'ACC poll timer started');
  }

  private tick(): void {
    if (this.busy) {
      return;
    }
    const dir: string = this.baseDir();
    if (dir === '') {
      return;
    }
    const cmdPath: string = joinPath(dir, CMD_FILE);
    if (!fileExists(cmdPath)) {
      return;
    }
    const raw: string = readTextFile(cmdPath);
    removeFile(cmdPath);
    const cmd: TwinCmd | undefined = parseCmd(raw);
    if (cmd === undefined) {
      hilog.error(TWIN_DOMAIN, TWIN_TAG, 'ACC 收到无法解析的指令');
      return;
    }
    if (cmd.id === this.lastCmdId) {
      return;
    }
    this.lastCmdId = cmd.id;
    this.busy = true;
    hilog.info(TWIN_DOMAIN, TWIN_TAG, 'ACC 收到指令 id=%{public}d op=%{public}s', cmd.id, cmd.op);
    this.run(cmd).then(() => {
      this.busy = false;
      hilog.info(TWIN_DOMAIN, TWIN_TAG, 'ACC 指令结束 id=%{public}d', cmd.id);
    }).catch((e: Error) => {
      this.busy = false;
      this.status.state = 'error';
      this.logStep('指令异常：' + e.message);
      hilog.error(TWIN_DOMAIN, TWIN_TAG, 'ACC 指令异常 id=%{public}d err=%{public}s', cmd.id, e.message);
    });
  }

  private async run(cmd: TwinCmd): Promise<void> {
    const st = emptyStatus();
    st.id = cmd.id;
    st.op = cmd.op;
    st.state = 'running';
    st.ts = Date.now();
    this.status = st;
    this.logStep('开始执行 op=' + cmd.op);
    try {
      if (cmd.op === 'dump') {
        await this.doDump();
      } else if (cmd.op === 'tap') {
        await this.doTap(cmd.text);
      } else if (cmd.op === 'type') {
        await this.doType(cmd.text);
      } else if (cmd.op === 'back') {
        await this.doBack();
      } else if (cmd.op === 'home') {
        await this.doHome();
      } else if (cmd.op === 'swipe') {
        this.swipe(660, 2100, 660, 900, '上滑');
      } else if (cmd.op === 'wechat') {
        await this.doWechat(cmd.text, cmd.msg);
      } else {
        this.logStep('未知指令：' + cmd.op);
      }
      if (this.status.state !== 'error') {
        this.status.state = 'done';
      }
    } catch (e) {
      this.status.state = 'error';
      this.logStep('异常：' + (e as Error).message);
      hilog.error(TWIN_DOMAIN, TWIN_TAG, 'ACC run failed: %{public}s', (e as Error).message);
    }
    this.status.ts = Date.now();
    this.flush();
  }

  // ---------------------------------------------------------------- 基础能力

  private baseDir(): string {
    try {
      const dir: string = this.context.getApplicationContext().filesDir;
      if (dir !== undefined && dir !== '') {
        return dir;
      }
    } catch (e) {
      hilog.error(TWIN_DOMAIN, TWIN_TAG, 'app filesDir failed: %{public}s', (e as Error).message);
    }
    try {
      return this.context.filesDir;
    } catch (e) {
      return '';
    }
  }

  private flush(): void {
    const dir: string = this.baseDir();
    if (dir === '') {
      return;
    }
    writeTextFile(joinPath(dir, STATUS_FILE), statusToJson(this.status));
  }

  private logStep(msg: string): void {
    hilog.info(TWIN_DOMAIN, TWIN_TAG, 'ACC %{public}s', msg);
    this.status.steps.push(msg);
    if (this.status.steps.length > 120) {
      this.status.steps.shift();
    }
    this.flush();
  }

  private step(n: number, msg: string): void {
    this.status.step = n;
    this.logStep('第 ' + n + ' 步：' + msg);
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: (value: void) => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 只读前台包名（比 collect 便宜很多，用于等待某个应用到前台） */
  private async currentBundle(): Promise<string> {
    try {
      const wins: AccessibilityElement[] = await this.context.getWindows();
      for (let i = 0; i < wins.length; i++) {
        const w: AccessibilityElement = wins[i];
        let active: boolean = false;
        try {
          active = await w.attributeValue('isActive');
        } catch (e) {
          active = false;
        }
        if (active) {
          try {
            return await w.attributeValue('bundleName');
          } catch (e) {
            return '';
          }
        }
      }
    } catch (e) {
      hilog.error(TWIN_DOMAIN, TWIN_TAG, 'currentBundle failed: %{public}s', (e as Error).message);
    }
    return '';
  }

  /** 抓取当前活动窗口的节点树；顺带记录前台包名 */
  private async collect(maxNodes: number): Promise<NodeInfo[]> {
    const out: NodeInfo[] = [];
    let wins: AccessibilityElement[] = [];
    try {
      wins = await this.context.getWindows();
    } catch (e) {
      this.logStep('getWindows 失败：' + (e as Error).message);
      return out;
    }
    let activeId: number = -1;
    let activeBundle: string = '';
    let firstId: number = -1;
    let firstBundle: string = '';
    for (let i = 0; i < wins.length; i++) {
      const w: AccessibilityElement = wins[i];
      let bundleName: string = '';
      let winId: number = -1;
      let isActive: boolean = false;
      let wtype: string = '';
      try {
        bundleName = await w.attributeValue('bundleName');
      } catch (e) {
        bundleName = '';
      }
      try {
        winId = await w.attributeValue('windowId');
      } catch (e) {
        winId = -1;
      }
      try {
        isActive = await w.attributeValue('isActive');
      } catch (e) {
        isActive = false;
      }
      try {
        wtype = await w.attributeValue('type');
      } catch (e) {
        wtype = '';
      }
      if (i < 12) {
        hilog.info(TWIN_DOMAIN, TWIN_TAG, 'ACC window#%{public}d bundle=%{public}s id=%{public}d active=%{public}s type=%{public}s',
          i, bundleName, winId, '' + isActive, wtype);
      }
      if (firstId < 0) {
        firstId = winId;
        firstBundle = bundleName;
      }
      if (isActive && activeId < 0) {
        activeId = winId;
        activeBundle = bundleName;
      }
    }
    const rootId: number = activeId >= 0 ? activeId : firstId;
    this.lastBundle = activeId >= 0 ? activeBundle : firstBundle;
    if (rootId < 0) {
      this.logStep('没有可用窗口');
      return out;
    }
    let root: AccessibilityElement | undefined = undefined;
    try {
      root = await this.context.getWindowRootElement(rootId);
    } catch (e) {
      this.logStep('getWindowRootElement 失败：' + (e as Error).message);
      return out;
    }
    if (root === undefined) {
      return out;
    }
    const queue: QItem[] = [];
    queue.push(new QItem(root, 0));
    let head: number = 0;
    while (head < queue.length && out.length < maxNodes) {
      const item: QItem = queue[head];
      head++;
      const el: AccessibilityElement = item.el;
      const n = new NodeInfo();
      n.el = el;
      try {
        const t: string = await el.attributeValue('text');
        n.text = typeof t === 'string' ? t.trim() : '';
      } catch (e) {
        n.text = '';
      }
      try {
        const ty: string = await el.attributeValue('componentType');
        n.type = typeof ty === 'string' ? ty : '';
      } catch (e) {
        n.type = '';
      }
      try {
        n.clickable = await el.attributeValue('clickable');
      } catch (e) {
        n.clickable = false;
      }
      try {
        n.editable = await el.attributeValue('editable');
      } catch (e) {
        n.editable = false;
      }
      try {
        const rc = await el.attributeValue('rect');
        n.left = rc.left;
        n.top = rc.top;
        n.width = rc.width;
        n.height = rc.height;
      } catch (e) {
        n.left = 0;
        n.top = 0;
        n.width = 0;
        n.height = 0;
      }
      out.push(n);
      if (item.depth < 30) {
        try {
          const kids: AccessibilityElement[] = await el.attributeValue('children');
          for (let k = 0; k < kids.length; k++) {
            queue.push(new QItem(kids[k], item.depth + 1));
          }
        } catch (e) {
          hilog.warn(TWIN_DOMAIN, TWIN_TAG, 'ACC 取 children 失败');
        }
      }
    }
    this.logStep('读屏：前台包名=' + this.lastBundle + '，节点 ' + out.length + ' 个');
    return out;
  }

  private textsOf(nodes: NodeInfo[], cap: number): string[] {
    const out: string[] = [];
    for (let i = 0; i < nodes.length && out.length < cap; i++) {
      const t: string = nodes[i].text;
      if (t !== '' && out.indexOf(t) < 0) {
        out.push(t);
      }
    }
    return out;
  }

  private dumpNodes(nodes: NodeInfo[], cap: number): void {
    const limit: number = nodes.length < cap ? nodes.length : cap;
    for (let i = 0; i < limit; i++) {
      const n: NodeInfo = nodes[i];
      if (n.text === '' && !n.clickable && !n.editable) {
        continue;
      }
      hilog.info(TWIN_DOMAIN, TWIN_TAG, 'ACC node[%{public}d] <%{public}s> text="%{public}s" rect=[%{public}d,%{public}d][%{public}d,%{public}d] click=%{public}s edit=%{public}s',
        i, n.type, n.text, n.left, n.top, n.left + n.width, n.top + n.height, '' + n.clickable, '' + n.editable);
    }
  }

  private findByText(nodes: NodeInfo[], want: string): NodeInfo | undefined {
    if (want === '') {
      return undefined;
    }
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].text === want) {
        return nodes[i];
      }
    }
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].text.indexOf(want) >= 0) {
        return nodes[i];
      }
    }
    return undefined;
  }

  private firstEditable(nodes: NodeInfo[]): NodeInfo | undefined {
    for (let i = 0; i < nodes.length; i++) {
      const n: NodeInfo = nodes[i];
      if (n.editable || n.type === 'TextInput' || n.type === 'RichEditor' || n.type === 'TextArea') {
        return n;
      }
    }
    return undefined;
  }

  private hasEditable(nodes: NodeInfo[]): boolean {
    return this.firstEditable(nodes) !== undefined;
  }

  /** 命中的节点常常只是文字，真正能点的是祖先节点：向上找最近的可点祖先 */
  private async clickableOf(n: NodeInfo): Promise<AccessibilityElement | undefined> {
    const self: AccessibilityElement | undefined = n.el;
    if (self === undefined) {
      return undefined;
    }
    if (n.clickable) {
      return self;
    }
    let cur: AccessibilityElement = self;
    for (let i = 0; i < 6; i++) {
      let parent: AccessibilityElement | undefined = undefined;
      try {
        parent = await cur.attributeValue('parent');
      } catch (e) {
        parent = undefined;
      }
      if (parent === undefined) {
        return undefined;
      }
      let canClick: boolean = false;
      try {
        canClick = await parent.attributeValue('clickable');
      } catch (e) {
        canClick = false;
      }
      if (canClick) {
        return parent;
      }
      cur = parent;
    }
    return undefined;
  }

  private async clickNode(n: NodeInfo, what: string): Promise<boolean> {
    const el: AccessibilityElement | undefined = await this.clickableOf(n);
    if (el === undefined) {
      this.logStep('「' + what + '」没有可点击节点');
      return false;
    }
    try {
      await el.performAction('click');
      this.logStep('已点击「' + what + '」');
      return true;
    } catch (e) {
      this.logStep('点击「' + what + '」失败：' + (e as Error).message);
      return false;
    }
  }

  private async setTextOn(n: NodeInfo, text: string): Promise<boolean> {
    const el: AccessibilityElement | undefined = n.el;
    if (el === undefined) {
      return false;
    }
    const p: SetTextParams = { setText: text };
    try {
      await el.performAction('setText', p);
      this.logStep('写入文字成功（' + text.length + ' 字）');
      return true;
    } catch (e) {
      this.logStep('performAction(setText) 失败：' + (e as Error).message);
      return false;
    }
  }

  private swipe(x1: number, y1: number, x2: number, y2: number, what: string): void {
    try {
      const path = new GesturePath(400);
      const pts: GesturePoint[] = [];
      pts.push(new GesturePoint(x1, y1));
      for (let i = 1; i <= 8; i++) {
        pts.push(new GesturePoint(x1 + (x2 - x1) * i / 8, y1 + (y2 - y1) * i / 8));
      }
      path.points = pts;
      this.context.injectGestureSync(path);
      this.logStep('注入手势成功（' + what + '）');
    } catch (e) {
      this.logStep('injectGestureSync 失败：' + (e as Error).message);
    }
  }

  private async back(): Promise<void> {
    try {
      const root: AccessibilityElement = await this.context.getWindowRootElement();
      await root.performAction('back');
      this.logStep('performAction(back) 成功');
      return;
    } catch (e) {
      this.logStep('performAction(back) 失败：' + (e as Error).message);
    }
    this.swipe(20, 1400, 900, 1400, '左边缘右滑=返回');
  }

  // ---------------------------------------------------------------- 单项操作

  private async doDump(): Promise<void> {
    const nodes: NodeInfo[] = await this.collect(120);
    this.status.bundle = this.lastBundle;
    this.status.texts = this.textsOf(nodes, 50);
    this.logStep('屏幕文字 ' + this.status.texts.length + ' 条');
    this.dumpNodes(nodes, 60);
  }

  private async doTap(text: string): Promise<void> {
    const nodes: NodeInfo[] = await this.collect(120);
    const hit: NodeInfo | undefined = this.findByText(nodes, text);
    if (hit === undefined) {
      this.failAt(1, '找不到文字「' + text + '」', nodes);
      return;
    }
    await this.clickNode(hit, text);
    await this.sleep(600);
    const after: NodeInfo[] = await this.collect(120);
    this.status.bundle = this.lastBundle;
    this.status.texts = this.textsOf(after, 50);
  }

  private async doType(text: string): Promise<void> {
    let nodes: NodeInfo[] = await this.collect(120);
    let ed: NodeInfo | undefined = this.firstEditable(nodes);
    if (ed === undefined) {
      this.failAt(1, '当前界面没有可编辑输入框', nodes);
      return;
    }
    await this.clickNode(ed, '输入框');
    await this.sleep(500);
    nodes = await this.collect(120);
    ed = this.firstEditable(nodes);
    if (ed === undefined) {
      this.failAt(2, '聚焦后找不到输入框', nodes);
      return;
    }
    await this.setTextOn(ed, text);
    await this.sleep(500);
    const after: NodeInfo[] = await this.collect(120);
    this.status.bundle = this.lastBundle;
    this.status.texts = this.textsOf(after, 50);
  }

  private async doBack(): Promise<void> {
    await this.back();
    await this.sleep(600);
    const after: NodeInfo[] = await this.collect(120);
    this.status.bundle = this.lastBundle;
    this.status.texts = this.textsOf(after, 50);
  }

  private async doHome(): Promise<void> {
    try {
      const root: AccessibilityElement = await this.context.getWindowRootElement();
      await root.performAction('home');
      this.logStep('performAction(home) 成功');
    } catch (e) {
      this.logStep('performAction(home) 失败：' + (e as Error).message);
    }
  }

  // ---------------------------------------------------------------- 自动发微信

  private failAt(n: number, why: string, nodes: NodeInfo[]): void {
    this.status.state = 'error';
    this.logStep('❌ 第 ' + n + ' 步失败：' + why);
    const texts: string[] = this.textsOf(nodes, 50);
    this.logStep('当时的屏幕文字（' + texts.length + ' 条）：' + texts.join(' | '));
    this.dumpNodes(nodes, 60);
    throw new Error('第 ' + n + ' 步失败：' + why);
  }

  /** 顶部栏里「无文字但可点」的候选（微信右上角是搜索图标 + 加号图标，图标本身无文字），从左到右 */
  private topBarCandidates(nodes: NodeInfo[]): NodeInfo[] {
    const out: NodeInfo[] = [];
    for (let i = 0; i < nodes.length; i++) {
      const n: NodeInfo = nodes[i];
      if (!n.clickable) {
        continue;
      }
      if (n.text !== '') {
        continue;
      }
      if (n.top > 400 || n.left < 600) {
        continue;
      }
      if (n.width > 400 || n.height > 400) {
        continue;
      }
      out.push(n);
    }
    out.sort((a: NodeInfo, b: NodeInfo) => a.left - b.left);
    return out;
  }

  private async openWechatSearch(nodes: NodeInfo[], stepNo: number): Promise<boolean> {
    const byText: NodeInfo | undefined = this.findByText(nodes, '搜索');
    if (byText !== undefined) {
      this.step(stepNo, '按文字「' + byText.text + '」命中搜索入口');
      await this.clickNode(byText, '搜索');
      await this.sleep(1000);
      if (this.hasEditable(await this.collect(140))) {
        this.step(stepNo, '✅ 搜索页已打开（存在输入框）');
        return true;
      }
      this.step(stepNo, '点了「搜索」但没有出现输入框，改试图标候选');
    }
    const cands: NodeInfo[] = this.topBarCandidates(nodes);
    this.step(stepNo, '顶部候选 ' + cands.length + ' 个');
    for (let i = 0; i < cands.length; i++) {
      const c: NodeInfo = cands[i];
      this.step(stepNo, '试候选 ' + (i + 1) + ' rect=[' + c.left + ',' + c.top + '][' + (c.left + c.width) + ',' + (c.top + c.height) + ']');
      if (!await this.clickNode(c, '顶部按钮')) {
        continue;
      }
      await this.sleep(1100);
      const after: NodeInfo[] = await this.collect(140);
      if (this.hasEditable(after)) {
        this.step(stepNo, '✅ 搜索页已打开（存在输入框）');
        return true;
      }
      this.step(stepNo, '点开没有输入框，返回上一步');
      await this.back();
      await this.sleep(900);
    }
    return false;
  }

  private async typeIntoEditable(nodes: NodeInfo[], text: string, stepNo: number): Promise<NodeInfo[]> {
    let ed: NodeInfo | undefined = this.firstEditable(nodes);
    if (ed === undefined) {
      this.failAt(stepNo, '找不到可编辑输入框', nodes);
    }
    await this.clickNode(ed as NodeInfo, '输入框');
    await this.sleep(500);
    let again: NodeInfo[] = await this.collect(160);
    ed = this.firstEditable(again);
    if (ed === undefined) {
      this.failAt(stepNo, '聚焦后输入框消失', again);
    }
    if (!await this.setTextOn(ed as NodeInfo, text)) {
      this.failAt(stepNo, 'performAction(setText) 失败', again);
    }
    return again;
  }

  private async doWechat(contact: string, msg: string): Promise<void> {
    const who: string = contact === '' ? WECHAT_CONTACT : contact;
    const body: string = msg === '' ? WECHAT_MSG : msg;

    // 第 1 步：等微信到前台（AccessibilityExtensionContext 没有 startAbility，由 UI 进程负责拉起）
    this.step(1, '等待微信在前台（UI 进程已 startAbility ' + WECHAT_BUNDLE + '）');
    let front: string = '';
    for (let i = 0; i < 16; i++) {
      front = await this.currentBundle();
      if (front === WECHAT_BUNDLE) {
        break;
      }
      await this.sleep(500);
    }
    if (front !== WECHAT_BUNDLE) {
      this.failAt(1, '微信没有到前台（当前=' + front + '）', await this.collect(80));
    }
    this.step(1, '✅ 微信已在前台');
    await this.sleep(1500);

    // 第 2 步：确认前台是微信并读屏
    let nodes: NodeInfo[] = await this.collect(140);
    this.step(2, '前台包名=' + this.lastBundle + '，节点 ' + nodes.length + ' 个');
    this.status.bundle = this.lastBundle;
    this.status.texts = this.textsOf(nodes, 50);
    this.dumpNodes(nodes, 60);
    if (this.lastBundle !== WECHAT_BUNDLE) {
      this.failAt(2, '前台不是微信（当前=' + this.lastBundle + '）', nodes);
    }

    // 第 3 步：打开搜索页
    this.step(3, '寻找搜索入口');
    if (!await this.openWechatSearch(nodes, 3)) {
      const cur: NodeInfo[] = await this.collect(140);
      this.failAt(3, '没能打开微信搜索页', cur);
    }

    // 第 4 步：输入联系人
    this.step(4, '在搜索框输入「' + who + '」');
    nodes = await this.collect(160);
    nodes = await this.typeIntoEditable(nodes, who, 4);
    await this.sleep(2200);
    nodes = await this.collect(160);
    this.status.texts = this.textsOf(nodes, 50);

    // 第 5 步：选中联系人
    this.step(5, '选中联系人「' + who + '」');
    let hit: NodeInfo | undefined = this.findByText(nodes, who);
    if (hit === undefined) {
      this.failAt(5, '搜索结果里没有「' + who + '」', nodes);
    }
    if (!await this.clickNode(hit as NodeInfo, who)) {
      this.failAt(5, '联系人节点点不动', nodes);
    }
    await this.sleep(2000);
    nodes = await this.collect(160);
    this.status.bundle = this.lastBundle;
    this.status.texts = this.textsOf(nodes, 50);
    this.dumpNodes(nodes, 60);

    // 第 6 步：在会话输入框写入消息
    this.step(6, '写入消息到会话输入框');
    nodes = await this.typeIntoEditable(nodes, body, 6);
    await this.sleep(1200);
    nodes = await this.collect(160);
    this.status.texts = this.textsOf(nodes, 50);

    // 第 7 步：点发送
    this.step(7, '点「发送」');
    let send: NodeInfo | undefined = this.findByText(nodes, '发送');
    if (send === undefined) {
      nodes = await this.collect(160);
      send = this.findByText(nodes, '发送');
    }
    if (send === undefined) {
      this.failAt(7, '找不到「发送」按钮', nodes);
    }
    if (!await this.clickNode(send as NodeInfo, '发送')) {
      this.failAt(7, '发送按钮点不动', nodes);
    }
    await this.sleep(1500);

    // 收尾：读屏确认消息真的出现在会话里
    nodes = await this.collect(160);
    this.status.bundle = this.lastBundle;
    this.status.texts = this.textsOf(nodes, 50);
    const shown: boolean = this.findByText(nodes, body) !== undefined;
    if (shown) {
      this.logStep('🎉 自动发微信完成：会话里已读到「' + body + '」');
    } else {
      this.logStep('⚠️ 已点发送，但读屏没读到这条消息，请人工确认');
    }
    this.dumpNodes(nodes, 60);
  }
}
