# 信使任务技术方案

状态：核心、后台、主应用宿主、管理窗与 Codex 桌面 IPC 已实现；Codex 当前精确版本通过真实只读核对，未实发验收；Claude 延期。核对日期：2026-11-08。范围见[开发计划](courier-development-plan.md)，版本和证据见[兼容记录](courier-compatibility.md)。本文保留设计原因；准确的 Codable 合同以[Models.swift](../native/Sources/CourierCore/Models.swift)、路由以[CourierEndpoints.swift](../native/Sources/RuneService/CourierEndpoints.swift)为准，不是独立稳定的外部 API 承诺。

## 1. 基线与关键决策

信使在指定时间向 Codex／Claude Desktop 的指定已有聊天发送纯文本。保持桌面上下文，不调用 codex exec、Claude headless 或新建后台 Agent 会话代替；也不代替桌面 Agent 批准工具操作。

### 当前可复用的基础

- [Service.swift](../native/Sources/RuneService/Service.swift)：独立后台、一次性定时、唤醒/时钟/网络恢复事件。
- [Storage.swift](../native/Sources/RuneService/Storage.swift)：私有文件权限、拒绝符号链接、原子写和持久化刷新。
- [HTTPServer.swift](../native/Sources/RuneService/HTTPServer.swift)、[ServiceClient.swift](../native/Sources/RuneMenu/ServiceClient.swift)：回环鉴权请求与状态订阅。
- [main.swift](../native/Sources/RuneMenu/main.swift)：主应用、菜单栏、面板生命周期。
- [Runtime.swift](../native/Sources/RuneService/Runtime.swift)：launchd 与服务运行包。当前只复制 Service.app，不能据此假设后台有稳定的主应用副本可自动启动。

CodexTransport 当前仅处理短时账号/额度/重置协议，固定 CLI 0.153.0、默认 15 秒、工作目录为根目录，不承载聊天投递。CLI 版本与两个桌面应用的版本单独管理。

### 主选结构

~~~text
RuneMenu：任务管理窗 + DesktopDeliveryHost（桌面投递主体）
    ↕ 现有 localhost 鉴权请求 / SSE 提示
RuneService：CourierCoordinator + CourierStore + 一次性定时
    └─ RuneEngine：保留原备用重置事务与授权

DesktopDeliveryHost
    ├─ CodexNativeIPCAdapter → 原桌面 owner → 原 thread 的 startTurn
    └─ Claude/AX 框架（真实验证延期）→ 定位/草稿检查/单次按钮
         → 精确目标 → 预检 → 持久授权 → 单次提交 → 关联回执
~~~

已增加 CourierCore 与 DesktopAutomation：前者只含合同/纯调度/状态转换，后者含只读发现、Codex 原生 IPC、AX 封装与模拟。RuneService 依赖前者，RuneMenu 依赖两者；后台不执行桌面 I/O，任务核心不访问聊天或凭据。

不新增第二个常驻后台或 HTTP 端口。Codex 使用已运行桌面的内部 Unix router，不启动独立 App Server。AX 路径的调用者仍是主应用，不能以主应用获权推断 helper 获权。[Apple：当前进程的辅助功能信任检查](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)

## 2. 运行条件与生命周期

首版要求主应用正在运行。关闭面板/任务窗不会终止投递宿主；显式退出主应用会注销宿主并关闭本地发送门禁，后台保留排期，在截止前等待用户重新打开。后台不自动拉起主应用，不注册第二套登录项，不要求关闭锁屏，不持有防睡眠锁或生成防空闲输入事件。

| 动作 | 信使任务 | 自动使用神符 |
| --- | --- | --- |
| 关闭面板或管理窗 | 主应用仍运行，可继续 | 继续原规则 |
| 退出主应用 | 不再取得发送授权；已有发送按实际结果记账，其他等待宿主重连 | 独立后台继续原规则 |
| 暂停所有信使任务 | 立即停止新的发送授权，保存暂停状态 | 不改变 |
| 关闭自动使用神符 | 不改变 | 暂停 |
| 停止/卸载后台 | 宿主断连关门禁，不新增发送；保留历史/未知证据；stop 不等于持久暂停 | 按现有维护流程停止 |
| 重新打开主应用 | 重新注册唯一宿主；已启用且未过截止的任务可继续 | 不新增授权 |
| 用户注销、关机、睡眠、锁屏 | 不承诺发送；恢复后按固定截止时间处理 | 保持原边界 |

主应用退出与调度暂停是不同概念，界面显示「等待主应用运行」及最晚发送时间，不能把后台存活显示成信使就绪。现有「登录时启动」只负责后台 LaunchAgent，不保证主应用投递宿主在线；首版用户登录后需自行打开主应用，本期不新增主应用登录启动机制，也不因创建任务静默开启后台登录启动。

当前 stop 只是停止进程，后续 UI/CLI 操作仍可能按原语义启动服务；持久禁止信使发送应使用信使暂停，不用 stop 冒充。卸载阶段需持久关闭信使授权，防止重装自动恢复。投递宿主独立于面板视图存活，不能复用仅在视图可见时工作的连接。

## 3. 合同与状态模型

任务保存「发送」语义，不保存模型、shell 命令或独立工作目录执行权限。

### CourierTask

| 字段 | 拟定含义 |
| --- | --- |
| id / revision | UUID 与乐观并发版本；编辑携带预期 revision |
| name / text | text 是唯一用户填写的正文；列表与记录使用其空白折叠后的最多 120 字符摘要。name 为兼容 v1 状态保留，新保存时由同一摘要生成，不要求用户另填；实际发送的 text 保持原文，不裁剪或规范化 |
| target | agent 类型、bundle ID、经核对的安装/本地来源标识、稳定聊天 ID、标题/项目提示快照 |
| scheduledAt | UTC 毫秒；相对时间在保存时换算，不在重启后重新倒计时 |
| timeZoneID / scheduleInput | 创建时显示用时区和输入方式，不改变已保存的绝对时刻 |
| deadlineAt | 新建、编辑、复制及重新排期由后台固定为 scheduledAt + 15 分钟；保留 v1 字段兼容，客户端传值不决定新排期。旧 60 分钟任务/历史按原期限读取和恢复，不迁移既有快照 |
| enabled / lifecycle | 草稿、已排期、暂停、终态；界面保存即启用，仍可暂停；草稿状态保留用于复制与 v1 兼容 |
| createdAt / updatedAt | UTC 毫秒 |

目标项目路径仅用于聊天区分，不是后台执行目录。任务沿用目标桌面在发送时的账号和聊天权限，不独立管理登录，也不以备用重置账号推断桌面身份。来源、owner、签名或版本变化时停止/重新核对；登录和额度错误由桌面返回处理，不读取认证文件。当前未实现对桌面账号切换的独立账号 ID 绑定。

新建、编辑或恢复排期必须在保存时重新验证 scheduledAt 大于当前 UTC、相对时长为正、deadlineAt 晚于 scheduledAt。确认期间时间已过则拒绝保存并要求重选，不隐式立即发送。发送中/终态的目标、正文和时间只读，复制才能创建新派发。

### CourierRun 与 Attempt

首版每项单次任务至多一个逻辑 run；编辑尚未发送的排期生成新的 scheduleRevision，对旧未开始 run 作废。runId 与 taskId/scheduleRevision 绑定，不能只靠时间戳去重。

run 保存目标/文本/时间的不可变快照、状态、等待原因、nextAttemptAt、最终证据、人工确认。attempt 保存尝试 ID、宿主会话、服务代次、目标预检结果、发前消息游标及各阶段时间。重试只生成新 attempt，不改变原 run 或截止时间。

~~~text
draft → scheduled ↔ paused
scheduled → preparing → dispatching → sent
preparing → scheduled（确定未按发送，可恢复）
preparing → failed / missed / cancelled
dispatching → unknown（无法确认是否送达）
dispatching → scheduled（仅有可信“未调用发送”回执且仍未过截止）
unknown → sent / userConfirmedNotSent（追加核对结果，不自动重发）
~~~

界面将 preparing/dispatching 统一显示为「发送中」，但内部必须区分。sent 的文字是「已发送」，不是「执行完成」。failed 表示确定未发送且不可自动恢复；missed 表示截止前未进入可能发送阶段；unknown 不因截止到来自动改成 missed 或 failed。

同一聊天存在「尚未核对」的 unknown 时阻断它后续的信使派发，避免在未明状态叠加消息；其他明确聊天可以继续。追加可信核实结果或用户明确确认已发送/未发送后，解除该项核对阻断，保留原始 unknown 证据与时间；确需再发通过新任务完成，不恢复旧 attempt。

容量：正文最大 32 KiB UTF-8、名称 120 个字符、最多 100 项非终态任务。Codex 每次展示最近至多 500 项并返回 hasMore；标题/项目/ID 搜索在全索引过滤后限页，不以总聊天超过 500 拒绝。标题仅展示有省略号的有界摘要，稳定 ID 不截断。实际发送能力仍按版本与实时状态检查；任务条数还受持久文件总字节预算约束。

## 4. 持久化与故障恢复

拟使用数据根目录内的 courier/state.json，单一版本化 envelope 保存设置、任务、run 和未决 attempt；这样授权状态与发送阶段能在一次原子提交内更新，不引入跨文件事务或 SQLite 依赖。复用 PrivateFiles 原语，由后台单写者管理，主应用不得直接改文件。

- 目录 0700、文件 0600，拒绝不安全链接；模拟位于独立 simulation/courier，正式和模拟宿主、来源、端口严格隔离。
- 关键迁移：领取、允许输入、允许发送、确认回执、暂停/删除均先可靠落盘再回应。写失败不授权后续 UI 动作。
- 首版拟保留最多 500 条终态派发记录，并受总字节预算约束，超过任一上限先淘汰最旧普通终态；未知、正在准备/发送和人工待核对证据不自动删。仅持久化任务必需文本，不持久化完整聊天历史、令牌或原始全量日志。Codex IPC 临时接收有界的目标 owner snapshot 以核对身份、忙碌和回执，在内存处理后释放，不写诊断日志。
- 正文不进入普通日志、SSE 摘要或通知；取详情需鉴权。删除任务可移除可调度定义，但不立即删除已有记录；普通终态可按保留规则自动清理，未决证据继续保留，界面提前说明。
- 现有 FileStateStore 读取上限为 16 MiB。CourierStore 独立读取其 envelope，显式采用相同的 16 MiB 硬上限，不能合法写出下次无法读取的文件。常规写入目标不超过 12 MiB，为关键迁移预留空间；attempt 引用 run 快照而非重复复制正文，回执证据最大 8 KiB，发前至少预留 64 KiB 提交空间。写前按实际编码后的字节数核验；淘汰普通终态后仍超预算则拒绝新建/编辑/投递，不清未决证据凑容量。磁盘故障仍可能使发后提交失败，此时保留 dispatching 待恢复，不能重发。
- 文件损坏、schema 不支持、磁盘满或 fsync 失败时关闭信使发送，保留原文件；不重建空状态继续运行。神符状态不与信使文件混用。
- 服务重启：preparing 先撤销旧宿主授权、确认旧操作已停止，再重新排期；dispatching 一律恢复为 unknown，先核实回执，不凭超时创建第二笔发送。旧宿主崩溃的解除规则见下一节。
- 升级/回退检查 courier schema 与 courier protocol 的可读范围；服务和宿主握手声明能力。当前旧程序的 --check-state 只认识神符，不能作为信使兼容证明。已存在信使状态时，维护入口必须先核验候选程序能力；回退到完全不认识信使的版本应拒绝，不拿旧 compatible-v1 放行。新主应用连接旧服务时显示「信使不可用」，不发送。不能恢复旧任务快照。卸载保留数据，重新安装不得仅凭旧 enabled 自动恢复信使授权，应重新确认且保留未决证据。

本地 run/attempt 去重不等于桌面端幂等。不能把 AX 点击或 Codex IPC 的 clientUserMessageId 当作可安全重试的服务端幂等保证，因此不承诺恰好一次送达。

## 5. 后台与投递宿主协议

沿用现有回环 Bearer 鉴权、Origin 检查及有界订阅；它们隔离误连和其他用户，不防同一用户下任意恶意进程。现有 HTTP 请求正文上限为 4 KiB，不能直接承载 32 KiB 文本；拟仅对 /api/courier 路由设置 256 KiB 编码后请求体上限，涵盖 JSON 转义开销，其他接口维持原限制。不得开放任意应用、文件查询或命令执行。正式接口使用固定的目标应用白名单。

拟增加以下路由，以下均省略共同前缀 /api，具体命名在 P1 冻结：

| 接口组 | 能力 |
| --- | --- |
| /courier/status、/courier/tasks、/courier/runs | 摘要、任务管理、记录分页；修改带 revision |
| /courier/settings | 信使总开关、暂停与恢复；不修改神符设置 |
| /courier/host/register、/unregister | 注册唯一 brokerSession，返回 serviceEpoch；不接受另一宿主并行替换 |
| 目标发现（主应用内部） | 用户操作直接调用 DesktopAutomation 只读发现，保存归一化目标；首版未实现服务 /targets 路由，避免额外 IPC 工作队列 |
| /courier/claim、/begin-input | 领取一个 run；存储目标/消息游标和通道预检，批准本次准备阶段；AX 要求空草稿，Codex IPC 不读取输入框 |
| /courier/begin-send | 重新核对总开关、任务 revision、目标、宿主、截止；先提交 dispatching，再给一次性发送许可 |
| /courier/receipt | 追加 sent、definitelyNotSent 或 unknown 回执，重复提交同一回执幂等 |

每个推进请求携带 serviceEpoch、brokerSession、runId、attemptId 和不可猜 nonce。新服务代次拒绝旧授权；旧回执可进入恢复核对，但不能让状态倒退。SSE 只提示「有变化/有到期任务」，不携带可直接执行的发送命令；重复、断流、重连通过读取持久状态恢复。

所有 HTTP 控制请求快速确认，不等待整个桌面定位/提交/核实过程，也不放宽现有连接超时掩盖长任务。聊天发现在主应用异步完成，不经服务中转；SSE 只发脱敏摘要与版本变化，详情通过鉴权接口读取。任务/宿主能力使用单独 courierProtocol 版本，不改写既有神符状态 JSON 的含义。

菜单端的服务发现可能由 SSE 回调和普通异步请求并发触发。连接缓存的完整读取和替换须受同一短锁保护，包含值复制与旧值释放；文件读取和网络 await 不持锁，避免共享 Optional/String 的数据竞争，也不串行等待整个订阅。

当前 PanelModel 订阅只尝试 0、1、5、15 秒后结束，不足以作为投递宿主的恢复机制。宿主需要应用级连接管理：失败后有界指数退避至最多 60 秒，成功后停止重试，服务代次变化重做能力握手和未决对账；退出主应用即取消。宿主重连仅发现已运行服务，不因任务自行拉起已停止的后台；用户再次打开 UI/使用 CLI 仍按现有启动语义处理。

宿主仅在连接正常且取得 begin-send 成功回执后提交一次：Codex 向精确 owner 写出一次 IPC 请求，AX 操作一次发送按钮；不在网络/服务超时后自行重试提交。发送许可最多有效 5 秒且不超过 deadlineAt，必须绑定目标和正文快照。许可丢失、提交可能发生后响应丢失均保守进入 unknown；nonce 不能当作外部聊天的幂等键。

全局只允许一个信使宿主、一个投递 attempt，不同聊天也串行。目标 busy 或 AX 路径有草稿时，在预检后释放投递占用，允许其他到期任务检查；Codex IPC 不占用输入框。复用现有 menu.lock 的主应用单实例约束，后台的 claim/授权/暂停使用显式事务门禁，不以 actor 隔离代替跨 await 互斥。

宿主断线不等于退出：同进程重连先关闭本地旧 gate、确认旧操作停止，才登记新会话；崩溃时通过已记录进程实例（PID 加启动时间）确已退出及 menu.lock 可重新获取确认；无法确认则阻断交接。服务换代需等待上一代最长许可有效期过去，并让存活宿主确认撤销旧 gate 后再授权。旧进程已退出可替代其确认，避免崩溃后永久等待。旧 dispatching 始终保持 unknown；仅 preparing 且确认从未获得有效发送许可时可重新排期。

暂停先持久化关闭新授权，再通知宿主关本地门禁；收到宿主空闲确认后显示暂停已生效。已经获准或提交可能发生的最后一次发送仍需按结果记录，不能承诺暂停撤回。宿主失联时显示「已停止新增发送，最后一次结果待确认」，不能假报全部停止。删除、升级与退出使用同一阶段门禁。

## 6. 时间与调度

保留一个可重排的一次性计时器，取下一次神符检查、信使 nextAttemptAt 和截止处理的最早值；总开关分别计算，不能因神符 enabled=false 清掉信使计划，也不能因信使暂停停止神符检查。

信使协调器独立于 RuneEngine 事务和 ServiceCoordinator.working；桌面 IPC、AX、等窗口或回执只占信使操作队列。调度回调只推进/领取，不等待整个桌面发送完成。

- 所有业务判断使用当前 UTC；相对等待只用于节能。唤醒、时钟变化、宿主重连时重新计算，到发送许可及 IPC 写出/AX 点击前再核对截止。
- 确定未发送的临时条件采用 30 秒、60 秒、2 分钟、5 分钟上限退避，直到固定 deadlineAt。宿主离线等有可靠重连事件的条件优先等待事件，额外预约截止；权限恢复、忙碌结束、草稿清空若无已验证通知，则按该退避有界复查，并接受应用重新激活/用户点击重新检查触发，不能仅等一个不存在的事件。不每秒轮询。
- 网络变化只是重新检查已到期/此前失败条件的提示，不证明目标可用；远期任务不扫描聊天列表、窗口或远程额度。
- 目标未安装、版本不支持、稳定标识消失/冲突属于阻断原因，要求用户重选/检查；不无限后台搜索。
- 逐条或全局手动暂停后恢复已过计划时间的任务必须选新时间，暂停期间到期项不在总开关恢复时悄悄补发。全局暂停记录 pausedAt，恢复时对已过计划时刻的未发送项持久标记「需重新选择时间」，仍保持暂停；未来到期项才恢复原计划。普通宿主重连/解锁在用户保存的宽限期内属于原授权重试。
- 已进入 dispatching 的任务即使超时仍先核实结果，不将其算作未送达并重试。

当前 launchd 后台不是每个信使任务一个 StartCalendarInterval；恢复规则由持久状态主动实现，不能借用 launchd 文档声称现有计时器自动补跑。[Apple：睡眠与定时作业](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/ScheduledJobs.html)

## 7. 适配器接口与数据最小化

DesktopAdapter 提供 discoverTargets（含搜索）、preflight、stageText、pressSend、verifyReceipt、openTarget；解析/恢复由适配器内部完成。每个入口带有界超时与取消门禁；输出归一化结果与脱敏原因，IPC 帧、AX 树和文件读取均有上限。聊天标题和正文不写普通诊断日志。

只读发现由用户打开选择器/搜索触发，任务到期只解析已绑定目标，不维护常驻全量索引。Codex 的主数据库和 WAL 经有界 POSIX 读取及前后 inode/大小/mtime/ctime 核验后复制到私有 0700 临时快照；SQLite 仅在该副本恢复 WAL/创建 SHM，退出删除。原数据库、WAL、SHM 和文件集合不改动；不遍历凭据或 auth 文件。具体文件名不是公共协议，须按版本适配，schema 不符即停。

### CodexNativeIPCAdapter

当前锁定 ChatGPT.app / com.openai.codex 的 26.1103.41825、build 25679，并核对 OpenAI 签名、已选 bundle 可执行路径和 socket 内核对端。使用桌面已运行的 ~/.codex/ipc/ipc.sock，而非其 stdio App Server 的不存在侧路；不新开进程、不调用独立 exec。

1. 4 字节小端长度 + JSON 帧，最大 8 MiB。socket/父目录需用户私有，拒绝链接/替换；getpeereid、LOCAL_PEERPID 和 proc_pidpath 绑定实际桌面。连接、读写和消息循环均有界。
2. initialize v0 → thread-owner-discovery v1 → 定向 read-model-settings v1 → following v1 / state-changed v11。精确核对 local host、conversation ID、owner client 与支持外部输入的能力；未知 schema 拒绝。
3. 实时 snapshot 必须空闲，且无未确认提交、未完成主动目标或待审批请求；发送前再检查，不凭 UI 标题、前台或日志时间猜测。
4. 可信通道确认指定已有目标暂缺 owner 时，可对已签名 bundle 背景定向打开已有 UUID 聊天，再有界等待并重新核对 peer/owner/snapshot。unsafe、peer 变化、未知版本或 busy 不触发恢复；不创建会话、不退回当前聊天。准备时 Codex 未运行则等待。系统打开与退出并发存在竞态，不能声称系统级零启动/零激活。
5. stageText 只在内存暂存，不触碰桌面输入框。Core 的 preflight 使用 inputMode=desktopIPC、composerEmpty=false，不伪称已读取草稿；仅正式 Codex 能使用此模式，旧记录/AX 模式仍需空草稿证明。
6. 持久 begin-send 后，以 stage UUID 作为 clientUserMessageId，通过 thread-follower-start-turn v2 交给同一 owner。inheritThreadSettings=true，不传审批/沙箱/权限覆盖，不添加正文标记。
7. 响应需绑定 request ID、method 和 owner，并取得真实 turn/start 的 turn ID；再从同 owner/同 conversation 的新 snapshot 核对真实 turn ID、params.clientUserMessageId 与原文字节。自造 ID 或请求成功都不能单独判 sent。
8. 发送至多一次。进入提交请求后的部分写、超时、错误响应或断连一律 unknown 并直接 abort fd，不在半帧后再写取消订阅。正常完成才取消 following；unknown 不自动重发。

真实 Swift 发现与 prepare 已只读通过；提交及送达链依据安装包静态契约与合成 Unix socket 测试，尚未真实发送验收。内部协议版本相关，未知版本阻断。详细证据、范围与限制见[兼容核对](courier-compatibility.md)。

### ClaudeDesktopAdapter

- 旧实现读取 Claude Desktop 的 claude-code-sessions（兼容旧 local-agent-mode-sessions）索引，存在 Desktop sessionId、标题、cwd 和 cliSessionId 的映射线索。
- 旧实现通过侧栏标题搜索点击首个匹配项，不证明 UI 当前 sessionId；不能将这一策略直接投入自动发送。
- P0 必须验证发送前的稳定会话关联手段。同标题、重命名、多个 cwd 相同聊天均不可仅靠标题决定；发后查转写不能补救发前选错目标。
- 目标证据可评估 cliSessionId 对应的转写，但需严格解析新增 user 消息 ID/游标、会话关联与完整文本；不能用原始字符串包含匹配。
- 缺少 cliSessionId、索引延迟或证据不可读不直接判成功。原实现缺 ID 时默认 verified=true 的分支不移植。
- 不假定 claude://code/continue 可用；原项目历史记录该深链接被关闭，实际采用搜索。是否存在更可靠入口须按所支持版本验证。

如果一个应用版本无法提供可靠的发前目标关联，不能发送；如果不能获得足以验证送达的证据，该版本不得作为完成支持放行。运行时偶发核实失败进入 unknown，不重复点击。

## 8. AX 路径的输入、发送与回执

以下是保留的 AX 管线，当前 Claude 无通过的生产 profile。Codex 使用上一节 IPC，不执行下列输入框操作。

1. 检查实际 AX 调用进程已获权、会话未锁定、目标安装/版本/来源明确、宿主门禁打开。
2. 定位已绑定聊天，复核稳定身份、前台应用/窗口和运行状态。用户有未提交草稿或 Agent 忙碌时等待，不清空草稿、不排队插话。
3. 保存目标消息的发前游标/已见 ID，在 begin-input 成功后通过 AX 写入文本并读回精确校验。首选不用剪贴板；P0 若只能靠剪贴板需另列明确方案，不直接复制旧项目只恢复文本的做法。
4. 再核对聊天、窗口、正文与用户输入；取得 begin-send 的持久许可，检查本地暂停门禁和截止，执行一次发送按钮 AX action，不以回车替代。
5. 在拟定 30 秒有界窗口内读取目标关联证据。按钮 action 返回成功、输入框清空、前台正确、全局新请求均不足以独立判 sent。
6. 提交回执并等待后台持久化确认。回执通信失败只重传回执；不再次操作发送。

definitelyNotSent 只用于确定尚未调用发送 action 的情况；一旦调用，即使 AX 返回错误或输入框未清空也可能已被处理，应核实或 unknown，不能按「按钮失败」直接重试。

用户在准备阶段改变输入/切窗时取消，保留用户内容；清理仅限当前目标未变且草稿仍精确等于本次写入文本。无法证明归属则不清理，显示需检查输入框。不能原子锁住第三方 UI，P0 要验证竞态和取消路径，不能宣称完全排除用户同时操作风险。

发后证据优先使用目标会话的新消息 ID。纯文本相同且用户也可能同期发送时，不能仅凭计数和时间窗口认定本次；不足以关联就 unknown。消息文本不自动添加隐藏标记或任务号来解决关联，除非以后另行设计并获得用户明确同意。

## 9. 权限、兼容和分发

只有 canSend 且 requiresAccessibility 的适配器才在用户明确启用时请求辅助功能；Codex 不查询/申请 AX。AXIsProcessTrustedWithOptions 的提示是异步，不代表已经获权，实际操作仍检查可访问性。AX 由 local.reset-rune.desktop 调用，不复制 UsageWatch 的 TCC 授权、证书或用户数据。

AX 路径的 macOS 14+ 协作激活与 macOS 13 回退仍需真实验收。来源的 NSApp.yieldActivation(to:) 是 14+，不能直接放进 13 目标；AX 实际前台检查不可省略。Codex IPC 不依赖此激活路径。[Apple：AppKit macOS 14 发行说明](https://developer.apple.com/documentation/macos-release-notes/appkit-release-notes-for-macos-14)

两端版本策略：P0 记录应用 bundle ID、桌面版本/build、安装渠道、本地 schema、目标核对规则和回执规则；已验证范围之外默认不自动发送，显示需兼容性更新。不能以 CLI 固定版本替代桌面兼容矩阵。

npm/DMG 和升级后需实测主应用路径变化是否影响 TCC，权限失效时提示重授，不绕过系统或静默请求 helper 权限。本期不新增 Apple Events/屏幕录制权限；若 P0 证明必要，应解释具体调用、更新方案与用户流程后再实现，不能提前声称已有权限足够。

本次不变更签名、最低系统版本、打包脚本或应用身份。产品已选择的 Developer ID 分发继续使用；不根据旧项目 README 推断所有 AX 应用的商店政策。

## 10. 验证与尚待冻结事项

### 自动化

- CourierCore：假时钟、输入校验、相对时间固定化、截止、暂停恢复、两种功能开关独立、状态转换和公平调度。
- CourierStore：关键阶段前后故障、坏文件、只读/磁盘满、重启与 schema 回退；未知证据不丢失。
- 协议：重复 SSE、claim/receipt 重放、旧服务代次、旧宿主、新宿主争用、begin-send 响应丢失；不能出现第二次提交。
- 适配器：合成索引、Unix socket、转写与可注入 AX 驱动；错误目标、同名、忙碌、用户竞态、回执延迟和重复正文；AX 路径另核对草稿与控件。
- 生命周期：关闭窗口/退出主应用、后台停止重启、宿主断开、升级/回退，以及信使执行不阻塞神符定时。

mock 模式不得发现或操作真实 Codex/Claude 应用；测试适配器仅允许专用测试 bundle ID，目录明确注入，不默认回退真实 home、真实数据库或真实 AX。

### 实际环境门槛

Codex 已有当前精确版本的静态契约与生产 Swift 只读核对；真实提交/送达、锁屏、macOS 13/Intel 实机和发布路径仍需验收。Claude 已延期，发前身份、AX/TCC 与送达仍待验证。后续真实发送须另行授权并使用专用合成聊天，不在工作聊天测试，不使用真实备用重置。只读核对、合成链路和真实发送分别记录。

性能验证关注：主应用隐藏但宿主在线的 CPU/内存、无任务和远期任务的扫描次数、单次定位/核实耗时；不能以零周期定时器声称无目标应用运行成本。完整验收见[开发计划](courier-development-plan.md#5-验收矩阵)。

当前 Codex 代码可在用户明确启用后使用已锁版本的同桌面路径，实时门禁失败则等待/阻断。canSend 表示存在该代码路径，liveValidationRequired 明示未实发验收。Claude 继续阻断。测试结果见[验收记录](acceptance-matrix.md#信使任务开发验证)；本轮没有真实输入或发送。
