// INPUT: Presentation keys, courier states and normalized error codes.
// OUTPUT: English and Simplified Chinese task copy with honest delivery semantics.
// POS: Courier presentation copy. See design/theme.md.
import Foundation

enum CourierCopy {
    static func text(_ key: String, language: String) -> String {
        let values: [String: (String, String)] = [
            "title": ("Courier Tasks", "信使任务"),
            "intro": ("Choose a chat. Leave an instruction. Schedule its delivery.", "选好聊天，留下指令，安排信使送达。"),
            "semantics": ("Sent means the text reached the chat. It does not mean the Agent finished the work.", "已发送表示文本已送达聊天，不代表 Agent 已完成工作。"),
            "new": ("New task", "新建任务"), "refresh": ("Refresh", "刷新"),
            "tasks": ("Tasks", "任务"), "runs": ("Dispatch log", "派发记录"),
            "pauseAll": ("Pause courier", "暂停信使"), "enableAll": ("Enable courier", "启用信使"),
            "pausedAll": ("Courier paused", "信使已暂停"),
            "empty": ("Your next instruction can arrive on time.", "让下一条指令按时送达。"),
            "emptyDetail": ("Create a task for an existing Codex or Claude Code desktop chat. Your Mac and this app must be running.", "为已有的 Codex 或 Claude Code 桌面聊天创建任务。Mac 和本应用需要保持运行。"),
            "noRuns": ("Dispatches will appear here, with their actual delivery result.", "派发后在这里查看实际发送结果。"),
            "select": ("Select a task to review its target and schedule.", "选择任务，核对目标与发送安排。"),
            "agent": ("Desktop app", "目标应用"), "target": ("Target chat", "目标聊天"),
            "chooseTarget": ("Choose a specific chat…", "选择明确的聊天…"),
            "discover": ("Find chats", "查找聊天"), "discovering": ("Finding chats…", "正在查找聊天…"),
            "targetSearch": ("Search title, project or chat ID", "搜索标题、项目或聊天 ID"),
            "moreTargets": ("Showing the 500 most recent chats. Search with a keyword to find more.", "显示最近 500 项，请用关键词查找更多。"),
            "moreMatches": ("More than 500 chats match. Use a more specific keyword to narrow the results.", "匹配结果超过 500 项，请用更具体的关键词缩小范围。"),
            "noTargets": ("No chats found. Open the desktop app and refresh.", "未找到聊天。请打开目标桌面应用后刷新。"),
            "noMatchingTargets": ("No matching chats. Try another title, project or chat ID.", "未找到匹配聊天。请尝试其他标题、项目或聊天 ID。"),
            "targetHint": ("The selected chat keeps its own context and permissions.", "使用所选聊天已有的上下文和权限。"),
            "text": ("Text to send", "发送文本"), "time": ("Send time", "发送时间"),
            "absolute": ("At a time", "指定时间"), "relative": ("After a delay", "多久之后"),
            "minutes": ("minutes from saving", "分钟后（从保存时计算）"),
            "deadline": ("Latest delivery", "最晚发送时间"),
            "timeNote": ("If delivery is temporarily unavailable at the scheduled time, it waits up to 15 minutes, then stops.", "到点暂时无法发送时，最多等待 15 分钟，超过不再发送。"),
            "bringFront": ("Delivery may bring the target app to the front. Existing drafts and busy chats are left alone.", "派发可能将目标应用置前。已有草稿或聊天正忙时等待。"),
            "save": ("Save", "保存"),
            "saveNote": ("Saving enables this task and courier, and resumes other future schedules. Paused tasks whose send time passed still need a new time.", "保存即启用此任务和信使，并恢复其他未来排期。已过计划时间的暂停任务仍需重新安排。"),
            "cancel": ("Cancel", "取消"), "pause": ("Pause", "暂停"), "resume": ("Review and enable", "核对并启用"),
            "copy": ("Copy", "复制"), "delete": ("Delete", "删除"), "open": ("Open chat", "打开目标聊天"),
            "deleteTitle": ("Delete this task?", "删除此任务？"),
            "deleteNote": ("The pending schedule will be removed. Existing dispatch evidence remains; sent messages cannot be recalled.", "取消未发送安排，保留已有派发证据。已发出的消息不能撤回。"),
            "locked": ("This task is read-only. Copy it to schedule another delivery.", "此任务只读。需要再次发送时，请复制为新任务。"),
            "accessibility": ("Allow Accessibility", "授权辅助功能"),
            "accessNote": ("Accessibility is requested only when you save a task using this delivery route. This does not authorize automatic Reset Rune use.", "保存使用此派发通道的任务时才申请辅助功能权限，不改变神符自动使用授权。"),
            "codexPermissions": ("Codex does not need to stay in front. If the target is not loaded, the app tries to open that existing chat using its account and permissions. It does not operate the desktop input field or need Accessibility access. If Codex has quit, delivery waits for you to reopen it.", "无需保持 Codex 前台。目标尚未加载时会尝试打开该已有聊天，沿用其账号和权限。不操作桌面输入框，无需辅助功能权限。Codex 退出后等待你重新打开。"),
            "codexReadOnly": ("The current desktop channel passed read-only checks. Real delivery has not been verified yet.", "当前桌面通道只读已核对，尚未实发验收。"),
            "unsupported": ("This desktop version does not support delivery yet. Choose a supported target before saving.", "此桌面版本暂不支持派发，请选择兼容的目标后保存。"),
            "mock": ("Simulation · no real chat is read or changed", "模拟模式 · 不读取或操作真实聊天"),
            "hostWaiting": ("Waiting for this app's delivery host", "等待本应用的投递宿主"),
            "serviceWaiting": ("Courier service unavailable. Refresh to reconnect.", "信使服务暂不可用，请刷新重连。"),
            "unknownNote": ("Check the target chat before confirming. This record will remain in the dispatch history. Nothing is resent automatically.", "请先核对目标聊天再确认。原始派发证据会保留，不会自动重发。"),
            "confirmSent": ("I confirmed it was sent", "我已确认发送"),
            "confirmNotSent": ("I confirmed it was not sent", "我已确认未发送"),
            "confirmTitle": ("Record your chat check?", "记录人工核对结果？"),
            "confirmNote": ("This adds your confirmation without changing the original evidence. It does not send any text.", "追加人工确认并保留原始证据。此操作不会发送文本。"),
            "confirmedSent": ("User confirmed sent", "用户确认已发送"),
            "confirmedNotSent": ("User confirmed not sent", "用户确认未发送"),
            "instruction": ("Instruction", "指令"), "scheduled": ("Scheduled for", "计划发送"),
            "updated": ("Last update", "最近更新"), "waiting": ("Waiting", "等待"),
            "draft": ("Paused draft", "暂停草稿"), "scheduledStatus": ("Scheduled", "待发送"),
            "paused": ("Paused", "已暂停"), "preparing": ("Sending", "发送中"), "dispatching": ("Sending", "发送中"),
            "sent": ("Text sent", "文本已发送"), "failed": ("Not sent", "未发送"),
            "missed": ("Deadline missed", "已错过"), "cancelled": ("Cancelled", "已取消"),
            "unknown": ("Delivery needs confirmation", "发送结果待确认"), "completed": ("Finished schedule", "排期已结束")
        ]
        guard let value = values[key] else { return key }
        return language == "zh" ? value.1 : value.0
    }

    static func error(_ code: String, language: String) -> String {
        let values: [String: (String, String)] = [
            "courier-name-invalid": ("A task summary could not be derived. Check the text and save again.", "无法生成任务摘要，请检查文本后重新保存。"),
            "courier-text-invalid": ("Enter text of up to 32 KiB. The original text will be preserved.", "请输入不超过 32 KiB 的文本，发送时保留原文。"),
            "courier-target-required": ("Choose a specific chat before saving.", "请先选择明确的目标聊天。"),
            "courier-time-invalid": ("Choose a future send time, then save again.", "请选择未来的发送时间后重新保存。"),
            "courier-deadline-invalid": ("The delivery deadline is invalid. Choose a future send time and save again.", "发送截止时间无效，请选择未来的发送时间后重新保存。"),
            "courier-desktop-unsupported": ("This desktop version does not support delivery yet. Choose a supported target before saving.", "此桌面版本暂不支持派发，请选择兼容的目标后保存。"),
            "courier-accessibility-required": ("Allow Accessibility in System Settings, then save again.", "请在系统设置中授予辅助功能权限，然后重新保存。"),
            "accessibilityRequired": ("Allow Accessibility, then try again.", "请授予辅助功能权限后重试。"),
            "appMissing": ("The selected desktop app is not installed. Install it and find chats again.", "未安装所选桌面应用。请安装后重新查找聊天。"),
            "sourceUnavailable": ("Chat sources could not be read. Open the desktop app and try again.", "暂时无法读取聊天来源。请打开目标桌面应用后重试。"),
            "unsupportedVersion": ("This desktop version is not supported for delivery.", "此桌面版本暂不支持投递。"),
            "targetNotConfirmed": ("The exact target chat could not be confirmed. No text was sent.", "无法确认目标聊天，未发送文本。"),
            "receiptNotSupported": ("This version cannot provide reliable delivery evidence yet.", "此版本尚不能提供可靠的送达证据。"),
            "liveValidationRequired": ("The current desktop channel passed read-only checks. Real delivery has not been verified yet.", "当前桌面通道只读已核对，尚未实发验收。"),
            "courier-revision-conflict": ("This task changed. Refresh and review it before saving.", "任务已变更。请刷新核对后重新保存。")
            ,"courier-saved-paused": ("The task was saved, but enabling courier was not confirmed. Save again to retry, or refresh the status.", "任务已保存，但尚未确认信使开启。可重新保存重试，或刷新状态。"),
            "courier-reschedule-required": ("This scheduled time has passed. Choose a new future time.", "原计划时间已过，请选择新的未来时间。"),
            "courier-task-readonly": ("This task is already sending or finished. Copy it to make another schedule.", "任务已开始发送或排期已结束，请复制后重新安排。"),
            "courier-target-invalid": ("The selected chat is no longer valid. Find and select it again.", "所选聊天已失效，请重新查找并选择。"),
            "courier-service-unavailable": ("Courier service unavailable. Refresh to reconnect.", "信使服务暂不可用，请刷新重连。"),
            "courier-state-capacity": ("The task store is full. Remove unused tasks before saving another.", "任务存储已满，请删除不需要的任务后再保存。"),
            "courier-task-capacity": ("There are too many active tasks. Remove an unused task before creating another.", "待处理任务过多，请删除不需要的任务后再创建。")
        ]
        if let value = values[code] { return language == "zh" ? value.1 : value.0 }
        return text("serviceWaiting", language: language)
    }

    static func reason(_ code: String, language: String) -> String {
        let values: [String: (String, String)] = [
            "ready": ("Waiting for the delivery host", "等待投递宿主"),
            "host-unavailable": ("Waiting for this app to run", "等待本应用运行"),
            "courier-paused": ("Courier was paused", "信使已暂停"),
            "task-paused": ("This task was paused", "此任务已暂停"),
            "reschedule-required": ("Choose a new send time", "需要重新选择发送时间"),
            "deadline-passed": ("The latest send time passed", "已过最晚发送时间"),
            "task-deleted": ("The task was deleted", "任务已删除"),
            "schedule-replaced": ("The schedule was edited", "发送安排已修改"),
            "service-restarted": ("The service restarted after sending was authorized", "发送获准后服务重启"),
            "receipt-timeout": ("No reliable receipt arrived in time", "未能及时确认可靠回执"),
            "receipt-unverified": ("Delivery could not be verified", "无法核实发送结果"),
            "host-disconnected": ("The delivery host disconnected", "投递宿主断开连接"),
            "host-stopped": ("The delivery host stopped", "投递宿主已停止"),
            "old-host-stopped": ("The previous delivery host stopped", "上个投递宿主已停止"),
            "deleted-after-permit": ("The task was deleted after sending was authorized", "发送获准后任务被删除"),
            "retry-wait": ("Waiting to retry before the fixed deadline", "等待在固定截止前重试"),
            "not-sent": ("No text was sent", "未发送文本"),
            "targetBusy": ("The target chat is busy", "目标聊天正忙"),
            "userDraft": ("The target chat has an unsent draft", "目标聊天有未发送草稿"),
            "screenLocked": ("Waiting for the screen to unlock", "等待屏幕解锁"),
            "userInterference": ("You changed the chat or input while delivery was preparing", "准备派发时聊天或输入发生变化"),
            "notFrontmost": ("The target app is not in the foreground", "目标应用未在前台"),
            "textMismatch": ("The draft text did not match the task", "输入文本与任务不一致"),
            "sendUnavailable": ("The target chat cannot send right now", "目标聊天暂时无法发送"),
            "cancelled": ("The delivery was stopped before sending", "发送前已停止派发"),
            "resultUnknown": ("Delivery could not be confirmed", "无法确认是否送达"),
            "permitExpired": ("The short-lived send authorization expired", "本次发送授权已过期")
        ]
        if let value = values[code] { return language == "zh" ? value.1 : value.0 }
        return error(code, language: language)
    }

    static func date(_ milliseconds: Double, language: String, timeZoneID: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == "zh" ? "zh_CN" : "en_US")
        formatter.timeZone = timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        formatter.dateFormat = language == "zh" ? "yyyy年M月d日 HH:mm zzz" : "MMM d, yyyy 'at' HH:mm zzz"
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
}
