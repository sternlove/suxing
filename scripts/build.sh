#!/usr/bin/env bash
# 苏兴 · 构建脚本
# 用法: ./scripts/build.sh [--install]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- 1. 环境变量 ---
: "${DEVECO_SDK_HOME:?请先 export DEVECO_SDK_HOME=\"<DevEco>/sdk\"}"
: "${NODE_HOME:?请先 export NODE_HOME=\"<DevEco>/tools/node\"}"
export PATH="$NODE_HOME:$PATH"

HVIGOR="$DEVECO_SDK_HOME/../tools/hvigor/bin/hvigorw"
if [[ ! -f "$HVIGOR" ]]; then
  echo "✗ 找不到 hvigorw: $HVIGOR" >&2
  echo "  请确认 DEVECO_SDK_HOME 指向 DevEco Studio 的 sdk 目录" >&2
  exit 1
fi

# --- 2. 签名配置 ---
if [[ ! -f build-profile.json5 ]]; then
  echo "✗ 缺少 build-profile.json5" >&2
  echo "  二选一:" >&2
  echo "    A. 用 DevEco Studio 打开工程 → Project Structure → Signing Configs → 勾选自动签名" >&2
  echo "    B. cp build-profile.example.json5 build-profile.json5 后填入自己的证书" >&2
  exit 1
fi

# --- 3. 3D 模型 ---
RAW="entry/src/main/resources/rawfile"
mkdir -p "$RAW"
if [[ ! -f "$RAW/Avatar.glb" ]]; then
  echo "⚠  缺少 $RAW/Avatar.glb（3D 人形模型）" >&2
  echo "   没有它 App 能启动，但 3D 场景会加载失败并降级。" >&2
  echo "   详见 README「需要自备的资源」。" >&2
fi

# --- 4. 编译 ---
echo "→ 编译中..."
"$HVIGOR" --mode module -p product=default assembleHap --no-daemon

HAP="entry/build/default/outputs/default/entry-default-signed.hap"
if [[ ! -f "$HAP" ]]; then
  echo "✗ 编译产物不存在: $HAP" >&2
  exit 1
fi
echo "✓ 构建成功: $(du -h "$HAP" | cut -f1)"

# --- 5. 可选安装 ---
if [[ "${1:-}" == "--install" ]]; then
  HDC="${HDC:-$DEVECO_SDK_HOME/../sdk/default/openharmony/toolchains/hdc.exe}"
  echo "→ 检查设备..."
  "$HDC" list targets | grep -q . || { echo "✗ 没有连接的设备" >&2; exit 1; }
  echo "→ 安装..."
  "$HDC" install -r "$HAP"
  "$HDC" shell aa start -a EntryAbility -b com.oviora.cybertwin
  echo "✓ 已安装并启动"
fi
