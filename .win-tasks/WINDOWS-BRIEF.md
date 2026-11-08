# Windows 开发执行简报（由 Mac 协调者下发）

你是在 Windows 11 x64（morrow-pc）上执行 Bottled Reset Rune Windows 版开发的工程师。本文件是所有后续任务的共同上下文，先读它，再读仓库文档。

## 仓库与文档

- 仓库：`C:\Users\morrow\coding\reset-rune`（origin = github.com/sufferfml/reset-rune）。所有工作在分支 `windows-port` 上提交；**不要 push**，不要改 `native/`（macOS Swift 实现）里的业务代码。
- 必读：`AGENTS.md`、`docs/windows-development-plan.md`、`docs/windows-technical-design.md`、`native/README.md`、`native/Sources/CodexTransport/README.md`。
- 行为基线（必须逐行对照移植）：`native/Sources/RuneCore/{Contracts,State,Engine}.swift`、`native/Sources/CodexTransport/{Snapshot,CodexSource}.swift`、`test/reference/core/*.js`、`test/reference/codex/*.js`。
- 共享合同向量：`test/contracts/native-hash-vectors.json`、`test/contracts/native-engine-vectors.json`。Rust 测试必须加载这两个文件并逐条通过，不得修改向量。

## 硬性边界（违反即失败）

1. 禁止使用真实账号、真实 Codex 登录或真实兑换端点做任何测试。测试只用合成 App Server（可参考 `test/reference/codex/fixtures/app-server.mjs`）、假时钟、隔离 `RESET_RUNE_DATA_DIR`、空白 `CODEX_HOME`。
2. 不读取 `auth.json`、不碰 Windows Credential Manager、不复制 token。
3. 意图先持久化再发送；成功回执先持久化再重读；`notSent` 只用于能证明未发送的情况；未确认结果保留原 credit ID 与幂等键并阻断后续。
4. 默认关闭；`enable`/`bind` 需 `--confirm`；手动刷新只读。
5. 不注册 SYSTEM 服务、不要求管理员；计划任务为当前用户 InteractiveToken。
6. 不改 DSH 配置、不动其他项目。

## 工具链

- Rust：`%USERPROFILE%\.cargo\bin`（stable-x86_64-pc-windows-msvc 1.99，含 rustfmt/clippy）。调用 cargo 前把该目录加入 PATH。
- MSVC：VS 2022 Build Tools（C++ 工作负载）；构建前若 link.exe 不在 PATH，用 `"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat" -arch=x64` 或 cargo 的自动探测（cc crate / rustc 会自动找 MSVC，通常无需手动）。
- NSIS：`C:\Program Files (x86)\NSIS\makensis.exe`。
- Node：Codex 自带的 node（`%LOCALAPPDATA%\OpenAI\Codex\bin\node.exe`），用于跑合成 App Server fixture。
- **网络**：本机有 127.0.0.1:7897 代理；cargo 下载 crates 若卡住，在当前进程清除 `http_proxy/https_proxy/HTTP_PROXY/HTTPS_PROXY/all_proxy/ALL_PROXY` 再试。

## 工作方式

- 每个任务都是有限的；A2A 单次交互 10 分钟内必须返回。**编译/测试等耗时 >5 分钟的命令，用 `Start-Process -WindowStyle Hidden` 后台跑并把输出 Tee 到 `C:\Users\morrow\coding\reset-rune\.build\logs\<name>.log`**，然后立即返回“已启动，PID、日志路径”；下一条任务会来查日志。
- 每个任务结束时：`git add -A && git commit -m "<阶段>: <摘要>"`（在 `windows-port` 分支）。回复里给出 commit hash、变更文件列表、测试输出摘要（通过/失败数）、尚未完成项。
- 不确定的技术细节，优先遵循 `docs/windows-technical-design.md`；文档没写的，用最简单可验证的实现，并在回复中标注“决策：…”。
- 把每阶段的实测结果写到 `windows/docs/P<n>-report.md`（中文），包括：做了什么、证据（命令+输出摘要）、未达项。

## 目标目录结构（技术方案 §2）

```
windows/
  Cargo.toml  Cargo.lock  rust-toolchain.toml  README.md
  crates/
    rune-core/        业务状态、授权摘要、调度、引擎（移植 RuneCore + 合同向量测试）
    codex-transport/  codex.exe app-server stdio JSONL、发现、归一化（移植 CodexTransport）
    rune-storage/     rusqlite bundled SQLite（WAL+FULL），state/platform_settings 表，user_version
    rune-platform/    SID、命名管道、文件锁、Task Scheduler、计时器、电源/网络事件、通知、Job Object
    rune-app/         二进制 reset-rune.exe：CLI / --serve worker / --tray 角色，Win32 面板
    rune-launcher/    短时稳定入口（P4）
  packaging/          NSIS 脚本、manifest、ICO、许可
  tests/              合成 App Server 夹具（Node）、平台与生命周期测试
scripts/
  package-windows.mjs  verify-windows-artifacts.mjs  smoke-windows-lifecycle.ps1
```

## 阶段

P0 可行性样机 → P1 核心与存储 → P2 后台与 CLI → P3 托盘/面板 UI → P4 分发 → P5 验收。每个阶段的具体任务由 Mac 协调者逐条下发。
