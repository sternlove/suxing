import { textToSpeech, speechRecognizer } from '@kit.CoreSpeechKit';
import { audio } from '@kit.AudioKit';
import { abilityAccessCtrl, common, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';
const MIC_PERMISSION: Permissions = 'ohos.permission.MICROPHONE';
/** 离线识别引擎只收 640 / 1280 字节的定长 PCM 块（16000Hz/单声道/16bit → 1280B = 40ms） */
const ASR_CHUNK: number = 1280;
/** 一句话最长朗读/识别字符数：TTS 上限 10000，取保守值避免长文本卡住 UI */
const TTS_MAX_CHARS: number = 1800;
/** 播放结束轮询上限：1s 一次，封顶 90s */
const TTS_IDLE_POLLS: number = 90;
/** 单次按住说话最长录音 14s：实测连续写音频约 20s 会报 1002200003（超出最大音频长度） */
const ASR_MAX_BYTES: number = 14 * 32000;
/** RMS → 0..1 的软膝曲线系数：raw = sqrt(rms * GAIN)，rms 0.25 满量程 */
const TTS_LEVEL_GAIN: number = 4.0;
/** 振幅日志节流：200ms 一条，别每块 PCM 都刷 hilog */
const TTS_LEVEL_LOG_MS: number = 200;

/**
 * 实时朗读振幅（0..1，已做指数平滑）。
 * TTS 的 onData 回调里算 RMS 后写这里，3D 层每帧直接读静态字段驱动口型，
 * 不经过 @State、不反向调用组件方法，Speech 与 UI 保持零耦合。
 */
export class SpeechLevel {
  static value: number = 0;
}

/**
 * 语音能力对界面的回调。宿主页注入，Speech 自己不碰 @State。
 * hint 为空串表示「回到空闲，清掉提示」。
 */
export class SpeechHooks {
  onTtsState?: (speaking: boolean, hint: string) => void;
  onAsrState?: (listening: boolean, hint: string) => void;
  onAsrText?: (text: string, final: boolean) => void;
  onVoices?: (text: string) => void;
}

/** 运行时申请麦克风（user_grant）：已授权时系统不再弹框，直接返回 0 */
export async function requestMicPermission(ctx: common.UIAbilityContext): Promise<boolean> {
  try {
    const mgr: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const perms: Array<Permissions> = [MIC_PERMISSION];
    const res: PermissionRequestResult = await mgr.requestPermissionsFromUser(ctx, perms);
    const codes: Array<number> = res.authResults;
    let granted: boolean = false;
    for (let i = 0; i < codes.length; i++) {
      if (codes[i] === 0) {
        granted = true;
      }
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'speech mic permission granted=%{public}s codes=[%{public}s]',
      '' + granted, codes.join(','));
    return granted;
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(LOG_DOMAIN, LOG_TAG, 'speech mic permission failed code=%{public}d msg=%{public}s',
      err.code, err.message);
    return false;
  }
}

/** TTS 监听回调转接：引擎回调里不能直接 await，全部转给宿主类 */
class TtsListener implements textToSpeech.SpeakListener {
  private host: TwinTts;
  /**
   * onData 必须是实例自有属性（箭头函数）：可选回调在部分实现里按 own property 探测，
   * 写成原型方法可能取不到。构造函数之前初始化，调用时 this.host 已就绪。
   */
  onData: (requestId: string, audio: ArrayBuffer, response: textToSpeech.SynthesisResponse) => void =
    (requestId: string, audio: ArrayBuffer, response: textToSpeech.SynthesisResponse): void => {
      this.host.onAudioChunk(requestId, audio, response);
    };

  constructor(host: TwinTts) {
    this.host = host;
  }

  onStart(requestId: string, response: textToSpeech.StartResponse): void {
    this.host.onSpeakStart(requestId, response);
  }

  onComplete(requestId: string, response: textToSpeech.CompleteResponse): void {
    this.host.onSpeakComplete(requestId, response);
  }

  onStop(requestId: string, response: textToSpeech.StopResponse): void {
    this.host.onSpeakStop(requestId, response);
  }

  onError(requestId: string, errorCode: number, errorMessage: string): void {
    this.host.onSpeakError(requestId, errorCode, errorMessage);
  }

}

/**
 * 离线 TTS 朗读。整段朗读（不做逐 token），一次 speak 一个 requestId。
 * person: 13 = 聆小珊女声（默认内置）；0 = 同款别名，不需要下载。
 */
export class TwinTts {
  private engine: textToSpeech.TextToSpeechEngine | undefined = undefined;
  private creating: Promise<boolean> | undefined = undefined;
  private hooks: SpeechHooks = new SpeechHooks();
  private person: number = 13;
  private seq: number = 0;
  private requestId: string = '';
  private speaking: boolean = false;
  private voices: string = '';
  private idlePolls: number = 0;
  private level: number = 0;
  private lastLevelLog: number = 0;
  private chunks: number = 0;
  private simTimer: number = -1;
  private simT: number = 0;
  private srcNote: string = 'pcm';

  setHooks(h: SpeechHooks): void {
    this.hooks = h;
  }

  isSpeaking(): boolean {
    return this.speaking;
  }

  voicesText(): string {
    return this.voices;
  }

  personText(): string {
    return '音色 ' + this.person;
  }

  /** 切音色只在 13 / 0 之间轮换（21 男声需要联网下载，缺模型会直接报 1002300003） */
  cyclePerson(): number {
    this.person = this.person === 13 ? 0 : 13;
    this.releaseEngine();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'tts person -> %{public}d (engine reset)', this.person);
    return this.person;
  }

  private emit(speaking: boolean, hint: string): void {
    this.speaking = speaking;
    if (!speaking) {
      // 停止/完成/报错：立刻把目标振幅归零，3D 层再平滑收口（约 0.3s）
      this.level = 0;
      SpeechLevel.value = 0;
      this.stopSim();
    }
    const cb = this.hooks.onTtsState;
    if (cb !== undefined) {
      cb(speaking, hint);
    }
  }

  private releaseEngine(): void {
    const eng = this.engine;
    this.engine = undefined;
    if (eng === undefined) {
      return;
    }
    try {
      eng.stop();
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'tts stop on release: %{public}s', (e as BusinessError).message);
    }
    try {
      eng.shutdown();
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'tts shutdown on release: %{public}s', (e as BusinessError).message);
    }
  }

  private async ensure(): Promise<boolean> {
    if (this.engine !== undefined) {
      return true;
    }
    const pending = this.creating;
    if (pending !== undefined) {
      return pending;
    }
    const p: Promise<boolean> = this.create();
    this.creating = p;
    const ok: boolean = await p;
    this.creating = undefined;
    return ok;
  }

  private async create(): Promise<boolean> {
    const params: textToSpeech.CreateEngineParams = {
      language: 'zh-CN',
      person: this.person,
      online: 1
    };
    try {
      const eng: textToSpeech.TextToSpeechEngine = await textToSpeech.createEngine(params);
      this.engine = eng;
      eng.setListener(new TtsListener(this));
      hilog.info(LOG_DOMAIN, LOG_TAG, 'tts createEngine ok language=zh-CN person=%{public}d online=1',
        this.person);
      this.queryVoices();
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'tts createEngine failed code=%{public}d msg=%{public}s',
        err.code, err.message);
      this.emit(false, '❌ 朗读引擎不可用：' + err.message);
      return false;
    }
  }

  /** 查音色：查到后缓存成一行文本，操控面板直接显示（可选音色的依据） */
  private queryVoices(): void {
    const eng = this.engine;
    if (eng === undefined) {
      return;
    }
    const q: textToSpeech.VoiceQuery = { requestId: 'voices' + Date.now(), online: 1 };
    eng.listVoices(q).then((list: Array<textToSpeech.VoiceInfo>) => {
      const parts: Array<string> = [];
      for (let i = 0; i < list.length; i++) {
        const v: textToSpeech.VoiceInfo = list[i];
        const st: string = v.status === undefined ? '' : '/' + v.status;
        parts.push(v.language + '#' + v.person + '(' + v.gender + st + ')');
      }
      this.voices = parts.join(' ');
      hilog.info(LOG_DOMAIN, LOG_TAG, 'tts listVoices count=%{public}d [%{public}s]',
        list.length, this.voices);
      const cb = this.hooks.onVoices;
      if (cb !== undefined) {
        cb(this.voices);
      }
    }).catch((e: BusinessError) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'tts listVoices failed code=%{public}d msg=%{public}s',
        e.code, e.message);
    });
  }

  /** 整段朗读；调用方保证只在回复结束时调一次 */
  async speak(text: string): Promise<void> {
    const body: string = TwinTts.cleanText(text);
    if (body === '') {
      return;
    }
    if (this.speaking) {
      this.stop();
    }
    const ok: boolean = await this.ensure();
    if (!ok) {
      return;
    }
    const eng = this.engine;
    if (eng === undefined) {
      return;
    }
    this.seq++;
    const rid: string = 'ct' + Date.now() + this.seq;
    this.requestId = rid;
    const sp: textToSpeech.SpeakParams = { requestId: rid };
    try {
      eng.speak(body, sp);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'tts speak requestId=%{public}s chars=%{public}d',
        rid, body.length);
      this.chunks = 0;
      this.startSim(body.length);
      this.emit(true, '🔊 朗读中…');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'tts speak failed requestId=%{public}s code=%{public}d msg=%{public}s',
        rid, err.code, err.message);
      this.emit(false, '❌ 朗读失败：' + err.message);
    }
  }

  stop(): void {
    const eng = this.engine;
    if (eng === undefined) {
      this.emit(false, '');
      return;
    }
    if (!this.speaking) {
      return;
    }
    try {
      eng.stop();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'tts stop requestId=%{public}s', this.requestId);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'tts stop failed: %{public}s', (e as BusinessError).message);
    }
    this.emit(false, '');
  }

  shutdown(): void {
    this.releaseEngine();
    this.emit(false, '');
  }

  // ---------------------------------------------------------------- 引擎回调

  /**
   * 节律兜底：真机实测本引擎不回调 onData（onStart→sync complete→playback complete 齐全但 0 个音频块），
   * 拿不到 PCM 时按"音节节律"合成一条包络驱动口型，避免嘴不动。
   * 一旦真的收到音频块（chunks>0）立刻让位，绝不覆盖真实振幅。
   */
  private startSim(chars: number): void {
    this.stopSim();
    this.simT = 0;
    const dur: number = Math.max(800, Math.min(30000, chars * 230));
    hilog.info(LOG_DOMAIN, LOG_TAG, 'tts sim envelope start chars=%{public}d dur=%{public}dms',
      chars, dur);
    this.simTimer = setInterval(() => {
      if (this.chunks > 0) {
        this.stopSim();
        return;
      }
      this.simT += 0.1;
      if (this.simT * 1000 >= dur) {
        this.stopSim();
        return;
      }
      // 4.2Hz 音节 × 慢速重音 × 随机停顿：听起来像说话的起伏，而不是正弦波
      const syl: number = Math.abs(Math.sin(Math.PI * 4.2 * this.simT));
      const stress: number = 0.55 + 0.45 * Math.sin(2 * Math.PI * 0.37 * this.simT + 1.1);
      const gate: number = Math.random() < 0.06 ? 0.15 : 1.0;
      const env: number = Math.pow(syl, 0.7) * stress * gate;
      this.level = this.level * 0.55 + Math.min(1, env) * 0.45;
      SpeechLevel.value = this.level;
      this.srcNote = 'sim';
      const now: number = Date.now();
      if (now - this.lastLevelLog >= TTS_LEVEL_LOG_MS) {
        this.lastLevelLog = now;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'tts level=%{public}s src=sim chunks=0',
          this.level.toFixed(2));
      }
    }, 100);
  }

  private stopSim(): void {
    if (this.simTimer >= 0) {
      clearInterval(this.simTimer);
      this.simTimer = -1;
    }
  }

  /**
   * TTS 音频流回调：每块 PCM 算 RMS = sqrt(sum(x^2)/n)，归一化到 0..1，
   * 再做指数平滑 level = level*0.7 + raw*0.3，避免口型抖动。
   * 整个函数包 try/catch：口型链路任何异常都不许影响发声。
   */
  onAudioChunk(requestId: string, audio: ArrayBuffer, response: textToSpeech.SynthesisResponse): void {
    try {
      const bytes: number = audio.byteLength;
      if (bytes < 4) {
        return;
      }
      const n: number = bytes >> 1;
      const pcm: Int16Array = new Int16Array(audio, 0, n);
      // 16kHz 单块通常 640-3200 采样：抽到约 512 点算 RMS，省 CPU 又不丢包络
      const step: number = n > 512 ? Math.floor(n / 512) : 1;
      let sum: number = 0;
      let cnt: number = 0;
      for (let i = 0; i < n; i += step) {
        const v: number = pcm[i] / 32768.0;
        sum += v * v;
        cnt++;
      }
      const rms: number = cnt > 0 ? Math.sqrt(sum / cnt) : 0;
      const raw: number = Math.sqrt(Math.min(1, rms * TTS_LEVEL_GAIN));
      this.level = this.level * 0.7 + raw * 0.3;
      this.chunks++;
      this.srcNote = 'pcm';
      SpeechLevel.value = this.level;
      const now: number = Date.now();
      if (now - this.lastLevelLog >= TTS_LEVEL_LOG_MS) {
        this.lastLevelLog = now;
        hilog.info(LOG_DOMAIN, LOG_TAG,
          'tts level=%{public}s src=pcm rms=%{public}s raw=%{public}s chunks=%{public}d seq=%{public}d bytes=%{public}d',
          this.level.toFixed(2), rms.toFixed(4), raw.toFixed(2), this.chunks, response.sequence, bytes);
      }
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'tts onData rms failed: %{public}s', (e as BusinessError).message);
    }
  }

  onSpeakStart(requestId: string, response: textToSpeech.StartResponse): void {
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'tts onStart requestId=%{public}s rate=%{public}d ch=%{public}d bit=%{public}d type=%{public}s',
      requestId, response.sampleRate, response.audioChannel, response.sampleBit, response.audioType);
    this.emit(true, '🔊 朗读中…');
  }

  onSpeakComplete(requestId: string, response: textToSpeech.CompleteResponse): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'tts onComplete requestId=%{public}s type=%{public}d msg=%{public}s',
      requestId, response.type, response.message);
    if (response.type === 1) {
      this.emit(false, '');
      return;
    }
    this.watchIdle();
  }

  onSpeakStop(requestId: string, response: textToSpeech.StopResponse): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'tts onStop requestId=%{public}s type=%{public}d msg=%{public}s',
      requestId, response.type, response.message);
    this.emit(false, '');
  }

  onSpeakError(requestId: string, errorCode: number, errorMessage: string): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'tts onError requestId=%{public}s code=%{public}d msg=%{public}s',
      requestId, errorCode, errorMessage);
    this.emit(false, '❌ 朗读失败(' + errorCode + ')：' + errorMessage);
  }

  /** 合成完成(0) 之后播放还在继续：轮询 isBusy 直到真正空闲（实测 75 字 ≈ 16s） */
  private watchIdle(): void {
    const eng = this.engine;
    if (eng === undefined) {
      this.emit(false, '');
      return;
    }
    this.idlePolls = 0;
    this.pollIdle(eng);
  }

  private pollIdle(eng: textToSpeech.TextToSpeechEngine): void {
    this.idlePolls++;
    if (this.idlePolls > TTS_IDLE_POLLS) {
      this.emit(false, '');
      return;
    }
    setTimeout(() => {
      if (this.engine !== eng) {
        return;
      }
      let busy: boolean = false;
      try {
        busy = eng.isBusy();
      } catch (e) {
        busy = false;
      }
      if (!busy) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'tts playback idle after %{public}d polls', this.idlePolls);
        this.emit(false, '');
        return;
      }
      this.pollIdle(eng);
    }, 1000);
  }

  /** 去掉 markdown 标记与 emoji：TTS 会把符号念成噪音 */
  private static cleanText(text: string): string {
    let s: string = text;
    s = s.replace(new RegExp('[#*`>|~_]', 'g'), ' ');
    s = s.replace(new RegExp('\\[(.*?)\\]\\((.*?)\\)', 'g'), '$1');
    let out: string = '';
    for (let i = 0; i < s.length; i++) {
      const c: number = s.charCodeAt(i);
      if (c >= 0xD800 && c <= 0xDFFF) {
        continue;
      }
      if (c === 0xFE0F || c === 0x20E3 || c === 0x200D) {
        continue;
      }
      if (c >= 0x2190 && c <= 0x2BFF) {
        out += ' ';
        continue;
      }
      out += s.charAt(i);
    }
    out = out.trim();
    if (out.length > TTS_MAX_CHARS) {
      out = out.substring(0, TTS_MAX_CHARS);
    }
    return out;
  }
}

/** ASR 监听回调转接 */
class AsrListener implements speechRecognizer.RecognitionListener {
  private host: TwinAsr;

  constructor(host: TwinAsr) {
    this.host = host;
  }

  onStart(sessionId: string, eventMessage: string): void {
    this.host.onEngineStart(sessionId, eventMessage);
  }

  onEvent(sessionId: string, eventCode: number, eventMessage: string): void {
    this.host.onEngineEvent(sessionId, eventCode, eventMessage);
  }

  onResult(sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void {
    this.host.onEngineResult(sessionId, result);
  }

  onComplete(sessionId: string, eventMessage: string): void {
    this.host.onEngineComplete(sessionId, eventMessage);
  }

  onError(sessionId: string, errorCode: number, errorMessage: string): void {
    this.host.onEngineError(sessionId, errorCode, errorMessage);
  }
}

/**
 * 按住说话：麦克风 → AudioCapturer(16000/1/S16LE) → 定长 1280B → 离线识别引擎。
 * 识别引擎本身不采音，只吃 writeAudio 送进来的 PCM。
 */
export class TwinAsr {
  private engine: speechRecognizer.SpeechRecognitionEngine | undefined = undefined;
  private capturer: audio.AudioCapturer | undefined = undefined;
  private hooks: SpeechHooks = new SpeechHooks();
  private sessionId: string = '';
  private active: boolean = false;
  private buffer: Uint8Array = new Uint8Array(0);
  private lastText: string = '';
  private finalText: string = '';
  private bytes: number = 0;
  /** 引擎已经给出最后一句（isLast）后不再写音频，否则会报 1002200010 把成功提示覆盖成错误 */
  private resultDone: boolean = false;

  setHooks(h: SpeechHooks): void {
    this.hooks = h;
  }

  isListening(): boolean {
    return this.active;
  }

  private emit(listening: boolean, hint: string): void {
    const cb = this.hooks.onAsrState;
    if (cb !== undefined) {
      cb(listening, hint);
    }
  }

  private emitText(text: string, final: boolean): void {
    const cb = this.hooks.onAsrText;
    if (cb !== undefined) {
      cb(text, final);
    }
  }

  private async ensureEngine(): Promise<boolean> {
    if (this.engine !== undefined) {
      return true;
    }
    const params: speechRecognizer.CreateEngineParams = { language: 'zh-CN', online: 1 };
    try {
      const eng: speechRecognizer.SpeechRecognitionEngine = await speechRecognizer.createEngine(params);
      this.engine = eng;
      eng.setListener(new AsrListener(this));
      hilog.info(LOG_DOMAIN, LOG_TAG, 'asr createEngine ok language=zh-CN online=1(offline)');
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'asr createEngine failed code=%{public}d msg=%{public}s',
        err.code, err.message);
      this.emit(false, '❌ 识别引擎不可用(' + err.code + ')：' + err.message);
      return false;
    }
  }

  /** 按下：授权 → 引擎 → 采集器 → startListening，全部成功才算在听 */
  async start(ctx: common.UIAbilityContext): Promise<void> {
    if (this.active) {
      return;
    }
    const granted: boolean = await requestMicPermission(ctx);
    if (!granted) {
      this.emit(false, '❌ 麦克风未授权：请在系统设置里允许「苏兴」使用麦克风');
      return;
    }
    const ready: boolean = await this.ensureEngine();
    if (!ready) {
      return;
    }
    const eng = this.engine;
    if (eng === undefined) {
      return;
    }
    this.lastText = '';
    this.finalText = '';
    this.buffer = new Uint8Array(0);
    this.bytes = 0;
    this.resultDone = false;
    this.sessionId = 'ct_asr_' + Date.now();
    const info: speechRecognizer.AudioInfo = {
      audioType: 'pcm',
      sampleRate: 16000,
      soundChannel: 1,
      sampleBit: 16
    };
    const sp: speechRecognizer.StartParams = { sessionId: this.sessionId, audioInfo: info };
    try {
      eng.startListening(sp);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'asr startListening failed code=%{public}d msg=%{public}s',
        err.code, err.message);
      this.emit(false, '❌ 启动识别失败(' + err.code + ')：' + err.message);
      return;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'asr startListening sessionId=%{public}s', this.sessionId);
    const capOk: boolean = await this.startCapture();
    if (!capOk) {
      try {
        eng.cancel(this.sessionId);
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'asr cancel after capture fail: %{public}s',
          (e as BusinessError).message);
      }
      return;
    }
    this.active = true;
    this.emit(true, '🎙 正在听…');
  }

  private async startCapture(): Promise<boolean> {
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION,
      capturerFlags: 0
    };
    const opts: audio.AudioCapturerOptions = { streamInfo: streamInfo, capturerInfo: capturerInfo };
    try {
      const cap: audio.AudioCapturer = await audio.createAudioCapturer(opts);
      cap.on('readData', (buf: ArrayBuffer) => {
        this.feed(buf);
      });
      await cap.start();
      this.capturer = cap;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'asr capturer started 16000/1/S16LE raw');
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'asr capturer failed code=%{public}d msg=%{public}s',
        err.code, err.message);
      this.emit(false, '❌ 麦克风打不开(' + err.code + ')：' + err.message);
      return false;
    }
  }

  /** readData 块长不定，攒够 1280 字节才交给引擎 */
  private feed(buf: ArrayBuffer): void {
    const eng = this.engine;
    if (eng === undefined || !this.active || this.resultDone) {
      return;
    }
    const chunk: Uint8Array = new Uint8Array(buf);
    const merged: Uint8Array = new Uint8Array(this.buffer.length + chunk.length);
    merged.set(this.buffer, 0);
    merged.set(chunk, this.buffer.length);
    let off: number = 0;
    while (merged.length - off >= ASR_CHUNK) {
      const piece: Uint8Array = merged.slice(off, off + ASR_CHUNK);
      off += ASR_CHUNK;
      try {
        eng.writeAudio(this.sessionId, piece);
        this.bytes += ASR_CHUNK;
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'asr writeAudio failed code=%{public}d msg=%{public}s',
          err.code, err.message);
        break;
      }
    }
    this.buffer = merged.slice(off);
    if (this.bytes >= ASR_MAX_BYTES) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'asr auto stop: bytes=%{public}d reached cap', this.bytes);
      this.stopListen().catch((e: Error) => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'asr auto stop failed: %{public}s', e.message);
      });
    }
  }

  /** 松开：停采集 → finish 让引擎出最终结果 */
  async stopListen(): Promise<void> {
    if (!this.active) {
      return;
    }
    this.active = false;
    await this.stopCapture();
    const eng = this.engine;
    if (eng === undefined || this.sessionId === '') {
      this.emit(false, '');
      return;
    }
    try {
      eng.finish(this.sessionId);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'asr finish sessionId=%{public}s audioBytes=%{public}d',
        this.sessionId, this.bytes);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'asr finish failed code=%{public}d msg=%{public}s',
        err.code, err.message);
      this.emit(false, '❌ 结束识别失败(' + err.code + ')：' + err.message);
    }
  }

  private async stopCapture(): Promise<void> {
    const cap = this.capturer;
    this.capturer = undefined;
    if (cap === undefined) {
      return;
    }
    try {
      cap.off('readData');
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'asr off readData: %{public}s', (e as BusinessError).message);
    }
    try {
      await cap.stop();
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'asr capturer stop: %{public}s', (e as BusinessError).message);
    }
    try {
      await cap.release();
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'asr capturer release: %{public}s', (e as BusinessError).message);
    }
  }

  shutdown(): void {
    this.active = false;
    this.stopCapture();
    const eng = this.engine;
    this.engine = undefined;
    if (eng !== undefined) {
      try {
        eng.shutdown();
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'asr shutdown: %{public}s', (e as BusinessError).message);
      }
    }
    this.emit(false, '');
  }

  // ---------------------------------------------------------------- 引擎回调

  onEngineStart(sessionId: string, eventMessage: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'asr onStart sessionId=%{public}s msg=%{public}s',
      sessionId, eventMessage);
  }

  onEngineEvent(sessionId: string, eventCode: number, eventMessage: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'asr onEvent sessionId=%{public}s code=%{public}d msg=%{public}s',
      sessionId, eventCode, eventMessage);
  }

  onEngineResult(sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void {
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'asr onResult sessionId=%{public}s final=%{public}s last=%{public}s text=%{public}s',
      sessionId, '' + result.isFinal, '' + result.isLast, result.result);
    if (result.isLast) {
      this.resultDone = true;
    }
    if (result.result === '') {
      return;
    }
    this.lastText = result.result;
    if (result.isFinal) {
      this.finalText = result.result;
      this.emitText(result.result, true);
      this.emit(true, '🎙 ' + result.result);
    } else {
      this.emitText(result.result, false);
      this.emit(true, '🎙 ' + result.result);
    }
  }

  onEngineComplete(sessionId: string, eventMessage: string): void {
    const text: string = this.finalText === '' ? this.lastText : this.finalText;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'asr onComplete sessionId=%{public}s msg=%{public}s text=%{public}s',
      sessionId, eventMessage, text);
    if (text === '') {
      this.emit(false, '🎙 没听到内容');
      return;
    }
    this.emitText(text, true);
    this.emit(false, '✅ 已识别，可编辑后发送');
  }

  onEngineError(sessionId: string, errorCode: number, errorMessage: string): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'asr onError sessionId=%{public}s code=%{public}d msg=%{public}s',
      sessionId, errorCode, errorMessage);
    this.emit(false, '❌ 识别失败(' + errorCode + ')：' + errorMessage);
  }
}
