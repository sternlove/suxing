import { ModelProfile } from './ModelKit';

/**
 * viseme 口型状态机（纯逻辑，不碰引擎）。
 *
 * 输入：TTS 实时振幅（已平滑）+ 当前时间。
 * 输出：jawOpen / aa / ih / oh / ou / sil 六个权重，由 Avatar3D 写进两个 morph 几何体
 * （Nova 的 AvatarHead 与 AvatarTeethLower 都带这 6 个 shape，必须同时写，否则牙齿不跟着动）。
 *
 * 元音轮换按音节节奏走：说话中每 120-250ms 换一个元音，幅度乘振幅，
 * 所以重音处口型大、轻声处口型小；静音时 sil 抬到 1，其余归零。
 */
export interface VisemeWeights {
  jaw: number;
  aa: number;
  ih: number;
  oh: number;
  ou: number;
  sil: number;
}

const VOWEL_COUNT: number = 4;
/** 轮换间隔区间（毫秒） */
const SWAP_MIN_MS: number = 120;
const SWAP_MAX_MS: number = 250;
/** 元音幅度相对 jawOpen 的比例：元音是"口型形状"，不额外放大张口 */
const VOWEL_GAIN: number = 0.85;
/** 元音切换的淡入淡出速度（每帧插值系数） */
const VOWEL_LERP: number = 0.45;
/** 低于这个振幅视为静音 */
const SILENCE_LV: number = 0.02;

export class VisemeDriver {
  private cur: number = 0;
  private nextSwapMs: number = 0;
  private w: number[] = [0, 0, 0, 0];
  private silW: number = 0;
  private swaps: number = 0;
  private out: VisemeWeights = { jaw: 0, aa: 0, ih: 0, oh: 0, ou: 0, sil: 0 };

  get swapCount(): number {
    return this.swaps;
  }

  reset(): void {
    this.cur = 0;
    this.nextSwapMs = 0;
    this.w = [0, 0, 0, 0];
    this.silW = 0;
    this.swaps = 0;
  }

  /**
   * @param lv  平滑后的振幅 0..1
   * @param jaw 由振幅换算出的主张口权重 0..1
   * @param nowMs Date.now()
   * @param prof 当前模型配置（决定要不要跑元音轮换）
   */
  update(lv: number, jaw: number, nowMs: number, prof: ModelProfile): VisemeWeights {
    const voiced: boolean = lv > SILENCE_LV && prof.vowelShapes.length > 0;
    if (voiced) {
      if (nowMs >= this.nextSwapMs) {
        this.cur = (this.cur + 1) % VOWEL_COUNT;
        this.swaps++;
        this.nextSwapMs = nowMs + SWAP_MIN_MS + Math.random() * (SWAP_MAX_MS - SWAP_MIN_MS);
      }
    }
    for (let i = 0; i < VOWEL_COUNT; i++) {
      const want: number = (voiced && i === this.cur) ? jaw * VOWEL_GAIN : 0;
      this.w[i] = this.w[i] + (want - this.w[i]) * VOWEL_LERP;
      if (this.w[i] < 0.001) {
        this.w[i] = 0;
      }
    }
    const wantSil: number = lv <= SILENCE_LV ? 1 : 0;
    this.silW = this.silW + (wantSil - this.silW) * 0.35;
    if (this.silW < 0.001) {
      this.silW = 0;
    }
    this.out.jaw = jaw;
    this.out.aa = this.w[0];
    this.out.ih = this.w[1];
    this.out.oh = this.w[2];
    this.out.ou = this.w[3];
    this.out.sil = this.silW;
    return this.out;
  }
}
