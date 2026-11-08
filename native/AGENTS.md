# Native Bottled Reset Rune

## 范围

先读根 `AGENTS.md` 与[原生说明](README.md)。macOS 13+，原生菜单栏、独立后台和 CLI 共用同一执行核心。npm 与 DMG 只改变分发入口。

禁止使用真实备用重置测试，禁止测试进程发现真实登录或连接真实兑换端点。使用独立目录、假来源、假时钟和 `.mock` 服务标签。测试不得开启、暂停、重绑或覆盖真实用户配置。

## 模块

| 模块 | 职责 |
| --- | --- |
| `Sources/RuneCore` | JSON 合同、授权、操作状态机和调度决策 |
| `Sources/CodexTransport` | 固定兼容版本的官方 App Server，见模块 README |
| `Sources/CourierCore` | 单次任务合同、固定截止、持久状态和一次性发送许可；同步核心由服务串行拥有 |
| `Sources/DesktopAutomation` | 桌面目标、辅助功能边界、版本兼容门禁与内存模拟；不读取认证文件 |
| `Sources/RuneService` | 私有持久化、回环鉴权 API、状态订阅、launchd 和运行包管理 |
| `Sources/RuneCommand` | 短时 CLI 与安装、升级、回退、卸载入口 |
| `Sources/RuneMenu` | 菜单栏与神符面板；`CourierView/Model/Client` 管理任务，`CourierMenuController` 管理原生窗口，`CourierHost` 承载投递 |
| `Tests`、`../test/contracts` | 合成协议、状态机、生命周期和跨语言合同测试 |

## 必须保留

- 意图先持久化，成功回执先持久化再刷新；未知结果保留原目标和幂等键。
- `RuneEngine` 的显式异步互斥及暂停、关闭门禁。actor 在 await 期间可重入，不能用 actor 隔离代替完整事务互斥。
- 已确认完整库存时，最早卡远期不周期查询。空或未知库存才低频发现。读取本机状态不能推迟任务。
- 手动刷新只读；已开启的自动调度是独立后台动作。
- 调度提示不等于兑换授权。坏状态不能重置成空白后继续发送。
- 同一机器用户只有一个执行器。生命周期锁约束安装写者，独占监听约束执行者。
- 升级和回退只切换程序，始终使用最新操作记录，不能恢复旧状态快照或删除未决证据。
- 信使和神符分别授权、存储与排期；长时间桌面操作不得占用神符事务。后台不执行 AX；主应用退出后不自动拉起。
- 桌面版本缺少稳定发前目标关联或发后消息证据时不授权生产发送。未知结果不自动重发，同一聊天未核对前不叠加派发。
- 信使预览须同时满足 mock 和显式合成面板预览，只用内存状态；不得退回真实服务、聊天目录或权限查询。

## 验证

运行 `swift test --package-path native`。改变摘要或跨语言状态合同时，运行 `../test/contracts/generate-*-vectors.mjs` 并检查有意差异。构建与资源预算不是实测结果；模拟低 CPU 不能证明真实 Codex 查询成本。

`python3 scripts/smoke-native-lifecycle.py` 只注册并清理自己创建的 `.mock` 服务。`node scripts/verify-native-artifacts.mjs` 只在隔离沙箱中运行帮助和版本命令，并核验签名、公证、架构及 npm / DMG 内容一致性。
