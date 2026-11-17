import { promptAction } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { accessibility } from '@kit.AccessibilityKit';
import {
  TwinCmd,
  TwinStatus,
  CMD_FILE,
  STATUS_FILE,
  joinPath,
  readTextFile,
  writeTextFile,
  parseStatus,
  parseSendCommand,
  SendIntent,
  WECHAT_CONTACT
} from '../common/TwinProto';
import { sharePlainText, shareTextWithTitle, shareTextAsFile, copyText, launchWechat } from '../common/WechatShare';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { AiRouter, RouteMode } from '../common/AiRouter';
import { CloudApi, ChatMsg } from '../common/CloudApi';
import { LlamaBridge } from '../common/LlamaBridge';
import { TwinTts, TwinAsr, SpeechHooks } from '../common/Speech';
import {
  ChatMemory,
  ChatTurn,
  MemRow,
  LOAD_LIMIT,
  HISTORY_ROUNDS,
  LOCAL_PROMPT_CHARS,
  CLOUD_PROMPT_CHARS,
  recentTurns,
  buildLocalPromptPack,
  PromptPack,
  buildCloudMessages,
  describeTurns
} from '../common/Memory';
import { MemoryHit, RAG_TOPK, buildRagBlock, pickFresh, oneLine } from '../common/Rag';
import {
  PROACTIVE_TICK_MS,
  PROACTIVE_IDLE_MS,
  PROACTIVE_MAX_PER_HOUR,
  PROACTIVE_LLM_TIMEOUT_MS,
  PROACTIVE_BUBBLE_PREFIX,
  PROACTIVE_DEBUG_HOUR,
  ProactiveGate,
  ProactiveTracker,
  effectiveHour,
  buildProactivePrompt,
  cleanProactive,
  periodName
} from '../common/Proactive';
import {
  PersonaStore,
  Trait,
  TraitHit,
  EmotionState,
  EmotionStep,
  PROMPT_TRAITS,
  PERSONA_MAX_CHARS,
  defaultEmotion,
  extractTraitHits,
  composeSystemPrompt,
  stepEmotion,
  emotionFace,
  emotionLabel,
  directAnswer,
  guardReply,
  wantsClipboard,
  clipForPrompt
} from '../common/Persona';
import { Avatar3D } from '../common/Avatar3D';
import { DEFAULT_MODEL_KIND, KIND_ANIME, KIND_REALISTIC, profileOf } from '../common/ModelKit';
import {
  matchReaction,
  ReactionHit,
  packReactionPing,
  rxnTriggerName,
  rxnReasonName
} from '../common/AvatarReaction';

interface ChatLine {
  role: string;
  text: string;
}

/** 偏好文件名与键名：Key 只落应用沙箱，不进代码、不进日志 */
const PREF_NAME: string = 'cybertwin_cfg';
const KEY_API_KEY: string = 'cloud_api_key';
const KEY_MODEL: string = 'cloud_model';
/** 上次导入的模型（沙箱绝对路径），重启后直接接上，不用再选一次 */
const KEY_MODEL_PATH: string = 'model_path';
const DEFAULT_MODEL: string = 'deepseek-chat';
/** system 提示的唯一来源是 Persona.composeSystemPrompt（底线人格写死在 Persona.BASE_PERSONA） */
const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';

/**
 * 朗读前的思考链清洗：Qwen3 这类模型会在回答前吐 think 段落，念出来就是"自言自语"。
 *
 * 覆盖：
 *   ① 完整块   <think>思考</think>回答 / <think>思考<｜end▁of▁thinking｜>回答  → 只留「回答」
 *   ② 未闭合   abc <think>还在想…                    → 只留「abc」，<think 之后全丢
 *   ③ 只有裸结束标记、没有起始标签 abc thinking思考<｜end▁of▁thinking｜> 回答 → 标记之前按思考丢弃，只留「回答」
 *   ④ 全角      ＜think＞ 也认（全角括号按 1:1 归一，不改字长，索引不会错位）
 *   ⑤ 多块      循环替换，直到不再有完整块
 * 返回值可能就是空串（整段都在思考里）—— 调用方必须据此「不朗读」，也不要补「思考中」。
 */
function stripThink(text: string): string {
  if (text === '') {
    return '';
  }
  // ① 归一全角/私用分隔符：全部单字符替换，长度不变
  let s: string = text.split('＜').join('<').split('＞').join('>')
    .split('｜').join('|').split('▁').join('_');
  // ② 完整块：<think …>…</think>（含 <|start_of_thinking|>…<|end_of_thinking|>）
  let prev: string = '';
  while (prev !== s) {
    prev = s;
    s = s.replace(/<think[^>]*>[\s\S]*?<\/think>/gi, '');
    s = s.replace(/<\|start_of_thinking\|>[\s\S]*?<\|end_of_thinking\|>/gi, '');
  }
  // ③ 只有结束标记、没有起始标签（特殊 token 被渲染成裸文本）：标记之前全是思考
  const endMarks: string[] = ['</think>', '<|end_of_thinking|>'];
  let cut: number = -1;
  let cutLen: number = 0;
  for (const em of endMarks) {
    const p: number = s.toLowerCase().indexOf(em);
    if (p >= 0 && (cut < 0 || p < cut)) {
      cut = p;
      cutLen = em.length;
    }
  }
  if (cut >= 0) {
    // 标记后面还有正文 → 标记之前是思考；标记在句尾 → 它只是残留，前面都是正文
    const after: string = s.substring(cut + cutLen).trim();
    s = after === '' ? s.substring(0, cut) : after;
  }
  // ④ 裸 think 起始（后面紧跟中文/空白+中文才是起始符，避免误伤英文里的 think）
  const bare: RegExp = /think(?:ing)?[\s]*(?=[\u4e00-\u9fa5])/i;
  const bareAt: number = s.search(bare);
  if (bareAt >= 0) {
    s = s.substring(0, bareAt);
  }
  // ⑤ 未闭合：从 <think / <|start_of_thinking|> 起全部丢弃（含到结尾）
  const marks: string[] = ['<think', '<|start_of_thinking|>'];
  for (const m of marks) {
    const at: number = s.toLowerCase().indexOf(m);
    if (at >= 0) {
      s = s.substring(0, at);
    }
  }
  // ④ 兜底清掉残留标签：</think>、<|end_of_thinking|> 等
  s = s.replace(/<\/?think[^>]*>/gi, '');
  s = s.replace(/<\|[^|>]*thinking[^|>]*\|>/gi, '');
  // ⑤ 空白归一：连续空行/空格压成一个，首尾去掉
  s = s.split('\r').join('').split('\n').join(' ').trim();
  while (s.indexOf('  ') >= 0) {
    s = s.split('  ').join(' ');
  }
  return s;
}

/** 整条消息都是思考链时气泡里的占位文案（比空气泡可读，也不会被误当成有效回复） */
const THINK_OMITTED: string = '（思考已省略）';

/** 文本里是否真的带思考标签（用于区分「模型输出」与「用户手打的含 think 字样的话」） */
function hasThinkTag(raw: string): boolean {
  const s: string = raw.toLowerCase();
  return s.indexOf('<think') >= 0 || s.indexOf('<|start_of_thinking|>') >= 0
    || s.indexOf('<|end_of_thinking|>') >= 0 || s.indexOf('｜') >= 0
    || s.indexOf('＜') >= 0 || s.indexOf('▁') >= 0;
}

/**
 * 气泡显示文本：渲染前先剥思考链 —— 与 TTS 朗读走同一个 stripThink，
 * 库里存的原文不动（数据库保留模型原始输出，便于事后排查）。
 *
 * 三种情况：
 *   ① 剥完还有正文        → 显示正文
 *   ② 原文非空但剥完为空   → assistant 显示「（思考已省略）」，user 原样显示（用户自己打的字别改）
 *   ③ 原文本身为空/是流式占位（…） → 原样显示，避免气泡闪成占位文案
 */
function bubbleText(raw: string, role: string): string {
  if (role === 'user') {
    // 用户自己打的字只在真的带标签时清洗：stripThink 的「裸 think」启发式会误伤
    // 「我在想 think 这个词」这类正常中文，气泡不能替用户改字
    if (!hasThinkTag(raw)) {
      return raw;
    }
    const u: string = stripThink(raw);
    return u !== '' ? u : raw;
  }
  const clean: string = stripThink(raw);
  if (clean !== '') {
    return clean;
  }
  if (raw.trim() === '') {
    return raw;
  }
  return THINK_OMITTED;
}


/**
 * 主机版对话页。
 *
 * 和 Android 版的行为对齐：端云双模 + 流式 + 可中断 + 兜底。
 * 差异：鸿蒙云端是非流式（@ohos.net.http 不支持 SSE）。
 */
@Entry
@Component
struct Index {
  @State lines: ChatLine[] = [];
  @State input: string = '';
  @State generating: boolean = false;
  @State status: string = '模型未加载';
  @State modeLabel: string = '';
  /** 导入模型进行中（选文件 / 复制 / 加载），期间禁用按钮并显示进度文案 */
  @State loading: boolean = false;
  @State showCloud: boolean = false;
  @State keyInput: string = '';
  @State modelInput: string = DEFAULT_MODEL;
  @State localReady: boolean = false;
  /** 🤖 操控（调试/授权）：无障碍状态 / 读屏结果 / 单步指令日志 */
  @State showCtrl: boolean = false;
  @State accOn: boolean = false;
  @State ctrlBundle: string = '';
  @State ctrlTexts: string[] = [];
  @State ctrlLog: string = '';
  @State ctrlBusy: boolean = false;
  @State ctlTapText: string = '搜索';
  @State ctlTypeText: string = '';
  /** 🔊 TTS 朗读开关（默认开）；🎙 按住说话状态；speechHint 是状态条上的语音提示 */
  @State ttsOn: boolean = true;
  @State speaking: boolean = false;
  @State listening: boolean = false;
  @State speechHint: string = '';
  @State voiceText: string = '';
  /** 🧠 记忆：库里现有条数（面板显示用） */
  @State memCount: number = 0;
  /** 🔍 历史检索：本轮命中条数、候选池条数、查询词前 20 字（面板显示用） */
  @State ragHitCount: number = 0;
  @State ragPool: number = 0;
  @State ragQuery: string = '';
  /** 💭 主动搭话：静默/次数/去重池的实时快照（面板显示用） */
  @State proInfo: string = '';
  /** 🎭 人格：偏好条数 + 情绪三元组的面板镜像 */
  @State traitCount: number = 0;
  @State emoValence: number = 0.5;
  @State emoTip: string = '平稳';
  @State emoFace: string = '😐';

  /** 形象：0 写实 Avatar.glb / 1 动漫 nova.glb（两个模型都在 rawfile 里，可随时切） */
  @State avatarKind: number = DEFAULT_MODEL_KIND;
  /** 3D 背景层自报状态/错误；空串表示无话可说 */
  @State v3dMsg: string = '';
  /** 🎭 语义动作：seq*100+kind*10+reason 一个数字传给 3D 层，数字一变演一次 */
  @State rxnPing: number = 0;
  private rxnSeq: number = 0;

  private llama: LlamaBridge = new LlamaBridge();
  private tts: TwinTts = new TwinTts();
  private asr: TwinAsr = new TwinAsr();
  private cloudKey: string = '';
  private cloudModel: string = DEFAULT_MODEL;
  private pendingIndex: number = -1;
  private pref: preferences.Preferences | undefined = undefined;
  private modelPath: string = '';
  /** 聊天记忆（SQLite）与「最近 N 轮」的内存副本，两者同步维护 */
  private mem: ChatMemory = new ChatMemory();
  private history: ChatTurn[] = [];
  /** 本轮 user 文本：回复落地时和 assistant 一起进 history，避免 prompt 里当前句重复 */
  private pendingUserText: string = '';
  /** 本轮检索到的历史片段：只活一轮，拼 prompt 时注入 */
  private ragLines: string[] = [];
  /** 🎭 人格内核：traits + emotion 落库，traitTop/emotion 是每次拼 prompt 的缓存 */
  private persona: PersonaStore = new PersonaStore();
  private personaReady: Promise<boolean> | undefined = undefined;
  private traitTop: Trait[] = [];
  private emotion: EmotionState = defaultEmotion();
  /** 本次进程内的对话轮次：连续 5 轮以上加亲密度 */
  private turnSeq: number = 0;
  /** 启动清洗出的脏名字：prompt 与回复都要过滤掉，称呼固定「先生」 */
  private bannedNames: string[] = [];
  /** 💭 主动搭话状态机 + 前台定时器句柄（-1 = 没在跑） */
  private proactive: ProactiveTracker = new ProactiveTracker();
  private tickId: number = -1;
  /** 正在生成/展示一次主动搭话（防止 await 期间下一个 tick 再进来） */
  private proBusy: boolean = false;

  aboutToAppear(): void {
    this.initSpeech();
    this.initSettings().catch((e: Error) => {
      this.status = '读取配置失败：' + e.message;
    });
    this.initMemory().catch((e: Error) => {
      this.status = '读取聊天记录失败：' + e.message;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'initMemory failed: %{public}s', e.message);
    });
    this.ensurePersona().catch((e: Error) => {
      this.status = '读取人格库失败：' + e.message;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'ensurePersona failed: %{public}s', e.message);
    });
  }

  /** 回到前台：静默计时从现在算起，并启动 30 秒一次的检查（后台绝不检查、不发通知） */
  onPageShow(): void {
    this.proactive.reset(Date.now());
    this.startTicker();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'proactive ticker start idleMs=%{public}d debugHour=%{public}d',
      PROACTIVE_IDLE_MS, PROACTIVE_DEBUG_HOUR);
  }

  /** 离开前台：停表，后台不再有任何主动行为 */
  onPageHide(): void {
    this.stopTicker();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'proactive ticker stop');
  }

  aboutToDisappear(): void {
    this.stopTicker();
    this.tts.shutdown();
    this.asr.shutdown();
    this.llama.release();
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 3D 背景层铺满全屏，人物站在场景里走来走去；聊天 UI 叠在它上面
      Avatar3D({
        reactionPing: this.rxnPing,
        modelKind: this.avatarKind,
        onMsg: (m: string) => {
          this.v3dMsg = m;
        }
      })

      // 深空纵深：上下压暗、中间留透明，人物与粒子在中段透出来，文字区另有暗色遮罩
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#E60A0A10', 0.0], ['#1A0A0A10', 0.28], ['#00000000', 0.45],
            ['#00000000', 0.62], ['#33101018', 0.85], ['#E60D0D14', 1.0]]
        })
        .hitTestBehavior(HitTestMode.Transparent)

      Column() {
        Row() {
          Text('Cyber-Twin')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .layoutWeight(1)

          Button(this.loading ? '导入中…' : '📦 模型')
            .height(32)
            .fontSize(13)
            .borderRadius(16)
            .backgroundColor('#3D3D4D')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.importModel();
            })

          Button('☁️ 云端')
            .height(32)
            .fontSize(13)
            .borderRadius(16)
            .backgroundColor('#3D3D4D')
            .fontColor('#FFFFFF')
            .margin({ left: 8 })
            .onClick(() => {
              this.keyInput = this.cloudKey;
              this.modelInput = this.cloudModel;
              this.showCloud = true;
            })

          Button('🤖 操控')
            .height(32)
            .fontSize(13)
            .borderRadius(16)
            .backgroundColor(this.accOn ? '#2E7D32' : '#3D3D4D')
            .fontColor('#FFFFFF')
            .margin({ left: 8 })
            .onClick(() => {
              this.openCtrl();
            })
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#E62C2C35')

        Row() {
          Text(this.modeLabel)
            .fontSize(12)
            .fontColor('#AAAAAA')
            .layoutWeight(1)
          Text(this.ttsOn ? '🔊' : '🔇')
            .fontSize(15)
            .fontColor(this.ttsOn ? '#7BE495' : '#66666F')
            .padding({ left: 10, right: 10 })
            .onClick(() => {
              this.toggleTts();
            })
          if (this.speechHint !== '') {
            Text(this.speechHint)
              .fontSize(11)
              .fontColor(this.listening ? '#FFD180' : '#7BE495')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: '40%' })
              .margin({ right: 8 })
          }
          if (this.v3dMsg !== '') {
            Text(this.v3dMsg)
              .fontSize(10)
              .fontColor(this.v3dMsg.indexOf('失败') >= 0 ? '#FF8A65' : '#7BE495')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: '32%' })
              .margin({ right: 6 })
          }
          Text(this.status)
            .fontSize(11)
            .fontColor('#8A8A99')
            .layoutWeight(2)
            .textAlign(TextAlign.End)
            .maxLines(2)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .backgroundColor('#E6242430')

        List({ space: 10 }) {
          ForEach(this.lines, (line: ChatLine, index: number) => {
            ListItem() {
              Row() {
                // 显示层剥离思考链：流式中间态与最终正文走同一条路径，气泡里永远看不到 think 标签
                Text(bubbleText(line.text, line.role))
                  .padding(14)
                  .borderRadius(18)
                  .fontSize(16)
                  .fontColor('#FFFFFF')
                  .backgroundColor(line.role === 'user' ? '#6C63FF' : '#C0333333')
                  .constraintSize({ maxWidth: '78%' })
              }
              .width('100%')
              .justifyContent(line.role === 'user' ? FlexAlign.End : FlexAlign.Start)
            }
            // key 必须随内容变化：纯 index key 会让 splice 替换同索引元素后 ListItem 不重建，
            // 气泡会永久停在占位符「…」（已真机验证）
          }, (line: ChatLine, index: number) => index.toString() + '|' + line.role + '|' + line.text)
        }
        .layoutWeight(1)
        .width('100%')
        .padding(16)
        .backgroundColor('#99141820')

        Row({ space: 8 }) {
          Button(this.listening ? '🎙' : '🎤')
            .width(46)
            .height(44)
            .fontSize(17)
            .borderRadius(22)
            .backgroundColor(this.listening ? '#C62828' : '#3D3D4D')
            .fontColor('#FFFFFF')
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.startListening();
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.stopListen();
              }
            })

          Button('📋')
            .width(46)
            .height(44)
            .fontSize(17)
            .borderRadius(22)
            .backgroundColor('#3D3D4D')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.fillFromClipboard();
            })

          TextInput({ text: this.input, placeholder: '说说你现在怎么了…' })
            .layoutWeight(1)
            .height(44)
            .borderRadius(22)
            .backgroundColor('#33333F')
            .fontColor('#FFFFFF')
            .placeholderColor('#8A8A99')
            .onChange((value: string) => {
              this.input = value;
              this.touchInteraction('input');
            })
            .onClick(() => {
              this.touchInteraction('input-click');
              this.stopSpeaking();
            })

          Button(this.generating ? '停止' : '发送')
            .height(40)
            .borderRadius(20)
            .backgroundColor(this.generating ? '#C62828' : '#6C63FF')
            .onClick(() => {
              if (this.generating) {
                this.stopGenerating();
              } else {
                this.send();
              }
            })
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#F22C2C35')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)

      if (this.showCloud) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#99000000')
            .onClick(() => {
              this.showCloud = false;
            })
          this.CloudPanel()
        }
        .width('100%')
        .height('100%')
      }

      if (this.showCtrl) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#99000000')
            .onClick(() => {
              this.showCtrl = false;
            })
          this.CtrlPanel()
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#1E1E24')
  }

  @Builder
  CloudPanel() {
    Column({ space: 12 }) {
      Text('☁️ 云端 Key 配置')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .width('100%')
      Text('Key 只保存在应用沙箱（preferences），不上传、不写日志。')
        .fontSize(11)
        .fontColor('#8A8A99')
        .width('100%')
      TextInput({ text: this.keyInput, placeholder: 'API Key（sk-…）' })
        .type(InputType.Password)
        .height(44)
        .borderRadius(10)
        .backgroundColor('#33333F')
        .fontColor('#FFFFFF')
        .placeholderColor('#8A8A99')
        .onChange((value: string) => {
          this.keyInput = value;
        })
      TextInput({ text: this.modelInput, placeholder: DEFAULT_MODEL })
        .height(44)
        .borderRadius(10)
        .backgroundColor('#33333F')
        .fontColor('#FFFFFF')
        .placeholderColor('#8A8A99')
        .onChange((value: string) => {
          this.modelInput = value;
        })
      Row({ space: 8 }) {
        Button('保存')
          .layoutWeight(1)
          .height(40)
          .borderRadius(20)
          .backgroundColor('#6C63FF')
          .onClick(() => {
            this.saveCloudKey();
          })
        Button('清除 Key')
          .layoutWeight(1)
          .height(40)
          .borderRadius(20)
          .backgroundColor('#C62828')
          .onClick(() => {
            this.clearCloudKey();
          })
        Button('关闭')
          .layoutWeight(1)
          .height(40)
          .borderRadius(20)
          .backgroundColor('#3D3D4D')
          .onClick(() => {
            this.showCloud = false;
          })
      }
      .width('100%')
    }
    .width('86%')
    .padding(20)
    .borderRadius(16)
    .backgroundColor('#2C2C35')
  }

  @Builder
  CtrlPanel() {
    Column({ space: 8 }) {
      Row() {
        Text('🤖 操控（调试 / 授权）')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
        Button('关闭')
          .height(30)
          .fontSize(12)
          .borderRadius(15)
          .backgroundColor('#3D3D4D')
          .onClick(() => {
            this.showCtrl = false;
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Text('🧍 形象：' + profileOf(this.avatarKind).label + '（' + profileOf(this.avatarKind).file + '）')
          .fontSize(13)
          .fontColor('#7BE495')
          .layoutWeight(1)
        Button('切换形象')
          .height(30)
          .fontSize(12)
          .borderRadius(15)
          .backgroundColor('#6C63FF')
          .onClick(() => {
            const next: number = this.avatarKind === KIND_ANIME ? KIND_REALISTIC : KIND_ANIME;
            this.avatarKind = next;
            this.v3dMsg = '正在切换到' + profileOf(next).label + '形象…';
            hilog.info(LOG_DOMAIN, LOG_TAG, 'avatar switch from panel -> kind=%{public}d', next);
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Text(this.accOn ? '无障碍：✅ 已开启' : '无障碍：❌ 未开启')
          .fontSize(13)
          .fontColor(this.accOn ? '#7BE495' : '#FF8A80')
          .layoutWeight(1)
        Button('刷新状态')
          .height(30)
          .fontSize(12)
          .borderRadius(15)
          .backgroundColor('#3D3D4D')
          .onClick(() => {
            this.refreshAccState();
          })
        Button('去开启')
          .height(30)
          .fontSize(12)
          .borderRadius(15)
          .backgroundColor('#6C63FF')
          .onClick(() => {
            this.gotoAccessibilitySettings();
          })
      }
      .width('100%')

      if (!this.accOn) {
        Text('系统要求本人手动打开，App 无法代开：设置 → 辅助功能 → 无障碍 → 苏兴无障碍 → 打开开关。')
          .fontSize(11)
          .fontColor('#FFD180')
          .width('100%')
      }

      Text('前台包名：' + (this.ctrlBundle === '' ? '（还没读屏）' : this.ctrlBundle))
        .fontSize(12)
        .fontColor('#AAAAAA')
        .width('100%')

      Row({ space: 8 }) {
        Text('🧠 记忆：' + this.memCount + ' 条')
          .fontSize(13)
          .fontColor('#7BE495')
          .layoutWeight(1)
        Button('清空聊天记录')
          .height(30)
          .fontSize(12)
          .borderRadius(15)
          .backgroundColor('#C62828')
          .onClick(() => {
            this.confirmClearMemory();
          })
      }
      .width('100%')

      Text('🔍 历史检索：命中 ' + this.ragHitCount + ' 条 / 候选 ' + this.ragPool + ' 条'
        + (this.ragQuery === '' ? '' : '（最近查询：' + this.ragQuery + '）'))
        .fontSize(12)
        .fontColor(this.ragHitCount > 0 ? '#7BA7FF' : '#8A8A99')
        .width('100%')
        .maxLines(2)

      Text('💭 主动搭话：' + (this.proInfo === '' ? '待命' : this.proInfo))
        .fontSize(12)
        .fontColor('#C8A6FF')
        .width('100%')
        .maxLines(2)

      Row({ space: 8 }) {
        Text('🎭 人格：先生 · 偏好 ' + this.traitCount + ' 条')
          .fontSize(13)
          .fontColor('#FFD180')
          .layoutWeight(1)
        Button('清空偏好')
          .height(30)
          .fontSize(12)
          .borderRadius(15)
          .backgroundColor('#3D3D4D')
          .onClick(() => {
            this.clearTraits();
          })
      }
      .width('100%')

      Text(this.emoFace + ' 情绪：' + this.emoTip + '（valence ' + this.emoValence.toFixed(2) + '）')
        .fontSize(12)
        .fontColor('#AAAAAA')
        .width('100%')

      Text('记忆落库：' + (this.mem.dbPath() === '' ? '（未知）' : this.mem.dbPath()))
        .fontSize(10)
        .fontColor('#8A8A99')
        .width('100%')
        .maxLines(2)

      Scroll() {
        Column({ space: 2 }) {
          ForEach(this.ctrlTexts, (t: string, i: number) => {
            Text((i + 1) + '. ' + t)
              .fontSize(11)
              .fontColor('#DDDDDD')
              .width('100%')
          }, (t: string, i: number) => i.toString() + '|' + t)
        }
        .width('100%')
      }
      .height(110)
      .width('100%')

      Row({ space: 8 }) {
        Button('刷新读屏')
          .layoutWeight(1)
          .height(34)
          .fontSize(12)
          .borderRadius(17)
          .backgroundColor('#3D3D4D')
          .onClick(() => {
            this.sendCmd('dump', '', '');
          })
        Button('返回')
          .layoutWeight(1)
          .height(34)
          .fontSize(12)
          .borderRadius(17)
          .backgroundColor('#3D3D4D')
          .onClick(() => {
            this.sendCmd('back', '', '');
          })
        Button('滑动')
          .layoutWeight(1)
          .height(34)
          .fontSize(12)
          .borderRadius(17)
          .backgroundColor('#3D3D4D')
          .onClick(() => {
            this.sendCmd('swipe', '', '');
          })
        Button('回桌面')
          .layoutWeight(1)
          .height(34)
          .fontSize(12)
          .borderRadius(17)
          .backgroundColor('#3D3D4D')
          .onClick(() => {
            this.sendCmd('home', '', '');
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.ctlTapText, placeholder: '要点击的文字' })
          .layoutWeight(1)
          .height(36)
          .fontSize(12)
          .borderRadius(10)
          .backgroundColor('#33333F')
          .fontColor('#FFFFFF')
          .onChange((value: string) => {
            this.ctlTapText = value;
          })
        Button('点按')
          .height(36)
          .fontSize(12)
          .borderRadius(18)
          .backgroundColor('#6C63FF')
          .onClick(() => {
            this.sendCmd('tap', this.ctlTapText, '');
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.ctlTypeText, placeholder: '写入输入框的文字' })
          .layoutWeight(1)
          .height(36)
          .fontSize(12)
          .borderRadius(10)
          .backgroundColor('#33333F')
          .fontColor('#FFFFFF')
          .onChange((value: string) => {
            this.ctlTypeText = value;
          })
        Button('写入')
          .height(36)
          .fontSize(12)
          .borderRadius(18)
          .backgroundColor('#6C63FF')
          .onClick(() => {
            this.sendCmd('type', this.ctlTypeText, '');
          })
      }
      .width('100%')

      Text('现状：HOS 7.0 已封死三方无障碍（设置页不再列出已安装服务，扩展能力为 system 级），'
        + '本机无法后台静默发微信。改为两条降级路径：① 系统分享面板（内容已填好，点微信 → 选联系人 → 发送）；'
        + '② 系统分享不可用时，自动复制到剪贴板并拉起微信，长按粘贴即可。')
        .fontSize(11)
        .fontColor('#FFD180')
        .width('100%')

      Text('主用法：在对话框里直接说「给微信文件传输助手发消息：明天见」，分身会自己解析收件人和内容并执行。')
        .fontSize(11)
        .fontColor('#7BE495')
        .width('100%')

      Row({ space: 8 }) {
        Text('🔊 朗读：' + (this.ttsOn ? '开' : '关') + ' · '
          + (this.voiceText === '' ? '音色未查询（朗读一次后出现）' : this.voiceText))
          .fontSize(11)
          .fontColor('#AAAAAA')
          .layoutWeight(1)
          .maxLines(3)
        Button('切音色')
          .height(30)
          .fontSize(12)
          .borderRadius(15)
          .backgroundColor('#3D3D4D')
          .onClick(() => {
            this.cycleVoice();
          })
        Button('🔊 试听口型')
          .height(30)
          .fontSize(12)
          .borderRadius(15)
          .backgroundColor('#2E7D32')
          .onClick(() => {
            // 面板内直测：不依赖云模型，用来验证 TTS 振幅是否真的驱动 viseme
            this.speakReply('苏兴在这儿，这是形象口型测试，一、二、三、四。');
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Button('测试分享 · 文本')
          .layoutWeight(1)
          .height(34)
          .fontSize(12)
          .borderRadius(17)
          .backgroundColor('#6C63FF')
          .onClick(() => {
            this.testShare(false);
          })
        Button('测试分享 · 文件')
          .layoutWeight(1)
          .height(34)
          .fontSize(12)
          .borderRadius(17)
          .backgroundColor('#3D3D4D')
          .onClick(() => {
            this.testShare(true);
          })
      }
      .width('100%')

      Button('测试剪贴板 + 拉起微信')
        .width('100%')
        .height(34)
        .fontSize(12)
        .borderRadius(17)
        .backgroundColor('#2E7D32')
        .onClick(() => {
          this.testClipboardLaunch();
        })

      Scroll() {
        Text(this.ctrlLog === '' ? '（暂无日志）' : this.ctrlLog)
          .fontSize(10)
          .fontColor('#9AD0FF')
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .height(120)
      .width('100%')
    }
    .width('92%')
    .height('90%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor('#2C2C35')
  }

  // ------------------------------------------------------------ 🤖 操控面板逻辑

  /** UI 进程与无障碍扩展进程共用的应用级沙箱目录 */
  private twinDir(): string {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const dir: string = ctx.getApplicationContext().filesDir;
      if (dir !== undefined && dir !== '') {
        return dir;
      }
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'twinDir failed: %{public}s', (e as Error).message);
    }
    return '';
  }

  // ------------------------------------------------------------ 🧠 聊天记忆（持久化 + 上下文接续）

  /** 启动时建库 → 回填最近 100 条 → 取最近 6 轮做上下文 */
  private async initMemory(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    const ok: boolean = await this.mem.init(ctx);
    if (!ok) {
      this.status = '⚠️ 聊天记录不可用（数据库初始化失败）';
      return;
    }
    // 先清洗历史脏数据（「我叫某某」这类），再回填 —— 否则名字会顺着上下文被小模型学去当称呼
    this.bannedNames = await this.mem.purgeNameRows();
    if (this.bannedNames.length > 0) {
      const okP: boolean = await this.ensurePersona();
      if (okP) {
        await this.persona.purgeTraits(this.bannedNames);
        this.traitTop = await this.persona.topTraits(PROMPT_TRAITS);
        this.traitCount = await this.persona.traitCount();
      }
    }
    const rows: MemRow[] = await this.mem.loadRecent(LOAD_LIMIT);
    // 旧消息渲染前同样过 stripThink：库里仍存原文（不改存储），但显示与上下文都只用干净文本。
    // 整条都是思考的 assistant 行直接丢弃（不显示「思考已省略」占位，历史里那种气泡没有信息量）。
    const cleanRows: MemRow[] = [];
    let dropped: number = 0;
    for (const r of rows) {
      const clean: string = stripThink(r.text);
      const keep: string = clean !== '' ? clean : (r.role === 'user' ? r.text : '');
      if (keep === '') {
        dropped++;
        continue;
      }
      cleanRows.push({ id: r.id, role: r.role, text: keep, ts: r.ts, mode: r.mode });
    }
    const loaded: ChatLine[] = [];
    for (const r of cleanRows) {
      const line: ChatLine = { role: r.role === 'user' ? 'user' : 'assistant', text: r.text };
      loaded.push(line);
    }
    if (loaded.length > 0) {
      this.lines = loaded;
    }
    const cap: number = HISTORY_ROUNDS * 2;
    const recent: MemRow[] =
      cleanRows.length > cap ? cleanRows.slice(cleanRows.length - cap) : cleanRows;
    this.history = [];
    for (const r of recent) {
      const turn: ChatTurn = { role: r.role === 'user' ? 'user' : 'assistant', text: r.text };
      this.history.push(turn);
    }
    this.memCount = await this.mem.count();
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'memory loaded rows=%{public}d count=%{public}d hist=%{public}d stripDropped=%{public}d path=%{public}s',
      loaded.length, this.memCount, this.history.length, dropped, this.mem.dbPath());
    hilog.info(LOG_DOMAIN, LOG_TAG, 'memory hist text=[%{public}s]', describeTurns(this.history, 400));
  }

  /**
   * 🔍 历史检索：拿当前这句去库里做 BM25，挑出「最近 6 轮之外」的相关历史。
   * 结果只在本轮有效；无命中时 ragLines 为空 → prompt 里一个字的检索段落都不写。
   */
  private async recall(userText: string): Promise<string[]> {
    this.ragLines = [];
    if (!this.mem.isReady() || userText.trim() === '') {
      this.ragHitCount = 0;
      this.ragPool = 0;
      this.ragQuery = '';
      hilog.info(LOG_DOMAIN, LOG_TAG, 'rag skip ready=%{public}s chars=%{public}d',
        '' + this.mem.isReady(), userText.length);
      return [];
    }
    const recent: string[] = [];
    for (const t of this.history) {
      recent.push(t.text);
    }
    let hits: MemoryHit[] = [];
    try {
      hits = await this.mem.search(userText, RAG_TOPK * 3);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'rag search failed: %{public}s', (e as Error).message);
      hits = [];
    }
    const fresh: MemoryHit[] = pickFresh(hits, recent, userText, RAG_TOPK);
    const lines: string[] = [];
    const scores: string[] = [];
    for (const h of fresh) {
      // 命中行可能是模型旧回复，里面带 think 标签 —— 注入前先洗掉，别让小模型学着鹦鹉学舌
      const body: string = stripThink(h.text);
      if (body === '') {
        continue;
      }
      lines.push(body);
      scores.push(h.score.toFixed(2));
    }
    this.ragLines = lines;
    this.ragHitCount = lines.length;
    // 候选池 = SQL 实际回捞的行数（应等于 min(库内总条数, RAG_CANDIDATES)）
    this.ragPool = this.mem.lastPoolSize();
    this.ragQuery = oneLine(userText, 20);
    const block: string = buildRagBlock(lines);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'rag query=%{public}s candidates=%{public}d hits=%{public}d top=[%{public}s] chars=%{public}d',
      oneLine(userText, 30), this.ragPool, lines.length, scores.join(','), block.length);
    for (const h of fresh) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'rag hit id=%{public}d role=%{public}s score=%{public}s text=[%{public}s]',
        h.id, h.role, h.score.toFixed(2), oneLine(h.text, 40));
    }
    return lines;
  }

  /** 只落库：user 消息一发出就写，进程被 force-stop 也不丢这一行 */
  private async recordDb(role: string, text: string, mode: string): Promise<void> {
    if (!this.mem.isReady() || text === '') {
      return;
    }
    await this.mem.append(role, text, mode);
    const n: number = await this.mem.count();
    this.memCount = n;
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'memory append role=%{public}s mode=%{public}s chars=%{public}d count=%{public}d',
      role, mode, text.length, n);
  }

  private pushHistory(role: string, text: string): void {
    if (text === '') {
      return;
    }
    const turn: ChatTurn = { role: role, text: text };
    this.history.push(turn);
    while (this.history.length > HISTORY_ROUNDS * 2) {
      this.history.shift();
    }
  }

  /** 一轮收尾：这一问一答进内存 history，assistant 那行落库。流式中间态不进这里。 */
  private finishTurn(reply: string, modeName: string): void {
    const ask: string = this.pendingUserText;
    this.pendingUserText = '';
    if (reply === '') {
      return;
    }
    this.pushHistory('user', ask);
    // 上下文里只放剥过思考链的正文：模型看到 <think> 标签会照着学，还白吃 prompt 预算
    const clean: string = stripThink(reply);
    if (clean === '') {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'memory turn assistant all-think dropped chars=%{public}d',
        reply.length);
    } else {
      this.pushHistory('assistant', clean);
    }
    this.recordDb('assistant', reply, modeName).catch((e: Error) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'memory append assistant failed: %{public}s', e.message);
    });
    hilog.info(LOG_DOMAIN, LOG_TAG, 'memory turn closed mode=%{public}s hist=%{public}d',
      modeName, this.history.length);
  }

  /** 清空要二次确认：删的是不可恢复的记录 */
  private confirmClearMemory(): void {
    if (this.memCount === 0) {
      promptAction.showToast({ message: '还没有聊天记录', duration: 1500 });
      return;
    }
    AlertDialog.show({
      title: '清空聊天记录',
      message: '将删除全部 ' + this.memCount + ' 条记录（含启动时回填的对话），无法恢复。确定清空？',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'memory clear cancelled count=%{public}d', this.memCount);
        }
      },
      secondaryButton: {
        value: '确定清空',
        fontColor: '#C62828',
        action: () => {
          this.clearMemory();
        }
      }
    });
  }

  /** 清空：数据库 + 内存列表 + 上下文一起清，否则重启/下一句还会带出旧内容 */
  private async clearMemory(): Promise<void> {
    this.lines = [];
    this.history = [];
    this.pendingIndex = -1;
    this.pendingUserText = '';
    const ok: boolean = await this.mem.clear();
    this.memCount = await this.mem.count();
    this.ctrlLog = ok ? ('已清空全部聊天记录（库 + 内存列表），当前 ' + this.memCount + ' 条')
      : '清空失败：数据库还没就绪，见 hilog';
    hilog.info(LOG_DOMAIN, LOG_TAG, 'memory clear ok=%{public}s count=%{public}d path=%{public}s',
      '' + ok, this.memCount, this.mem.dbPath());
    promptAction.showToast({ message: ok ? '🧠 已清空聊天记录' : '清空失败', duration: 2000 });
  }

  // ------------------------------------------------------------ 📋 剪贴板（用户明确要求时才读）

  /** 读系统剪贴板。只在命中触发词或点了 📋 时调用，不在每轮消息里偷读 */
  private async readClipboard(): Promise<string> {
    try {
      const data: pasteboard.PasteData = await pasteboard.getSystemPasteboard().getData();
      let raw: string = '';
      try {
        raw = data.getPrimaryText();
      } catch (e) {
        raw = '';
      }
      const clip: string = clipForPrompt(raw === undefined ? '' : raw);
      if (clip === '') {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'clipboard empty');
      } else {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'clipboard read chars=%{public}d', clip.length);
      }
      return clip;
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'clipboard failed: %{public}s', (e as Error).message);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'clipboard empty');
      return '';
    }
  }

  /** 📋 按钮：读剪贴板塞进输入框，用户可改完再发 */
  private async fillFromClipboard(): Promise<void> {
    const clip: string = await this.readClipboard();
    if (clip === '') {
      promptAction.showToast({ message: '📋 剪贴板是空的', duration: 1500 });
      return;
    }
    this.input = clip;
    this.ctrlLog = '已读入剪贴板 ' + clip.length + ' 字，可编辑后发送';
    hilog.info(LOG_DOMAIN, LOG_TAG, 'clipboard filled input chars=%{public}d', clip.length);
  }

  // ------------------------------------------------------------ 🎭 人格内核（底线人格 + 偏好 + 情绪）

  /** 惰性初始化：aboutToAppear 先拉起一次，send 里再 await 同一条 Promise，避免两条建库竞态 */
  private ensurePersona(): Promise<boolean> {
    if (this.personaReady === undefined) {
      const ctx = getContext(this) as common.UIAbilityContext;
      this.personaReady = this.loadPersona(ctx);
    }
    return this.personaReady;
  }

  private async loadPersona(ctx: common.UIAbilityContext): Promise<boolean> {
    const ok: boolean = await this.persona.init(ctx);
    if (!ok) {
      this.status = '⚠️ 人格库不可用（偏好/情绪不落库）';
      return false;
    }
    this.traitTop = await this.persona.topTraits(PROMPT_TRAITS);
    this.traitCount = await this.persona.traitCount();
    this.emotion = await this.persona.loadEmotion();
    this.emoValence = this.emotion.valence;
    this.emoTip = emotionLabel(this.emotion.valence);
    this.emoFace = emotionFace(this.emotion.valence);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'persona loaded traits=%{public}d valence=%{public}s face=%{public}s',
      this.traitCount, this.emotion.valence.toFixed(2), this.emoFace);
    return true;
  }

  private currentSystemPrompt(tag: string): string {
    const turns: ChatTurn[] = recentTurns(this.history, HISTORY_ROUNDS);
    const sys: string = composeSystemPrompt(this.traitTop, this.emotion, this.bannedNames);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'persona prompt(%{public}s) chars=%{public}d cap=%{public}d traits=%{public}d face=%{public}s banned=[%{public}s] body=[%{public}s]',
      tag, sys.length, PERSONA_MAX_CHARS, this.traitTop.length, this.emoFace,
      this.bannedNames.join(','), sys.split('\n').join('⏎'));
    return sys;
  }

  /** 明说提取：这句里出现「我喜欢 X」就入库，重复的累加 weight */
  private async absorbTraits(text: string): Promise<void> {
    if (!this.persona.isReady()) {
      return;
    }
    const hits: TraitHit[] = extractTraitHits(text, Date.now());
    if (hits.length === 0) {
      return;
    }
    for (const h of hits) {
      const t: Trait | undefined = await this.persona.absorb(h);
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'persona trait hit kind=%{public}s topic=[%{public}s] weight=%{public}s',
        h.kind, h.topic, t === undefined ? 'store-failed' : '' + t.weight);
    }
    this.traitTop = await this.persona.topTraits(PROMPT_TRAITS);
    this.traitCount = await this.persona.traitCount();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'persona traits total=%{public}d injected=%{public}d',
      this.traitCount, this.traitTop.length);
  }

  private async updateEmotion(text: string): Promise<void> {
    if (!this.persona.isReady()) {
      return;
    }
    const step: EmotionStep = stepEmotion(this.emotion, text, this.turnSeq);
    this.emotion = step.state;
    this.emoValence = step.state.valence;
    this.emoTip = emotionLabel(step.state.valence);
    this.emoFace = emotionFace(step.state.valence);
    await this.persona.saveEmotion(step.state);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'emotion valence=%{public}s arousal=%{public}s intimacy=%{public}s reason=[%{public}s] turn=%{public}d',
      step.state.valence.toFixed(2), step.state.arousal.toFixed(2),
      step.state.intimacy.toFixed(2), step.reason, this.turnSeq);
  }

  /** 只清偏好：聊天记录与情绪都不动 */
  private async clearTraits(): Promise<void> {
    const ok: boolean = await this.persona.clearTraits();
    this.traitTop = [];
    this.traitCount = 0;
    this.currentSystemPrompt('after-clear-traits');
    hilog.info(LOG_DOMAIN, LOG_TAG, 'persona clear traits ok=%{public}s count=%{public}d',
      '' + ok, this.traitCount);
    promptAction.showToast({ message: ok ? '🎭 已清空偏好（聊天记录保留）' : '清空偏好失败', duration: 2000 });
  }

  // ------------------------------------------------------------ 🔊 朗读 / 🎙 语音识别

  /** 把语音模块的状态回调接到页面 @State 上：状态条提示 + 识别文本回填输入框 */
  private initSpeech(): void {
    const hooks: SpeechHooks = new SpeechHooks();
    hooks.onTtsState = (speaking: boolean, hint: string) => {
      this.speaking = speaking;
      this.speechHint = hint;
    };
    hooks.onAsrState = (listening: boolean, hint: string) => {
      this.listening = listening;
      this.speechHint = hint;
    };
    hooks.onAsrText = (text: string, final: boolean) => {
      // 只把最终结果填进输入框（不自动发送），中间结果只当状态提示
      if (final && text !== '') {
        this.input = text;
      }
    };
    hooks.onVoices = (text: string) => {
      this.voiceText = text;
    };
    this.tts.setHooks(hooks);
    this.asr.setHooks(hooks);
  }

  private toggleTts(): void {
    this.ttsOn = !this.ttsOn;
    if (!this.ttsOn) {
      this.tts.stop();
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'tts toggle on=%{public}s', '' + this.ttsOn);
  }

  /** 停止朗读：点输入框 / 关掉 🔊 都走这里 */
  private stopSpeaking(): void {
    if (!this.speaking) {
      return;
    }
    this.tts.stop();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'tts stop by user');
  }

  private cycleVoice(): void {
    const person: number = this.tts.cyclePerson();
    this.voiceText = this.tts.voicesText();
    promptAction.showToast({ message: '音色已切到 ' + person + '（下次朗读生效）', duration: 2000 });
  }

  /**
   * 分身的整段回复读出来：只在回复结束时调，流式过程不读。
   * 念之前先剥思考链 —— 否则 Qwen3 的 think 段落会被原样念出来。
   */
  private speakReply(text: string): void {
    const clean: string = stripThink(text);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'tts strip raw=%{public}d clean=%{public}d changed=%{public}s head=[%{public}s]',
      text.length, clean.length, '' + (clean !== text), oneLine(clean, 30));
    if (clean === '') {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'tts skip empty after strip raw=[%{public}s]',
        oneLine(text, 40));
      return;
    }
    if (!this.ttsOn) {
      return;
    }
    this.tts.speak(clean).catch((e: Error) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'tts speak rejected: %{public}s', e.message);
    });
  }

  private startListening(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.touchInteraction('mic');
    hilog.info(LOG_DOMAIN, LOG_TAG, 'asr mic down');
    this.asr.start(ctx).catch((e: Error) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'asr start rejected: %{public}s', e.message);
      this.speechHint = '❌ 识别启动失败：' + e.message;
    });
  }

  private stopListen(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'asr mic up');
    this.asr.stopListen().catch((e: Error) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'asr stop rejected: %{public}s', e.message);
    });
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: (value: void) => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private refreshAccState(): void {
    let on: boolean = false;
    try {
      on = accessibility.isOpenAccessibilitySync();
    } catch (e) {
      on = false;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'isOpenAccessibilitySync failed: %{public}s', (e as Error).message);
    }
    this.accOn = on;
    // 诊断：框架里到底认不认我们这个无障碍扩展（决定「去开启」对用户是否有意义）
    let extList: string = '';
    try {
      const list: accessibility.AccessibilityAbilityInfo[] =
        accessibility.getAccessibilityExtensionListSync('all', 'install');
      const items: string[] = [];
      for (let i = 0; i < list.length; i++) {
        items.push(list[i].bundleName + '/' + list[i].name);
      }
      extList = items.join(',');
    } catch (e) {
      extList = 'ERR:' + (e as Error).message;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'ctrl accOpen=%{public}s dir=%{public}s extList=[%{public}s]',
      '' + on, this.twinDir(), extList);
  }

  /** 面板里的排查入口：验证路径 2（写剪贴板 + startAbility 拉起微信） */
  private async testClipboardLaunch(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    const text: string = this.ctlTypeText === '' ? '这是苏兴的剪贴板测试文本' : this.ctlTypeText;
    try {
      await copyText(text);
    } catch (e) {
      this.ctrlLog = '写剪贴板失败：' + (e as Error).message;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'testClipboard failed: %{public}s', (e as Error).message);
      return;
    }
    try {
      await launchWechat(ctx);
      this.ctrlLog = '剪贴板已写入（' + text.length + ' 字），微信已拉起';
    } catch (e) {
      this.ctrlLog = '剪贴板已写入，但拉起微信失败：' + (e as Error).message;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'testLaunchWechat failed: %{public}s', (e as Error).message);
    }
  }

  /** 面板里的排查入口：直接弹分享面板看微信在不在，文本 / 文件两种 utd 各试一次 */
  private async testShare(asFile: boolean): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    const text: string = this.ctlTypeText === '' ? '这是苏兴的分享测试文本' : this.ctlTypeText;
    try {
      if (asFile) {
        const uri: string = await shareTextAsFile(ctx, text, WECHAT_CONTACT);
        this.ctrlLog = '测试分享（文件）已弹面板：' + uri;
      } else {
        await sharePlainText(ctx, text, WECHAT_CONTACT);
        this.ctrlLog = '测试分享（文本）已弹面板';
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'testShare asFile=%{public}s ok', '' + asFile);
    } catch (e) {
      this.ctrlLog = '测试分享失败：' + (e as Error).message;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'testShare asFile=%{public}s failed: %{public}s',
        '' + asFile, (e as Error).message);
    }
  }

  private openCtrl(): void {
    this.showCtrl = true;
    this.refreshAccState();
  }

  private gotoAccessibilitySettings(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        bundleName: 'com.huawei.hmos.settings',
        abilityName: 'com.huawei.hmos.settings.MainAbility'
      };
      ctx.startAbility(want).then(() => {
        promptAction.showToast({ message: '设置 → 辅助功能 → 无障碍 → 苏兴无障碍', duration: 4000 });
      }).catch((e: Error) => {
        this.ctrlLog = '打开系统设置失败：' + e.message + '\n请手动：设置 → 辅助功能 → 无障碍 → 苏兴无障碍';
        hilog.error(LOG_DOMAIN, LOG_TAG, 'startAbility settings failed: %{public}s', e.message);
      });
    } catch (e) {
      this.ctrlLog = '打开系统设置失败：' + (e as Error).message;
    }
  }

  /** 下发一条指令并等扩展回写结果 */
  private async sendCmd(op: string, text: string, msg: string): Promise<TwinStatus | undefined> {
    this.refreshAccState();
    const dir: string = this.twinDir();
    if (dir === '') {
      this.ctrlLog = '拿不到应用沙箱目录，无法与无障碍扩展通信';
      return undefined;
    }
    if (!this.accOn) {
      this.ctrlLog = '无障碍未开启：扩展进程没在运行，指令发出去没人执行。\n'
        + '请点「去开启」→ 设置 → 辅助功能 → 无障碍 → 苏兴无障碍 → 打开开关。';
      return undefined;
    }
    const cmd: TwinCmd = { id: Date.now(), op: op, text: text, msg: msg };
    writeTextFile(joinPath(dir, CMD_FILE), JSON.stringify(cmd));
    this.ctrlBusy = true;
    this.ctrlLog = '指令 ' + op + ' 已下发（id=' + cmd.id + '），等待扩展执行…';
    hilog.info(LOG_DOMAIN, LOG_TAG, 'cmd send op=%{public}s id=%{public}d', op, cmd.id);
    const st: TwinStatus | undefined = await this.waitStatus(cmd.id, op === 'wechat' ? 90000 : 25000);
    this.ctrlBusy = false;
    if (st === undefined) {
      this.ctrlLog = this.ctrlLog + '\n❌ 超时：扩展没有回写结果（检查无障碍是否真的开启、扩展是否被系统绑定）';
      hilog.error(LOG_DOMAIN, LOG_TAG, 'cmd %{public}s timeout', op);
      return undefined;
    }
    this.ctrlBundle = st.bundle;
    this.ctrlTexts = st.texts;
    this.ctrlLog = st.steps.join('\n');
    hilog.info(LOG_DOMAIN, LOG_TAG, 'cmd %{public}s done state=%{public}s steps=%{public}d',
      op, st.state, st.steps.length);
    return st;
  }

  private async waitStatus(id: number, timeoutMs: number): Promise<TwinStatus | undefined> {
    const dir: string = this.twinDir();
    const p: string = joinPath(dir, STATUS_FILE);
    const t0: number = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      const st: TwinStatus | undefined = parseStatus(readTextFile(p));
      if (st !== undefined && st.id === id) {
        if (st.steps.length > 0) {
          this.ctrlLog = st.steps.join('\n');
        }
        if (st.state === 'done' || st.state === 'error') {
          return st;
        }
      }
      await this.delay(500);
    }
    return undefined;
  }

  private endIntent(): void {
    this.generating = false;
    this.modeLabel = '';
  }

  /** 分享面板里的标题：有收件人就是「发给<收件人>」，否则带上目标 App */
  private shareTitle(intent: SendIntent): string {
    if (intent.contact !== '') {
      return '发给' + intent.contact;
    }
    return intent.app === '' ? '由苏兴分享' : intent.app + ' · 由苏兴分享';
  }

  /** 气泡文案：面板不可指定目标 App，所以必须明确告诉用户点哪个 */
  private shareTip(intent: SendIntent): string {
    if (intent.app === '') {
      return '📤 已打开分享，内容已填好。选择任意应用发送。';
    }
    if (intent.contact === '') {
      return '📤 已打开分享。选「' + intent.app + '」保存。';
    }
    return '📤 已打开分享，内容已填好。在面板里选「' + intent.app + '」→ 联系人「' + intent.contact + '」→ 发送。';
  }

  /**
   * 对话即指令的执行层（通用版：微信 / QQ / 邮件 / 备忘录 / 飞书 / 企业微信）。
   * 无障碍被 HOS 7.0 封死（第三方服务无法注册，装包报 9568289），所以改为「内容先准备好、
   * 用户点两下」的两条降级路径，按序尝试、失败原因逐级写进气泡：
   *   路径 1  系统分享面板（ShareKit，纯文本）—— 面板不可指定目标 App，由用户点
   *   路径 2  写系统剪贴板（微信再 startAbility 拉起，其它 App 只能手动打开）
   */
  private async runSendIntent(intent: SendIntent): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.generating = true;
    this.modeLabel = '📤 准备发送';
    let shareErr: string = '';
    try {
      await shareTextWithTitle(ctx, intent.message, this.shareTitle(intent));
      this.replacePending(this.shareTip(intent));
      hilog.info(LOG_DOMAIN, LOG_TAG, 'intent send path=systemShare ok app=[%{public}s] contact=[%{public}s]',
        intent.app, intent.contact);
      this.endIntent();
      return;
    } catch (e) {
      shareErr = (e as Error).message;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'intent send path=systemShare failed app=[%{public}s]: %{public}s',
        intent.app, shareErr);
    }
    try {
      await copyText(intent.message);
    } catch (e) {
      const copyErr: string = (e as Error).message;
      this.replacePending('❌ 发送失败：系统分享不可用（' + shareErr + '）；复制到剪贴板也失败（' + copyErr + '）');
      hilog.error(LOG_DOMAIN, LOG_TAG, 'intent send path=clipboard failed: %{public}s', copyErr);
      this.endIntent();
      return;
    }
    // 只有微信有实测可用的拉起通道；其它 App 拉起会失败，直接让用户手动开
    if (intent.app !== '微信') {
      this.replacePending('📋 系统分享不可用（' + shareErr + '），内容已复制到剪贴板。请手动打开「'
        + (intent.app === '' ? '任意应用' : intent.app) + '」粘贴发送。');
      hilog.info(LOG_DOMAIN, LOG_TAG, 'intent send path=clipboard only app=[%{public}s]', intent.app);
      this.endIntent();
      return;
    }
    const who: string = intent.contact === '' ? '' : ('「' + intent.contact + '」');
    try {
      await launchWechat(ctx);
      this.replacePending('📋 内容已复制，微信已打开。粘贴后发给' + who
        + '即可。（系统分享不可用：' + shareErr + '）');
      hilog.info(LOG_DOMAIN, LOG_TAG, 'intent send path=clipboard ok contact=[%{public}s]', intent.contact);
    } catch (e) {
      const launchErr: string = (e as Error).message;
      this.replacePending('❌ 发送失败：系统分享不可用（' + shareErr + '）；拉起微信失败（' + launchErr
        + '）。内容已复制到剪贴板，可手动打开微信粘贴。');
      hilog.error(LOG_DOMAIN, LOG_TAG, 'intent send path=clipboard launch failed: %{public}s', launchErr);
    }
    this.endIntent();
  }

  private tailSteps(st: TwinStatus, n: number): string {
    const start: number = st.steps.length > n ? st.steps.length - n : 0;
    return st.steps.slice(start).join('\n');
  }

  /** 偏好持久化读回：Key / 模型名 / 上次是否已有本地模型（模型文件随沙箱存在） */
  private async initSettings(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const pref: preferences.Preferences = await preferences.getPreferences(ctx, PREF_NAME);
      this.pref = pref;
      const k: preferences.ValueType = pref.getSync(KEY_API_KEY, '');
      this.cloudKey = typeof k === 'string' ? k : '';
      const m: preferences.ValueType = pref.getSync(KEY_MODEL, DEFAULT_MODEL);
      this.cloudModel = (typeof m === 'string' && m !== '') ? m : DEFAULT_MODEL;
      const mp: preferences.ValueType = pref.getSync(KEY_MODEL_PATH, '');
      this.modelPath = typeof mp === 'string' ? mp : '';
      this.keyInput = this.cloudKey;
      this.modelInput = this.cloudModel;
    } catch (e) {
      this.status = '读取配置失败：' + (e as Error).message;
    }
    this.logNativeSelfCheck();
    await this.nextFrame();
    this.autoLoadLastModel();
    this.refreshMode();
  }

  /** 启动时把上次导入的模型接上；路径丢了就扫沙箱里现成的 .gguf */
  private autoLoadLastModel(): void {
    let path: string = this.modelPath;
    if (path === '' || !fs.accessSync(path)) {
      path = this.findModelInSandbox();
    }
    if (path === '') {
      return;
    }
    this.modelPath = path;
    this.status = '加载上次的模型…';
    const t0: number = Date.now();
    const ok: boolean = this.llama.loadModel(path);
    const ms: number = Date.now() - t0;
    this.localReady = ok;
    this.status = ok ? ('✅ 本地模型已加载：' + this.fileNameOf(path))
      : ('❌ 加载失败：' + this.llama.getLastError());
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'autoLoad path=%{public}s ok=%{public}s ms=%{public}d err=%{public}s',
      path, '' + ok, ms, this.llama.getLastError());
    this.logNativeSelfCheck();
  }

  /** 沙箱里现成的 .gguf（上次导入过就直接用，不需要再选一遍） */
  private findModelInSandbox(): string {
    try {
      const dir: string = (getContext(this) as common.UIAbilityContext).filesDir;
      const names: string[] = fs.listFileSync(dir);
      for (const n of names) {
        if (n.toLowerCase().endsWith('.gguf')) {
          return dir + '/' + n;
        }
      }
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'scan filesDir failed: %{public}s', (e as Error).message);
    }
    return '';
  }

  /**
   * 自检：由 App 自己读 /proc/self/maps（hdc shell 读不到别家进程的 maps），
   * 把 llama 相关映射写进 hilog —— 这是「NAPI .so 真的被加载进进程」的可取证据。
   */
  /** /proc 下文件的 stat size 是 0，readTextSync 会拿到空串，只能按块读 */
  private readProcFile(path: string): string {
    const buf: ArrayBuffer = new ArrayBuffer(96 * 1024);
    const dec: util.TextDecoder = util.TextDecoder.create('utf-8');
    let text: string = '';
    const f: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      let n: number = fs.readSync(f.fd, buf);
      while (n > 0) {
        text += dec.decodeToString(new Uint8Array(buf.slice(0, n)));
        n = fs.readSync(f.fd, buf);
      }
    } finally {
      fs.closeSync(f);
    }
    return text;
  }

  private logNativeSelfCheck(): void {
    try {
      const maps: string = this.readProcFile('/proc/self/maps');
      const rows: string[] = maps.split('\n');
      let hits: number = 0;
      let sample: string = '';
      for (const row of rows) {
        if (row.toLowerCase().indexOf('llama') >= 0) {
          hits++;
          if (sample === '') {
            sample = row.substring(row.lastIndexOf(' ') + 1);
          }
        }
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'maps llama mappings=%{public}d sample=%{public}s',
        hits, sample);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'maps self-check failed: %{public}s', (e as Error).message);
    }
  }

  /** 顶部三档标签只反映「配置状态」，不反映单次请求的临时降级 */
  private refreshMode(): void {
    if (this.cloudKey !== '') {
      this.modeLabel = AiRouter.label(RouteMode.CLOUD);
    } else if (this.localReady) {
      this.modeLabel = AiRouter.label(RouteMode.LOCAL);
    } else {
      this.modeLabel = AiRouter.label(RouteMode.FALLBACK);
    }
  }

  private async saveCloudKey(): Promise<void> {
    const key: string = this.keyInput.trim();
    const rawModel: string = this.modelInput.trim();
    const model: string = rawModel === '' ? DEFAULT_MODEL : rawModel;
    try {
      let pref: preferences.Preferences;
      if (this.pref === undefined) {
        pref = await preferences.getPreferences(getContext(this) as common.UIAbilityContext, PREF_NAME);
        this.pref = pref;
      } else {
        pref = this.pref;
      }
      pref.putSync(KEY_API_KEY, key);
      pref.putSync(KEY_MODEL, model);
      await pref.flush();
      this.cloudKey = key;
      this.cloudModel = model;
      this.showCloud = false;
      this.refreshMode();
      promptAction.showToast({
        message: key === '' ? '已保存，Key 为空仍走本地/词库' : '☁️ 云端 Key 已保存',
        duration: 2000
      });
    } catch (e) {
      promptAction.showToast({ message: '保存失败：' + (e as Error).message, duration: 3000 });
    }
  }

  private async clearCloudKey(): Promise<void> {
    try {
      let pref: preferences.Preferences;
      if (this.pref === undefined) {
        pref = await preferences.getPreferences(getContext(this) as common.UIAbilityContext, PREF_NAME);
        this.pref = pref;
      } else {
        pref = this.pref;
      }
      pref.putSync(KEY_API_KEY, '');
      await pref.flush();
      this.cloudKey = '';
      this.keyInput = '';
      this.refreshMode();
      promptAction.showToast({ message: '☁️ Key 已清除', duration: 2000 });
    } catch (e) {
      promptAction.showToast({ message: '清除失败：' + (e as Error).message, duration: 3000 });
    }
  }

  /**
   * 导入模型：picker 选 .gguf → 复制进应用沙箱 → llama 用真实路径加载。
   *
   * 为什么要复制：picker 返回的是 file://docs/... 形式的 URI，权限是临时的，
   * llama.cpp 只吃真实文件路径；应用沙箱内的路径才是可长期持有、可直接 mmap 的。
   */
  private async importModel(): Promise<void> {
    if (this.loading) {
      return;
    }
    if (this.generating) {
      promptAction.showToast({ message: '正在生成，先停止再换模型', duration: 2000 });
      return;
    }
    this.loading = true;
    this.status = '打开文件选择器…';
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['GGUF 模型|.gguf'];
      const uris: string[] = await docPicker.select(options);
      if (uris === undefined || uris.length === 0) {
        this.status = '已取消选择';
        return;
      }
      const uri: string = uris[0];
      const dest: string = await this.stageModel(ctx, uri);
      if (dest === '') {
        return;
      }
      this.status = '加载模型…（' + this.humanSize(fs.statSync(dest).size) + '）';
      await this.nextFrame();
      // loadModel 是同步 NAPI，阻塞 ArkTS 线程；先把状态刷到屏幕上再进来
      const t0: number = Date.now();
      const ok: boolean = this.llama.loadModel(dest);
      const ms: number = Date.now() - t0;
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'import uri=%{public}s dest=%{public}s ok=%{public}s ms=%{public}d err=%{public}s',
        uri, dest, '' + ok, ms, this.llama.getLastError());
      if (ok) {
        this.localReady = true;
        this.modelPath = dest;
        await this.saveModelPath(dest);
        this.status = '✅ 本地模型已加载：' + this.fileNameOf(dest);
        promptAction.showToast({ message: '✅ 本地模型已加载', duration: 2000 });
      } else {
        this.localReady = false;
        this.status = '❌ 加载失败：' + this.llama.getLastError();
        promptAction.showToast({ message: '本地模型加载失败', duration: 3000 });
      }
    } catch (e) {
      this.status = '❌ 导入失败：' + (e as Error).message;
      promptAction.showToast({ message: '导入失败：' + (e as Error).message, duration: 3000 });
    } finally {
      this.loading = false;
      this.refreshMode();
    }
  }

  private async saveModelPath(path: string): Promise<void> {
    try {
      let pref: preferences.Preferences;
      if (this.pref === undefined) {
        pref = await preferences.getPreferences(getContext(this) as common.UIAbilityContext, PREF_NAME);
        this.pref = pref;
      } else {
        pref = this.pref;
      }
      pref.putSync(KEY_MODEL_PATH, path);
      await pref.flush();
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'saveModelPath failed: %{public}s', (e as Error).message);
    }
  }

  /** 把 picker 的 URI 落到沙箱；同尺寸副本已存在则跳过复制（400MB 不想每次重来） */
  private async stageModel(ctx: common.UIAbilityContext, uri: string): Promise<string> {
    const name: string = this.fileNameOf(uri);
    const dest: string = ctx.filesDir + '/' + name;
    this.status = '读取所选文件…';
    const f: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const size: number = fs.statSync(f.fd).size;
      if (fs.accessSync(dest) && fs.statSync(dest).size === size) {
        this.status = '沙箱内已有同尺寸副本，跳过复制';
        return dest;
      }
      this.status = '复制到应用沙箱…（' + this.humanSize(size) + '）';
      hilog.info(LOG_DOMAIN, LOG_TAG, 'stage uri=%{public}s dest=%{public}s bytes=%{public}d',
        uri, dest, size);
      await this.nextFrame();
      // 用 fd 复制：URI 打不开成路径，但可以 open 出 fd，copy 支持 fd → 路径
      await fs.copyFile(f.fd, dest);
    } finally {
      fs.closeSync(f);
    }
    return dest;
  }

  /** 让状态文案先渲染一帧，再进入同步阻塞段 */
  private nextFrame(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, 50);
    });
  }

  private fileNameOf(p: string): string {
    const slash: number = p.lastIndexOf('/');
    let name: string = slash >= 0 ? p.substring(slash + 1) : p;
    const q: number = name.indexOf('?');
    if (q >= 0) {
      name = name.substring(0, q);
    }
    return name === '' ? 'local_model.gguf' : name;
  }

  private humanSize(n: number): string {
    if (n >= 1024 * 1024) {
      return (n / (1024 * 1024)).toFixed(1) + ' MB';
    }
    if (n >= 1024) {
      return (n / 1024).toFixed(1) + ' KB';
    }
    return n.toString() + ' B';
  }

  private stopGenerating(): void {
    // 只发中断请求；generating 由 generateStream 的结束信号复位，
    // 避免 native 还在回调时按钮已经变回「发送」。
    if (!this.llama.isGenerating()) {
      this.generating = false;
      return;
    }
    this.llama.cancel();
    this.modeLabel = '停止中…';
  }

  /**
   * 用户这句话 → 分身动作。规则匹配，命中才发；3D 层没就绪也不会抛（内部吞异常）。
   * 只是视觉层：不打断 TTS、不影响推理、不改聊天流程。
   */
  private reactToAvatar(text: string): void {
    try {
      const hit: ReactionHit | null = matchReaction(text);
      if (hit === null) {
        return;
      }
      this.rxnSeq = (this.rxnSeq % 90000) + 1;
      this.rxnPing = packReactionPing(this.rxnSeq, hit);
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'avatar reaction trigger=%{public}s reason=%{public}s word=%{public}s ping=%{public}d',
        rxnTriggerName(hit.kind), rxnReasonName(hit.reason), hit.word, this.rxnPing);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'avatar reaction failed: %{public}s', (e as Error).message);
    }
  }

  private async send(): Promise<void> {
    // 防重入：生成中再次触发会让两路推理并发，lines / pendingIndex 会错位。
    // 界面层虽然把「发送」换成了「停止」按钮，但快速双击仍可能穿过这个窗口，
    // 且任何代码路径都能直接调用 send()。
    if (this.generating) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'send ignored reason=generating');
      return;
    }
    const text = this.input.trim();
    if (text === '') {
      return;
    }
    this.input = '';
    this.touchInteraction('send');
    this.pendingUserText = text;
    this.lines.push({ role: 'user', text: text });
    // 语义动作：只看这句用户文本，纯视觉层，不碰 TTS / 推理
    this.reactToAvatar(text);
    // 先落库再干活：进程此时被杀，这句用户消息也不会丢
    await this.recordDb('user', text, 'user');

    // 对话即指令：本地正则先判意图，未命中才走云端/本地/词库聊天
    const intent: SendIntent | undefined = parseSendCommand(text);
    if (intent !== undefined) {
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'intent send parsed app=[%{public}s] bundle=[%{public}s] contact=[%{public}s] message=[%{public}s]',
        intent.app, intent.bundle, intent.contact, intent.message);
      const target: string = intent.contact !== ''
        ? '发给 ' + intent.contact + (intent.app === '' ? '' : '（' + intent.app + '）')
        : '分享到' + (intent.app === '' ? '应用' : intent.app);
      this.pendingIndex = this.lines.length;
      this.lines.push({ role: 'assistant', text: '🤖 正在准备' + target + '…' });
      await this.runSendIntent(intent);
      const bubble: string = (this.pendingIndex >= 0 && this.pendingIndex < this.lines.length)
        ? this.lines[this.pendingIndex].text : '';
      this.finishTurn(bubble, intent.app === '' ? '分享' : intent.app);
      return;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'intent none -> normal chat');

    // 人格内核：先吸收这句里的显式偏好、微调情绪，再决定让谁回答
    await this.ensurePersona();
    this.turnSeq = this.turnSeq + 1;
    await this.absorbTraits(text);
    await this.updateEmotion(text);
    this.currentSystemPrompt('pre-route');

    // 📋 剪贴板：只有用户明确要求（命中触发词）才读，读完拼进这一句再交给模型
    let ask: string = text;
    if (wantsClipboard(text)) {
      const clip: string = await this.readClipboard();
      if (clip === '') {
        const empty: string = '先生，剪贴板是空的。';
        this.pendingIndex = this.lines.length;
        this.lines.push({ role: 'assistant', text: empty });
        this.modeLabel = '📋 剪贴板';
        this.finishTurn(empty, '剪贴板');
        hilog.info(LOG_DOMAIN, LOG_TAG, 'clipboard ask but empty in=[%{public}s]', text);
        return;
      }
      ask = text + '\n用户剪贴板内容如下：' + clip;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'clipboard prompt chars=%{public}d body=[%{public}s]',
        ask.length, ask.split('\n').join('⏎'));
    }

    // 称呼直答：纯寒暄不交给 0.5B（它会寒暄一大段，违反底线人格）
    const say: string = directAnswer(text);
    if (say !== '') {
      this.pendingIndex = this.lines.length;
      this.lines.push({ role: 'assistant', text: say });
      this.modeLabel = '🎭 人格';
      this.speakReply(say);
      this.finishTurn(say, '人格');
      hilog.info(LOG_DOMAIN, LOG_TAG, 'persona direct answer in=[%{public}s] reply=%{public}s',
        text, say);
      return;
    }

    // 🔍 历史检索：用「当前这句」当 query，供本轮 prompt 注入（本轮之前的历史库已落库完毕）
    await this.recall(ask);

    this.pendingIndex = this.lines.length;
    this.lines.push({ role: 'assistant', text: '…' });
    hilog.info(LOG_DOMAIN, LOG_TAG, 'send pendingIndex=%{public}d lines=%{public}d chars=%{public}d',
      this.pendingIndex, this.lines.length, text.length);

    const cloudReady = this.cloudKey !== '';
    const mode = await AiRouter.decide(cloudReady, this.llama.isReady());
    this.modeLabel = AiRouter.label(mode);

    if (mode === RouteMode.CLOUD) {
      await this.runCloud(ask);
      return;
    }
    if (mode === RouteMode.LOCAL) {
      await this.runLocal(ask, '');
      return;
    }
    // 词库档：本地模型没加载、云端也没配置
    const lex: string = AiRouter.lexiconReply(text);
    this.replacePending(AiRouter.label(RouteMode.FALLBACK) + '\n' + lex);
    this.speakReply(lex);
    this.finishTurn(lex, AiRouter.modeName(RouteMode.FALLBACK));
  }

  private async runCloud(text: string): Promise<void> {
    this.generating = true;
    try {
      // 云端同样带历史：DeepSeek 直接吃 messages 数组
      const turns: ChatTurn[] = recentTurns(this.history, HISTORY_ROUNDS);
      const msgs: ChatMsg[] = buildCloudMessages(turns, text, CLOUD_PROMPT_CHARS, this.ragLines);
      // 云端也吃同一份人格 prompt，两个版本的说话方式必须一致
      const sys: string = composeSystemPrompt(this.traitTop, this.emotion, this.bannedNames);
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'cloud prompt msgs=%{public}d hist=%{public}d sysChars=%{public}d rag=%{public}d ragChars=%{public}d histText=[%{public}s]',
        msgs.length, turns.length, sys.length, this.ragLines.length,
        buildRagBlock(this.ragLines).length, describeTurns(turns, 400));
      // 流式回调：云端增量到达就刷新气泡
      const reply = await CloudApi.chat(this.cloudKey, this.cloudModel, sys, msgs,
        (partial: string) => {
          this.replacePending(partial);
        });
      const guarded: string = guardReply(reply, this.bannedNames);
      this.replacePending(guarded);
      this.speakReply(guarded);
      this.finishTurn(guarded, AiRouter.modeName(RouteMode.CLOUD));
    } catch (e) {
      // 云端任何错误（含超时）都继续走下一档，绝不吞异常返回空
      await this.degrade(text, RouteMode.CLOUD, e as Error);
    } finally {
      this.generating = false;
    }
  }

  /** 降级链：云端 → 本地 → 词库，每档都带「现在是谁在回答」的提示 */
  private async degrade(text: string, from: RouteMode, err: Error): Promise<void> {
    const next: RouteMode = AiRouter.nextMode(from, this.llama.isReady());
    const note: string =
      AiRouter.degradeNote(from, next, AiRouter.reasonOf(err));
    this.modeLabel = AiRouter.label(next);
    promptAction.showToast({ message: note, duration: 3000 });
    if (next === RouteMode.LOCAL) {
      this.replacePending(note);
      await this.runLocal(text, note);
      return;
    }
    const lex: string = AiRouter.lexiconReply(text);
    this.replacePending(note + '\n' + lex);
    this.speakReply(lex);
    this.finishTurn(lex, AiRouter.modeName(RouteMode.FALLBACK));
  }

  private async runLocal(text: string, prefix: string): Promise<void> {
    if (!this.llama.isReady()) {
      const miss: string = prefix === '' ? '本地模型未加载。' : prefix;
      this.replacePending(miss);
      this.finishTurn(miss, AiRouter.modeName(RouteMode.FALLBACK));
      return;
    }
    this.generating = true;
    const prompt = this.buildChatMl(text);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'runLocal enter ready=%{public}s pending=%{public}d lines=%{public}d promptChars=%{public}d',
      '' + this.llama.isReady(), this.pendingIndex, this.lines.length, prompt.length);
    let lastText: string = '';
    const paint = (body: string): string => prefix === '' ? body : prefix + '\n' + body;
    try {
      // Native 侧通过 TSFN 投递累计全文，Promise 在 native 真正结束时才 settle
      const finalText: string = await this.llama.generateStream(prompt, (partial: string) => {
        lastText = partial;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'onToken chars=%{public}d', partial.length);
        this.replacePending(paint(partial));
      });
      hilog.info(LOG_DOMAIN, LOG_TAG, 'runLocal done finalText_chars=%{public}d last_chars=%{public}d',
        finalText.length, lastText.length);
      const raw: string = finalText === '' ? lastText : finalText;
      // 守卫：模型偶尔把用户名字当称呼、或冒出寒暄，这里确定性替换成「先生」
      const replyBody: string = guardReply(raw, this.bannedNames);
      this.replacePending(paint(replyBody));
      this.speakReply(replyBody);
      this.finishTurn(replyBody, AiRouter.modeName(RouteMode.LOCAL));
      if (this.modeLabel === '停止中…') {
        this.modeLabel = '已停止';
      }
    } catch (e) {
      const err = e as Error;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'runLocal failed: %{public}s', err.message);
      promptAction.showToast({ message: '本地生成失败', duration: 2000 });
      // 本地也失败 → 继续降级到词库，链不能断
      await this.degrade(text, RouteMode.LOCAL, err);
    } finally {
      this.generating = false;
    }
  }

  private replacePending(text: string): void {
    const idx: number = this.pendingIndex;
    if (idx >= 0 && idx < this.lines.length) {
      // 整体替换数组：@State 根数组换引用 + ForEach key 随文本变化，双重保证刷新
      const next: ChatLine[] = this.lines.slice();
      next[idx] = { role: 'assistant', text: text };
      this.lines = next;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'replacePending idx=%{public}d lines=%{public}d chars=%{public}d',
        idx, this.lines.length, text.length);
    } else {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'replacePending skip idx=%{public}d lines=%{public}d',
        idx, this.lines.length);
    }
  }

  /**
   * 本地 prompt：system + 最近 6 轮 + 当前这句。
   * 超出 LOCAL_PROMPT_CHARS 时 buildLocalPrompt 从最旧的开始裁，当前输入永远保留。
   */
  private buildChatMl(userText: string): string {
    const turns: ChatTurn[] = recentTurns(this.history, HISTORY_ROUNDS);
    // system 由人格内核统一拼：底线人格 + 事实 + 偏好(≤3) + 情绪，总长封顶 PERSONA_MAX_CHARS
    const sys: string = this.currentSystemPrompt('chatml');
    const pack: PromptPack = buildLocalPromptPack(sys, turns, userText, LOCAL_PROMPT_CHARS, this.ragLines);
    const prompt: string = pack.prompt;
    const kept: number = prompt.split('<|im_start|>').length - 1;
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'local prompt hist=%{public}d chars=%{public}d msgs=%{public}d sysChars=%{public}d rag=%{public}d ragChars=%{public}d histText=[%{public}s]',
      turns.length, prompt.length, kept, sys.length, pack.ragCount, pack.ragChars,
      describeTurns(turns, 400));
    hilog.info(LOG_DOMAIN, LOG_TAG, 'local prompt body=[%{public}s]',
      prompt.split('\n').join('⏎'));
    return prompt;
  }

  // ------------------------------------------------------------ 💭 主动搭话

  /** 只在前台跑：onPageShow 起表，onPageHide/aboutToDisappear 停表 */
  private startTicker(): void {
    if (this.tickId >= 0) {
      return;
    }
    this.tickId = setInterval(() => {
      this.proactiveTick();
    }, PROACTIVE_TICK_MS);
  }

  private stopTicker(): void {
    if (this.tickId < 0) {
      return;
    }
    clearInterval(this.tickId);
    this.tickId = -1;
  }

  /** 用户任何交互（发消息 / 点输入框 / 按麦克风 / 开关朗读）：静默计时归零，同时解除上次搭话的冷却 */
  private touchInteraction(why: string): void {
    this.proactive.touch(Date.now());
    hilog.info(LOG_DOMAIN, LOG_TAG, 'proactive touch why=%{public}s %{public}s',
      why, this.proactive.debugLine(Date.now()));
  }

  /** 30 秒一次：判定 → 生成 → 展示。判定与生成本身都不阻塞 UI（生成是 async，不 await 在 tick 里） */
  private proactiveTick(): void {
    const now: number = Date.now();
    const hour: number = effectiveHour(now);
    const gate: ProactiveGate = this.proactive.check(now, hour);
    this.proInfo = this.proactive.debugLine(now);
    if (!gate.allowed) {
      // 静默还没到阈值就不刷日志，免得 30 秒一条把 hilog 淹了
      if (gate.idleReady) {
        hilog.info(LOG_DOMAIN, LOG_TAG,
          'proactive skip reason=%{public}s idle=%{public}d hour=%{public}d %{public}s',
          gate.reason, gate.idleSec, hour, this.proactive.debugLine(now));
      }
      return;
    }
    if (this.proBusy || this.generating || this.llama.isGenerating()) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'proactive skip reason=busy idle=%{public}d hour=%{public}d',
        gate.idleSec, hour);
      return;
    }
    this.fireProactive(now, gate.idleSec, hour).catch((e: Error) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'proactive fire failed: %{public}s', e.message);
    });
  }

  /**
   * 搭话内容：优先本地模型（3 秒超时），超时/失败/重复一律降级到规则模板。
   * 任何分支都要么给出正文，要么明确放弃 —— 不出现空气泡。
   */
  private async fireProactive(now: number, idleSec: number, hour: number): Promise<void> {
    this.proBusy = true;
    try {
      let src: string = 'template';
      let body: string = '';
      if (this.llama.isReady()) {
        try {
          const raw: string = await this.generateProactive(hour, idleSec);
          const clean: string = cleanProactive(stripThink(raw));
          if (clean === '') {
            hilog.info(LOG_DOMAIN, LOG_TAG, 'proactive llm empty raw=[%{public}s]',
              oneLine(raw, 40));
          } else if (this.proactive.isDup(clean)) {
            hilog.info(LOG_DOMAIN, LOG_TAG, 'proactive llm dup text=[%{public}s]',
              oneLine(clean, 40));
          } else {
            body = clean;
            src = 'llm';
          }
        } catch (e) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'proactive llm downgrade: %{public}s',
            (e as Error).message);
        }
      } else {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'proactive llm skipped reason=model-not-ready');
      }
      if (body === '') {
        body = this.proactive.pickTemplate(hour);
        src = 'template';
      }
      if (body === '') {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'proactive abandon reason=all-dup hour=%{public}d', hour);
        return;
      }
      const shown: string = PROACTIVE_BUBBLE_PREFIX + body;
      this.lines.push({ role: 'assistant', text: shown });
      this.proactive.markFired(now, body);
      this.proInfo = this.proactive.debugLine(Date.now());
      // 进上下文的是不带 💭 的正文：不然模型会学着在每句开头画个气泡符号
      this.pushHistory('assistant', body);
      this.recordDb('assistant', shown, 'proactive').catch((e: Error) => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'proactive append failed: %{public}s', e.message);
      });
      this.speakReply(body);
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'proactive fire idle=%{public}d hour=%{public}d count=%{public}d src=%{public}s max=%{public}d period=%{public}s text=[%{public}s]',
        idleSec, hour, this.proactive.todayCount(Date.now()), src, PROACTIVE_MAX_PER_HOUR,
        periodName(hour), body);
    } finally {
      this.proBusy = false;
    }
  }

  /**
   * 本地模型生成一次搭话。3 秒超时：到点发 cancel，native 随后以 code 1 结束，
   * 我们按「超时」处理（截断的半句不要），交给模板兜底。
   */
  private async generateProactive(hour: number, idleSec: number): Promise<string> {
    const sys: string = this.currentSystemPrompt('proactive');
    const topic: string = this.recentTopic();
    const prompt: string = buildProactivePrompt(sys, topic, idleSec, hour);
    let partial: string = '';
    let timedOut: boolean = false;
    const timer: number = setTimeout(() => {
      timedOut = true;
      this.llama.cancel();
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'proactive llm timeout ms=%{public}d cancel sent',
        PROACTIVE_LLM_TIMEOUT_MS);
    }, PROACTIVE_LLM_TIMEOUT_MS);
    try {
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'proactive prompt chars=%{public}d topic=[%{public}s] body=[%{public}s]',
        prompt.length, topic, prompt.split('\n').join('⏎'));
      const finalText: string = await this.llama.generateStream(prompt, (t: string) => {
        partial = t;
      });
      if (timedOut) {
        throw new Error('生成超时 ' + PROACTIVE_LLM_TIMEOUT_MS + 'ms');
      }
      const out: string = finalText === '' ? partial : finalText;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'proactive llm done chars=%{public}d', out.length);
      return out;
    } finally {
      clearTimeout(timer);
    }
  }

  /** 最近 1-2 条 user 消息当话题线索（剥掉思考链、压成一行、各裁 20 字） */
  private recentTopic(): string {
    const parts: string[] = [];
    for (let i: number = this.history.length - 1; i >= 0 && parts.length < 2; i--) {
      const t: ChatTurn = this.history[i];
      if (t.role !== 'user') {
        continue;
      }
      const flat: string = oneLine(stripThink(t.text), 20);
      if (flat !== '') {
        parts.push(flat);
      }
    }
    parts.reverse();
    return parts.join(' / ');
  }
}
