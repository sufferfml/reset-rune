// INPUT: The authenticated local service's v1 JSON view.
// OUTPUT: Display-only native panel state; never authorizes or performs redemption.
// POS: Native menu presentation, described in native/README.md.
import Foundation

struct PanelConfig: Decodable, Equatable {
    var enabled = false
    var lead = 10
    var language = "en"
    var appearance = "system"
    var startup = false
    var notify = true
}

struct PanelIdentity: Decodable, Equatable {
    var accountId: String?
    var scope: String?
    var email: String?
}

struct PanelCredit: Decodable, Equatable, Identifiable {
    var id: String
    var expiresAt: Double?
}

struct PanelRuneRow: Equatable, Identifiable {
    let id: String
    let expiresAt: Double?
    let count: Int
}

struct PanelInventory: Decodable {
    var identity: PanelIdentity?
    var availableCount: Int?
    var credits: [PanelCredit]?
    var remainingPercent: Double?
}

struct PanelEvent: Decodable, Identifiable {
    var at: Double
    var type: String
    // Index is used for ForEach because two events can share a timestamp/type.
    var id: String { "\(at):\(type)" }
}

struct PanelEventRow: Identifiable {
    let id: String
    let event: PanelEvent
}

struct PanelState: Decodable {
    var config: PanelConfig
    var mode: String
    var snapshot: PanelInventory?
    var consent: String?
    var status: String
    var error: String?
    var events: [PanelEvent]
    var lastCheckedAt: Double?

    enum Bottle: String {
        case stored, empty, unknown

        var fallbackSymbol: String {
            switch self {
            case .stored: return "drop.fill"
            case .empty: return "drop"
            case .unknown: return "questionmark"
            }
        }
    }

    func bottle(disconnected: Bool = false, now: Double = Date().timeIntervalSince1970 * 1000) -> Bottle {
        let uncertain: Set<String> = ["error", "blocked", "identity-unknown", "identity-changed", "pending", "unconfirmed", "reset-unverified", "no-credit"]
        guard !disconnected, !uncertain.contains(status), let count = snapshot?.availableCount, count >= 0 else { return .unknown }
        guard count > 0 else { return .empty }
        if let checked = lastCheckedAt, snapshot?.credits?.contains(where: { credit in
            guard let expiry = credit.expiresAt, validEpoch(expiry) else { return false }
            return checked < expiry && expiry <= now
        }) == true { return .unknown }
        return .stored
    }

    func nextCredit(now: Double) -> PanelCredit? {
        (snapshot?.credits ?? []).filter { validEpoch($0.expiresAt) && $0.expiresAt! > now }
            .min { $0.expiresAt! < $1.expiresAt! }
    }

    func inventoryRows(now: Double) -> [PanelRuneRow] {
        let credits = snapshot?.credits ?? []
        let future = credits.compactMap(\.expiresAt)
            .filter { validEpoch($0) && $0 > now }
        let byMinute = Dictionary(grouping: future) { Int64($0 / 60_000) }
        var rows = byMinute.sorted { $0.key < $1.key }.map { group in
            PanelRuneRow(id: "minute-\(group.key)", expiresAt: group.value.min(), count: group.value.count)
        }
        let unknownCount = max(0, (snapshot?.availableCount ?? 0) - future.count)
        if unknownCount > 0 {
            rows.append(PanelRuneRow(id: "unknown", expiresAt: nil, count: unknownCount))
        }
        return rows
    }

    func recentEvents() -> [PanelEventRow] {
        var occurrences: [String: Int] = [:]
        let known:Set<String>=["enabled","paused","bound","checked","intent","reset","reset-unverified","nothing-to-reset","no-credit","unconfirmed","missed"]
        return events.filter { validEpoch($0.at) && known.contains($0.type) }.sorted { $0.at > $1.at }.prefix(10).map { event in
            let key = event.id
            occurrences[key, default: 0] += 1
            return PanelEventRow(id: "\(key):\(occurrences[key]!)", event: event)
        }
    }
}

func validEpoch(_ value: Double?) -> Bool {
    guard let value else { return false }
    return value.isFinite && value > 0 && value <= 8.64e15
}

enum PanelCopy {
    static func text(_ key: String, language: String) -> String {
        let copy: [String: (String, String)] = [
            "intro": ("Automatically use Codex Reset Runes before they expire.", "在 Codex 重置神符过期前自动使用"),
            "automatic": ("Automatic use", "自动使用"),
            "connecting": ("Connecting to Bottled Reset Rune…", "正在连接 Bottled Reset Rune…"),
            "disconnected": ("Local service unavailable. Check the connection.", "本地服务暂不可用，请检查连接。"),
            "stale": ("Connection interrupted. Showing the last reading.", "连接中断，显示上次读数。"),
            "mock": ("Simulation", "模拟模式"),
            "next": ("Next expiry", "最近到期"),
            "knownNext": ("Next known expiry", "最近已知到期"),
            "fading": ("Expiring soon", "即将到期"),
            "rune": ("Reset Rune", "重置神符"),
            "inventory": ("Bottle inventory", "魔瓶库存"),
            "runeEffect": ("Resets eligible Codex usage limits when redeemed.", "兑换后可重置符合条件的 Codex 额度。"),
            "showRunes": ("Show Reset Rune details", "展开重置神符明细"),
            "hideRunes": ("Hide Reset Rune details", "收起重置神符明细"),
            "empty": ("Empty bottle", "魔瓶已空"),
            "stored": ("Reset Rune stored", "已储存重置神符"),
            "unknown": ("Inventory unconfirmed", "库存待确认"),
            "unknownExpiry": ("Expiry unavailable", "到期时间未知"),
            "partial": ("Some Reset Runes have no expiry details.", "部分重置神符缺少到期信息。"),
            "allowance": ("Codex allowance left", "Codex 剩余额度"),
            "noAllowance": ("No allowance reading", "暂无额度读数"),
            "lastReading": ("Last available reading", "上次读数"),
            "timing": ("Automatic use timing", "自动使用时机"),
            "windowOpen": ("Attempt window open", "已进入尝试时段"),
            "settings": ("Settings", "设置"),
            "activity": ("Activity", "记录"),
            "battleLog": ("Reset battle log", "兑换战报"),
            "lead": ("Lead time", "提前尝试"),
            "appearance": ("Appearance", "外观"),
            "system": ("System", "跟随系统"),
            "light": ("Light", "浅色"),
            "dark": ("Dark", "深色"),
            "language": ("Language", "语言"),
            "startup": ("Launch at login", "登录时启动"),
            "notify": ("Notify after a reset", "重置成功时通知"),
            "check": ("Check connection", "检查连接"),
            "bind": ("Bind this account and workspace", "绑定当前账号与工作区"),
            "cancel": ("Cancel", "取消"),
            "enable": ("Enable automatic use", "开启自动使用"),
            "confirmBind": ("Confirm binding", "确认绑定"),
            "enableTitle": ("Allow automatic use?", "允许自动使用？"),
            "bindTitle": ("Bind the current Codex login?", "绑定当前 Codex 登录？"),
            "settingsNote": ("Changes save automatically. Your Mac must be awake and online. Codex determines reset eligibility.", "设置自动保存。Mac 需保持唤醒并联网。兑换资格由 Codex 判定。"),
            "noEvents": ("No activity yet.", "暂无记录。"),
            "mockNote": ("Reset attempts in this mode are simulated.", "此模式下的兑换均为模拟。"),
            "noIdentity": ("Account unavailable", "账号暂不可用"),
            "detected": ("Codex account detected", "已识别 Codex 账号"),
            "localLogin": ("Local Codex sign-in", "本机 Codex 登录"),
            "today": ("Today", "今天"),
            "saveFailed": ("Couldn’t save the setting. Try again.", "设置保存失败，请重试。"),
            "refreshFailed": ("Couldn’t refresh Codex status. Try again.", "暂时无法刷新 Codex 状态，请重试。"),
            "bindRequired": ("Bind the current account and workspace in Settings first.", "请先在设置中绑定当前账号与工作区。"),
            "identityUnavailable": ("The account or workspace is unavailable. Check the connection first.", "无法确认账号或工作区，请先检查连接。"),
            "consentRequired": ("The account or lead time changed. Review and confirm again.", "账号或提前量已变更，请重新核对并确认。"),
            "pauseFirst": ("Turn automatic use off before binding another account.", "请先关闭自动使用，再绑定其他账号。"),
            "upgrade": ("Update the background service with the new command to reconnect.", "请使用新版命令升级后台服务后重新连接。"),
            "reconnect": ("Reconnect local service", "重新连接本机服务"),
            "open": ("Open Bottled Reset Rune", "打开 Bottled Reset Rune"),
            "quit": ("Quit menu bar interface", "退出菜单栏界面"),
            "quitNote": ("The background service keeps running.", "后台服务继续运行。")
        ]
        guard let entry = copy[key] else { return key }
        return language == "zh" ? entry.1 : entry.0
    }

    static func status(_ value: String, language: String, mock: Bool = false) -> String {
        let values: [String: (String, String)] = [
            "idle": ("Ready to check", "等待检查"), "checking": ("Checking Codex…", "正在检查 Codex…"),
            "ready": ("Enabled · Monitoring", "已开启 · 正在监控"),
            "disabled": ("Off · Monitoring only", "未开启 · 仅监控"),
            "waiting": ("Enabled · Waiting for expiry", "已开启 · 等待进入临期时段"),
            "outside-window": ("Enabled · Waiting for expiry", "已开启 · 等待进入临期时段"),
            "no-credits": ("Waiting for a Reset Rune", "等待新的重置神符"),
            "missing-expiry": ("Waiting for Reset Rune expiry details", "等待重置神符到期明细"),
            "identity-unknown": ("Account or workspace unavailable", "无法确认账号或工作区"),
            "identity-changed": ("Paused · Account or workspace changed", "已暂停 · 账号或工作区已变更"),
            "readonly": ("Monitoring only in this build", "此版本仅监控"),
            "blocked": ("Paused · Check status and recent activity", "已暂停 · 请检查状态和近期记录"),
            "pending": ("Attempt result unconfirmed", "尝试结果未确认"),
            "unconfirmed": ("Attempt result unconfirmed", "尝试结果未确认"),
            "reset": mock ? ("Reset Rune used · Simulated", "重置神符已使用 · 模拟兑换") : ("Reset Rune redeemed", "重置神符已兑换"),
            "reset-unverified": ("Reset redeemed · Allowance unconfirmed", "已兑换 · 额度待读回"),
            "no-credit": ("Selected Reset Rune unavailable", "选中的重置神符已不可用"),
            "nothing-to-reset": ("No eligible reset window", "当前无可重置窗口"),
            "rejected": ("No eligible reset window", "当前无可重置窗口"),
            "missed": ("Reset Rune expired", "已错过到期时段"),
            "error": ("Codex status unavailable", "Codex 状态暂不可用"),
            "runtime-missing": ("Codex runtime unavailable. Check the connection.", "找不到 Codex 运行时，请检查连接。"),
            "runtime-incompatible": ("The Codex runtime is incompatible.", "当前 Codex 运行时不兼容。"),
            "timed-out": ("Codex status check timed out", "检查 Codex 状态超时")
        ]
        let result = values[value] ?? values["error"]!
        return language == "zh" ? result.1 : result.0
    }

    static func event(_ type: String, language: String, mock: Bool) -> String {
        let entries: [String: (String, String)] = [
            "enabled": ("Automatic use enabled", "已开启自动使用"),
            "paused": ("Automatic use paused", "已暂停自动使用"),
            "bound": ("Account and workspace bound", "已绑定账号与工作区"),
            "checked": ("Connection checked", "已检查连接"),
            "intent": ("Reset attempt started", "开始尝试兑换")
        ]
        if let pair = entries[type] { return language == "zh" ? pair.1 : pair.0 }
        return status(type, language: language, mock: mock)
    }

    static func eventDetail(_ type: String, language: String) -> String? {
        let entries: [String: (String, String)] = [
            "reset-unverified": ("A successful redemption was recorded. The updated allowance was still pending at this point.", "已收到成功兑换的回执，当时尚未读回更新后的额度。"),
            "nothing-to-reset": ("The attempt returned no eligible allowance window.", "本次尝试返回的结果是没有符合条件的额度窗口。"),
            "unconfirmed": ("The attempt had no confirmed outcome. Whether a Reset Rune was consumed is unknown.", "这次尝试未能确认结果，是否消耗了重置神符仍待核实。"),
            "missed": ("The attempt window ended without a recorded redemption.", "这枚重置神符的尝试时段已结束，未记录成功兑换。")
        ]
        guard let pair = entries[type] else { return nil }
        return language == "zh" ? pair.1 : pair.0
    }

    static func date(_ epoch: Double, language: String, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: epoch / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == "zh" ? "zh_CN" : "en_US")
        if Calendar.current.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return "\(text("today", language: language)) \(formatter.string(from: date))"
        }
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        formatter.dateFormat = language == "zh" ? (sameYear ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm") : (sameYear ? "MMM d, HH:mm" : "MMM d, yyyy HH:mm")
        return formatter.string(from: date)
    }
}
