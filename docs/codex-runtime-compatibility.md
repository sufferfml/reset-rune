# Codex CLI 运行时与兼容维护

神符功能使用短时 App Server 会话，只依赖账号、额度、库存和指定神符兑换协议。CLI 更新后会重新核对实际程序与所需能力，无需为每个兼容版本维护精确允许名单。

## 支持范围与默认使用

0.1.3 支持官方 **Codex CLI 0.153.0 及以上版本**。这是最低版本，不是精确版本固定：0.153.0 的预发行版低于门槛，构建元数据不影响比较；更高版本继续通过实际稳定协议与必要能力核对。低于最低版本的程序在建立账号会话前拒绝。

默认直接发现 PATH 与常见安装位置中的本机 Codex，无需额外安装旧版。`RESET_RUNE_CODEX_PATH` 仅用于明确选择入口；如果从此前的专用 0.153.0 副本切回本机 CLI，可使用下例（路径按实际安装调整）：

```sh
RESET_RUNE_CODEX_PATH="$HOME/.local/bin/codex" \
  "/Applications/Bottled Reset Rune.app/Contents/Helpers/Bottled Reset Rune Service.app/Contents/MacOS/reset-rune" restart
```

选择稳定的安装入口，而不是包含 `releases/0.169.0-...` 的版本目录；全局 CLI 更新该入口后，下次查询会重新核对实际程序。此设置只修改 reset-rune 后台的入口配置，不改全局 Codex 或登录存储。切换后先核对账号、额度和库存；真实验证只读，不用神符测试兼容。可选的独立副本无需删除，可供后续明确回退。

## 已实现的独立安装

官方 CLI `0.153.0` 保留为已验证的可选独立安装基线。维护脚本只安装应用专用副本，不替换全局 `codex`、不改 PATH，不读取或复制登录令牌，不开启自动使用或重启服务：

```sh
python3 scripts/install-codex-runtime.py
```

需要 Python 3.10+。脚本按本机架构选择固定的官方 GitHub 发行包，先验证内置 SHA-256，再检查归档成员；在空白临时 HOME / CODEX_HOME 中验证版本后原子安装。已有副本必须通过完整性回执与版本检查才会重用，损坏副本不会被静默覆盖。支持 `--archive <已下载的官方归档>`，仍执行相同校验；`--data-dir` 用于隔离验证。

默认位置为：

```text
~/Library/Application Support/Bottled Reset Rune/codex-runtime/0.153.0/<target>/codex
```

`<target>` 为 `aarch64-apple-darwin` 或 `x86_64-apple-darwin`。副本不使用全局 CLI 的 `current` 软链接，系统 CLI 更新不会替换它。登录继续交给官方 App Server 复用本机 Codex 登录，不另建或复制认证存储。

## 已安装应用的激活与恢复

先在面板关闭自动使用，再把 `RESET_RUNE_CODEX_PATH` 设为脚本输出的绝对路径，通过当前安装中的 CLI 重启服务。例如 Apple 芯片、DMG 安装：

```sh
RESET_RUNE_CODEX_PATH="$HOME/Library/Application Support/Bottled Reset Rune/codex-runtime/0.153.0/aarch64-apple-darwin/codex" \
  "/Applications/Bottled Reset Rune.app/Contents/Helpers/Bottled Reset Rune Service.app/Contents/MacOS/reset-rune" restart
```

现有服务生成器会把该路径写入会话配置；启用登录启动（`startup=true`）时，后台启动还会同步登录启动配置。核对会话 `local.reset-rune.service.plist`，以及已启用登录启动时对应的 LaunchAgents 文件，确认该环境变量指向专用副本。恢复后核对状态无读取错误、账号/工作区与库存可见、原配置和操作记录保留。只读验证不调用兑换；自动使用仍由用户在面板明确开启。

0.1.3 的维护命令会保留明确选择的 CLI 入口：`restart` / `upgrade` 等重新生成服务配置时，未显式指定新路径就继承同一目录、同一服务标签内已固定的路径；显式环境变量优先，损坏配置会报错，模拟服务不继承正式固定。0.1.2 没有这项保留规则，使用其维护命令时须继续带上上述环境变量。只更新源码不会自动替换本机已安装的二进制。

## 自动协议兼容

0.1.3 默认尝试不低于 0.153.0 的 Codex CLI，包括更高的稳定版与预发行版，不维护逐版允许名单。版本输出用于识别入口和最低门槛，具体兼容性由实际协议判断；这不承诺未知未来协议一定兼容。已经明确选择的入口继续优先，不自动下载 CLI 或改动全局安装。

- **读取**：使用稳定协议初始化与账号/额度读取，忽略无关新增字段。必要合同缺失、无法解析或服务端拒绝所需方法时阻断；未知库存和到期信息保持未知，不补成零库存或无限期。
- **自动兑换前**：已验证基线保持现有行为；其他运行时在第一次兑换前，用空白临时 HOME / CODEX_HOME 生成稳定 schema，只检查指定神符兑换所需的方法、`creditId`、`idempotencyKey` 和结果结构。允许新增字段和额外枚举值。通过结果按实际二进制指纹缓存，文件变化后重新检查；读取不会反复生成 schema。旧版缺少指定神符参数也会被拦住，避免服务端忽略该参数后自行选取另一枚。
- **提示**：CLI 版本号改变本身不提示。必要协议不兼容时面板提示更新 reset-rune 或切回兼容运行时；网络超时、退出登录、额度不足等仍使用各自的状态，不能一概提示重新适配。
- **发送边界**：实际发送前继续核对账号/工作区、指定 credit ID、到期时间、可重置额度和发送门禁，沿用固定幂等键。发送后的未知结果继续保留原记录，不自动切换运行时重发，也不清理未决证据。

会话显式使用 `experimentalApi: false`。官方文档区分稳定与实验接口，并说明生成的 schema 与执行 CLI 的版本对应：[实验接口选择](https://learn.chatgpt.com/docs/app-server#experimental-api-opt-in) · [message schema](https://learn.chatgpt.com/docs/app-server#message-schema)。自动检查可以确认可观察的结构能力，不能无副作用地证明服务端兑换资格或所有未来语义；禁止用真实备用重置测试兼容性。

重点依赖包括 `initialize` / `initialized`、`account/read`、`account/rateLimits/read`、`account/rateLimitResetCredit/consume`。库存数量与详情完整性必须分开判断，时间单位不能从字段名推断。兑换结果目前区分 `reset`、`nothingToReset`、`noCredit`、`alreadyRedeemed`；实际收到未知结果时不能猜成成功或安全重试。

例如，`0.169.0` 高于最低版本，无需为它新增精确允许名单；仍须通过实际协议与必要能力核对。离线 schema 检查不等于真实兑换验收，具体发布验证见[验收记录](acceptance-matrix.md)。

只有必要协议实际变化时才需要人工适配：对齐新合同，更新合成协议与故障测试，并在另行授权后进行真实只读核对。更新独立安装基线则另行核实固定资产及 SHA-256，并保留旧程序供回退；始终使用最新操作记录，不恢复状态快照或自动重新授权。已发布的 0.1.2 二进制仍要求精确 CLI 0.153.0；上述最低版本与协议兼容行为从 0.1.3 起提供。

## 维护验证

```sh
python3 -m unittest discover -s scripts -p 'test_install_codex_runtime.py'
swift test --package-path native --filter ServiceTests
swift test --package-path native --filter ProtocolTests
swift test --package-path native --filter CapabilityTests
```

安装脚本测试只使用合成归档和临时目录；真实环境恢复回执存于忽略的 `.build/`，不记录账号、聊天内容或登录令牌。
