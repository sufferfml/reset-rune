任务 CODEX-167：把 Codex 兼容白名单从单一 0.153.0 扩展为 {0.153.0, 0.167.0}，升级本机 Codex CLI 到 0.167.0，重建并重新安装正式版供用户验收

目录 C:\Users\morrow\coding\reset-rune，分支 windows-port。注意：
- 一个 24 小时 soak 正在以计划任务 "\Bottled Reset Rune\Soak" 运行（mock 三进程、数据目录 .build\soak-20261108-213525），**不要动它**；也不要用 mock 模式跑任何会抢 mock 单实例的冒烟/测试（cargo test 的单元测试不涉及 mock 单实例，可以跑；smoke-windows-lifecycle.ps1 / smoke-windows-ui.ps1 / p5-faults 不要跑）。
- 正式版已安装在 %LOCALAPPDATA%\Programs\Bottled Reset Rune，后台任务 "\Bottled Reset Rune\Bottled Reset Rune" 在运行。
- 绝不执行 enable/bind；不读取 auth.json。

协调者已在 Mac 上 diff 过 openai/codex rust-v0.153.0 与 rust-v0.167.0 的 app-server-protocol：account/read、account/rateLimits/read、account/rateLimitResetCredit/consume、account/updated、initialize.capabilities.experimentalApi、`--listen stdio://` 全部一致；0.167.0 仅新增可选字段 GetAccountRateLimitsResponse.ordinaryUsageAllowed、RateLimitSnapshot.normalModelSlug、Account(chatgpt).workspaceName、GetAccountResponse.workspaceRouting（experimental）、新增账号类型 gcp。归一化忽略未知字段、非 chatgpt 类型视为无身份，因此协议层无需改动。

步骤：
1. 升级 Codex CLI：先 `codex --version` 记录当前（0.130.0）；`npm i -g @openai/codex@0.167.0`（代理卡住则清除 http(s)_proxy 重试）；确认 `codex --version` 输出 `codex-cli 0.167.0`；用 where.exe codex 与 Get-Command 记录实际 exe 路径，并确认 %LOCALAPPDATA%\OpenAI\Codex\bin\codex.exe 是否也存在且版本（若那份仍是旧版本且 PATH 优先级更高，在报告中指出；RuntimeResolver 的候选顺序是 PATH 优先）。
2. 白名单：在 windows/crates/codex-transport 中把 `supported version` 常量改为集合 `SUPPORTED_CODEX_VERSIONS = ["0.153.0", "0.167.0"]`，匹配规则仍是精确 "codex-cli <v>"；错误码不变。同步修改：
   - native/Sources/CodexTransport/CodexSource.swift 的 `supportedCodexVersion` → `supportedCodexVersions: Set<String>`（这是唯一允许改 native/ 的地方；只改这一处与其用法，不改业务逻辑）；
   - test/reference/codex/index.js 的版本检查；
   - test/reference/codex/fixtures/app-server.mjs：保持 `--version` 默认输出 0.153.0（已有 wrong-version 模式输出 99.0.0），新增模式 `version-167` 输出 `codex-cli 0.167.0` 并照常工作；
   - native/Sources/CodexTransport/README.md 与 windows/README.md、docs/windows-technical-design.md §4 中"固定版本"的描述改为"固定版本白名单 0.153.0 / 0.167.0"（docs 只改措辞，不改结构）。
3. 测试：codex-transport 新增用例：fake-codex 以 version-167 模式 → read 成功；wrong-version 仍 runtime-incompatible。`cargo test --workspace` 全通过；fmt/clippy -D warnings。`node --test test/reference/codex/index.test.js` 在本机 Node 下尽量运行（Windows 上 fixture 的 sh shebang 不可用则记录为"参考测试需在 macOS 运行"）。
4. 重建与重新打包：按 windows/README.md 的命令运行 scripts/package-windows.mjs（版本保持 0.1.2，或用 RESET_RUNE_VERSION=0.1.2 明确），再运行 scripts/verify-windows-artifacts.mjs 的静态部分（**跳过全链路安装/升级冒烟**，因为它会用 mock 单实例并卸载正式版；若脚本无跳过参数则只核对 SHA256SUMS、VersionInfo、PE 导入）。
5. 重新安装正式版：静默卸载当前版（uninstall.exe /S，保留数据目录）→ 安装新 setup.exe /S → `reset-rune.exe start` → `reset-rune.exe status`。预期：runtime 解析到 0.167.0，status 不再是 runtime-incompatible；若本机 Codex 已登录则 snapshot.identity 有 email（**不要输出 email 明文，脱敏为前 2 字符+***）、availableCount 等；若未登录则 identity 为 null，这也算通过。把 status JSON（脱敏）贴回。然后 `reset-rune.exe ui` 拉起托盘。
6. 提交 "Codex: accept 0.167.0 alongside 0.153.0; upgrade local Codex CLI"（不 push）。最终报告 ≤ 40 行：Codex 版本与路径、改动文件、测试计数、产物 SHA-256、status 摘要（脱敏）、决策、未完成项。
