# Codex 适配

`index.js` 通过官方 Codex App Server 的稳定协议读取账号、Codex 额度桶与备用重置库存，也能发送指定备用重置的兑换请求。它复用 Codex 的本机登录存储，由 Codex 处理文件或钥匙串模式。Bottled Reset Rune 不直接打开登录文件，也不传入 API 密钥。

- `createCodexSource()` 返回只读来源。并发读取合并，每次读取使用独立的 stdio 会话。仅发送 `initialize`（`experimentalApi: false`）、`initialized`、`account/read`（`refreshToken: false`）和 `account/rateLimits/read`。已登录的 ChatGPT 账号才会查询额度。
- `createCodexSource({ allowConsume: true })` 返回 `mode: 'live'`，额外提供 `consume({ id, key, identity, startsAt, expiresAt, maySend })`。来源在同一个独立 App Server 会话内重新读取账号、额度和具体条目，再核对账号。确认账号、库存条目与到期时间一致并且仍在窗口内，且至少一项 Codex 窗口有已用额度、调用方仍允许发送时，才发出显式 `creditId` 和固定 UUID 的兑换请求。
- 结果为 `reset`、`already-redeemed`、`nothing-to-reset` 或 `no-credit`。发送前确定失败标为 `notSent: true`，发送后无可靠结果则由调用方按不确定处理。恢复尝试同样要求读到原条目。
- `MINIMUM_CODEX_VERSION` 定义最低支持版本 `0.153.0`（含），`BASELINE_CODEX_VERSION` 记录已验证的协议基线。版本按 SemVer 判断：低版本及最低版本的预发布版拒绝，构建元数据不影响顺序，更高版本的预发布版可继续核对协议。范围内的版本仍须通过实际握手和关键字段合同。非基线版本兑换前，在空白临时 HOME / CODEX_HOME 中生成稳定 schema，仅确认兑换方法接受显式 `creditId`、`idempotencyKey` 且保留已知结果；按二进制路径和文件指纹缓存成功核对。无法确认时在读取账号或发送兑换前拒绝，绝不靠真实兑换探测能力。新增可选字段不会阻断，缺失身份、目标或额度条件时仍拒绝发送，不能声称已验证所有未来版本。`RESET_RUNE_CODEX_PATH` 可指定可信的绝对可执行路径，否则查找 PATH、常见 macOS 安装目录和 `~/.local/bin`；不自动下载、切换运行时或放宽兑换门禁。
- `normalizeSnapshot()` 的库存总数来自服务端 `availableCount`，`creditsKnown` 区分仅有总数和后端提供了明细。过期时间统一为毫秒，缺失或无效为 `null`。绑定需要额度响应中的工作区账户标识、明确的 Codex 额度桶与 `account/read` 返回的邮箱；`scope` 是 Codex 池名与邮箱摘要，供内部比较使用。UI 的 `remainingPercent` 保留主窗口含义，调度使用两窗口可知剩余额度的最小值 `redeemablePercent`。
- `CodexSourceError.code` 是对外错误标识。兑换前发现方法或参数不兼容时返回 `runtime-incompatible`；兑换请求写出后的同类错误仍按未知结果处理。进程 stderr、RPC 错误正文和未知消息不会进入应用日志或状态。

运行 `node --test test/reference/codex/index.test.js` 检查模拟握手、版本与超时、读取归一化、隔离 schema 核对及指纹缓存、兑换参数与结果、预检拒绝和不确定响应。测试仅启动合成 App Server，不接入真实登录。[OpenAI Docs 的兑换接口](https://learn.chatgpt.com/docs/app-server#8-earned-rate-limit-resets-chatgpt) · [基线版本的账户响应实现](https://github.com/openai/codex/blob/rust-v0.153.0/codex-rs/app-server/src/request_processors/account_processor.rs#L1131-L1213)
