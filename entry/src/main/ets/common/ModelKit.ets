/**
 * 双模型配置 + 骨骼映射表。
 *
 * 为什么不再用"名字子串"匹配：Nova 是 VRM 命名，子串规则会漏（LeftArm 不含 upperarm、
 * Hips 不含 waist）也会多（HeadTop_End / AvatarHead 都含 head，会被重复驱动）。
 * 所以每个模型一张精确名映射表：查不到就跳过并打日志，不崩、不瞎驱动。
 */
export const KIND_REALISTIC: number = 0;
export const KIND_ANIME: number = 1;
/** 默认形象：写实版 Avatar.glb（用户指定）。动漫版 nova.glb 仍在 rawfile，面板可切换。 */
export const DEFAULT_MODEL_KIND: number = KIND_REALISTIC;

export const ROLE_NONE: number = -1;
export const ROLE_THIGH: number = 0;
export const ROLE_CALF: number = 1;
export const ROLE_FOOT: number = 2;
export const ROLE_TOE: number = 3;
export const ROLE_ARM: number = 4;
export const ROLE_FOREARM: number = 5;
export const ROLE_WAIST: number = 6;
export const ROLE_SPINE_LOW: number = 7;
export const ROLE_SPINE_UP: number = 8;
export const ROLE_NECK: number = 9;
export const ROLE_HEAD: number = 10;

export const ROLE_NAMES: string[] = [
  'Thigh', 'Calf', 'Foot', 'Toe', 'Upperarm', 'Forearm', 'Waist',
  'Spine01', 'Spine02', 'Neck', 'Head'
];

export interface RawVec3 {
  x: number;
  y: number;
  z: number;
}

export interface ModelProfile {
  kind: number;
  /** 面板显示名 */
  label: string;
  /** rawfile 里的 GLB 文件名（两个文件都保留在包里） */
  file: string;
  /** 额外基准偏航（度）：把模型原生朝向掰到"面朝 +X"，整套动作按 +X 前进标定 */
  yawFixDeg: number;
  /** 归一化身高（场景单位）；<=0 表示不缩放 */
  normHeight: number;
  /** 原始模型空间的唇线坐标（光团按模型子节点挂载，用原始空间即可自动跟随缩放） */
  mouth: RawVec3;
  /** 主张口 shape */
  jawShapes: string[];
  /** 元音轮换 shape */
  vowelShapes: string[];
  /** 静音 shape */
  silShapes: string[];
  /** WAVE 抬臂角度系数：T-pose 基线已经水平，抬臂幅度要按比例缩小，否则翻到头顶 */
  waveArmScale: number;
  /** WAVE 屈肘角度系数 */
  waveElbowScale: number;
  /** 嘴部光团亮度系数（Nova 有真 morph，光团要更暗，避免糊嘴） */
  glowAlphaScale: number;
  /**
   * T-pose → A-pose 的抬臂修正角（度）：0 = 模型本身已是 A 字，不动。
   * Nova 的 LeftHand 与 LeftArm 等高（完全平举），不改就是一直摊着胳膊。
   */
  armDownDeg: number;
  /** 肩关节横向位置（模型原始空间），粒子云折臂时当枢轴用 */
  tposeShoulderX: number;
  /** 肩关节高度（模型原始空间） */
  tposeShoulderY: number;
}

/**
 * 写实版 Avatar.glb（Tripo）。身高 0.9992、面朝 +X，不需要偏航修正。
 * 骨骼实测：L_Thigh/L_Calf/L_Foot/L_ToeBase/L_Upperarm/L_Forearm/Waist/Spine01/Spine02/
 * NeckTwist01/NeckTwist02/Head，只有 'mouthOpen' 一个 morph。
 */
const REALISTIC: ModelProfile = {
  kind: KIND_REALISTIC,
  label: '写实',
  file: 'Avatar.glb',
  yawFixDeg: 0,
  normHeight: 0.9992,
  mouth: { x: 0.058, y: 0.8495, z: -0.004 },
  jawShapes: ['mouthOpen'],
  vowelShapes: [],
  silShapes: [],
  waveArmScale: 1.0,
  waveElbowScale: 1.0,
  glowAlphaScale: 1.0,
  armDownDeg: 0,
  tposeShoulderX: 0,
  tposeShoulderY: 0
};

/**
 * 动漫版 nova.glb（VRM）。实测：Y-up、面朝 +Z、身高 1.8143、T-pose（LeftHand 与 LeftArm 等高）。
 * 所以要 +90° 偏航才能对上"面朝 +X"，并缩到 0.999 与场景装置/机位同标定。
 * morph 落在 3 个几何节点：AvatarHead(66)/AvatarTeethLower(19) 都有 jawOpen+aa/ih/oh/ou/sil。
 */
const ANIME: ModelProfile = {
  kind: KIND_ANIME,
  label: '动漫',
  file: 'nova.glb',
  yawFixDeg: 90,
  normHeight: 0.9992,
  mouth: { x: 0, y: 1.6073, z: 0.105 },
  jawShapes: ['jawOpen'],
  vowelShapes: ['aa', 'ih', 'oh', 'ou'],
  silShapes: ['sil'],
  waveArmScale: 0.32,
  waveElbowScale: 0.75,
  glowAlphaScale: 0.5,
  armDownDeg: 45,
  tposeShoulderX: 0.174,
  tposeShoulderY: 1.429
};

export function profileOf(kind: number): ModelProfile {
  return kind === KIND_ANIME ? ANIME : REALISTIC;
}

/**
 * 映射表：行号即 ROLE_*，值是"小写精确节点名"。
 * 写实版这张表与旧子串匹配的结果逐条等价（旧逻辑靠 twist/knee/share/eye 等黑名单排除辅助骨，
 * 这里靠精确名达成同样效果）。
 */
const REALISTIC_MAP: string[][] = [
  ['l_thigh', 'r_thigh'],
  ['l_calf', 'r_calf'],
  ['l_foot', 'r_foot'],
  ['l_toebase', 'r_toebase'],
  ['l_upperarm', 'r_upperarm'],
  ['l_forearm', 'r_forearm'],
  ['waist'],
  ['spine01'],
  ['spine02'],
  ['necktwist01', 'necktwist02'],
  ['head']
];

/** 动漫版（VRM 标准命名）。注意只取 Neck，不取 Neck1/Neck2，避免呼吸被叠三次 */
const ANIME_MAP: string[][] = [
  ['leftupleg', 'rightupleg'],
  ['leftleg', 'rightleg'],
  ['leftfoot', 'rightfoot'],
  ['lefttoebase', 'righttoebase'],
  ['leftarm', 'rightarm'],
  ['leftforearm', 'rightforearm'],
  ['hips'],
  ['spine'],
  ['spine1'],
  ['neck'],
  ['head']
];

export function boneMapOf(kind: number): string[][] {
  return kind === KIND_ANIME ? ANIME_MAP : REALISTIC_MAP;
}

/** 节点名 → 角色号；ROLE_NONE = 这张表里没有它（跳过，由调用方打日志） */
export function roleOfName(kind: number, nodeName: string): number {
  const ln: string = nodeName.toLowerCase();
  if (ln === '') {
    return ROLE_NONE;
  }
  const map: string[][] = boneMapOf(kind);
  for (let r = 0; r < map.length; r++) {
    const names: string[] = map[r];
    for (let i = 0; i < names.length; i++) {
      if (names[i] === ln) {
        return r;
      }
    }
  }
  return ROLE_NONE;
}

/** 左右判定：两套命名都覆盖（l_thigh / leftupleg） */
export function isLeftName(nodeName: string): boolean {
  const ln: string = nodeName.toLowerCase();
  if (ln.indexOf('left') === 0) {
    return true;
  }
  if (ln.indexOf('right') === 0) {
    return false;
  }
  if (ln.indexOf('l_') === 0) {
    return true;
  }
  if (ln.indexOf('r_') === 0) {
    return false;
  }
  return ln.indexOf('left') >= 0;
}

export function roleName(role: number): string {
  return role >= 0 && role < ROLE_NAMES.length ? ROLE_NAMES[role] : 'none';
}
