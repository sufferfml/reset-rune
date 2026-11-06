# Bottled Reset Rune 原生实现

原生菜单栏界面、后台服务和 CLI 面向 macOS 13+，通过固定兼容版本的官方 Codex App Server 操作。npm 与 DMG 使用相同的执行核心，不携带浏览器或 Node.js 常驻运行时。

## 入口与职责

| 入口 | 职责 |
| --- | --- |
| `Package.swift` | `RuneCore`、`CodexTransport`、`RuneService`、命令行与界面目标及锁定依赖 |
| `Sources/RuneCore/Contracts.swift` | JSON 合同、`ResetSource`、`StateStore`、错误及调度结果 |
| `Sources/RuneCore/State.swift` | 配置、身份、授权与库存摘要 |
| `Sources/RuneCore/Engine.swift` | 串行状态机、持久操作记录和下一任务决策 |
| `Sources/CodexTransport` | App Server stdio 传输、运行时发现、账号与库存归一化 |
| `Sources/RuneService` | 私有文件、回环通信、订阅、系统事件和运行包管理 |
| `Sources/RuneCommand` | `reset-rune` 命令入口 |
| `Sources/RuneMenu` | `BottledResetRuneMenu` 菜单栏与紧凑原生面板。[MenuArtwork](Sources/RuneMenu/MenuArtwork.swift) 在应用包和源码调试环境中加载[界面美术](../assets/ARTWORK.md)。 |
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
