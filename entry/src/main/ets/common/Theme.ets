/**
 * 主题常量表：UI 层的颜色只有这一个来源，页面里不再出现十六进制字面量。
 *
 * 两套主题：
 *   DARK  默认。半透明深色面 + 白色文字，配合底层深色全息 3D 场景。
 *   LIGHT 浅色。近白面 + 深色文字；3D 层（Avatar3D）本身仍是深色全息场景、不参与切换，
 *         由页面在它上面盖一层 veil3d 浅色纱（见 Index.build），把它压成背景水印，
 *         这样「只切 UI 层」和「浅色下文字清晰」两件事同时成立。
 *
 * 颜色格式与 ArkUI 一致：#AARRGGBB（8 位）或 #RRGGBB（6 位）。
 */

/** 深色主题标识（落 preferences 的值） */
export const THEME_DARK: string = 'dark';
/** 浅色主题标识（落 preferences 的值） */
export const THEME_LIGHT: string = 'light';

/** 一套主题的全部颜色槽位；页面只通过 paletteOf() 取用 */
export interface Palette {
  /** 主题标识：THEME_DARK / THEME_LIGHT */
  theme: string;
  /** 面板上显示的名字 */
  label: string;
  /** 是否是深色（3D 层、状态判断用） */
  isDark: boolean;
  /** 页面根底色 */
  bgRoot: string;
  /** 顶部按钮条 */
  bgHeader: string;
  /** 状态条（模式 / 语音 / 提示） */
  bgStatus: string;
  /** 消息列表区 */
  bgList: string;
  /** 底部输入条 */
  bgInputBar: string;
  /** 输入框 / 小输入框 */
  bgInput: string;
  /** 弹层（云端 / 操控 / 会话面板）底色 */
  bgPanel: string;
  /** 用户气泡底 */
  bubbleUser: string;
  /** 用户气泡字 */
  bubbleUserText: string;
  /** 分身气泡底 */
  bubbleBot: string;
  /** 分身气泡字 */
  bubbleBotText: string;
  /** 主文字 */
  text: string;
  /** 次级文字 */
  textDim: string;
  /** 更弱的文字（提示行 / 占位说明） */
  textMuted: string;
  /** 输入框占位符 */
  placeholder: string;
  /** 关闭态图标（🔇 之类） */
  textOff: string;
  /** 主色（发送 / 确定 / 强调） */
  primary: string;
  /** 危险色（清空 / 删除 / 停止） */
  danger: string;
  /** 成功色（状态文字 / 打开态） */
  ok: string;
  /** 成功底色（绿色按钮） */
  okBg: string;
  /** 提醒色（注意事项） */
  warn: string;
  /** 错误色（错误文字） */
  err: string;
  /** 轻错误色（状态条小字） */
  errSoft: string;
  /** 信息色（检索命中） */
  info: string;
  /** 强调副色（主动搭话） */
  accent2: string;
  /** 中性按钮底 */
  btnBg: string;
  /** 边框 / 分隔线 */
  border: string;
  /** 弹层背后的遮罩 */
  scrim: string;
  /** 盖在 3D 层上的纱：深色主题全透明，浅色主题压暗全息场景 */
  veil3d: string;
  /** 日志文字 */
  logText: string;
}

const DARK: Palette = {
  theme: THEME_DARK,
  label: '深色',
  isDark: true,
  bgRoot: '#1E1E24',
  bgHeader: '#E62C2C35',
  bgStatus: '#E6242430',
  bgList: '#99141820',
  bgInputBar: '#F22C2C35',
  bgInput: '#33333F',
  bgPanel: '#2C2C35',
  bubbleUser: '#6C63FF',
  bubbleUserText: '#FFFFFF',
  bubbleBot: '#C0333333',
  bubbleBotText: '#FFFFFF',
  text: '#FFFFFF',
  textDim: '#AAAAAA',
  textMuted: '#8A8A99',
  placeholder: '#8A8A99',
  textOff: '#66666F',
  primary: '#6C63FF',
  danger: '#C62828',
  ok: '#7BE495',
  okBg: '#2E7D32',
  warn: '#FFD180',
  err: '#FF8A80',
  errSoft: '#FF8A65',
  info: '#7BA7FF',
  accent2: '#C8A6FF',
  btnBg: '#3D3D4D',
  border: '#3D3D4D',
  scrim: '#99000000',
  veil3d: '#00000000',
  logText: '#9AD0FF'
};

const LIGHT: Palette = {
  theme: THEME_LIGHT,
  label: '浅色',
  isDark: false,
  bgRoot: '#F2F3F7',
  bgHeader: '#F7FFFFFF',
  bgStatus: '#F2EAEBF1',
  // 88% 白：3D 全息还能透出一点影子，20% 的暗底不会压掉文字对比度
  bgList: '#E0F7F8FB',
  bgInputBar: '#F7FFFFFF',
  bgInput: '#ECEDF2',
  bgPanel: '#FFFFFF',
  bubbleUser: '#4F46E5',
  bubbleUserText: '#FFFFFF',
  bubbleBot: '#E4E5EC',
  bubbleBotText: '#1B1B22',
  text: '#1B1B22',
  textDim: '#4E4E5C',
  textMuted: '#63636F',
  placeholder: '#8A8A99',
  textOff: '#9A9AA6',
  primary: '#4F46E5',
  danger: '#C62828',
  ok: '#1B7F3B',
  okBg: '#2E7D32',
  warn: '#8A5A00',
  err: '#B3261E',
  errSoft: '#B3261E',
  info: '#2F5FBF',
  accent2: '#6B3FA0',
  btnBg: '#E4E5EC',
  border: '#D5D6DE',
  scrim: '#66000000',
  // 70% 浅纱：Avatar3D 仍是深色场景，只是被压成背景水印
  veil3d: '#B3F2F3F7',
  logText: '#1F5FA8'
};

/** 主题标识 → 颜色表；未知值一律按深色（默认主题）处理 */
export function paletteOf(theme: string): Palette {
  return theme === THEME_LIGHT ? LIGHT : DARK;
}

/** 面板上显示的名字 */
export function themeLabel(theme: string): string {
  return theme === THEME_LIGHT ? LIGHT.label : DARK.label;
}
