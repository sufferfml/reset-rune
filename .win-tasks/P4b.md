P4b 任务（接续）：稳定运行包与激活。P4a（rune-launcher 监管器）已提交为 33e0da8。
注意：上一轮执行因模型服务中断在中途停止。工作区有未提交的半成品：coordinator.rs、serve.rs、rune-platform/{Cargo.toml,lib.rs,pipe.rs,runtime.rs} 修改（+340/-2）与未跟踪的 rune-platform/src/signature.rs。先 git diff 看清，判断保留哪些，在其基础上继续；不要盲目丢弃。
目录 C:\Users\morrow\coding\reset-rune，分支 windows-port。全部测试用 mock + 隔离 RESET_RUNE_DATA_DIR。签名做成可选、有则验证，未签名标记 unsigned。
控制阅读量：读 rune-platform/src/runtime.rs、signature.rs、rune-app/src/{cli.rs,serve.rs} 相关段、rune-launcher/src/main.rs 的参数约定（grep）；其余 grep。

4b. 稳定运行包与激活（技术方案 §10 "共享稳定运行包"）
- 目录：data_root\runtime\versions\<version>-<arch>-<manifest摘要前12>\（含 reset-rune.exe、rune-launcher.exe、LICENSE、THIRD_PARTY.txt、manifest.json），data_root\runtime\current.json（{"version","dir","manifestDigest","activatedAt"}），previous.json。
- manifest.json：productId "local.reset-rune"、version、arch、files[{path,sha256,size}]、schemaRange [1,1]。
- `reset-rune install-runtime` / 由 `start`（非开发模式）自动触发：LifecycleLock → 校验来源目录（自身 exe 所在目录）的 manifest 与每个文件哈希、无额外文件 → 若有 Authenticode 签名则验证发布者（WinVerifyTrust + 证书主题匹配 packaging/publisher.json 中允许列表；无签名时记录 unsigned 并允许，但在 status 输出里 runtime.signed=false）→ 进入维护门禁（通过管道请求 worker 暂停接受新事务并等待当前事务完成，最多 30 秒）→ stop worker → 复制到 versions\<id>\staging 再 rename → 写 current.json（原子：写 tmp + MoveFileExW REPLACE_EXISTING|WRITE_THROUGH）→ 更新计划任务 Exec 指向新 launcher → start → 健康检查 ping。失败回退 current.json，不动数据库。
- `upgrade` = install-runtime；`rollback`：previous 存在且 schema 兼容 → 交换 current/previous → 重启；不恢复旧数据库。只保留 current + previous，其余版本目录清理（跳过正在使用的）。
- uninstall-service 同步删除 runtime 目录与 current/previous 指针。
- 测试：两个不同 manifest 摘要的版本目录 A→B 升级→rollback→再 upgrade；篡改一个文件哈希/添加额外文件 → 拒绝（manifest-mismatch / unexpected-file）；current.json 损坏 → 枚举 versions 里 manifest 有效者恢复。

完成标准（P4-1）：cargo test --workspace 通过；fmt/clippy -D warnings；闪窗检测与崩溃重拉实测记录；升级/回退测试通过；windows/docs/P4-report.md 建立并写入 4a/4b 小节（闪窗检测结果、崩溃重拉实测时间、升级/回退证据、决策、未达项）。提交 "P4a: ..." 与 "P4b: ..."。最终报告 ≤ 40 行。
控制阅读量：只读 rune-launcher/src、rune-app/src/{main.rs,cli.rs,serve.rs 或 worker 模块}、rune-platform/src/{scheduler.rs,lock.rs} 的 pub 接口与 P2-report.md 未完成项；其余 grep。
