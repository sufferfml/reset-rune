注意：本任务的上一轮执行因模型服务中断在中途停止。工作区有 4 个未提交的半成品改动（tray.rs、ui/panel.rs、ui/sections.rs、ui/tray_icon.rs，共 +273/-32）。先 git diff 看清这些改动，判断哪些可以保留，然后在其基础上继续；不要盲目 git checkout 丢弃。

P3c-3 任务：辅助功能、键盘、通知、Explorer 重启、断线重连、面板资源释放 + P3d 验证脚本（P3 第三步 3/3 + P3d）

目录 C:\Users\morrow\coding\reset-rune，分支 windows-port。前置：P3c-1、P3c-2 已提交。
控制阅读量：读 ui/panel.rs、ui/tray.rs（或 tray.rs）、P3-report.md 现有小节；其余按需 grep。

范围：
1. 键盘与焦点：WS_EX_CONTROLPARENT + IsDialogMessageW 让 Tab/Shift+Tab 在可见控件间循环（隐藏区控件 WS_TABSTOP 关闭）；Space/Enter 激活按钮与复选框；Esc 关闭面板；面板显示时焦点落在"自动使用"复选框；焦点矩形可见（不要 WM_UPDATEUISTATE 隐藏）。owner-draw 列表项需支持键盘上下移动并被 Narrator 朗读（LISTBOX 原生支持；确认 UIA 能读到每行文本——若 owner-draw 导致 Name 为空，为每行提供 LB_ADDSTRING 文本）。
2. 自绘元素可访问性：魔瓶、蓝量条、分隔线为纯装饰（不进入 Tab 顺序）；但魔瓶状态与额度百分比需有文本等价：在对应 STATIC 中已有文字即可；为自绘控件窗口设置 WS_EX_NOACTIVATE 或不创建独立 HWND。
3. 高对比：SPI_GETHIGHCONTRAST 为真时 theme 用系统色（已在 theme.rs），自绘位图保留但背景/文字用 GetSysColor(COLOR_WINDOW/COLOR_WINDOWTEXT)；WM_SETTINGCHANGE（lParam "ImmersiveColorSet" 或高对比变更）与 WM_THEMECHANGED 时重算主题并重绘。
4. 通知：worker 的 notify 事件（管道 push {"event":"notify","result":"reset","language":..}）→ 托盘 Shell_NotifyIconW NIM_MODIFY NIF_INFO 气泡，标题 "Bottled Reset Rune"，正文中英文（mock: "已使用一枚重置神符，模拟重置完成。"/"Reset Rune used. Simulated reset complete."；live: "已使用一枚重置神符，Codex 额度已重置。"/"Reset Rune used. Your Codex quota was reset."）；不含邮箱；失败忽略。若 worker 侧还没有 push notify 事件，在 worker 的 on_event 中实现（通过订阅通道广播）。
5. Explorer 重启：RegisterWindowMessageW("TaskbarCreated") 收到后 NIM_ADD 重建图标并恢复三态；手工验证：Stop-Process explorer（会自动重启）→ 等 5 秒 → 托盘图标仍在（用 UIA 在任务栏通知区查找 Name 含 "Bottled Reset Rune" 的按钮；若在溢出区则记录为"需手动确认"）。
6. 断线重连：订阅连接断开 → 面板显示 stale 文案（保留上次读数）→ 5s/10s/30s 退避重连（不固定心跳）；worker 重启后自动恢复订阅。手工验证：stop worker → 面板显示 disconnected/stale → start worker → 30 秒内恢复。
7. 资源：面板隐藏时释放解码位图与 GDI 对象（DeleteObject），验证隐藏 10 秒后 Private Bytes 相比展开时下降；托盘空闲无计时器（用 Get-Process 60 秒采样 CPU 增量 ≈ 0）。
7b. 吸收 P3c-1/2 遗留：live 模式开启确认改为面板内确认区（enableTitle/bindTitle + 说明 + 确认/取消按钮，按 design/README.md 就地展开，不用 MessageBox；mock 保持直接开启）；设置区与主开关的复选框改为自绘（owner-draw BS_OWNERDRAW 或 BS_CHECKBOX + 自绘），尺寸按 DPI 20 DIP，保留 BS_CHECKBOX 语义与键盘/焦点矩形。
8. P3d 验证脚本 scripts/smoke-windows-ui.ps1：隔离目录 + mock：start worker、启动 tray、FindWindow 面板类名 → SendMessage 显示 → UIA 枚举控件（Name/ControlType/IsKeyboardFocusable）→ Tab 遍历输出焦点顺序 → config language=zh 后断言至少 3 个控件 Name 变为中文 → appearance=dark 后 PrintWindow 采样背景色接近 #202723 → 三种库存（空/正常/无到期）切换后断言托盘 tooltip 与魔瓶文案 → 隐藏/显示 Private Bytes 对比 → 输出 JSON 结果到 .build\logs\smoke-ui.json 与截图 .build\logs\ui-p3d-*.png。最后结束自己启动的进程（stop worker、关 tray）。
9. 完成标准：cargo test --workspace，fmt/clippy -D warnings；smoke-windows-ui.ps1 本机通过并保存输出；提交 "P3c-3: accessibility, notifications, reconnect, resource release" 与 "P3d: UI smoke script and report"；P3-report.md 汇总整个 P3（截图、UIA 清单、键盘顺序、中英文/深浅/高对比、三态、Explorer 重启、重连、资源数字、决策、未达项）。最终报告 ≤ 50 行。
