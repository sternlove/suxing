# 苏兴 · HarmonyOS 原生 AI 数字分身

> **English summary** — An on-device AI companion for HarmonyOS, written in ArkTS. All inference runs locally via llama.cpp (cross-compiled to OHOS) with a NAPI bridge, so it works fully offline; when online it can fall back to cloud APIs. Features a 3D avatar rendered with ArkGraphics3D that walks, sits, waves and moves its mouth in sync with speech, plus SQLite-backed memory with BM25 retrieval, a self-evolving persona, and natural-language commands that route to the system share sheet. See the [Known Limitations](#已知限制如实) section for what it deliberately does not do.

一个跑在鸿蒙（HarmonyOS / OpenHarmony）上的**本地优先** AI 分身应用。全部推理在端侧完成，断网可用；联网时自动切换云端模型。

3D 形象站在全屏场景里踱步、呼吸、说话时张口，聊天界面叠在场景之上。

> 个人项目，仍在迭代中。**已知限制都写在文末**，没有隐瞒。

---

## 界面

| 主界面 | 3D 形象与聊天叠加 |
|---|---|
| ![主界面](docs/images/main-screen.jpg) | ![场景](docs/images/scene-early.jpg) |

**口型同步**（闭嘴 vs 朗读中，13 倍放大自己的脸部区域）：

![口型对比](docs/images/mouth-ab.jpg)

**对话指令 → 系统分享**（说「用 QQ 发给李四：文件收到了」，解析出目标后唤起分享面板）：

![分享面板](docs/images/share-panel.jpg)

---

## 功能

| 模块 | 说明 |
|---|---|
| **本地推理** | llama.cpp + NAPI 桥接，Qwen 系列 GGUF 模型端侧运行（0.5B 加载约 285 ms，1.7B 约 400 ms） |
| **端云双模** | 三档降级：云端 API → 本地模型 → 本地词库。连接 10s / 读取 60s / SSE 空闲 30s 三层超时 |
| **3D 形象** | ArkGraphics3D 全屏背景，骨骼驱动行走 / 坐下 / 挥手 / 说话点头，9043 个粒子光场 + 全息装置 |
| **口型同步** | 模型自带 `mouthOpen` 形变目标，按 TTS 振幅驱动；支持切换到带 viseme 的 VRM 模型 |
| **语音** | Core Speech Kit：TTS 朗读 + **离线**语音识别（`mode:1`，不联网） |
| **记忆** | SQLite 持久化，重启不丢；最近 6 轮上下文 + BM25 检索历史（top 3 注入 prompt） |
| **人格** | 固定称用户「先生」；偏好自演化（从"我喜欢/讨厌 X"提取）；情绪三维度（愉悦/能量/亲近）随时间衰减 |
| **主动搭话** | 静默 10 分钟主动开口，每小时上限 2 次，23:00-07:00 静默，不重复最近 3 句 |
| **对话指令** | 说「用 QQ 发给李四：文件收到了」→ 解析出目标应用/收件人/内容 → 唤起系统分享 |
| **剪贴板** | 说「看看我的报错」→ 读取剪贴板内容分析（2000 字截断） |
| **技能框架** | 动作型请求走可插拔技能，新增能力不用改对话主流程 |
| **MCP 客户端** | 接入外部 MCP server，工具自动变成技能 |

---

## 技术栈

```
语言      ArkTS（鸿蒙原生）
UI        ArkUI 声明式
3D        ArkGraphics3D（@ohos.graphics.scene）
推理      llama.cpp（交叉编译为 OHOS .so）+ NAPI
语音      @hms.ai.textToSpeech / @hms.ai.speechRecognizer
存储      @ohos.data.relationalStore（SQLite）
人格      Prompt 工程（无微调，全部在 ArkTS 侧拼装）
```

## 架构

```mermaid
graph TD
    UI["Index.ets<br/>主界面 · 叠层渲染"]

    UI --> Router["AiRouter<br/>端云路由"]
    UI --> Llama["LlamaBridge<br/>本地推理"]
    UI --> Mem["Memory<br/>SQLite 记忆"]
    UI --> Persona["Persona<br/>人格拼装"]
    UI --> Proactive["Proactive<br/>主动搭话闸门"]
    UI --> Speech["Speech<br/>TTS · 离线 ASR"]
    UI --> Proto["TwinProto<br/>指令解析"]
    UI --> Skills["SkillRegistry<br/>技能注册表"]
    UI --> Avatar["Avatar3D<br/>全屏 3D 场景"]
    UI --> React["AvatarReaction<br/>语义动作映射"]

    Router --> Cloud["CloudApi<br/>云端 SSE"]
    Mem --> Rag["Rag<br/>BM25 检索"]
    Proto --> Share["WechatShare<br/>系统分享"]
    Avatar --> Kit["ModelKit<br/>双模型配置"]
    Avatar --> Viseme["Viseme<br/>口型驱动"]

    Skills --> Builtin["skills/ 内置技能<br/>剪贴板 · 系统状态 · 技能清单"]
    Skills --> Bridge["McpSkillBridge<br/>MCP 工具 → 技能"]
    Bridge --> Mcp["McpClient<br/>JSON-RPC over HTTP"]
    Mcp -. "JSON-RPC" .-> McpServer["外部 MCP Server"]

    Llama -. "NAPI" .-> Native["libllamaohos.so<br/>llama.cpp 交叉编译"]
    Cloud -. "HTTPS" .-> API["云端 API"]
```

## 一次对话的数据流

```mermaid
sequenceDiagram
    participant U as 用户
    participant I as Index
    participant R as Rag
    participant M as Memory
    participant P as Persona
    participant L as LlamaBridge
    participant T as Speech
    participant A as Avatar3D

    U->>I: 我喜欢喝什么
    I->>R: search(query, top3)
    R->>M: loadDocs(最近 1500 条)
    M-->>R: 历史文档
    R-->>I: 相关片段 + 分数
    I->>P: 拼人格 prompt
    P-->>I: system prompt（≤200 字）
    I->>M: 拼上下文（6 轮 + 检索片段）
    M-->>I: 完整 ChatML
    I->>L: generateStream
    L-->>I: 流式 token
    I->>T: speak(剥离思考链后的正文)
    T-->>A: 振幅 → 张嘴 + 点头 + 光团
    I->>M: 落库（存剥离后正文）
```

---

## 构建

### 环境
- DevEco Studio 26.0.0.865 或更高
- HarmonyOS SDK API 26（compatibleSdkVersion `26.0.0`）
- 真机或模拟器

### 步骤

```bash
# 1. 配置签名（二选一）
#    A. DevEco Studio → File → Project Structure → Signing Configs → 勾选 Automatically generate signature
#    B. 复制 build-profile.example.json5 为 build-profile.json5，填入你自己的调试证书

# 2. 准备 3D 模型（见下节）
cp <你的模型>.glb entry/src/main/resources/rawfile/Avatar.glb

# 3. 构建
export DEVECO_SDK_HOME="<DevEco>/sdk"
export NODE_HOME="<DevEco>/tools/node"
"<DevEco>/tools/hvigor/bin/hvigorw" --mode module -p product=default assembleHap --no-daemon

# 4. 安装
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

---

## 需要自备的资源

仓库**不包含**以下文件（体积大 / 第三方素材，见 `.gitignore`）：

### 1. GGUF 模型
放在手机上，App 内「📦 模型」按钮导入，会复制到应用沙箱。

推荐：Qwen 系列（0.5B / 1.7B / 3B），Q4 或 Q6 量化。
```
qwen1_5-0_5b-chat-q4_k_m.gguf    约 400 MB
Qwen3-1.7B-Q6_K.gguf             约 1.4 GB
```

### 2. 3D 模型
`entry/src/main/resources/rawfile/` 下需要：
```
Avatar.glb    写实人形，带骨骼（用于行走/坐下/挥手）
nova.glb      可选，VRM 模型，带 viseme 口型（A/I/U/E/O）
```

模型要求：
- glTF 2.0 格式
- 人形骨骼（Hips / Spine / Head / UpperArm / Forearm / Thigh / Calf / Foot）
- 面向 +X 方向（本项目相机在 3/4 前侧）
- 可选：`mouthOpen` morph target（写实版）或 viseme morph target（动漫版）

### 3. llama.cpp 预编译库
`entry/libs/arm64-v8a/` 下需要：
```
libllama.so  libggml.so  libggml-base.so  libggml-cpu.so  libc++_shared.so
```
交叉编译到 OHOS（arm64-v8a）后放入，详见 `README-llama.md`（待补）。

---

## 扩展：加一个技能

动作型请求（「看看剪贴板」这类）走技能系统，不用改 3200 行的 `Index.ets`。

```ts
// skills/MySkill.ets
import { Skill, SkillEnv, SkillResult } from '../common/Skill';

export const mySkill: Skill = {
  id: 'my-skill',
  name: '我的技能',
  // 用户输入「包含」任一触发词就命中 —— 不要求精确匹配
  triggers: ['我的触发器', '另一个说法'],
  run: async (input: string, env: SkillEnv): Promise<SkillResult> => {
    // env.filesDir  沙箱目录
    // env.say(x)    往对话里追加一条
    // env.status(x) 状态栏提示
    return { handled: true, reply: '先生，做完了。' };
  }
};
```

在 `pages/Index.ets` 的 `aboutToAppear` 里注册一行：

```ts
this.skills.register(mySkill);
```

**执行顺序**（`send()` 内）：结构化指令 → 技能 → 聊天。技能抛异常时记 warn 并落回聊天，不会卡住对话。

## 接入 MCP 工具

苏兴是 MCP **Client**：连上外部 server 后，它的每个工具都会自动变成一个技能。

```bash
# 电脑上起测试 server（零依赖，只用标准库）
python tools/mcp_test_server.py
# → MCP test server on http://0.0.0.0:8765/mcp
```

手机上：复制 `http://<电脑局域网IP>:8765/mcp` → 打开苏兴 → **🤖 操控** → 「从剪贴板连接 MCP server」。

连上后：

```
add {"a":3,"b":4}   → 调用 add 工具 → 7.0
你会什么             → 技能清单里会出现这三个工具
```

**触发方式说明**：本地 1.7B 不支持 function calling，没法让它自己选工具。所以走「输入里出现工具名即触发」，参数取输入里的 JSON，没有 JSON 就把工具名之后的文字当单参数。等模型支持工具调用后，这里的 triggers 可以退化成纯 schema。

## 借鉴与致谢

技能框架与 MCP 支持的设计参考了 [shitoudaidi/GDDXX-Jarvis](https://github.com/shitoudaidi/GDDXX-Jarvis)（Windows 桌面贾维斯）的插件与工具接入思路。

**代码未复制**：该项目是 GPL-3.0，苏兴是 MIT。GPL 有传染性，复制代码会迫使本项目改用 GPL。所有实现均为 ArkTS 重写。

具体借鉴的四项体验改进：

| 借鉴点 | 本项目实现 |
|---|---|
| 随时打断（barge-in） | 按下麦克风先停朗读，避免录到自己 |
| 实时字幕 | 朗读时显示当前句，点击即停 |
| 多套皮肤 | 深色/浅色/赛博紫/琥珀/极简（3D 层不参与） |
| 系统状态 | 状态条显示电量与充电 |
| 插件系统 | `common/Skill.ets` + `skills/` |
| MCP 工具接入 | `common/McpClient.ets` + `skills/McpSkillBridge.ets` |

## 项目结构

```
entry/src/main/ets/
├── pages/Index.ets              主界面（聊天 + 工具栏 + 面板）
├── common/
│   ├── Avatar3D.ets             3D 场景（骨骼驱动/粒子/装置/口型）
│   ├── AvatarReaction.ets       语义动作映射
│   ├── ModelKit.ets             双模型配置 + 骨骼名映射表
│   ├── Viseme.ets               口型驱动
│   ├── LlamaBridge.ets          本地推理（NAPI 封装）
│   ├── CloudApi.ets             云端 API（SSE 流式 + 三层超时）
│   ├── AiRouter.ets             端云路由
│   ├── Memory.ets               SQLite 记忆 + prompt 拼装
│   ├── Rag.ets                  BM25 检索（中文 bigram，零依赖）
│   ├── Persona.ets              人格（底线 + 偏好演化 + 情绪）
│   ├── Proactive.ets            主动搭话（闸门/模板/冷却）
│   ├── Speech.ets               TTS + 离线 ASR
│   ├── TwinProto.ets            对话指令解析
│   ├── Skill.ets                技能接口 + 注册表
│   ├── McpClient.ets            MCP 客户端（JSON-RPC over HTTP）
│   └── WechatShare.ets          系统分享
├── skills/                      可插拔技能
│   ├── ClipboardSkill.ets       读剪贴板
│   ├── SystemSkill.ets          时间与电量
│   ├── SkillsSkill.ets          元技能：说出自己会什么
│   └── McpSkillBridge.ets       MCP 工具 → 技能
├── card/                        桌面小组件
├── formability/                 小组件生命周期
├── tools/                       开发辅助
│   └── mcp_test_server.py       MCP 测试服务器（零依赖）
├── cpp/                         NAPI 桥接（napi_init.cpp + CMakeLists）
└── resources/rawfile/           3D 模型（自备）
```

---

## 已知限制（如实）

| 限制 | 原因 |
|---|---|
| **无法自动操作其他应用** | 华为 HarmonyOS 7.0 移除了三方无障碍入口；`ACCESSIBILITY_EXTENSION_ABILITY` 不在 AGC 可申请 ACL 列表内。代码保留在 `accessibility/`，权限开放即可启用 |
| **系统分享无法指定目标 App** | `ShareControllerOptions` 无 `bundleName` 字段，只能弹面板让用户点 |
| **TTS 拿不到真实音频流** | 离线引擎 `onData` 不回调，口型由按字数估算的音节包络驱动 |
| **BM25 检索换说法就漏** | 无 embedding 模型，纯字面匹配。同义词/语义检索需向量库 |
| **小模型表达能力有限** | 0.5B / 1.7B 即使拿到正确上下文也可能答不好，这是模型能力问题 |
| **写实模型口型幅度小** | 只有一个 `mouthOpen` 形变（约 21mm），远处看不清；带 viseme 的 VRM 模型效果更好 |

---

## 许可

MIT License，见 `LICENSE`。

第三方素材（3D 模型、GGUF 模型）各自遵循其原始许可，本仓库不包含。
