# Bottled Reset Rune 原生实现

原生菜单栏界面、后台服务和 CLI 面向 macOS 13+；神符功能通过固定兼容版本的官方 Codex App Server 操作，信使功能使用各目标桌面适配器。npm 与 DMG 使用相同的执行核心，不携带浏览器或 Node.js 常驻运行时。

「信使任务」已有本地合同、调度、主应用投递宿主、原生管理窗和内存模拟适配器。Codex 采用当前桌面版本的本机聊天通道，只读握手核对与真实发送验收分别记录；已只读核对的精确版本配置可由用户明确启用派发，发送前再核对桌面通道和指定聊天的归属。当前尚未执行真实发送验收，模拟通过不能作为真实送达证据。Claude 和未知 Codex 版本继续按各自兼容门禁处理。范围与验证门槛见[开发计划](../docs/courier-development-plan.md)和[技术方案](../docs/courier-technical-design.md)。

## 入口与职责

| 入口 | 职责 |
| --- | --- |
| `Package.swift` | 神符与信使核心、CodexTransport、DesktopAutomation、服务、CLI／界面及锁定依赖 |
| `Sources/RuneCore/Contracts.swift` | JSON 合同、`ResetSource`、`StateStore`、错误及调度结果 |
| `Sources/RuneCore/State.swift` | 配置、身份、授权与库存摘要 |
| `Sources/RuneCore/Engine.swift` | 串行状态机、持久操作记录和下一任务决策 |
| `Sources/CodexTransport` | App Server stdio 传输、运行时发现、账号与库存归一化 |
| `Sources/CourierCore` | 单次信使任务、固定截止、持久派发合同与发送许可；不访问桌面 |
| `Sources/DesktopAutomation` | Codex／Claude 目标发现、显式打开、桌面通道与兼容门禁、隔离模拟；按版本分别记录验收状态 |
| `Sources/RuneService` | 私有文件、回环通信、订阅、系统事件和运行包管理 |
| `Sources/RuneCommand` | `reset-rune` 命令入口 |
| `Sources/RuneMenu` | `BottledResetRuneMenu` 菜单栏与紧凑原生面板。[MenuArtwork](Sources/RuneMenu/MenuArtwork.swift) 在应用包和源码调试环境中加载[界面美术](../assets/ARTWORK.md)。 |
| `Sources/RuneMenu/CourierMenuController.swift`、`CourierView.swift` | 368px 面板摘要入口、独立信使管理窗、合成预览与截图 |
| `Sources/RuneMenu/CourierModel.swift`、`CourierClient.swift`、`CourierCopy.swift` | 表单时间与目标校验、鉴权 API／变更订阅、中英文派发文案 |
| `Sources/RuneMenu/CourierHost.swift` | 主应用的宿主注册、领取、输入／发送许可与回执；独立于窗口可见性 |
| `Tests`、`../test/contracts` | 假时钟、合成服务与共享合同验证 |

## 构建与测试

需要 Xcode / Swift 6.0+ 和 Node.js；精确依赖见 `Package.resolved`。

```sh
npm test
swift test --package-path native
swift build --package-path native -c release
```

测试不得发现真实 Codex 登录。集成检查将 `RESET_RUNE_DATA_DIR` 指向新建的 0700 临时目录，将 `HOME`、`CODEX_HOME` 指向隔离目录，并使用 `--mock`。开发二进制需显式设置 `RESET_RUNE_DEVELOPMENT=1`，不得把该开关用于真实服务。`.mock` 服务注册前必须确认没有其他检查占用；结束时只清理本次创建的服务、进程和临时目录。

```sh
node test/contracts/generate-hash-vectors.mjs
node test/contracts/generate-engine-vectors.mjs
swift test --package-path native
```

生成器只导入 `test/reference` 中的参考实现并使用合成来源，不运行真实 Codex 或模型请求。

## 核心边界

`RuneEngine` 是 actor，另有显式异步互斥，保证 await 跨越期间的一笔操作不会被另一笔兑换插入。暂停和关闭先关发送门禁，再等待已有操作；已经发出的请求仍按实际结果记账。

- `ResetSource.read()` 返回归一化账号、库存和额度，核心不打开登录文件。
- `consume(_:maySend:)` 在发送前重新检查调用方门禁、身份、目标和到期时间。
- `StateStore.read/write` 保证私有权限、原子替换和持久化刷新。意图写入成功后才能发送。
- `RuneError.notSent` 只表示确定未发送。请求写出后断线或超时属于结果可能未知。
- 成功回执先落盘，再刷新库存。未确认操作始终保留原目标和幂等键。
- 升级、回退和重启均读取最新操作记录，不恢复安装前状态。

所有业务时间为 UTC 毫秒，时区只影响展示。假时钟和假来源使到期边界、身份变化、重启与恢复可重复验证。

## 信使管理与预览

主面板的信使摘要打开独立原生管理窗，任务与派发记录分别浏览。只填写一处发送文本，不另填任务名称；列表和记录直接使用文本摘要。表单只设置发送时间，支持单次指定时间与保存时固定的相对时间；新建、编辑、复制或重新排期由后台统一保留 15 分钟补发期限，没有「允许延后发送」选项。已有 60 分钟期限的 v1 任务与历史按原值恢复，不因升级改写；再次保存或重排时使用 15 分钟，派发记录仍显示最晚发送时间。唯一的「保存」按钮会启用该任务和信使派发；如信使原先全局暂停，也会恢复其他未来排期，已过计划时刻的任务仍需重新安排。神符授权与信使授权独立。

目标选择器默认发现最近至多 500 个聊天；还有更多时明确提示。输入标题、项目或聊天 ID 后按回车或「查找聊天」搜索，仍有超过 500 项匹配时提示缩小关键词。搜索期间切换应用、新建任务或更改查询会使旧请求失效，旧异步结果不能覆盖当前列表；搜索不依赖常驻全量聊天索引或额外权限。

权限由适配器能力决定，不以「信使任务」统一申请辅助功能。无需保持 Codex 前台；目标尚未加载时会尝试打开该已有聊天，沿用其账号和权限，不操作桌面输入框，也无需 AX 授权。恢复目标仅在可信本机通道握手成功而该聊天尚无归属时进行，定向当前已核对签名的 Codex 应用打开精确的已有聊天，随后重新核对归属和快照；不新建聊天或回退到当前聊天。正常开始准备时要求 Codex 已运行，未运行则等待；恢复期间若 Codex 与系统打开操作并发退出，系统可能重启目标应用，不能承诺零启动/零激活，返回 PID 变化时会阻断本次投递。

仅需 AX 的可发送适配器在用户明确启用派发时查询和申请辅助功能权限。界面分别显示当前版本只读已核对／尚未实发验收，以及未知版本不兼容，不能把未验收写成已成功，也不能一概将已接入通道描述为不可用。

管理窗关闭后释放视图，不停止主应用投递宿主。退出主应用则停止取得新的发送许可，后台仅保留计划等待重开；不会自动重开用户已退出的界面。已发出的消息不能因暂停或删除撤回。「文本已发送」只说明送达，不代表 Agent 已完成工作；未知结果需打开目标聊天人工核对，不自动重发。

`CourierMenuController.showPreview(editor:)` 与 `savePreviewScreenshot(to:)` 仅在 `--mock` 且面板使用显式合成 `--preview` 文件时可用。它们通过内存 `CourierEngine` 生成双端任务与未知派发记录，不发现本地服务、真实聊天或辅助功能树；截图只导出当前管理窗内容。真实模式不会因预览参数写入任务或发送文本。

开发程序可用 `--mock --preview <合成面板.json> --courier-preview` 打开管理窗示意，加 `--courier-editor` 展示编辑器；`--screenshot <绝对路径> --quit-after-screenshot` 导出后退出。`python3 scripts/smoke-courier.py` 验证隔离后台与菜单栏宿主的完整双端内存派发和重启，不注册 launchd。

## 调度与进程

已确认完整库存的最早项只预约 `expiresAt - lead`，远期不周期性访问 Codex。库存为空或最早项未知时，默认每 30 分钟重新发现；临期且尚不能使用时每 60 秒观察；已发送的未决操作最早 30 秒后用原键恢复。明确结果无法确认时阻断后续兑换。暂停后不安排周期任务。

完整性要求有效总数、唯一 ID、有效到期明细和明细数量相互一致，不能仅凭列表非空推断。调度以新增重置不会早于已知最早项到期为业务前提。状态读取不能把任务越推越后。

后台只有一个可重排的一次性定时器。唤醒、时钟变化和网络恢复仅提前处理已到期或此前失败的任务。面板订阅本机状态变化，隐藏时释放视图，不进行定时状态查询。Codex App Server 按需短时启动，完成后释放，不常驻保活。

## 运行目录与维护

应用名为 `Bottled Reset Rune.app`，应用身份为 `local.reset-rune.desktop`。后台 helper 为 `Bottled Reset Rune Service.app`，身份为 `local.reset-rune.runtime`；launchd 标签为 `local.reset-rune.service`，模拟标签附加 `.mock`。

数据目录为 `~/Library/Application Support/Bottled Reset Rune`，模拟状态位于其中的 `simulation` 子目录。`RESET_RUNE_DATA_DIR` 可指定独立目录，`RESET_RUNE_CODEX_PATH` 可指定兼容的官方 Codex 可执行文件。`CODEX_HOME` 由 Codex 自行管理。

后台运行包保存为 `runtime/current` 和一个 `runtime/previous`。安装写者由生命周期锁串行化，执行者由独占监听约束。配置和操作记录与程序副本分离。

通过 npm 安装可直接运行 `reset-rune`。通过 DMG 安装时，CLI 位于应用内，例如移除后台服务：

```sh
"/Applications/Bottled Reset Rune.app/Contents/Helpers/Bottled Reset Rune Service.app/Contents/MacOS/reset-rune" uninstall-service
```

该命令移除后台服务并保留操作记录与 Codex 登录，之后再删除应用；npm 安装可随后运行 `npm uninstall -g reset-rune`。`upgrade` 激活当前安装中的运行包；`rollback` 切换到上一个可用运行包，始终保留最新操作记录。

## 发行构建

```sh
node scripts/package-native.mjs --arch all
node scripts/package-native.mjs --arch all --signed
node scripts/verify-native-artifacts.mjs
```

`--signed` 使用本机明确选择的 Developer ID；`--notarize` 另行上传 Apple 并使用指定的 Keychain profile。默认不上传、不发布。

`dist/native/` 包含 Apple 芯片与 Intel 两份 DMG、两个原生 npm 平台包、npm 主包、manifest 和校验清单。npm 主包是薄入口，实际下载量包括匹配架构的平台包。两种渠道的签名应用内容必须一致。
