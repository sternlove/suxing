import {
  Scene,
  SceneResourceFactory,
  SceneNodeParameters,
  SceneResourceParameters,
  Camera,
  Node,
  NodeType,
  Container,
  Geometry,
  Light,
  LightType,
  Quaternion,
  Vec3,
  Vec4,
  Color,
  Material,
  MaterialType,
  MeshResource,
  UnlitMaterial,
  MetallicRoughnessMaterial,
  CustomGeometry,
  CylinderGeometry,
  GeometryDefinition,
  EnvironmentBackgroundType,
  Blend,
  CullMode,
  PolygonMode,
  PostProcessSettings,
  BloomSettings,
  ToneMappingType,
  Morpher
} from '@kit.ArkGraphics3D';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { SpeechLevel } from './Speech';
import {
  ModelProfile,
  RawVec3,
  profileOf,
  roleOfName,
  isLeftName,
  roleName,
  KIND_ANIME,
  DEFAULT_MODEL_KIND,
  ROLE_NONE,
  ROLE_THIGH,
  ROLE_CALF,
  ROLE_FOOT,
  ROLE_TOE,
  ROLE_ARM,
  ROLE_FOREARM,
  ROLE_WAIST,
  ROLE_SPINE_LOW,
  ROLE_SPINE_UP,
  ROLE_NECK,
  ROLE_HEAD
} from './ModelKit';
import { VisemeDriver, VisemeWeights } from './Viseme';

const LOG_DOMAIN: number = 0xC0DE;
const LOG_TAG: string = 'CyberTwin';

/** 固定步长：动作推进不吃真实帧间隔，帧率抖动不会让骨骼一顿一顿 */
const FIXED_DT: number = 1 / 60;
const MAX_STEPS: number = 5;

/**
 * 帧节拍：先按 60fps 跑，实测掉到 PERF_MIN_FPS 以下自动退回 30fps（同一进程内只降不升）。
 * 门槛 46 → 38：46 太敏感，连续对话时一次推理卡顿就会永久锁在 30fps 直到重启。
 *
 * 已知设计缺陷：「只降不升」意味着一次抖动会永久牺牲后续流畅度。彻底修法是加带冷却的
 * 回升（连续 N 秒 fps>55 才尝试回 60），但会在临界点反复横跳，需要更谨慎的实测。
 */
const TICK_FAST: number = 16;
const TICK_SLOW: number = 33;
const PERF_WINDOW: number = 90;
const PERF_MIN_FPS: number = 38;

const GAIT_HZ: number = 1.0;
const BREATH_PERIOD: number = 3.6;
const YAW_AMP: number = 0.25;
const WALK_SPEED: number = 0.16;
const DWELL_DRIFT: number = 0.25;
const DWELL_GAIT: number = 0.30;
const X_LIMIT: number = 0.5;
const DEG: number = Math.PI / 180;

/** A 段缓动：整段位移 easeInOutSine 包一层，落地顿点 x0.85，转身角速度梯形曲线 */
const LAND_DIP: number = 0.85;
const LAND_WIN: number = 0.25;
const TURN_S: number = 1.25;
/** 极低频呼吸式起伏：7.3 秒一圈，让步态不像节拍器 */
const SLOW_WAVE_PERIOD: number = 7.3;
const SLOW_WAVE_AMP: number = 0.18;
const SLOW_BOB: number = 0.005;

/**
 * 粒子壳：整体外扩到人体外围，人体表面不放任何点。
 * 沿模型法线外浮 0.075-0.155 倍身高（近层 / 远层），再叠 ±0.012 倍身高的三维抖动，
 * 越靠外越稀（远层点数更多但球面面积更大），形成环绕人形的光场而非"贴在皮肤上"。
 */
const PARTICLE_TARGET: number = 9040;
const NEAR_OUT_MIN: number = 0.075;
const NEAR_OUT_MAX: number = 0.105;
const FAR_OUT_MIN: number = 0.110;
const FAR_OUT_MAX: number = 0.155;
const PART_SIZE: number = 0.0020;
const PART_JITTER: number = 0.012;
const NEAR_GROUPS: number = 5;
const FAR_GROUPS: number = 3;

const ST_WALK: number = 0;
const ST_DWELL: number = 1;
const ST_SIT: number = 2;
const ST_WAVE: number = 3;

const K_BREATH: number = 0;
const K_THIGH: number = 1;
const K_CALF: number = 2;
const K_ARM: number = 3;
const K_SWAY: number = 4;
const K_HEAD: number = 5;
const K_FOOT: number = 6;

/** 姿态骨骼分类（绕世界轴驱动，运行时换算到骨骼局部轴） */
const PK_THIGH: number = 10;
const PK_CALF: number = 11;
const PK_FOOT: number = 12;
const PK_UARM: number = 13;
const PK_FARM: number = 14;
const PK_HEAD: number = 15;

/** B 段：SIT / WAVE 时序与角度 */
const SIT_IN_MIN: number = 1.2;
const SIT_IN_MAX: number = 1.8;
const SIT_HOLD_MIN: number = 8.0;
const SIT_HOLD_MAX: number = 15.0;
const SIT_GAP_MIN: number = 40.0;
const SIT_GAP_MAX: number = 90.0;
const SIT_THIGH_DEG: number = 75;
const SIT_CALF_DEG: number = -85;
const SIT_FOOT_DEG: number = 10;
/** 坐下时整体下沉量 = 比例 x 模型高度（实测：让脚尖回到地面） */
const SIT_DROP_RATIO: number = 0.206;

const WAVE_UP_S: number = 0.40;
const WAVE_HOLD_MIN: number = 2.0;
const WAVE_HOLD_MAX: number = 3.0;
const WAVE_DOWN_S: number = 0.80;
const WAVE_GAP_MIN: number = 120.0;
const WAVE_GAP_MAX: number = 300.0;
/** 上臂抬起 55°（静止已是 A 字 52°，合起来略高于水平，再高会拉裂肩部蒙皮） */
const WAVE_ARM_DEG: number = -55;
const WAVE_ELBOW_DEG: number = -60;
const WAVE_OSC_DEG: number = 15;
const WAVE_OSC_HZ: number = 1.6;

const NOD_S: number = 1.6;
const NOD_DEG: number = 7;

/** D 段：故障抖动 + 场景装置 */
const GLITCH_GAP_MIN: number = 8.0;
const GLITCH_GAP_MAX: number = 15.0;
const GLITCH_DUR_MIN: number = 0.10;
const GLITCH_DUR_MAX: number = 0.20;
const GLITCH_AMP_MIN: number = 0.0025;
const GLITCH_AMP_MAX: number = 0.0060;
const RING_SEG: number = 72;
const RING_R_IN: number = 0.23;
const RING_R_OUT: number = 0.28;
const SCAN_R_IN: number = 0.20;
const SCAN_R_OUT: number = 0.245;
const SCAN_PERIOD: number = 7.0;
const HALO_R_IN: number = 0.26;
const HALO_R_OUT: number = 0.62;
/** 线框笼半径：原来 0.46 贴着身体，前壁竖线正好压在人脸上像裂纹，放大到 0.62 让线散到轮廓外 */
const SHELL_R: number = 0.62;
const SHELL_H: number = 0.98;

/** 语义动作编码：与 common/AvatarReaction.ets 的 RXN_* 一致 */
const RXN_NONE: number = 0;
const RXN_WAVE: number = 1;
const RXN_SIT: number = 2;
const RXN_NOD: number = 3;

/**
 * 赛博口型：模型空间嘴部坐标（身高 1.0，面朝 +X，Z 为左右轴）。
 * 由 Avatar.glb 顶点实测：唇线 Y=0.8495，面前表面 X=0.058，面中线 Z=-0.004。
 * 音频振幅驱动两套表现：morph target 'mouthOpen'（真张口）+ 嘴部光团（暗处可读）。
 */
// 唇线坐标与 shape 名已按模型走 common/ModelKit.ets 的 ModelProfile：
// 写实版 (0.058, 0.8495, -0.004) + 'mouthOpen'；Nova (0, 1.6073, 0.105) + 'jawOpen'。
// 保留这段注释是因为这些数字是从 Avatar.glb 顶点实测来的，别照搬给别的模型。
/** morph 权重增益：weight = min(1, lv^0.70 * 1.3) */
const MOUTH_GAIN: number = 1.3;
/** 光团：半径 0.010（直径 0.02）→ 最大 3 倍（0.06）；透明度 0.05 → 0.75 */
const GLOW_R: number = 0.010;
const GLOW_SCALE_MAX: number = 1.5;
const GLOW_A_MIN: number = 0.04;
/** 亮团压在唇线正上方会糊住张口（放大 9 倍实测）：压到 0.22 并下沉到下巴 */
const GLOW_A_MAX: number = 0.22;
/** 光团相对唇线的纵向偏移：负值 = 往下沉到下巴，让上下唇之间保持通透 */
const GLOW_DY: number = -0.022;
/**
 * 机位：3/4 前侧。模型原生面朝 +X（R_Eye/L_Eye 只差 Z 轴、FacialBone 在 Head 的 +X 侧），
 * 原来的 (0,1.15,4.4) 沿 -Z 看，画面里永远是侧脸乃至后脑勺，嘴根本看不见。
 * 现在相机放到 +X 侧 30° 方向（3.80/2.20）看向躯干：yaw ±0.5rad 时脸在 1.4°~58.6° 斜角内，
 * 正脸占比明显更大；人物沿 +X 走，正好是"朝相机走近/走远"，不会出现横着走。
 */
const CAM_X: number = 3.80;
const CAM_Y: number = 1.15;
const CAM_Z: number = 2.20;
const CAM_TY: number = 0.85;
/** 振幅平滑：起音慢一点不炸，落音要快（实测 0.13 时归零需 0.6-1.0s，超过要求的 0.3s） */
const LEVEL_ATTACK: number = 0.35;
const LEVEL_RELEASE: number = 0.50;
/** 头部律动：振幅 → 点头角度（世界 Z 轴 = 左右轴，绕它转才是俯仰） */
const SPEECH_NOD_DEG: number = 10.0;
const SPEECH_SPINE_DEG: number = 1.5;
const SPEECH_LOG_MS: number = 200;

const RSN_NAMES: string[] = ['unknown', 'greeting', 'tired', 'happy', 'confused'];
const RXN_NAMES: string[] = ['none', 'wave', 'sit', 'nod'];

interface GltfAccessor {
  bufferView: number;
  byteOffset?: number;
  componentType: number;
  count: number;
  type: string;
}
interface GltfBufferView {
  buffer: number;
  byteOffset?: number;
  byteLength: number;
}
interface GltfPrim {
  attributes: Record<string, number>;
}
interface GltfMeshDef {
  primitives: GltfPrim[];
}
interface GltfDoc {
  accessors: GltfAccessor[];
  bufferViews: GltfBufferView[];
  meshes: GltfMeshDef[];
}
interface AccessorView {
  dv: DataView;
  count: number;
}
interface GlbSamples {
  pts: Vec3[];
  nms: Vec3[];
}
/**
 * 一个几何体上的 morph 集合。Nova 的 morph 分散在 3 个 mesh（AvatarHead 66 / AvatarTeethLower 19 /
 * AvatarEyelashes 33），引擎的 Morpher 是"每个 Geometry 各自一个"，所以要按几何体逐个写权重。
 */
interface MorphUnit {
  node: string;
  mp: Morpher;
  keys: string[];
}

interface SwingBone {
  node: Node;
  base: Quaternion;
  ampRad: number;
  phase: number;
  axis: number;
  kind: number;
  lead: boolean;
}
interface PoseBone {
  node: Node;
  /** 骨骼静止姿态（注册时深拷贝），姿态层永远从它起算，绝不从当前旋转起算 */
  base: Quaternion;
  ax: Vec3;
  /** true = 该节点也在 bones 里，每帧已被步态循环复位；false = 只有姿态层驱动它 */
  owned: boolean;
  kind: number;
}
interface AnnulusResult {
  node: Geometry;
  mat: UnlitMaterial;
}
interface ParticleGroup {
  node: Node;
  mat: UnlitMaterial;
  cr: number;
  cg: number;
  cb: number;
  alpha0: number;
  phase: number;
  period: number;
  ampY: number;
  ampZ: number;
  far: boolean;
}

function qcopy(q: Quaternion): Quaternion {
  const r: Quaternion = { x: q.x, y: q.y, z: q.z, w: q.w };
  return r;
}

function quatMul(a: Quaternion, b: Quaternion): Quaternion {
  const r: Quaternion = {
    x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
    y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
    z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
  };
  return r;
}

function quatAxis(ax: number, ay: number, az: number, ang: number): Quaternion {
  const len: number = Math.sqrt(ax * ax + ay * ay + az * az);
  if (len < 1e-9) {
    const id: Quaternion = { x: 0, y: 0, z: 0, w: 1 };
    return id;
  }
  const h: number = ang * 0.5;
  const s: number = Math.sin(h) / len;
  const r: Quaternion = { x: ax * s, y: ay * s, z: az * s, w: Math.cos(h) };
  return r;
}

function quatFromTo(fx: number, fy: number, fz: number, tx: number, ty: number, tz: number): Quaternion {
  const fl: number = Math.sqrt(fx * fx + fy * fy + fz * fz);
  const tl: number = Math.sqrt(tx * tx + ty * ty + tz * tz);
  if (fl < 1e-6 || tl < 1e-6) {
    const id: Quaternion = { x: 0, y: 0, z: 0, w: 1 };
    return id;
  }
  const a: Vec3 = { x: fx / fl, y: fy / fl, z: fz / fl };
  const b: Vec3 = { x: tx / tl, y: ty / tl, z: tz / tl };
  const d: number = a.x * b.x + a.y * b.y + a.z * b.z;
  if (d > 0.999999) {
    const id: Quaternion = { x: 0, y: 0, z: 0, w: 1 };
    return id;
  }
  if (d < -0.999999) {
    return quatAxis(0, 1, 0, Math.PI);
  }
  const cx: number = a.y * b.z - a.z * b.y;
  const cy: number = a.z * b.x - a.x * b.z;
  const cz: number = a.x * b.y - a.y * b.x;
  const w: number = 1 + d;
  const len: number = Math.sqrt(cx * cx + cy * cy + cz * cz + w * w);
  const r: Quaternion = { x: cx / len, y: cy / len, z: cz / len, w: w / len };
  return r;
}

function quatRotVec(q: Quaternion, v: Vec3): Vec3 {
  const tx: number = 2 * (q.y * v.z - q.z * v.y);
  const ty: number = 2 * (q.z * v.x - q.x * v.z);
  const tz: number = 2 * (q.x * v.y - q.y * v.x);
  const r: Vec3 = {
    x: v.x + q.w * tx + (q.y * tz - q.z * ty),
    y: v.y + q.w * ty + (q.z * tx - q.x * tz),
    z: v.z + q.w * tz + (q.x * ty - q.y * tx)
  };
  return r;
}

function quatConj(q: Quaternion): Quaternion {
  const r: Quaternion = { x: -q.x, y: -q.y, z: -q.z, w: q.w };
  return r;
}

function quatNorm(q: Quaternion): Quaternion {
  const l: number = Math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
  if (l < 1e-9) {
    const id: Quaternion = { x: 0, y: 0, z: 0, w: 1 };
    return id;
  }
  const r: Quaternion = { x: q.x / l, y: q.y / l, z: q.z / l, w: q.w / l };
  return r;
}

function smooth(p: number): number {
  const x: number = p < 0 ? 0 : (p > 1 ? 1 : p);
  return x * x * (3 - 2 * x);
}

function easeInOutSine(p: number): number {
  const x: number = p < 0 ? 0 : (p > 1 ? 1 : p);
  return 0.5 - 0.5 * Math.cos(Math.PI * x);
}

function easeOutQuad(p: number): number {
  const x: number = p < 0 ? 0 : (p > 1 ? 1 : p);
  return 1 - (1 - x) * (1 - x);
}

/** 梯形速度曲线：加速-匀速-减速，转身用它就没有"啪一下转完" */
function easeInOutQuad(p: number): number {
  const x: number = p < 0 ? 0 : (p > 1 ? 1 : p);
  if (x < 0.5) {
    return 2 * x * x;
  }
  const y: number = 1 - x;
  return 1 - 2 * y * y;
}

function clamp01(p: number): number {
  return p < 0 ? 0 : (p > 1 ? 1 : p);
}

function f2(n: number): string {
  return n.toFixed(2);
}

function accessorView(buf: ArrayBuffer, doc: GltfDoc, binOff: number, idx: number,
  comps: number): AccessorView | null {
  if (idx < 0 || idx >= doc.accessors.length) {
    return null;
  }
  const acc: GltfAccessor = doc.accessors[idx];
  if (acc.bufferView >= doc.bufferViews.length) {
    return null;
  }
  const bv: GltfBufferView = doc.bufferViews[acc.bufferView];
  const accOff: number = acc.byteOffset === undefined ? 0 : acc.byteOffset;
  const bvOff: number = bv.byteOffset === undefined ? 0 : bv.byteOffset;
  const start: number = binOff + bvOff + accOff;
  const count: number = acc.count;
  const bytes: number = count * comps * 4;
  if (count <= 0 || start + bytes > buf.byteLength) {
    return null;
  }
  const v: AccessorView = { dv: new DataView(buf, start, bytes), count: count };
  return v;
}

/**
 * 引擎没有顶点回读 API，粒子顶点靠自己拆 GLB：
 * 容器 magic 0x46546C67 → JSON 块 + BIN 块 → accessor/bufferView 偏移 → POSITION/NORMAL float32。
 */
function readGlbPoints(buf: ArrayBuffer, target: number): GlbSamples {
  const out: GlbSamples = { pts: [], nms: [] };
  const dv: DataView = new DataView(buf);
  if (dv.byteLength < 20 || dv.getUint32(0, true) !== 0x46546C67) {
    return out;
  }
  let off: number = 12;
  let jsonText: string = '';
  let binOff: number = 0;
  let binLen: number = 0;
  while (off + 8 <= dv.byteLength) {
    const len: number = dv.getUint32(off, true);
    const ctype: number = dv.getUint32(off + 4, true);
    if (off + 8 + len > dv.byteLength) {
      break;
    }
    if (ctype === 0x4E4F534A) {
      const jsonBytes: Uint8Array = new Uint8Array(buf, off + 8, len);
      jsonText = util.TextDecoder.create('utf-8').decodeToString(jsonBytes);
    } else if (ctype === 0x004E4942) {
      binOff = off + 8;
      binLen = len;
    }
    off += 8 + len;
  }
  if (jsonText === '' || binLen === 0) {
    return out;
  }
  const doc: GltfDoc = JSON.parse(jsonText) as GltfDoc;
  if (doc.meshes.length === 0) {
    return out;
  }
  // 遍历全部 mesh：写实版一个 mesh 装 30 万顶点，动漫版拆成 10 个（body 只有 1437 顶点，
  // 大头在 head/outfit 上）。只读 mesh[0] 会让光场点数塌到六分之一。
  const views: AccessorView[] = [];
  const nviews: (AccessorView | null)[] = [];
  let total: number = 0;
  for (let m = 0; m < doc.meshes.length; m++) {
    const mesh: GltfMeshDef = doc.meshes[m];
    if (mesh.primitives === undefined || mesh.primitives.length === 0) {
      continue;
    }
    const prim: GltfPrim = mesh.primitives[0];
    const posIdx: number = prim.attributes['POSITION'] as number;
    const pv: AccessorView | null = accessorView(buf, doc, binOff, posIdx, 3);
    if (pv === null) {
      continue;
    }
    let nv: AccessorView | null = null;
    if (prim.attributes['NORMAL'] !== undefined && prim.attributes['NORMAL'] !== null) {
      nv = accessorView(buf, doc, binOff, prim.attributes['NORMAL'] as number, 3);
    }
    views.push(pv);
    nviews.push(nv);
    total += pv.count;
  }
  if (total === 0) {
    return out;
  }
  const stride: number = Math.max(1, Math.floor(total / target));
  let gi: number = 0;
  for (let v = 0; v < views.length; v++) {
    const pv: AccessorView = views[v];
    const nv: AccessorView | null = nviews[v];
    for (let i = 0; i < pv.count; i++) {
      const take: boolean = (gi % stride) === 0;
      gi++;
      if (!take) {
        continue;
      }
      const b: number = i * 12;
      const p: Vec3 = {
        x: pv.dv.getFloat32(b, true),
        y: pv.dv.getFloat32(b + 4, true),
        z: pv.dv.getFloat32(b + 8, true)
      };
      let n: Vec3 = { x: 0, y: 0, z: 0 };
      if (nv !== null && i < nv.count) {
        const nx: number = nv.dv.getFloat32(b, true);
        const ny: number = nv.dv.getFloat32(b + 4, true);
        const nz: number = nv.dv.getFloat32(b + 8, true);
        const nl: number = Math.sqrt(nx * nx + ny * ny + nz * nz);
        if (nl > 1e-6) {
          n = { x: nx / nl, y: ny / nl, z: nz / nl };
        }
      }
      out.pts.push(p);
      out.nms.push(n);
    }
  }
  return out;
}

/**
 * 全屏 3D 背景：Avatar.glb 站在场景里踱步 + 呼吸 + 外围粒子光场。
 * 模型没有 animations 数据，全部程序化驱动。聊天 UI 由父组件叠在上面。
 *
 * 视觉：人体本体只用原始网格 + 贴图（表面不放粒子），靠材质透明度做半透明全息玻璃；
 * 粒子沿法线外浮 0.075-0.155 倍身高分层散布，是环绕人形的尘埃/光场；
 * 另有线框笼、上方光环、扫描环、地面光晕作为场景装置。
 *
 * 行为四态（WALK / DWELL / SIT / WAVE）：SIT 与 WAVE 是叠加在基础踱步之上的姿态层，
 * 切换期间基础状态机暂停、位移速度按姿态进度衰减，不存在瞬移。
 * 动作推进走固定步长（1/60s）累加，帧率抖动不会让姿态一顿一顿。
 * 页面通过 reactionPing（单个数字）把语义触发的动作塞进来，无需反向调用组件方法。
 * 任何失败都在内部吞掉（只回传文案），不向外抛，保证聊天可用。
 */
@Component
export struct Avatar3D {
  onMsg: (m: string) => void = (_m: string) => {};
  /** seq*100 + kind*10 + reason；数字一变就演一次，避免两个 @Prop 的更新时序问题 */
  @Prop @Watch('onReactionPing') reactionPing: number = 0;
  /** 形象选择：0 写实 Avatar.glb / 1 动漫 nova.glb；一变就整场重建 */
  @Prop @Watch('onKindWatch') modelKind: number = DEFAULT_MODEL_KIND;

  @State private ready: boolean = false;

  private scene: Scene | null = null;
  private cam: Camera | null = null;
  private modelRoot: Node | null = null;
  private baseRot: Quaternion = { x: 0, y: 0, z: 0, w: 1 };
  private baseY: number = 0;
  private baseZ: number = 0;
  private avatarScale: Vec3 = { x: 1, y: 1, z: 1 };
  private rigH: number = 0.87;
  private bones: SwingBone[] = [];
  private posers: PoseBone[] = [];
  private particleGroups: ParticleGroup[] = [];
  private particlePts: number = 0;
  private ringNode: Node | null = null;
  private ringMat: UnlitMaterial | null = null;
  private scanNode: Node | null = null;
  private scanMat: UnlitMaterial | null = null;
  private haloNode: Node | null = null;
  private shellNode: Node | null = null;
  private timer: number = -1;
  private t: number = 0;
  private acc: number = 0;
  private lastMs: number = 0;
  private frame: number = 0;
  private nodeCount: number = 0;
  private rigNote: string = '';
  private tickMs: number = TICK_FAST;
  private tickFails: number = 0;
  private perfAcc: number = 0;
  private perfN: number = 0;
  private glassNote: string = '';

  private state: number = ST_DWELL;
  private stateT: number = 0;
  private dwellDur: number = 0.6;
  private posX: number = 0;
  private targetX: number = 0.45;
  private walkFrom: number = 0;
  private walkTo: number = 0;
  private walkT: number = 1;
  private walkU: number = 0;
  private yaw: number = 0;
  private yawFrom: number = 0;
  private yawTo: number = 0;
  private gaitPhase: number = 0;
  private gaitRate: number = 1;
  private strideAmp: number = 1;
  private gaitAmp: number = 0;
  private leadDelta: number = 0;
  private motion: number = 0;

  /** SIT：0 无 / 1 坐下中 / 2 保持 / 3 起身中 */
  private sitPhase: number = 0;
  private sitAmt: number = 0;
  private sitT: number = 0;
  private sitDur: number = 1.5;
  private sitHold: number = 0;
  private nextSitAt: number = 45;
  /** WAVE：0 无 / 1 抬起 / 2 摆动 / 3 放下 */
  private wavePhase: number = 0;
  private waveAmt: number = 0;
  private waveT: number = 0;
  private waveHold: number = 0;
  private waveOsc: number = 0;
  private pendingWave: boolean = false;
  private nextWaveAt: number = 150;
  /** NOD：点头进度（<0 表示没在点） */
  private nodT: number = -1;
  private nodAmt: number = 0;

  private lastPing: number = 0;
  private glitchUntil: number = 0;
  private glitchNext: number = 0;
  private glitchOff: number = 0;
  private glitchTick: number = 0;
  private glitchCount: number = 0;

  private morphUnits: MorphUnit[] = [];
  private morphNote: string = '';
  private morphWriteOk: boolean = false;
  private shapeStats: string = '';
  private missingNote: string = '';
  private glowNode: Node | null = null;
  /** true = 光团挂在模型根下（跟随人物变换）；false = 退化挂在场景根（自己算位置） */
  private glowAttached: boolean = false;
  private glowMat: UnlitMaterial | null = null;
  private speechHead: Node | null = null;
  private speechHeadAx: Vec3 = { x: 0, y: 0, z: 1 };
  private speechSpine: Node | null = null;
  private speechSpineAx: Vec3 = { x: 0, y: 0, z: 1 };
  private level: number = 0;
  private lastSpeechLog: number = 0;
  private speechFrames: number = 0;
  private mouthWrites: number = 0;
  /** 当前生效的形象（0 写实 / 1 动漫），与 @Prop modelKind 同步 */
  private activeKind: number = DEFAULT_MODEL_KIND;
  private prof: ModelProfile = profileOf(DEFAULT_MODEL_KIND);
  private viseme: VisemeDriver = new VisemeDriver();
  private kindSwitches: number = 0;
  private loading: boolean = false;

  aboutToAppear(): void {
    this.activeKind = this.modelKind;
    this.prof = profileOf(this.activeKind);
    this.doLoad();
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    const sc: Scene | null = this.scene;
    if (sc !== null) {
      try {
        sc.destroy();
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'Avatar3D destroy failed: %{public}s', (e as Error).message);
      }
      this.scene = null;
    }
  }

  build() {
    Stack() {
      if (this.ready) {
        Component3D({ scene: this.sceneArg(), modelType: ModelType.SURFACE })
          .width('100%')
          .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0D0D12')
  }

  private sceneArg(): Scene {
    return this.scene as Scene;
  }

  /** 语义动作入口：页面把 kind/reason 压进一个数字，这里只解析不阻塞 */
  private onReactionPing(): void {
    const v: number = this.reactionPing;
    if (v === this.lastPing || v <= 0) {
      return;
    }
    this.lastPing = v;
    const kind: number = Math.floor(v / 10) % 10;
    const reason: number = v % 10;
    try {
      this.applyReaction(kind, reason);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'Avatar3D reaction failed: %{public}s', (e as Error).message);
    }
  }

  private applyReaction(kind: number, reason: number): void {
    const rName: string = reason >= 0 && reason < RSN_NAMES.length ? RSN_NAMES[reason] : 'unknown';
    const kName: string = kind >= 0 && kind < RXN_NAMES.length ? RXN_NAMES[kind] : 'none';
    hilog.info(LOG_DOMAIN, LOG_TAG, 'avatar reaction apply trigger=%{public}s reason=%{public}s sit=%{public}d wave=%{public}d',
      kName, rName, this.sitPhase, this.wavePhase);
    if (kind === RXN_WAVE) {
      if (this.sitPhase !== 0) {
        this.pendingWave = true;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'avatar reaction wave deferred: stand up first');
        return;
      }
      this.beginWave();
      return;
    }
    if (kind === RXN_SIT) {
      if (this.sitPhase === 0) {
        this.beginSit();
      } else if (this.sitPhase === 2) {
        this.sitHold = SIT_HOLD_MIN + Math.random() * (SIT_HOLD_MAX - SIT_HOLD_MIN);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'avatar reaction sit hold extended');
      }
      return;
    }
    if (kind === RXN_NOD) {
      this.beginNod();
    }
  }

  /** 形象切换：整场重建（先卸 UI、销毁旧场景，再按新配置加载），短暂黑屏可接受 */
  private onKindWatch(): void {
    const k: number = this.modelKind;
    if (k === this.activeKind || this.loading) {
      return;
    }
    this.kindSwitches++;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D kind switch %{public}d -> %{public}d (#%{public}d)',
      this.activeKind, k, this.kindSwitches);
    this.rebuild(k);
  }

  private async rebuild(kind: number): Promise<void> {
    this.loading = true;
    this.ready = false;
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    // 让 Component3D 先卸载，再销毁场景资源：边渲染边销毁在真机上会直接崩
    await new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, 80);
    });
    const old: Scene | null = this.scene;
    this.scene = null;
    if (old !== null) {
      try {
        old.destroy();
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'Avatar3D destroy old scene failed: %{public}s',
          (e as Error).message);
      }
    }
    this.resetModelState();
    this.activeKind = kind;
    this.prof = profileOf(kind);
    this.loading = false;
    await this.doLoad();
  }

  /** 换模型前把所有"指向旧场景对象"的引用清空，否则新模型会被旧骨骼驱动 */
  private resetModelState(): void {
    this.bones = [];
    this.posers = [];
    this.particleGroups = [];
    this.morphUnits = [];
    this.modelRoot = null;
    this.ringNode = null;
    this.ringMat = null;
    this.scanNode = null;
    this.scanMat = null;
    this.haloNode = null;
    this.shellNode = null;
    this.glowNode = null;
    this.glowMat = null;
    this.glowAttached = false;
    this.speechHead = null;
    this.speechSpine = null;
    this.cam = null;
    this.nodeCount = 0;
    this.particlePts = 0;
    this.rigNote = '';
    this.glassNote = '';
    this.morphNote = '';
    this.shapeStats = '';
    this.missingNote = '';
    this.morphWriteOk = false;
    this.mouthWrites = 0;
    this.speechFrames = 0;
    this.level = 0;
    this.viseme.reset();
  }

  private async doLoad(): Promise<void> {
    const tStart: number = Date.now();
    const prof: ModelProfile = this.prof;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D load begin kind=%{public}d rawfile=%{public}s',
      prof.kind, prof.file);
    let sc: Scene | null = null;
    try {
      if (prof.kind === KIND_ANIME) {
        sc = await Scene.load($rawfile('nova.glb'));
      } else {
        sc = await Scene.load($rawfile('Avatar.glb'));
      }
    } catch (e) {
      const err: Error = e as Error;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'Avatar3D Scene.load failed: %{public}s', err.message);
      this.fail('3D 模型加载失败：' + err.message);
      return;
    }
    if (sc === null) {
      this.fail('3D 模型加载返回空场景');
      return;
    }
    try {
      const ok: boolean = await this.setup(sc);
      if (!ok) {
        return;
      }
    } catch (e) {
      const err: Error = e as Error;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'Avatar3D setup failed: %{public}s', err.message);
      this.fail('3D 初始化失败：' + err.message);
      return;
    }
    this.scene = sc;
    this.ready = true;
    this.lastMs = Date.now();
    this.state = ST_DWELL;
    this.stateT = 0;
    this.dwellDur = 0.6;
    this.yawFrom = 0;
    this.yawTo = YAW_AMP;
    this.targetX = 0.45;
    this.nextSitAt = SIT_GAP_MIN + Math.random() * (SIT_GAP_MAX - SIT_GAP_MIN);
    this.nextWaveAt = WAVE_GAP_MIN + Math.random() * (WAVE_GAP_MAX - WAVE_GAP_MIN);
    this.glitchNext = GLITCH_GAP_MIN + Math.random() * (GLITCH_GAP_MAX - GLITCH_GAP_MIN);
    this.scheduleTick();
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'Avatar3D ready kind=%{public}d(%{public}s) file=%{public}s nodes=%{public}d pts=%{public}d rig=%{public}s h=%{public}s glass=%{public}s step=%{public}s tick=%{public}dms cost=%{public}dms mouth=%{public}s map=%{public}s',
      this.prof.kind, this.prof.label, this.prof.file, this.nodeCount, this.particlePts, this.rigNote,
      this.rigH.toFixed(3), this.glassNote, FIXED_DT.toFixed(4), this.tickMs,
      Date.now() - tStart, this.morphNote, this.missingNote);
    this.onMsg('形象·' + this.prof.label + ' · ' + this.rigNote + ' · ' + this.morphNote +
      ' · ' + this.missingNote);
  }

  private fail(msg: string): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'Avatar3D failure: %{public}s', msg);
    try {
      this.onMsg(msg);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'Avatar3D onMsg threw: %{public}s', (e as Error).message);
    }
  }

  private async setup(sc: Scene): Promise<boolean> {
    const root: Node | null = sc.root;
    if (root === null) {
      this.fail('3D 场景为空（root=null）');
      return false;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D scene root=%{public}s anims=%{public}d',
      root.name, sc.animations.length);

    const avatar: Node | null = this.pickAvatar(root);
    if (avatar === null) {
      this.fail('3D 场景里没有可显示的模型节点');
      return false;
    }
    this.modelRoot = avatar;
    this.baseY = avatar.position.y;
    this.baseZ = avatar.position.z;
    this.avatarScale = { x: avatar.scale.x, y: avatar.scale.y, z: avatar.scale.z };
    // 身高归一化：整套装置/机位/粒子外浮都按"身高 1.0"标定。
    // Nova 原生 1.8143，不缩就把圆环压到腰上、把人物怼到镜头前。
    const rawH: number = this.measureHeight(avatar);
    const prof: ModelProfile = this.prof;
    if (prof.normHeight > 0 && rawH > 0.05) {
      const f: number = prof.normHeight / rawH;
      if (Math.abs(f - 1) > 0.01) {
        avatar.scale = { x: this.avatarScale.x * f, y: this.avatarScale.y * f, z: this.avatarScale.z * f };
        this.avatarScale = { x: avatar.scale.x, y: avatar.scale.y, z: avatar.scale.z };
        hilog.info(LOG_DOMAIN, LOG_TAG,
          'Avatar3D normalize kind=%{public}d rawH=%{public}s -> %{public}s factor=%{public}s',
          prof.kind, rawH.toFixed(4), prof.normHeight.toFixed(4), f.toFixed(4));
      }
    }
    // 朝向：动作层全部按"面朝 +X、沿 +X 走"标定。Nova 原生面朝 +Z，要 +90° 偏航；
    // 偏航烘进 baseRot（每帧 rotNow 由 baseRot 乘 yaw 得来），不是每帧叠加。
    const yawFix: Quaternion = quatAxis(0, 1, 0, prof.yawFixDeg * DEG);
    this.baseRot = quatMul(qcopy(avatar.rotation), yawFix);
    this.rigH = prof.normHeight > 0 ? prof.normHeight : rawH;
    this.buildRig(avatar);
    this.glassNote = this.applyGlass(avatar);
    this.findMorpher(avatar);

    const f: SceneResourceFactory = sc.getResourceFactory();

    const env = sc.environment;
    env.backgroundType = EnvironmentBackgroundType.BACKGROUND_NONE;

    const camParams: SceneNodeParameters = { name: 'avatarCam' };
    const cam: Camera = await f.createCamera(camParams);
    const cp: Vec3 = { x: CAM_X, y: CAM_Y, z: CAM_Z };
    cam.position = cp;
    // 朝向：把相机前向 -Z 转到指向躯干中心（与 makeDirLight 同一套 quatFromTo）
    const cr: Quaternion = quatFromTo(0, 0, -1, -CAM_X, CAM_TY - CAM_Y, -CAM_Z);
    cam.rotation = cr;
    cam.fov = 0.75;
    cam.nearPlane = 0.05;
    cam.farPlane = 60;
    const clear: Color = { r: 0.051, g: 0.051, b: 0.071, a: 1 };
    cam.clearColor = clear;
    cam.enabled = true;
    this.cam = cam;
    this.applyPostProcess(cam);

    await this.makeDirLight(f, 'keyLight', 1.0, 2.2, 2.4);
    await this.makeDirLight(f, 'fillLight', -1.6, 1.2, 1.4);
    await this.makeDirLight(f, 'rimLight', 0.2, 2.6, -2.2);

    try {
      await this.buildParticles(f);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'Avatar3D particles failed: %{public}s', (e as Error).message);
    }
    try {
      await this.buildDecor(f);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'Avatar3D decor failed: %{public}s', (e as Error).message);
    }
    try {
      await this.buildMouthGlow(f);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'Avatar3D mouth glow failed: %{public}s', (e as Error).message);
    }
    return true;
  }

  /** 模型包围盒估高度：粒子外浮距离、座位下沉量、装置尺寸都按它缩放 */
  private measureHeight(avatar: Node): number {
    const all: Node[] = [];
    this.collect(avatar, all, 0);
    let mn: number = 1e9;
    let mx: number = -1e9;
    for (let i = 0; i < all.length; i++) {
      const nd: Node = all[i];
      if (nd.nodeType !== NodeType.GEOMETRY) {
        continue;
      }
      const g: Geometry = nd as Geometry;
      try {
        const bb = g.mesh.aabb;
        if (bb !== undefined && bb !== null) {
          if (bb.aabbMin.y < mn) {
            mn = bb.aabbMin.y;
          }
          if (bb.aabbMax.y > mx) {
            mx = bb.aabbMax.y;
          }
        }
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'Avatar3D aabb read failed: %{public}s', (e as Error).message);
      }
    }
    if (mx <= mn || mx - mn < 1e-4) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'Avatar3D aabb invalid min=%{public}s max=%{public}s -> fallback 0.87',
        f2(mn), f2(mx));
      return 0.87;
    }
    const h: number = (mx - mn) * this.avatarScale.y;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D height local=%{public}s..%{public}s world=%{public}s',
      f2(mn), f2(mx), h.toFixed(3));
    return h > 0.05 ? h : 0.87;
  }

  /**
   * 半透明全息玻璃：只改材质参数，不换材质、不克隆模型（克隆 30 万顶点会拖慢也可能爆内存）。
   * RGB 乘一层冷色 = 玻璃色偏；alpha 0.82 + 开混合 = 本体半透明，能透出背景与外围粒子。
   * 引擎没有 fresnel / 自定义着色器通道，边缘光做不出来（见交付说明）。
   */
  private applyGlass(avatar: Node): string {
    const all: Node[] = [];
    this.collect(avatar, all, 0);
    const seen: Record<string, boolean> = {};
    let tinted: number = 0;
    for (let i = 0; i < all.length; i++) {
      const nd: Node = all[i];
      if (nd.nodeType !== NodeType.GEOMETRY) {
        continue;
      }
      const g: Geometry = nd as Geometry;
      const subs = g.mesh.subMeshes;
      if (subs === undefined || subs === null) {
        continue;
      }
      for (let k = 0; k < subs.length; k++) {
        const m: Material = subs[k].material;
        if (m === undefined || m === null) {
          continue;
        }
        const key: string = m.name === undefined ? ('mat' + k) : m.name;
        if (seen[key] === true) {
          continue;
        }
        seen[key] = true;
        if (m.materialType !== MaterialType.METALLIC_ROUGHNESS) {
          continue;
        }
        try {
          const mr: MetallicRoughnessMaterial = m as MetallicRoughnessMaterial;
          const f0: Vec4 = mr.baseColor.factor;
          const tint: Vec4 = {
            x: f0.x * 0.76,
            y: f0.y * 0.90,
            z: f0.z * 1.00,
            w: 1.00
          };
          mr.baseColor.factor = tint;
          // 半透明会让脸部内部（后脑皮肤、头发内侧、衣领）透出来，在脸颊/额头形成
          // 不规则青色碎块（用户报的"碎瓷裂纹"）。不透明只保留冷色调，脸就干净了。
          const bl: Blend = { enabled: false };
          m.blend = bl;
          tinted++;
          hilog.info(LOG_DOMAIN, LOG_TAG,
            'Avatar3D glass mat=%{public}s type=%{public}d rgba=%{public}s/%{public}s/%{public}s/%{public}s',
            key, m.materialType, f2(tint.x), f2(tint.y), f2(tint.z), f2(tint.w));
        } catch (e) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'Avatar3D glass skip %{public}s: %{public}s', key,
            (e as Error).message);
        }
      }
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D glass mats=%{public}d', tinted);
    return '玻璃' + tinted + ' alpha1.00';
  }

  /** Bloom 只给亮部一点点扩散：阈值高、扩散低，宁可暗不刺眼 */
  private applyPostProcess(cam: Camera): void {
    try {
      const bloom: BloomSettings = {
        thresholdHard: 0.92,
        thresholdSoft: 0.86,
        scaleFactor: 0.35,
        scatter: 0.55
      };
      const pp: PostProcessSettings = {
        toneMapping: { type: ToneMappingType.ACES, exposure: 1.0 },
        bloom: bloom
      };
      cam.postProcess = pp;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D postprocess bloom=on hard=0.92 soft=0.86 scale=0.35');
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'Avatar3D bloom unsupported: %{public}s', (e as Error).message);
    }
  }

  private makeUnlit(f: SceneResourceFactory, name: string, r: number, g: number, b: number,
    a: number, line: boolean): Promise<UnlitMaterial> {
    const matP: SceneResourceParameters = { name: name };
    return f.createMaterial(matP, MaterialType.UNLIT).then((mat: Material) => {
      const u: UnlitMaterial = mat as UnlitMaterial;
      const fac: Vec4 = { x: r, y: g, z: b, w: a };
      u.baseColor.factor = fac;
      const bl: Blend = { enabled: true };
      u.blend = bl;
      u.cullMode = CullMode.NONE;
      if (line) {
        u.polygonMode = PolygonMode.LINE;
      }
      return u;
    });
  }

  /**
   * 外围粒子：沿法线外浮 0.075-0.155 倍身高，分近层（60%，5 组）/远层（40%，3 组），
   * 再叠 ±0.012 倍身高的三维抖动，人体表面不留点。远层点数更多但球面更大，所以越靠外越稀。
   */
  private async buildParticles(f: SceneResourceFactory): Promise<void> {
    const t0: number = Date.now();
    const ctx = getContext(this) as common.UIAbilityContext;
    const bytes: Uint8Array = await ctx.resourceManager.getRawFileContent(this.prof.file);
    const sample: GlbSamples = readGlbPoints(bytes.buffer as ArrayBuffer, PARTICLE_TARGET);
    this.foldTPoseArms(sample.pts, sample.nms);
    const pts: Vec3[] = sample.pts;
    if (pts.length === 0) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'Avatar3D particles: sample empty');
      return;
    }
    this.particlePts = pts.length;
    const h: number = this.rigH;

    const nearVerts: Vec3[][] = [];
    const nearIdx: number[][] = [];
    for (let i = 0; i < NEAR_GROUPS; i++) {
      nearVerts.push([]);
      nearIdx.push([]);
    }
    const farVerts: Vec3[][] = [];
    const farIdx: number[][] = [];
    for (let i = 0; i < FAR_GROUPS; i++) {
      farVerts.push([]);
      farIdx.push([]);
    }

    let nearN: number = 0;
    let farN: number = 0;
    for (let i = 0; i < pts.length; i++) {
      const p: Vec3 = pts[i];
      const n: Vec3 = sample.nms[i];
      const isNear: boolean = (i % 20) < 12;
      const out: number = isNear
        ? h * (NEAR_OUT_MIN + Math.random() * (NEAR_OUT_MAX - NEAR_OUT_MIN))
        : h * (FAR_OUT_MIN + Math.random() * (FAR_OUT_MAX - FAR_OUT_MIN));
      const jx: number = (Math.random() * 2 - 1) * PART_JITTER * h;
      const jy: number = (Math.random() * 2 - 1) * PART_JITTER * h;
      const jz: number = (Math.random() * 2 - 1) * PART_JITTER * h;
      const px: number = p.x + n.x * out + jx;
      const py: number = p.y + n.y * out * 0.9 + jy;
      const pz: number = p.z + n.z * out + jz;
      if (isNear) {
        const gi: number = i % NEAR_GROUPS;
        this.pushOcta(nearVerts[gi], nearIdx[gi], px, py, pz, PART_SIZE);
        nearN++;
      } else {
        const gi: number = i % FAR_GROUPS;
        this.pushOcta(farVerts[gi], farIdx[gi], px, py, pz, PART_SIZE * 0.85);
        farN++;
      }
    }

    let vertsTotal: number = 0;
    for (let g = 0; g < NEAR_GROUPS; g++) {
      if (nearVerts[g].length === 0) {
        continue;
      }
      const mat: UnlitMaterial = await this.makeUnlit(f, 'pMatNear' + g, 0.45, 0.92, 1.00, 0.62, false);
      const node: Node = await this.makeParticleNode(f, 'pNear' + g, nearVerts[g], nearIdx[g], mat);
      this.particleGroups.push(this.newGroup(node, mat, 0.45, 0.92, 1.00, 0.62, 4.0, 8.0, false));
      vertsTotal += nearVerts[g].length;
    }
    for (let g = 0; g < FAR_GROUPS; g++) {
      if (farVerts[g].length === 0) {
        continue;
      }
      const mat: UnlitMaterial = await this.makeUnlit(f, 'pMatFar' + g, 0.38, 0.80, 1.00, 0.34, false);
      const node: Node = await this.makeParticleNode(f, 'pFar' + g, farVerts[g], farIdx[g], mat);
      this.particleGroups.push(this.newGroup(node, mat, 0.38, 0.80, 1.00, 0.40, 6.0, 10.0, true));
      vertsTotal += farVerts[g].length;
    }

    hilog.info(LOG_DOMAIN, LOG_TAG,
      'Avatar3D particles ok pts=%{public}d near=%{public}d far=%{public}d groups=%{public}d verts=%{public}d nearOut=%{public}s-%{public}s farOut=%{public}s-%{public}s size=%{public}dmm jitter=%{public}s blend=on',
      pts.length, nearN, farN, this.particleGroups.length, vertsTotal,
      (h * NEAR_OUT_MIN).toFixed(3), (h * NEAR_OUT_MAX).toFixed(3),
      (h * FAR_OUT_MIN).toFixed(3), (h * FAR_OUT_MAX).toFixed(3),
      Math.round(PART_SIZE * 1000), (h * PART_JITTER).toFixed(3), Date.now() - t0);
  }

  private newGroup(node: Node, mat: UnlitMaterial, r: number, g: number, b: number, a: number,
    pMin: number, pMax: number, far: boolean): ParticleGroup {
    const grp: ParticleGroup = {
      node: node,
      mat: mat,
      cr: r,
      cg: g,
      cb: b,
      alpha0: a,
      phase: Math.random() * 6.283,
      period: pMin + Math.random() * (pMax - pMin),
      ampY: 0.0022 + Math.random() * 0.0008,
      ampZ: 0.0012 + Math.random() * 0.0008,
      far: far
    };
    return grp;
  }

  /** 6 顶点八面体：引擎只有三角面拓扑，点云的"点"只能这样拼 */
  private pushOcta(verts: Vec3[], idx: number[], px: number, py: number, pz: number, hh: number): void {
    const b: number = verts.length;
    verts.push({ x: px + hh, y: py, z: pz });
    verts.push({ x: px - hh, y: py, z: pz });
    verts.push({ x: px, y: py + hh, z: pz });
    verts.push({ x: px, y: py - hh, z: pz });
    verts.push({ x: px, y: py, z: pz + hh });
    verts.push({ x: px, y: py, z: pz - hh });
    idx.push(b + 0, b + 2, b + 4, b + 2, b + 1, b + 4, b + 1, b + 3, b + 4, b + 3, b + 0, b + 4);
    idx.push(b + 2, b + 0, b + 5, b + 1, b + 2, b + 5, b + 3, b + 1, b + 5, b + 0, b + 3, b + 5);
  }

  private async makeParticleNode(f: SceneResourceFactory, name: string, verts: Vec3[],
    idx: number[], mat: UnlitMaterial): Promise<Node> {
    const cg: CustomGeometry = new CustomGeometry();
    cg.vertices = verts;
    cg.indices = idx;
    const mp: SceneResourceParameters = { name: name + 'Mesh' };
    const geoDef: GeometryDefinition = cg;
    const mr: MeshResource = await f.createMesh(mp, geoDef);
    const np: SceneNodeParameters = { name: name };
    const geo: Geometry = await f.createGeometry(np, mr);
    geo.mesh.materialOverride = mat;
    geo.scale = this.avatarScale;
    return geo;
  }

  /** 环形圆盘（内径-外径）自定义网格：光环 / 扫描环 / 地面光晕共用 */
  private async makeAnnulus(f: SceneResourceFactory, name: string, rIn: number, rOut: number,
    r: number, g: number, b: number, a: number): Promise<AnnulusResult> {
    const verts: Vec3[] = [];
    const idx: number[] = [];
    for (let k = 0; k <= RING_SEG; k++) {
      const ang: number = 2 * Math.PI * k / RING_SEG;
      const ca: number = Math.cos(ang);
      const sa: number = Math.sin(ang);
      verts.push({ x: ca * rIn, y: 0, z: sa * rIn });
      verts.push({ x: ca * rOut, y: 0, z: sa * rOut });
    }
    for (let k = 0; k < RING_SEG; k++) {
      const bb: number = k * 2;
      idx.push(bb, bb + 1, bb + 2, bb + 1, bb + 3, bb + 2);
    }
    const mat: UnlitMaterial = await this.makeUnlit(f, name + 'Mat', r, g, b, a, false);
    const cg: CustomGeometry = new CustomGeometry();
    cg.vertices = verts;
    cg.indices = idx;
    const mp: SceneResourceParameters = { name: name + 'Mesh' };
    const geoDef: GeometryDefinition = cg;
    const mr: MeshResource = await f.createMesh(mp, geoDef);
    const np: SceneNodeParameters = { name: name };
    const geo: Geometry = await f.createGeometry(np, mr);
    geo.mesh.materialOverride = mat;
    geo.scale = { x: 1, y: 1, z: 1 };
    const res: AnnulusResult = { node: geo, mat: mat };
    return res;
  }

/** 世界轴 → 骨骼局部轴（与 addPoser 同一套换算，姿态层叠乘才不打架） */
  private localAxis(nd: Node, wx: number, wy: number, wz: number): Vec3 {
    const inv: Quaternion = quatConj(this.restWorldQuat(nd));
    const a: Vec3 = quatRotVec(inv, { x: wx, y: wy, z: wz });
    const nn: Quaternion = quatNorm({ x: a.x, y: a.y, z: a.z, w: 0 });
    const r: Vec3 = { x: nn.x, y: nn.y, z: nn.z };
    return r;
  }

  /**
   * 找带 morph target 的几何节点，并对 Morpher.targets 做一次读写探测。
   * d.ts 里 targets 是 readonly 属性，但 readonly 只锁引用、不锁 Record 键值：
   * 真机探测的结果决定口型走 morph 还是只能退回纯光效。
   */
  private findMorpher(root: Node): void {
    const all: Node[] = [];
    this.collect(root, all, 0);
    this.morphUnits = [];
    const probeKey: string = this.prof.jawShapes[0];
    for (let i = 0; i < all.length; i++) {
      const nd: Node = all[i];
      if (nd.nodeType !== NodeType.GEOMETRY) {
        continue;
      }
      const g: Geometry = nd as Geometry;
      let subs: number = -1;
      let y0: string = 'n/a';
      let y1: string = 'n/a';
      try {
        subs = g.mesh.subMeshes.length;
        const bb = g.mesh.aabb;
        if (bb !== undefined && bb !== null) {
          y0 = bb.aabbMin.y.toFixed(4);
          y1 = bb.aabbMax.y.toFixed(4);
        }
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'Avatar3D mesh probe failed: %{public}s', (e as Error).message);
      }
      let mp: Morpher | undefined = undefined;
      try {
        mp = g.morpher;
      } catch (e) {
        mp = undefined;
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'Avatar3D morpher read failed: %{public}s', (e as Error).message);
      }
      let keys: string = 'none';
      if (mp !== undefined && mp !== null) {
        try {
          const t: Record<string, number> = mp.targets;
          if (t !== undefined && t !== null) {
            const ks: string[] = Object.keys(t);
            keys = ks.length === 0 ? 'empty' : ks.join('|');
            if (ks.length > 0) {
              this.morphUnits.push({ node: nd.name, mp: mp, keys: ks });
            }
            // 写后立刻回读：readonly 只锁引用不锁键值，能不能真写必须实测
            if (ks.indexOf(probeKey) >= 0) {
              let probe: string = '';
              try {
                t[probeKey] = 0.5;
                const b1: number = t[probeKey];
                this.morphWriteOk = Math.abs(b1 - 0.5) < 0.001;
                probe = b1.toFixed(3);
                t[probeKey] = 0;
              } catch (e) {
                this.morphWriteOk = false;
                probe = 'throw:' + (e as Error).message;
              }
              hilog.info(LOG_DOMAIN, LOG_TAG,
                'Avatar3D morpher write probe node=%{public}s key=%{public}s wrote=0.50 readBack=%{public}s ok=%{public}d',
                nd.name, probeKey, probe, this.morphWriteOk ? 1 : 0);
            }
          }
        } catch (e) {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'Avatar3D morpher targets failed: %{public}s',
            (e as Error).message);
        }
      }
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'Avatar3D geom node=%{public}s aabbY=[%{public}s..%{public}s] subs=%{public}d morph=%{public}s',
        nd.name, y0, y1, subs, keys);
    }
    if (this.morphUnits.length === 0) {
      this.morphNote = 'morph[无]';
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'Avatar3D no morpher in scene: 口型退回纯光效');
      return;
    }
    // 逐个口型 shape 统计"有几个几何体带它"：Nova 的 jawOpen 应在 2 个体上，
    // 只有 1 个说明牙齿那层没被驱动，嘴会张开但牙不动
    const names: string[] = this.prof.jawShapes.concat(this.prof.vowelShapes)
      .concat(this.prof.silShapes);
    let stat: string = '';
    for (let i = 0; i < names.length; i++) {
      let n: number = 0;
      for (let u = 0; u < this.morphUnits.length; u++) {
        if (this.morphUnits[u].keys.indexOf(names[i]) >= 0) {
          n++;
        }
      }
      stat = stat + (stat === '' ? '' : ' ') + names[i] + ':' + n;
    }
    this.shapeStats = stat;
    this.morphNote = 'morph[' + this.morphUnits.length + '体' +
      (this.morphWriteOk ? '可写' : '只读') + ' ' + stat + ']';
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D morph shapes %{public}s units=%{public}d writeOk=%{public}d',
      stat, this.morphUnits.length, this.morphWriteOk ? 1 : 0);
  }

  /**
   * 写一个 shape 到所有带它的几何体，重复调用不会累加（targets 是绝对值）。
   * 返回实际写入的几何体数，用于日志核对。
   */
  private writeShape(name: string, w: number): number {
    let n: number = 0;
    for (let i = 0; i < this.morphUnits.length; i++) {
      const u: MorphUnit = this.morphUnits[i];
      if (u.keys.indexOf(name) < 0) {
        continue;
      }
      try {
        u.mp.targets[name] = w;
        n++;
      } catch (e) {
        if (this.mouthWrites === 0) {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'Avatar3D morph write %{public}s failed: %{public}s',
            name, (e as Error).message);
        }
      }
    }
    return n;
  }

  /** 回读：取第一个带该 shape 的几何体的当前权重，日志用 */
  private readShape(name: string): string {
    for (let i = 0; i < this.morphUnits.length; i++) {
      const u: MorphUnit = this.morphUnits[i];
      if (u.keys.indexOf(name) < 0) {
        continue;
      }
      try {
        const v: number = u.mp.targets[name];
        return v.toFixed(2);
      } catch (e) {
        return 'err';
      }
    }
    return 'na';
  }

  /**
   * 嘴部光团：两个八面体拼的小发光体（引擎没有点云，三角面拼），
   * 顶点直接写在嘴部模型坐标上，节点 position/scale/rotation 跟着人物根走，
   * 于是常驻但极暗，说话时放大提亮。
   */
  private async buildMouthGlow(f: SceneResourceFactory): Promise<void> {
    const verts: Vec3[] = [];
    const idx: number[] = [];
    // 八面体画在原点，嘴部位置交给节点 position：这样说话时放大光团只会变大，
    // 不会因为顶点自带偏移而被"推"离嘴部
    this.pushOcta(verts, idx, 0, 0, 0, GLOW_R);
    this.pushOcta(verts, idx, 0, 0, 0, GLOW_R * 1.9);
    const mat: UnlitMaterial = await this.makeUnlit(f, 'mouthGlowMat', 0.42, 0.93, 1.00,
      GLOW_A_MIN, false);
    const cg: CustomGeometry = new CustomGeometry();
    cg.vertices = verts;
    cg.indices = idx;
    const mp: SceneResourceParameters = { name: 'mouthGlowMesh' };
    const geoDef: GeometryDefinition = cg;
    const mr: MeshResource = await f.createMesh(mp, geoDef);
    const np: SceneNodeParameters = { name: 'mouthGlowNode' };
    const geo: Geometry = await f.createGeometry(np, mr);
    geo.mesh.materialOverride = mat;
    // 原来光团直接挂在场景根上、用绝对坐标拼嘴部位置：它和模型自身的变换链不同源，
    // 真机实测飘在头顶上方约 0.4 个身位（根本不在嘴上）。改成模型根的子节点后，
    // 顶点就是模型坐标，比例/朝向/下蹲全部自动跟随。
    let attached: boolean = false;
    const root: Node | null = this.modelRoot;
    if (root !== null) {
      try {
        const p: Node | null = geo.parent;
        if (p !== null) {
          p.children.remove(geo);
        }
        root.children.append(geo);
        const mp0: RawVec3 = this.prof.mouth;
        geo.position = { x: mp0.x, y: mp0.y + GLOW_DY, z: mp0.z };
        geo.rotation = { x: 0, y: 0, z: 0, w: 1 };
        geo.scale = { x: 1, y: 1, z: 1 };
        attached = true;
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'Avatar3D glow reparent failed: %{public}s',
          (e as Error).message);
      }
    }
    if (!attached) {
      const mp1: RawVec3 = this.prof.mouth;
      geo.position = {
        x: this.posX, y: this.baseY + (mp1.y + GLOW_DY) * this.avatarScale.y, z: this.baseZ
      };
      geo.scale = this.avatarScale;
    }
    this.glowNode = geo;
    this.glowAttached = attached;
    this.glowMat = mat;
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'Avatar3D mouth glow ok attached=%{public}s x=%{public}s y=%{public}s z=%{public}s r=%{public}s alpha0=%{public}s',
      attached ? 'model' : 'scene', this.prof.mouth.x.toFixed(3), this.prof.mouth.y.toFixed(4),
      this.prof.mouth.z.toFixed(3), GLOW_R.toFixed(3), GLOW_A_MIN.toFixed(2));
  }

  /**
   * 振幅 → morph 权重。原始映射 weight=lv 时，实际张口峰值只有 21mm，
   * 在正常观看距离（脸 30-40px）下只有 6-13px，肉眼看不出。
   * 幂次压中段 + 线性增益，让"说中音"就明显张嘴；上限硬顶 1.0 防止过度拉扯。
   */
  private mouthWeight(lv: number): number {
    if (lv <= 0.002) {
      return 0;
    }
    const w: number = Math.pow(lv, 0.70) * MOUTH_GAIN;
    return w > 1 ? 1 : w;
  }

  /**
   * 赛博口型帧更新：读 TTS 实时振幅 → 平滑 → 驱动 (1) morph 权重 (2) 光团尺寸/亮度
   * (3) 头部俯仰律动。三件事都包在 try/catch 里，任何一项坏掉不影响另外两项和聊天。
   */
  private speechStep(rootX: number, basePosY: number, rotNow: Quaternion): void {
    let target: number = SpeechLevel.value;
    if (!(target > 0)) {
      target = 0;
    }
    if (target > 1) {
      target = 1;
    }
    const k: number = target > this.level ? LEVEL_ATTACK : LEVEL_RELEASE;
    this.level = this.level + (target - this.level) * k;
    if (this.level < 0.002) {
      this.level = 0;
    }
    const lv: number = this.level;
    this.speechFrames++;

    // 口型：jawOpen 吃振幅做主驱动，aa/ih/oh/ou 按音节轮换，静音时 sil=1 其余归零。
    // Nova 的这 6 个 shape 分布在 AvatarHead 与 AvatarTeethLower 两层，writeShape 会同时写，
    // 只写一层会出现"嘴唇张了牙没动"。
    const prof: ModelProfile = this.prof;
    const jaw: number = this.mouthWeight(lv);
    const vw: VisemeWeights = this.viseme.update(lv, jaw, Date.now(), prof);
    let vwBody: number = 0;
    const jawWrote: number = this.writeShape(prof.jawShapes[0], vw.jaw);
    if (jawWrote > 0) {
      this.mouthWrites++;
    }
    for (let i = 0; i < prof.vowelShapes.length; i++) {
      const wn: string = prof.vowelShapes[i];
      const ww: number = i === 0 ? vw.aa : (i === 1 ? vw.ih : (i === 2 ? vw.oh : vw.ou));
      if (this.writeShape(wn, ww) > 0) {
        vwBody++;
      }
    }
    for (let i = 0; i < prof.silShapes.length; i++) {
      this.writeShape(prof.silShapes[i], vw.sil);
    }

    const gn: Node | null = this.glowNode;
    if (gn !== null) {
      const gs: number = 1 + (GLOW_SCALE_MAX - 1) * lv;
      if (this.glowAttached) {
        // 已是模型子节点：位置/朝向由父链接管，这里只做发声时的体积脉动
        gn.scale = { x: gs, y: gs, z: gs };
      } else {
        gn.position = { x: rootX, y: basePosY, z: this.baseZ };
        gn.rotation = rotNow;
        gn.scale = { x: this.avatarScale.x * gs, y: this.avatarScale.y * gs, z: this.avatarScale.z * gs };
      }
      const gm: UnlitMaterial | null = this.glowMat;
      if (gm !== null) {
        const aMax: number = GLOW_A_MAX * this.prof.glowAlphaScale;
        gm.baseColor.factor = { x: 0.42, y: 0.93, z: 1.00, w: GLOW_A_MIN + (aMax - GLOW_A_MIN) * lv };
      }
    }

    const hd: Node | null = this.speechHead;
    if (hd !== null && lv > 0.002) {
      const ax: Vec3 = this.speechHeadAx;
      // 绕世界 Z（左右轴）转负角 = 低头；再叠上半点脊柱起伏
      const qh: Quaternion = quatAxis(ax.x, ax.y, ax.z, -SPEECH_NOD_DEG * DEG * lv);
      hd.rotation = quatMul(qcopy(hd.rotation), qh);
    }
    const sp: Node | null = this.speechSpine;
    if (sp !== null && lv > 0.002) {
      const ax: Vec3 = this.speechSpineAx;
      const qs: Quaternion = quatAxis(ax.x, ax.y, ax.z, -SPEECH_SPINE_DEG * DEG * lv);
      sp.rotation = quatMul(qcopy(sp.rotation), qs);
    }

    const now: number = Date.now();
    if (now - this.lastSpeechLog >= SPEECH_LOG_MS) {
      this.lastSpeechLog = now;
      // 每组权重都回读：写进去和真的生效是两件事
      const rbJaw: string = this.readShape(prof.jawShapes[0]);
      const rbAa: string = prof.vowelShapes.length > 0 ? this.readShape(prof.vowelShapes[0]) : 'na';
      const rbSil: string = prof.silShapes.length > 0 ? this.readShape(prof.silShapes[0]) : 'na';
      const aMax: number = GLOW_A_MAX * prof.glowAlphaScale;
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'avatar viseme kind=%{public}d lv=%{public}s jaw=%{public}s rb=%{public}s aa=%{public}s rb=%{public}s sil=%{public}s rb=%{public}s units=%{public}d vowelUnit=%{public}d glow=%{public}s writes=%{public}d pitch=%{public}sdeg',
        prof.kind, lv.toFixed(2), vw.jaw.toFixed(2), rbJaw, vw.aa.toFixed(2), rbAa,
        vw.sil.toFixed(2), rbSil, this.morphUnits.length, vwBody,
        (GLOW_A_MIN + (aMax - GLOW_A_MIN) * lv).toFixed(2), this.mouthWrites,
        (SPEECH_NOD_DEG * lv).toFixed(2));
    }
  }

  /** 场景装置：上方发光圆环 + 线框笼 + 扫描环 + 地面光晕（都不在人物身上） */
  private async buildDecor(f: SceneResourceFactory): Promise<void> {
    const h: number = this.rigH;

    const ringR: AnnulusResult = await this.makeAnnulus(f, 'ringNode', RING_R_IN * h, RING_R_OUT * h,
      0.72, 0.95, 1.00, 0.52);
    ringR.node.position = { x: this.posX, y: this.baseY + h * 1.10, z: this.baseZ };
    this.ringNode = ringR.node;
    this.ringMat = ringR.mat;

    const scanR: AnnulusResult = await this.makeAnnulus(f, 'scanNode', SCAN_R_IN * h, SCAN_R_OUT * h,
      0.55, 0.85, 1.00, 0.20);
    scanR.node.position = { x: this.posX, y: this.baseY + h * 0.5, z: this.baseZ };
    this.scanNode = scanR.node;
    this.scanMat = scanR.mat;

    const haloR: AnnulusResult = await this.makeAnnulus(f, 'haloNode', HALO_R_IN * h, HALO_R_OUT * h,
      0.42, 0.72, 1.00, 0.16);
    haloR.node.position = { x: this.posX, y: this.baseY + 0.002, z: this.baseZ };
    this.haloNode = haloR.node;

    const cyl: CylinderGeometry = new CylinderGeometry();
    cyl.radius = SHELL_R * h;
    cyl.height = SHELL_H * h;
    cyl.segmentCount = 12;
    // 不透明度 0.13 → 0.05：退成背景氛围，即使某条线扫过脸也不抢形变
    const shellMat: UnlitMaterial = await this.makeUnlit(f, 'shellMat', 0.30, 0.62, 0.92, 0.05, true);
    const smp: SceneResourceParameters = { name: 'shellMesh' };
    const smr: MeshResource = await f.createMesh(smp, cyl);
    const snp: SceneNodeParameters = { name: 'shellNode' };
    const shell: Geometry = await f.createGeometry(snp, smr);
    shell.mesh.materialOverride = shellMat;
    shell.position = { x: this.posX, y: this.baseY + h * 0.5, z: this.baseZ };
    this.shellNode = shell;

    hilog.info(LOG_DOMAIN, LOG_TAG,
      'Avatar3D decor ok ring=%{public}s/%{public}s y=%{public}s scan=%{public}s halo=%{public}s shell r=%{public}s h=%{public}s',
      f2(RING_R_IN * h), f2(RING_R_OUT * h), f2(this.baseY + h * 1.10),
      f2(SCAN_R_OUT * h), f2(HALO_R_OUT * h), f2(SHELL_R * h), f2(SHELL_H * h));
  }

  private async makeDirLight(f: SceneResourceFactory, name: string,
    dx: number, dy: number, dz: number): Promise<void> {
    const p: SceneNodeParameters = { name: name };
    const li: Light = await f.createLight(p, LightType.DIRECTIONAL);
    const len: number = Math.sqrt(dx * dx + dy * dy + dz * dz);
    const rot: Quaternion = quatFromTo(0, 0, -1, -dx / len, -dy / len, -dz / len);
    li.rotation = rot;
    const pos: Vec3 = { x: dx, y: dy, z: dz };
    li.position = pos;
    const col: Color = { r: 1, g: 1, b: 1, a: 1 };
    li.color = col;
    li.intensity = 1.4;
    li.shadowEnabled = false;
    li.enabled = true;
  }

  private pickAvatar(root: Node): Node | null {
    const ch: Container<Node> = root.children;
    const n: number = ch.count();
    for (let i = 0; i < n; i++) {
      const c: Node | null = ch.get(i);
      if (c !== null && this.hasGeometry(c, 0)) {
        return c;
      }
    }
    if (n > 0) {
      return ch.get(0);
    }
    return null;
  }

  private hasGeometry(node: Node, depth: number): boolean {
    if (node.nodeType === NodeType.GEOMETRY) {
      return true;
    }
    if (depth >= 8) {
      return false;
    }
    const ch: Container<Node> = node.children;
    const n: number = ch.count();
    for (let i = 0; i < n; i++) {
      const c: Node | null = ch.get(i);
      if (c !== null && this.hasGeometry(c, depth + 1)) {
        return true;
      }
    }
    return false;
  }

  private collect(node: Node, out: Node[], depth: number): void {
    out.push(node);
    if (depth >= 16) {
      return;
    }
    const ch: Container<Node> = node.children;
    const n: number = ch.count();
    for (let i = 0; i < n; i++) {
      const c: Node | null = ch.get(i);
      if (c !== null) {
        this.collect(c, out, depth + 1);
      }
    }
  }

  /**
   * T-pose → A-pose：把平举的大臂掰到自然下垂。
   * 必须在 addBone / addPoser 之前改节点：那两处的 base 是 qcopy 深拷贝，
   * 改在这里它们自然就以新姿态为基准，之后每帧"从 base 起算"的规矩不用破。
   */
  private applyArmDown(nd: Node, isLeft: boolean): void {
    const deg: number = this.prof.armDownDeg;
    if (deg <= 0.01) {
      return;
    }
    const ax: Vec3 = this.localAxis(nd, 1, 0, 0);
    const ang: number = (isLeft ? -deg : deg) * DEG;
    const q: Quaternion = quatAxis(ax.x, ax.y, ax.z, ang);
    nd.rotation = quatMul(qcopy(nd.rotation), q);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D armdown node=%{public}s deg=%{public}s left=%{public}d',
      nd.name, (isLeft ? -deg : deg).toFixed(1), isLeft ? 1 : 0);
  }

  /**
   * 粒子云是从 bind pose 顶点采出来的静态点，不跟骨骼蒙皮走。
   * 大臂改成下垂后，必须把手臂区（|x| > 肩宽）的点按同一个角度绕肩关节折下来，
   * 否则人物手臂已放下、粉尘还是横向一条 T 形。
   */
  private foldTPoseArms(pts: Vec3[], nms: Vec3[]): void {
    const prof: ModelProfile = this.prof;
    if (prof.armDownDeg <= 0) {
      return;
    }
    const sw: number = prof.tposeShoulderX;
    const shy: number = prof.tposeShoulderY;
    const a: number = prof.armDownDeg * DEG;
    const ca: number = Math.cos(a);
    const sa: number = Math.sin(a);
    let folded: number = 0;
    for (let i = 0; i < pts.length; i++) {
      const p: Vec3 = pts[i];
      const ax: number = Math.abs(p.x);
      if (ax <= sw || p.y < shy - 0.12) {
        continue;
      }
      const sign: number = p.x >= 0 ? 1 : -1;
      const dx: number = ax - sw;
      const dy: number = p.y - shy;
      p.x = sign * (sw + dx * ca + dy * sa);
      p.y = shy - dx * sa + dy * ca;
      if (i < nms.length) {
        const n: Vec3 = nms[i];
        const nxs: number = n.x * sign;
        const nys: number = n.y;
        n.x = (nxs * ca + nys * sa) * sign;
        n.y = -nxs * sa + nys * ca;
      }
      folded++;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D particle arm fold pts=%{public}d folded=%{public}d deg=%{public}s',
      pts.length, folded, prof.armDownDeg.toFixed(0));
  }

  private addBone(nd: Node, amp: number, phase: number, axis: number, kind: number,
    lead: boolean): void {
    const b: SwingBone = {
      node: nd, base: qcopy(nd.rotation), ampRad: amp, phase: phase, axis: axis, kind: kind, lead: lead
    };
    this.bones.push(b);
  }

  /**
   * 骨骼静止姿态的"世界朝向"：把从 modelRoot 到该骨骼的父链旋转乘起来。
   * 姿态驱动给的是世界轴（前=+X 上=+Y 侧=+Z），必须换算成骨骼局部轴：
   * q_local = conj(R) * W * R，等价于把世界轴转到局部轴再绕它旋转。
   */
  private restWorldQuat(nd: Node): Quaternion {
    const chain: Node[] = [];
    let cur: Node | null = nd;
    let guard: number = 0;
    while (cur !== null && guard < 40) {
      chain.push(cur);
      const p: Node | null = cur.parent;
      if (p === null || p === this.modelRoot) {
        break;
      }
      cur = p;
      guard++;
    }
    let q: Quaternion = { x: 0, y: 0, z: 0, w: 1 };
    for (let i = chain.length - 1; i >= 0; i--) {
      const r: Quaternion = chain[i].rotation;
      const cp: Quaternion = { x: r.x, y: r.y, z: r.z, w: r.w };
      q = quatMul(q, cp);
    }
    return quatNorm(q);
  }

  private addPoser(nd: Node, wx: number, wy: number, wz: number, kind: number,
    owned: boolean = true): void {
    const rw: Quaternion = this.restWorldQuat(nd);
    const inv: Quaternion = quatConj(rw);
    const axis: Vec3 = quatRotVec(inv, { x: wx, y: wy, z: wz });
    const pb: PoseBone = {
      node: nd, base: qcopy(nd.rotation),
      ax: quatNorm({ x: axis.x, y: axis.y, z: axis.z, w: 0 }), owned: owned, kind: kind
    };
    this.posers.push(pb);
  }

  /**
   * 骨骼归类：大腿 K_THIGH / 小腿 K_CALF / 脚掌 K_FOOT（踝补偿）/ 大臂 K_ARM /
   * 腰 K_SWAY（骨盆绕 Y 摆）/ 头 K_HEAD / 脊柱与颈 K_BREATH。
   * 腿臂上的 twist/share 辅助骨一律跳过——链式叠加会劈叉（真机踩过）。
   * 同一批骨骼再登记进 posers（绕世界轴），给 SIT / WAVE / NOD 用。
   */
  private buildRig(root: Node): void {
    const all: Node[] = [];
    this.collect(root, all, 0);
    this.nodeCount = all.length;
    let thigh: number = 0;
    let calf: number = 0;
    let arm: number = 0;
    let breath: number = 0;
    let foot: number = 0;
    let sway: number = 0;
    let head: number = 0;
    let leadN: number = 0;
    let posed: number = 0;
    const found: boolean[] = [false, false, false, false, false, false, false, false, false,
      false, false];
    let skipped: number = 0;
    for (let i = 0; i < all.length; i++) {
      const nd: Node = all[i];
      const nm: string = nd.name;
      if (nm === '') {
        continue;
      }
      const role: number = roleOfName(this.prof.kind, nm);
      if (role === ROLE_NONE) {
        skipped++;
        continue;
      }
      found[role] = true;
      const isLeft: boolean = isLeftName(nm);
      const lp: number = isLeft ? 0 : Math.PI;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D bone map role=%{public}s node=%{public}s left=%{public}d',
        roleName(role), nm, isLeft ? 1 : 0);
      if (role === ROLE_THIGH) {
        this.addBone(nd, 18 * DEG, lp, 3, K_THIGH, false);
        this.addPoser(nd, 0, 0, 1, PK_THIGH);
        thigh++;
        posed++;
      } else if (role === ROLE_CALF) {
        this.addBone(nd, 10 * DEG, lp + 0.25 * Math.PI, 3, K_CALF, false);
        this.addPoser(nd, 0, 0, 1, PK_CALF);
        calf++;
        posed++;
      } else if (role === ROLE_FOOT) {
        this.addBone(nd, 5.5 * DEG, lp + 0.25 * Math.PI, 3, K_FOOT, false);
        this.addPoser(nd, 0, 0, 1, PK_FOOT);
        foot++;
        posed++;
      } else if (role === ROLE_TOE) {
        this.addBone(nd, 5.5 * DEG, lp + 0.25 * Math.PI, 3, K_FOOT, false);
        foot++;
      } else if (role === ROLE_ARM) {
        this.applyArmDown(nd, isLeft);
        this.addBone(nd, 9 * DEG, lp + Math.PI, 3, K_ARM, false);
        if (!isLeft) {
          this.addPoser(nd, 1, 0, 0, PK_UARM);
          posed++;
        }
        arm++;
      } else if (role === ROLE_FOREARM) {
        // 肘铰链：绕世界 X（前后轴）屈肘才对；绕 Y（竖直轴）转 = 小臂绕身体横扫，
        // 这不是"弯肘"，加上逐帧累加会拧成麻花。小臂不在 bones 里，故 owned=false。
        if (!isLeft) {
          this.addPoser(nd, 1, 0, 0, PK_FARM, false);
          posed++;
        }
      } else if (role === ROLE_WAIST) {
        this.addBone(nd, 4 * DEG, 0.5 * Math.PI, 2, K_SWAY, false);
        sway++;
      } else if (role === ROLE_HEAD) {
        this.addBone(nd, 0.9 * DEG, 0.75 * Math.PI, 1, K_HEAD, true);
        this.addPoser(nd, 1, 0, 0, PK_HEAD);
        if (this.speechHead === null) {
          this.speechHead = nd;
          this.speechHeadAx = this.localAxis(nd, 0, 0, 1);
        }
        head++;
        leadN++;
        posed++;
      } else if (role === ROLE_NECK) {
        this.addBone(nd, 0.6 * DEG, 0, 1, K_BREATH, true);
        breath++;
        leadN++;
      } else if (role === ROLE_SPINE_LOW) {
        this.addBone(nd, 1.2 * DEG, 0, 1, K_BREATH, false);
        breath++;
      } else if (role === ROLE_SPINE_UP) {
        this.addBone(nd, 1.2 * DEG, 0, 1, K_BREATH, true);
        breath++;
        leadN++;
        if (this.speechSpine === null) {
          this.speechSpine = nd;
          this.speechSpineAx = this.localAxis(nd, 0, 0, 1);
        }
      }
    }
    // 查不到的骨骼逐个点名，绝不静默失败（映射表换了/模型换了，日志要能一眼看出来）
    let miss: string = '';
    for (let r = 0; r < found.length; r++) {
      if (!found[r]) {
        miss = miss + (miss === '' ? '' : ',') + roleName(r);
      }
    }
    this.missingNote = miss === '' ? 'map[全]' : ('map[缺' + miss + ']');
    if (miss !== '') {
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'Avatar3D bone map missing role=%{public}s kind=%{public}d (跳过，不崩)',
        miss, this.prof.kind);
    }
    this.rigNote = '腿' + thigh + ' 膝' + calf + ' 脚' + foot + ' 臂' + arm + ' 腰' + sway +
      ' 呼吸' + breath;
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'Avatar3D rig kind=%{public}d nodes=%{public}d thigh=%{public}d calf=%{public}d foot=%{public}d arm=%{public}d sway=%{public}d breath=%{public}d lead=%{public}d head=%{public}d posed=%{public}d unmatched=%{public}d',
      this.prof.kind, all.length, thigh, calf, foot, arm, sway, breath, leadN, head, posed, skipped);
  }

  private scheduleTick(): void {
    if (this.scene === null) {
      return;
    }
    this.timer = setTimeout(() => {
      this.tick();
    }, this.tickMs);
  }

  private swingQuat(axis: number, ang: number): Quaternion {
    if (axis === 3) {
      return quatAxis(0, 0, 1, ang);
    }
    if (axis === 2) {
      return quatAxis(0, 1, 0, ang);
    }
    return quatAxis(1, 0, 0, ang);
  }

  private pickTarget(): void {
    let nx: number = this.posX;
    for (let i = 0; i < 8; i++) {
      nx = (Math.random() * 2 - 1) * X_LIMIT;
      if (Math.abs(nx - this.posX) > 0.35) {
        break;
      }
    }
    this.targetX = nx;
    this.yawTo = nx >= this.posX ? YAW_AMP : -YAW_AMP;
  }

  private enterDwell(): void {
    this.state = ST_DWELL;
    this.stateT = 0;
    this.yawFrom = this.yaw;
    this.pickTarget();
    this.dwellDur = 0.8 + Math.random() * 2.7;
    this.gaitAmp = DWELL_GAIT;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D dwell next=%{public}s yawTo=%{public}s dur=%{public}s',
      f2(this.targetX), f2(this.yawTo), f2(this.dwellDur));
  }

  private enterWalk(): void {
    if (Math.abs(this.targetX - this.posX) < 0.05) {
      this.pickTarget();
    }
    this.state = ST_WALK;
    this.stateT = 0;
    this.walkFrom = this.posX;
    this.walkTo = this.targetX;
    this.walkU = 0;
    const dist: number = Math.abs(this.walkTo - this.walkFrom);
    this.walkT = Math.max(0.8, dist / (WALK_SPEED * 0.85));
    this.gaitRate = 0.9 + Math.random() * 0.2;
    this.strideAmp = 0.9 + Math.random() * 0.2;
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'Avatar3D walk from=%{public}s to=%{public}s dur=%{public}s rate=%{public}s stride=%{public}s',
      f2(this.walkFrom), f2(this.walkTo), f2(this.walkT), f2(this.gaitRate), f2(this.strideAmp));
  }

  private beginSit(): void {
    this.sitPhase = 1;
    this.sitT = 0;
    this.sitDur = SIT_IN_MIN + Math.random() * (SIT_IN_MAX - SIT_IN_MIN);
    this.state = ST_SIT;
    this.stateT = 0;
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'Avatar3D sit begin pose thigh=%{public}d calf=%{public}d foot=%{public}d drop=%{public}s dur=%{public}s',
      SIT_THIGH_DEG, SIT_CALF_DEG, SIT_FOOT_DEG, f2(SIT_DROP_RATIO * this.rigH), f2(this.sitDur));
  }

  private beginWave(): void {
    if (this.wavePhase !== 0) {
      return;
    }
    this.wavePhase = 1;
    this.waveT = 0;
    this.waveOsc = 0;
    this.state = ST_WAVE;
    this.stateT = 0;
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'Avatar3D wave begin arm=%{public}d elbow=%{public}d osc=%{public}ddeg up=%{public}s',
      WAVE_ARM_DEG, WAVE_ELBOW_DEG, WAVE_OSC_DEG, f2(WAVE_UP_S));
  }

  private beginNod(): void {
    this.nodT = 0;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D nod begin amp=%{public}ddeg dur=%{public}s',
      NOD_DEG, f2(NOD_S));
  }

  /** 姿态层推进：坐/挥/点头。返回 true 表示此刻"忙"，基础踱步状态机要让位 */
  private updatePosture(dt: number, t: number): boolean {
    if (this.sitPhase === 1) {
      this.sitT += dt;
      const p: number = clamp01(this.sitT / this.sitDur);
      this.sitAmt = smooth(p);
      if (p >= 1) {
        this.sitPhase = 2;
        this.sitHold = SIT_HOLD_MIN + Math.random() * (SIT_HOLD_MAX - SIT_HOLD_MIN);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D sit seated hold=%{public}s', f2(this.sitHold));
      }
    } else if (this.sitPhase === 2) {
      this.sitAmt = 1;
      this.sitHold -= dt;
      if (this.sitHold <= 0) {
        this.sitPhase = 3;
        this.sitT = 0;
        this.sitDur = SIT_IN_MIN + Math.random() * (SIT_IN_MAX - SIT_IN_MIN);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D sit rise dur=%{public}s', f2(this.sitDur));
      }
    } else if (this.sitPhase === 3) {
      this.sitT += dt;
      const p: number = clamp01(this.sitT / this.sitDur);
      this.sitAmt = 1 - smooth(p);
      if (p >= 1) {
        this.sitPhase = 0;
        this.sitAmt = 0;
        this.state = ST_DWELL;
        this.stateT = 0;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D sit done back to dwell');
        if (this.pendingWave) {
          this.pendingWave = false;
          this.beginWave();
        } else {
          this.enterDwell();
        }
      }
    }

    if (this.wavePhase === 1) {
      this.waveT += dt;
      const p: number = clamp01(this.waveT / WAVE_UP_S);
      this.waveAmt = easeOutQuad(p);
      if (p >= 1) {
        this.wavePhase = 2;
        this.waveT = 0;
        this.waveHold = WAVE_HOLD_MIN + Math.random() * (WAVE_HOLD_MAX - WAVE_HOLD_MIN);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D wave hold=%{public}s', f2(this.waveHold));
      }
    } else if (this.wavePhase === 2) {
      this.waveAmt = 1;
      this.waveOsc += dt * 2 * Math.PI * WAVE_OSC_HZ;
      this.waveT += dt;
      if (this.waveT >= this.waveHold) {
        this.wavePhase = 3;
        this.waveT = 0;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D wave lower');
      }
    } else if (this.wavePhase === 3) {
      this.waveT += dt;
      const p: number = clamp01(this.waveT / WAVE_DOWN_S);
      this.waveAmt = 1 - smooth(p);
      if (p >= 1) {
        this.wavePhase = 0;
        this.waveAmt = 0;
        this.waveOsc = 0;
        this.state = ST_DWELL;
        this.stateT = 0;
        this.nextWaveAt = t + WAVE_GAP_MIN + Math.random() * (WAVE_GAP_MAX - WAVE_GAP_MIN);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D wave done next=%{public}s', f2(this.nextWaveAt - t));
        this.enterDwell();
      }
    }

    if (this.nodT >= 0) {
      this.nodT += dt;
      const p: number = this.nodT / NOD_S;
      this.nodAmt = p < 1 ? Math.sin(Math.PI * clamp01(p)) : 0;
      if (p >= 1) {
        this.nodT = -1;
        this.nodAmt = 0;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D nod done');
      }
    }

    return this.sitPhase !== 0 || this.wavePhase !== 0;
  }

  private stateName(): string {
    if (this.sitPhase !== 0) {
      return 'SIT' + this.sitPhase;
    }
    if (this.wavePhase !== 0) {
      return 'WAVE' + this.wavePhase;
    }
    return this.state === ST_WALK ? 'WALK' : 'DWELL';
  }

  /** 单个固定步长：只推进状态，不碰节点（节点在 applyScene 里一帧写一次） */
  private step(dt: number): void {
    this.t += dt;
    const t: number = this.t;

    // 自然触发：坐下每 40-90s 一次，挥手每 2-5min 一次
    if (t >= this.nextSitAt && this.sitPhase === 0 && this.wavePhase === 0) {
      this.nextSitAt = t + SIT_GAP_MIN + Math.random() * (SIT_GAP_MAX - SIT_GAP_MIN);
      this.beginSit();
    }
    if (t >= this.nextWaveAt && this.wavePhase === 0 && this.sitPhase === 0 && this.state === ST_DWELL) {
      this.beginWave();
    }

    const busy: boolean = this.updatePosture(dt, t);

    if (!busy && this.state === ST_WALK) {
      this.gaitPhase += dt * 2 * Math.PI * GAIT_HZ * this.gaitRate;
      // 落地顿点：每半步开头 0.25 段速度 x0.85（1Hz 步频下约 0.1s）
      const halfIdx: number = Math.floor(this.gaitPhase / Math.PI);
      const within: number = this.gaitPhase / Math.PI - halfIdx;
      const dip: number = within < LAND_WIN
        ? 1 - (1 - LAND_DIP) * Math.sin(Math.PI * within / LAND_WIN) : 1;
      if (this.walkT > 0.01) {
        this.walkU = Math.min(1, this.walkU + dt * dip / this.walkT);
      }
      const prevX: number = this.posX;
      this.posX = this.walkFrom + (this.walkTo - this.walkFrom) * easeInOutSine(this.walkU);
      const v: number = Math.abs(this.posX - prevX) / dt;
      this.motion = Math.min(1, v / (WALK_SPEED * 0.6));
      this.gaitAmp = this.motion;
      if (this.walkU >= 1) {
        this.enterDwell();
      }
    } else if (!busy) {
      // 站定：位移不停死，0.25 倍速缓慢挪向下一个目标，配合角速度缓动转身更连贯
      this.stateT += dt;
      const dx: number = this.targetX - this.posX;
      const adv: number = WALK_SPEED * DWELL_DRIFT * dt;
      if (Math.abs(dx) <= adv) {
        this.posX = this.targetX;
      } else {
        this.posX += (dx > 0 ? adv : -adv);
      }
      this.motion = this.motion * 0.88;
      this.gaitAmp = DWELL_GAIT;
      const p: number = clamp01(this.stateT / TURN_S);
      const sp: number = easeInOutQuad(p);
      this.yaw = this.yawFrom + (this.yawTo - this.yawFrom) * sp;
      const leadP: number = clamp01(this.stateT / (TURN_S * 0.8));
      this.leadDelta = (this.yawTo - this.yawFrom) * (easeInOutQuad(leadP) - sp);
      if (this.stateT >= this.dwellDur) {
        this.enterWalk();
      }
    } else {
      this.motion = this.motion * 0.7;
      this.gaitAmp = this.gaitAmp * 0.8;
    }

    // 数字故障：每 8-15s 抖 0.1-0.2s，横向 2-5px
    if (t >= this.glitchNext) {
      const dur: number = GLITCH_DUR_MIN + Math.random() * (GLITCH_DUR_MAX - GLITCH_DUR_MIN);
      this.glitchUntil = t + dur;
      this.glitchNext = t + GLITCH_GAP_MIN + Math.random() * (GLITCH_GAP_MAX - GLITCH_GAP_MIN);
      this.glitchTick = 0;
      this.glitchCount++;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D glitch start #%{public}d dur=%{public}s next=%{public}s',
        this.glitchCount, dur.toFixed(3), f2(this.glitchNext - t));
    }
    if (t < this.glitchUntil) {
      if (t >= this.glitchTick) {
        const amp: number = GLITCH_AMP_MIN + Math.random() * (GLITCH_AMP_MAX - GLITCH_AMP_MIN);
        this.glitchOff = Math.random() < 0.5 ? -amp : amp;
        this.glitchTick = t + 0.035 + Math.random() * 0.03;
      }
    } else {
      this.glitchOff = 0;
    }
  }

  /** 一帧写一次节点：人、粒子、装置、骨骼，然后由 tick 提交 renderFrame */
  private applyScene(): void {
    const t: number = this.t;
    const sit: number = this.sitAmt;
    const wav: number = this.waveAmt;
    const nod: number = this.nodAmt;
    const rootX: number = this.posX + this.glitchOff;
    const sitDrop: number = SIT_DROP_RATIO * this.rigH * sit;
    const slowBob: number = Math.sin(2 * Math.PI * t / SLOW_WAVE_PERIOD + 1.1) * SLOW_BOB;
    const breath: number = Math.sin(2 * Math.PI * t / BREATH_PERIOD);
    const ph: number = this.gaitPhase;
    const drift: number = Math.sin(2 * Math.PI * 0.37 * t);
    const bob: number = Math.sin(ph * 2 + 0.3 * Math.PI) * 0.008 * this.motion;

    const rotNow: Quaternion = quatMul(this.baseRot, quatAxis(0, 1, 0, this.yaw));
    const basePosY: number = this.baseY + bob + slowBob - sitDrop;
    const root: Node | null = this.modelRoot;
    if (root !== null) {
      root.position = { x: rootX, y: basePosY, z: this.baseZ };
      root.rotation = rotNow;
    }

    // 粒子：整体跟人走；坐下时纵向收一点；远层自行扩开+变淡（外围尘埃的呼吸感）
    for (let i = 0; i < this.particleGroups.length; i++) {
      const g: ParticleGroup = this.particleGroups[i];
      const w: number = 2 * Math.PI * t / g.period + g.phase;
      let sx: number = this.avatarScale.x * (1 + 0.015 * sit);
      let sy: number = this.avatarScale.y * (1 - 0.22 * sit);
      let sz: number = this.avatarScale.z * (1 + 0.015 * sit);
      let alpha: number = g.alpha0;
      if (g.far) {
        const u: number = (t / g.period + g.phase / 6.283) % 1;
        const q: number = 0.5 - 0.5 * Math.cos(2 * Math.PI * u);
        const grow: number = 1 + 0.10 * q;
        sx = sx * grow;
        sy = sy * grow;
        sz = sz * grow;
        alpha = g.alpha0 * (0.35 + 0.65 * q);
      }
      g.node.position = {
        x: rootX,
        y: basePosY + Math.sin(w) * g.ampY,
        z: this.baseZ + Math.sin(w + 1.1) * g.ampZ
      };
      g.node.rotation = rotNow;
      g.node.scale = { x: sx, y: sy, z: sz };
      g.mat.baseColor.factor = { x: g.cr, y: g.cg, z: g.cb, w: alpha };
    }

    // 装置：光环缓慢自转 + 呼吸式明暗；扫描环自下而上升起；线框笼反向慢转
    const ring: Node | null = this.ringNode;
    if (ring !== null) {
      ring.position = { x: rootX, y: this.baseY + this.rigH * 1.10 + slowBob * 2, z: this.baseZ };
      ring.rotation = quatMul(quatAxis(1, 0, 0, 0.16), quatAxis(0, 1, 0, t * 0.35));
      const rm: UnlitMaterial | null = this.ringMat;
      if (rm !== null) {
        const pulse: number = 0.52 + 0.10 * Math.sin(2 * Math.PI * t / 5.2);
        rm.baseColor.factor = { x: 0.72, y: 0.95, z: 1.0, w: pulse };
      }
    }
    const scan: Node | null = this.scanNode;
    if (scan !== null) {
      const u: number = (t / SCAN_PERIOD) % 1;
      scan.position = { x: rootX, y: this.baseY + this.rigH * (0.04 + 0.96 * u) - sitDrop * 0.6, z: this.baseZ };
      scan.rotation = quatAxis(0, 1, 0, -t * 0.5);
      const sm: UnlitMaterial | null = this.scanMat;
      if (sm !== null) {
        sm.baseColor.factor = { x: 0.55, y: 0.85, z: 1.0, w: 0.22 * Math.sin(Math.PI * u) };
      }
    }
    const halo: Node | null = this.haloNode;
    if (halo !== null) {
      halo.position = { x: rootX, y: this.baseY + 0.002, z: this.baseZ };
    }
    const shell: Node | null = this.shellNode;
    if (shell !== null) {
      shell.position = { x: rootX, y: this.baseY + this.rigH * 0.5 - sitDrop * 0.5, z: this.baseZ };
      shell.rotation = quatAxis(0, 1, 0, -t * 0.22);
    }

    // 步态/呼吸骨骼
    const ampScale: number = this.strideAmp * this.gaitAmp * (1 - sit);
    for (let i = 0; i < this.bones.length; i++) {
      const b: SwingBone = this.bones[i];
      let ang: number = 0;
      if (b.kind === K_BREATH) {
        ang = breath * b.ampRad;
      } else if (b.kind === K_CALF) {
        ang = b.ampRad * (0.5 - 0.5 * Math.cos(ph + b.phase)) * ampScale;
      } else if (b.kind === K_FOOT) {
        ang = -b.ampRad * (0.5 - 0.5 * Math.cos(ph + b.phase)) * ampScale;
      } else if (b.kind === K_THIGH || b.kind === K_ARM) {
        const a: number = Math.sin(ph + b.phase) * b.ampRad +
          Math.sin(2 * (ph + b.phase)) * b.ampRad * 0.15 + drift * b.ampRad * 0.08;
        ang = a * ampScale;
      } else {
        ang = Math.sin(ph + b.phase) * b.ampRad * ampScale;
      }
      let q: Quaternion = this.swingQuat(b.axis, ang);
      if (b.lead && this.leadDelta !== 0) {
        q = quatMul(q, quatAxis(0, 1, 0, this.leadDelta));
      }
      b.node.rotation = quatMul(b.base, q);
    }

    // 姿态层：绕世界轴换算出的局部轴，叠在步态结果之上。
    // 铁律：owned 骨骼本帧已被步态循环从基准位复位，可以在其结果上叠加；
    // 非 owned 骨骼必须自己从 base 起算——node.rotation 是活引用，从它起算会逐帧累加
    // （真机事故：小臂 51fps x 60° ≈ 3000°/s，袖子瞬间拧成一团布）。
    const posing: boolean = sit > 0.0005 || wav > 0.0005 || nod > 0.0005;
    for (let i = 0; i < this.posers.length; i++) {
      const pb: PoseBone = this.posers[i];
      let ang: number = 0;
      if (posing) {
        if (pb.kind === PK_THIGH) {
          ang = SIT_THIGH_DEG * DEG * sit;
        } else if (pb.kind === PK_CALF) {
          ang = SIT_CALF_DEG * DEG * sit;
        } else if (pb.kind === PK_FOOT) {
          ang = SIT_FOOT_DEG * DEG * sit;
        } else if (pb.kind === PK_UARM) {
          // 抬臂角按基线缩放：写实版静止即 A 字 52°，Nova 是 T-pose 已经水平，
          // 用同一角度会直接翻到头顶（waveArmScale 见 ModelKit）
          ang = WAVE_ARM_DEG * DEG * wav * this.prof.waveArmScale;
        } else if (pb.kind === PK_FARM) {
          ang = (WAVE_ELBOW_DEG * DEG * this.prof.waveElbowScale +
            WAVE_OSC_DEG * DEG * Math.sin(this.waveOsc)) * wav;
        } else if (pb.kind === PK_HEAD) {
          ang = NOD_DEG * DEG * nod * Math.sin(this.nodT * 2 * Math.PI * 1.25);
        }
      }
      const moving: boolean = ang > 1e-5 || ang < -1e-5;
      if (!moving) {
        // 姿态量归零：非 owned 骨骼必须显式回基准，否则会停留在上一次的扭曲姿态
        if (!pb.owned) {
          pb.node.rotation = qcopy(pb.base);
        }
        continue;
      }
      const qp: Quaternion = quatAxis(pb.ax.x, pb.ax.y, pb.ax.z, ang);
      const cur: Quaternion = pb.owned ? qcopy(pb.node.rotation) : qcopy(pb.base);
      pb.node.rotation = quatMul(cur, qp);
    }

    // 赛博口型：叠在步态与姿态层之上，不打断 WALK / SIT / WAVE
    try {
      this.speechStep(rootX, basePosY, rotNow);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'Avatar3D speechStep failed: %{public}s', (e as Error).message);
    }
  }

  /** 帧入口：整帧包 try/catch，3D 出任何错都不许连累聊天（异常会打挂整个 App） */
  private tick(): void {
    if (this.scene === null) {
      return;
    }
    try {
      this.tickInner();
    } catch (e) {
      this.tickFails++;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'Avatar3D tick fail #%{public}d: %{public}s',
        this.tickFails, (e as Error).message);
      if (this.tickFails >= 3) {
        this.fail('3D 已降级（动画异常）：' + (e as Error).message);
        this.timer = -1;
        return;
      }
    }
    this.scheduleTick();
  }

  private tickInner(): void {
    const sc: Scene | null = this.scene;
    if (sc === null) {
      return;
    }
    const now: number = Date.now();
    let rawDt: number = (now - this.lastMs) / 1000;
    if (rawDt <= 0 || rawDt > 0.25) {
      rawDt = this.tickMs / 1000;
    }
    this.lastMs = now;
    this.frame++;

    // 帧率实测：先按 60fps 跑，不达标就退回 30fps（同一进程只降一次）
    this.perfAcc += rawDt;
    this.perfN++;
    if (this.perfN >= PERF_WINDOW) {
      const fps: number = this.perfN / this.perfAcc;
      if (this.tickMs === TICK_FAST && this.frame > PERF_WINDOW * 2 && fps < PERF_MIN_FPS) {
        this.tickMs = TICK_SLOW;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D tick 60->30 downgrade fps=%{public}d', Math.round(fps));
      } else if (this.frame % (PERF_WINDOW * 4) === 0) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'Avatar3D perf tick=%{public}dms fps=%{public}d state=%{public}s',
          this.tickMs, Math.round(fps), this.stateName());
      }
      this.perfAcc = 0;
      this.perfN = 0;
    }

    // 固定步长推进：动作时间基准与真实帧间隔解耦
    this.acc += rawDt;
    let steps: number = 0;
    while (this.acc >= FIXED_DT && steps < MAX_STEPS) {
      this.step(FIXED_DT);
      this.acc -= FIXED_DT;
      steps++;
    }
    if (steps === MAX_STEPS) {
      this.acc = 0;
    }

    this.applyScene();

    try {
      sc.renderFrame();
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'Avatar3D renderFrame failed: %{public}s', (e as Error).message);
    }

    if (this.frame % 60 === 0) {
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'Avatar3D tick f=%{public}d st=%{public}s x=%{public}s tx=%{public}s yaw=%{public}s motion=%{public}s gait=%{public}s sit=%{public}s wave=%{public}s glitch=%{public}s steps=%{public}d',
        this.frame, this.stateName(), f2(this.posX), f2(this.targetX), f2(this.yaw),
        f2(this.motion), f2(this.gaitAmp), f2(this.sitAmt), f2(this.waveAmt), f2(this.glitchOff), steps);
    }
  }
}
