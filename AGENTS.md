# Bottled Reset Rune

独立的 macOS 菜单栏工具。界面将一次 Codex 备用重置称为一枚「重置神符」（Reset Rune）。用户核对账号并开启自动使用后，应用可在神符到期前尝试使用。模拟模式使用独立状态。

开发中的「信使任务」已有任务管理、持久调度、隔离模拟及锁版本的 Codex 桌面原生 IPC 路径。当前 Codex 版本通过真实只读核对，未执行真实发送验收；Claude 真实验证按用户要求延期，未知版本不得绕过兼容门禁。

## 边界

- 仅修改本项目，不改动其他项目的代码、数据、部署或签名身份。
- 禁止使用真实账号的备用重置测试。开发验证使用合成账号、假时钟和隔离目录；另行授权的真实联调仅限只读。
- 不读取、复制、打印或提交真实登录令牌。通过官方 Codex App Server 复用本机登录。
- 用户必须明确开启自动使用；手动刷新只读。模拟成功不能证明线上兑换资格。
- 同一账号、工作区和额度池的用量由账户读取覆盖，不监听 DSH 请求。
- 未获授权不提交、推送或发布。发布构建只使用本机明确选择的签名身份和钥匙串凭据。
- 应用显示名为 `Bottled Reset Rune`；npm 包、CLI、GitHub 仓库和项目目录名为 `reset-rune`。
- 数据目录为 `~/Library/Application Support/Bottled Reset Rune`，服务标签为 `local.reset-rune.service`，环境变量使用 `RESET_RUNE_*`。模拟目录、服务标签和端口须与正式模式隔离。
- Dota 2 原版美术及适配图标按 `assets/ARTWORK.md` 记录出处与权利归属。展开明细中的重置神符由本项目单独设计。

## 导航

| 入口 | 职责 |
| --- | --- |
| `README.md`、`README.zh-CN.md` | 英文默认首页与独立中文版，面向用户说明安装、操作和使用限制 |
| `native/AGENTS.md`、`native/README.md` | 原生核心、后台、命令行、菜单栏界面与构建维护 |
| `native/Sources/CodexTransport/README.md` | 官方 Codex App Server 的协议和进程边界 |
| `distribution/npm/cli.cjs` | 按架构定位原生平台包的短时 npm 入口 |
| `scripts/package-native.mjs` | 双架构应用、DMG 与 npm 平台包构建 |
| `scripts/verify-native-artifacts.mjs` | 签名、架构和跨渠道内容核验 |
| `test/reference/core`、`test/reference/codex` | 供跨语言合同验证使用的 JavaScript 参考实现，不随发行包运行 |
| `test/contracts` | 合成账号、摘要和状态转换的共享测试向量 |
| `docs/acceptance-matrix.md` | 验证范围与需要区分的证据类型 |
| `docs/courier-development-plan.md`、`docs/courier-technical-design.md`、`docs/courier-compatibility.md` | 「信使任务」范围、实现与兼容核对；Codex 同桌面原生路径仅锁定已核对版本，尚未实发验收；Claude 延期；派发不代表 Agent 工作完成 |
| `docs/windows-development-plan.md`、`docs/windows-technical-design.md` | 尚未实现的 Windows 开发计划、拟定架构、分发与验收门槛；不得作为 Windows 已可用的证据 |
| `design/README.md`、`design/theme.md`、`.impeccable.md` | 紧凑面板、魔瓶主题与交互约定 |
| [美术来源](assets/ARTWORK.md)、`assets/panel`、`assets/icons` | Dota 2 原版素材、各平台图标及明细区专用的重置神符图 |

## 验证

```sh
npm test
swift test --package-path native
node scripts/package-native.mjs --arch all
node scripts/verify-native-artifacts.mjs
```

集成检查必须设置独立的 `RESET_RUNE_DATA_DIR` 和空白 `CODEX_HOME`。运行模拟服务与界面时使用 `--mock`；`RESET_RUNE_DEVELOPMENT=1` 只用于明确的本地开发二进制。测试不得改变真实服务的启用、绑定、配置或状态。

`python3 scripts/smoke-native.py --seconds 120` 运行隔离模拟界面和资源采样。`python3 scripts/smoke-native-lifecycle.py` 验证自己的 `.mock` 服务生命周期；先拒绝冲突，退出时只清理本次创建的注册与进程。

`python3 scripts/smoke-courier.py` 使用已构建的 Debug 程序，验证独立目录中的双端内存模拟派发、后台重启及神符授权隔离；不注册 launchd、不操作真实聊天或登录。
