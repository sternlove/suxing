# scripts

| 脚本 | 用途 |
|---|---|
| `build.sh` | 带前置检查的构建（环境变量 / 签名配置 / 模型文件），加 `--install` 可编译后直接装机 |

```bash
export DEVECO_SDK_HOME="<DevEco>/sdk"
export NODE_HOME="<DevEco>/tools/node"

./scripts/build.sh              # 只编译
./scripts/build.sh --install    # 编译 + 装机 + 启动
```
