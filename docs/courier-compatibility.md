# 信使桌面兼容核对

核对日期：2026-11-08。**Codex 已实现同桌面 owner 的本机 IPC 投递路径，并通过真实只读核对；本轮未发送真实消息，真实投递验收仍未完成。Claude 按用户要求延期，真实发送保持阻断。**

## 当前支持范围

| 项目 | Codex | Claude Desktop |
| --- | --- | --- |
| 已检查安装包 | `ChatGPT.app` / `com.openai.codex`，26.1103.41825，build 25679 | `Claude.app` / `com.anthropic.claudefordesktop`，4.29.0 |
| 当前生产代码 | `CodexNativeIPCAdapter`，只放行上述精确版本/build；其他版本阻断 | 发现入口与可注入 AX 驱动保留；生产投递无已放行 profile |
| 身份边界 | 已运行桌面的 Unix router → 精确 conversation ID → 明确 owner client → owner snapshot | 发前稳定会话身份尚未取得，不能依赖标题匹配 |
| 本轮证据 | 生产发现、签名/peer 绑定、initialize、owner discovery、read settings、目标 snapshot 的真实只读核对通过 | 仅早期静态/只读线索；后续真实验证延期 |
| 真实输入/发送 | 未执行 | 未执行 |

`canSend=true` 表示存在已锁版本的代码路径，实际每次投递仍需重新检查 socket、owner、能力、空闲状态和发送许可。`liveValidationRequired` 是未实发验收的说明，不代表已完成线上发送验证。Codex 不要求辅助功能权限，也不需要切到前台；Claude 后续的 AX 路径另行验证。

目录中的旧聊天不保证当前有桌面 owner。只有已完成可信 IPC initialize 且 owner discovery 明确返回 no-client-found 时，预检才重新核对源索引仍存在该 UUID，并向已签名、锁版本的同一应用定向请求打开 `codex://threads/<id>`；每次预检最多一次，导航回调最多等待 3 秒，取消/超时一次性结束且忽略迟到回调，随后丢弃旧连接、重新检查 peer/owner/snapshot，最多三次有界等待。不会新建聊天或回退当前聊天。unsafe socket、对端变化、版本不支持或目标忙碌均不触发该导航。

恢复使用 OpenConfiguration 的 activates=false、createsNewApplicationInstance=false、allowsRunningApplicationSubstitution=false，并复核原进程 PID 及打开回调。常规 Codex 未运行/无 socket 时等待，不以恢复启动应用；但系统 open 与进程并发退出之间存在极窄竞争，可能启动同一受信应用。回调 PID 变化会拒绝继续，不能把 running guard 宣称为系统级原子“不启动”保证。目标应用处理深链接仍可能调整窗口，本功能不要求它处于前台，不承诺从不发生导航。

## Codex 的本机通道

原生 App Server 子进程在本机没有 `--listen`，也未发现其 TCP 监听；不连接独立 CLI、不另开 App Server。桌面主进程实际监听 `~/.codex/ipc/ipc.sock`，安装包中存在 IpcRouter/IpcClient 与 thread owner/follower 协议。这是**版本相关的桌面内部协议**，不是承诺长期稳定的公共 API。

| 消息 | 当前版本 | 用途 |
| --- | --- | --- |
| `initialize` | 0 | 临时注册信使 client，取得 client ID |
| `thread-owner-discovery` | 1 | 对明确 conversation ID 查找现有桌面 owner |
| `thread-follower-read-model-settings` | 1 | 定向 owner 读取当前设置/就绪线索 |
| `thread-stream-following-changed` | 1 | 临时订阅一个目标 owner；结束时取消 |
| `thread-stream-state-changed` | 11 | 获取精确目标的 snapshot，核对身份、忙碌和未决请求 |
| `thread-follower-start-turn` | 2 | 经最终许可后调用同一 owner 的正常 startTurn 路径；本轮仅实现，未真实调用 |

帧为四字节小端长度加 UTF-8 JSON，应用端上限 8 MiB。生产连接要求 socket 属于当前 UID、无其他用户权限，父目录为本用户私有目录；通过内核 peer UID/PID、进程可执行路径绑定正在运行的所选桌面程序，并核对其签名 Team ID `2DC432GLL2`。不会启动或修复目标 router，找不到正确对端就停止。

同一 owner 已处于 following 状态时，再发 following=true 仍会返回新 snapshot；这由安装版 `handleThreadStreamFollowingChanged` 的分支支持，不依赖旧缓存。每次实际发送前再次发现 owner 和读取 snapshot。非 idle、未知状态、缺失的 turns schema、resuming、未终结 unconfirmed submission、可见 inProgress turn、active/未知 goal 或未决 approval 都拒绝发送。

## 请求、权限与回执的静态依据

安装版 `thread-follower-start-turn` handler 调用 `e.startTurn(conversationId, turnStart)`，返回嵌套的 `result.result.turn.id`；不是另外创建工作会话。owner 的 startTurn 先检查 request.threadId 与 conversationId 相同，使用调用方的 clientUserMessageId（未提供才生成），并经其现有 prepare/权限继承路径发送。

信使只提供 thread ID、原文 input、`clientUserMessageId=stageID` 与真实存在的 `context.inheritThreadSettings=true`；不传 approvalPolicy、approvalsReviewer、sandboxPolicy、permissions、cwd 或模型覆盖值。读 model settings 本身不证明权限继承；继承依据是安装版 owner 的 request prepare/fallback 代码。真实账号的审批保持仍未实发验收。

接受态代码将服务端返回的真实 turn ID 写入此前按 clientUserMessageId 保存的 turn，保留 params.clientUserMessageId 和 params.input；桌面 IPC 的 snapshot 投影保留可枚举状态字段。因此回执实现同时要求精确 owner/requestId 的成功响应，以及后续目标 snapshot 中的真实 turn ID、clientUserMessageId 与原文一致。自己的 UUID、相近时间或相同文本均不能单独证明送达。

发送帧在最终许可检查前编码；owner/空闲检查后，再跨回主应用检查门禁，且在真实写出前/分片写出时检查固定截止。只发送一次。进入可能写出的阶段后，任何错误、部分帧、丢响应、owner 变化或核实不足都断开并记为 unknown，不在半帧后追加清理消息，不自动重发。clientUserMessageId 用于关联，不据此承诺外部恰好一次。

Codex 路径不操作桌面输入框。安装版 owner 管理器的 startTurn 路径与 composer 交互分离；但完整 UI effect 和真实草稿保留未实发验收，不声称已证明任何页面都原样保留草稿。

## 只读实测与发现可用性

使用新 Swift 生产代码进行一次最小 harness：精确版本匹配；生产 `discoverTargets` 成功返回有界的最近 500 项；经过实际签名与 peer 检查，`CodexIPCSession.prepare` 成功取得目标 snapshot，owner、conversation ID、state ID、turns/runtime schema 均匹配；目标当时 active，正确得到非空闲判断。没有 stageText、pressSend、start-turn、模型请求或备用重置。订阅已取消、连接已关闭。输出只含布尔/数量，不记录真实 ID、正文、标题、账号或令牌。

实际索引超过 500 项，且 provisional title 可能是长首条 prompt。因此 500 是每页上限，不是总量门槛：初始显示最近 500 并返回 hasMore，标题/项目/ID 搜索在 SQL LIMIT 之前绑定过滤；UI 明确提示继续搜索。展示标题最长 512 字符并以省略号标记，稳定 ID 不截断。

发现使用一致性检查的私有 DB+WAL 临时快照，原文件只通过只读/no-follow 文件句柄复制；前后核对 inode、device、size、mtime、ctime，变化时有界重试。SQLite 只在 0700 私有副本恢复 WAL/创建 SHM，完成后删除。不会删除或 checkpoint 用户 WAL，不修改原 DB/WAL/SHM，也不因任何非空 WAL 永久拒绝发现。搜索参数绑定、通配符转义、超页查找与原文件不变有合成测试。

## 保留的 AX 与 Claude 线索

早期 Codex AX 路径在已有线程导航后仍只见 `app://-/index.html`，没有可关联的当前 thread ID 或 composer；因此改用上述桌面 owner 通道，而非放宽标题门槛。Claude 旧 continue 深链接后仍停在 new 页面；没有完成已有 Code 聊天的可靠定位。

临时 AX 观测准备已收尾：Claude ManualAccessibility 恢复原 false，返回 success；Codex EnhancedUserInterface 恢复原 false，setter 虽返回 notImplemented，读取确认已恢复。未改持久设置或系统授权。后续没有继续 Claude 真实核对。

## 静态产物证据与局限

采用 reverse-engineer-anything skill 和 REA 6.5.0 CLI fallback，没有修改客户端配置或安装反编译引擎。Evidence 保存在忽略的 `.build/courier-audit/`，不提交安装包源码。

- Codex ASAR SHA-256：`766faa8a3da8f6d6902c751d5b6b29395a6c5bf3c966ef7f8ca3f629d931df85`。IPC 定向分析 Evidence：`ev_7bd02058e4ca00d7d8bed75049f752c10f9781eb21c6a7be1442c2d7729414f3`；选择 early-bootstrap 的 339、854 与主模块，其余 10877 项未做关系分析。
- 关键普通文本定位：339 模块的 IpcRouter/IpcClient 与 owner 注册；854 模块约 offset 945192 为重复 following 快照、13583xx 为 client ID 继承、12578xx 为 params、12747xx 为接受态真实 turn ID、1451280 为 follower handler、43978xx 为 snapshot 投影。这些是该包对应的静态线索，不是动态发送证据。
- 早期 preload Evidence 为 `ev_b8ce056ee63f229ea97753041dbb605db8a98919608277a7a076376b331b5937`；Claude 静态 Evidence 为 `ev_66598ce1a5761b314bafd40f281a29386004e16e9c0183f06b536c00fa23fdf4`。
- 两包均有 unpacked native 文件声明完整性与实际字节矛盾；严格分析曾拒绝，随后按工具支持的 record-and-continue 保留为 untrusted。未据此推断安全状态，也未从那些 native 文件推导本协议。静态图覆盖不完整，不把未发现解释为不存在。

当前只读结果不覆盖未来桌面版本、其他架构/系统、应用重启后的所有状态或真实发送。实际投递、审批保持、桌面同步、草稿和后续结果仍需以后单独记录，不能将本轮合成测试和只读握手当作已实发验收。
