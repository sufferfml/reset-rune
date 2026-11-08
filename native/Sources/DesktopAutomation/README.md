# DesktopAutomation

信使桌面投递边界。入口是 `DesktopAdapters.make(agent:mock:)`，由主应用调用；不运行模型、不读登录令牌、不承担后台排期。产品约定见[技术方案](../../../docs/courier-technical-design.md)，版本证据与尚未放行的范围见[兼容核对](../../../docs/courier-compatibility.md)。

| 文件 | 职责 |
| --- | --- |
| `Types.swift` | 独立于 CourierCore 的目标、游标、预检、一次性许可与回执合同 |
| `TargetReader.swift`、`CodexIndexSnapshot.swift` | 有界本地索引发现、分页搜索与一致私有 WAL 快照；不改原数据库 |
| `CodexIPC.swift` | 桌面原生 IPC 帧、内核对端身份、owner/snapshot 协议与一次发送 |
| `CodexNativeIPCAdapter.swift` | 锁版本的 Codex 同桌面聊天投递；不需要 AX 或前台输入框 |
| `DeliveryAdapter.swift` | 可注入驱动的准备、原文读回、单次发送和关联回执流程 |
| `AccessibilityDriver.swift` | 有界 AX 操作；必须提供经验证的版本 profile 和稳定身份解析器，不使用标题匹配 |
| `DesktopAdapters.swift` | 主应用权限入口、真实适配器和严格独立的内存模拟 |

工厂为 Codex 优先选择 `CodexNativeIPCAdapter`：仅放行已核对的 26.1103.41825/build 25679，其余版本拒绝；每次重新检查 socket/owner/目标状态。`requiresAccessibility=false`，`liveValidationRequired` 说明尚未真实发送验收，不是 fatal blocker。真实发现与新 Swift IPC prepare 已只读通过，本轮没有真实输入或发送。Claude 仍阻断生产发送，按用户要求延期。通用 AX 驱动保留，但没有注册生产版本 profile。

Codex 索引以 POSIX 只读句柄创建一致性核对的私有 DB+WAL 副本，SQLite 只恢复自己的副本；不写原 DB/WAL/SHM、不 checkpoint 原库。初始返回最近 500 项并以 hasMore 明示更多；`discoverTargets(matching:)` / `discoverTargets(query:)` 按标题/项目/ID 在 LIMIT 前参数绑定搜索。标题是带省略号的有界展示摘要，ID 不截断。Claude 只读取明确索引目录的 `local_*.json`；同 ID 跨来源冲突拒绝，不搜索凭据。

`DesktopDeliveryAdapter` 不重试发送按钮。许可绑定 stage ID、最长五秒；按下前消耗本地 stage。AX 调用返回错误仍可能已被目标处理，归为结果待确认。字节不同的 Unicode 内容不会被视作原文一致；同样文字和相近时间若无本次提交的关联证据，也不会判已发送。

Codex 的 stageText 仅内存准备，不写 composer；pressSend 使用桌面 owner 的正常 startTurn，原文不注入隐藏标记，不覆盖审批/模型/目录。回执要求 owner 成功响应的真实 turn ID 与后续 snapshot 的 clientUserMessageId/原文关联。可能写出后的任何失败立即 abort，不自动重发。

可信 initialize 后仅遇明确 ownerUnavailable，预检可核对索引中的已有 UUID 并向签名锁定的同一应用请求一次后台深链接恢复。导航等待有三秒上限，取消/超时结束且忽略迟到回调；之后新建 IPC 连接重新核对 peer/owner/snapshot，最多三次 owner 等待，不新建/回退聊天。普通 app 未运行、坏 socket/peer、版本不支持和忙碌状态都不触发恢复。系统 open 在并发退出时可能重新打开受信应用，故回调 PID 改变即拒绝继续；没有原子零启动保证。

测试使用 `DesktopAutomationTests` 的假驱动、合成索引和临时目录。模拟目标只接受 `local.reset-rune.mock.codex` / `local.reset-rune.mock.claude`，不发现真实应用、不调用 AX、不读取真实 home。测试不得以真实聊天或备用重置验收。
