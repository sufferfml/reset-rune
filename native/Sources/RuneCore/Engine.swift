import Foundation

/// Actor isolation plus an explicit async mutex prevents reentrant mutations
/// while source I/O suspends. Pause/close gates remain callable during preflight.
public actor RuneEngine {
    private let source: ResetSource
    private let store: StateStore
    private let now: () -> Double
    private let key: () -> String
    private let onConfig: ((Bool) async throws -> Void)?
    private let onEvent: ((String, String) async -> Void)?
    private var state: JSONObject
    private var snapshot: JSONObject?
    private var lastGoodSnapshot: JSONObject?
    private var lastCheckedAt: Double?
    private var lastReadFinishedAt: Double?
    private var status = "idle"
    private var readError: String?
    private var failures = 0
    private var closing = false
    private var pausing = 0
    private var bindingRevoked = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let terminal: Set<String> = ["reset", "reset-unverified", "no-credit", "missed"]
    private let unsettled: Set<String> = ["intent", "unconfirmed"]

    public init(source: ResetSource, store: StateStore,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
                key: @escaping () -> String = { UUID().uuidString.lowercased() },
                onConfig: ((Bool) async throws -> Void)? = nil,
                onEvent: ((String, String) async -> Void)? = nil) throws {
        self.source = source; self.store = store; self.now = now; self.key = key
        self.onConfig = onConfig; self.onEvent = onEvent
        self.state = try RuneState.validate(store.read())
    }
    private var config: JSONObject { state["config"] as! JSONObject }
    private var binding: JSONObject? { state["binding"] as? JSONObject }
    private var operations: [JSONObject] { state["operations"] as? [JSONObject] ?? [] }
    private var live: Bool { source.mode == "live" }
    private var canConsume: Bool { ["live", "mock"].contains(source.mode) }
    private func enabled() -> Bool {
        canConsume && (config["enabled"] as? Bool == true) && (!live || (!bindingRevoked
            && state["liveAuthorization"] as? String != nil
            && RuneState.jsEqual(state["liveAuthorization"] as? String, RuneState.authorization(binding))))
    }
    private func consent(_ lead: Double? = nil) -> String? {
        live ? RuneState.consent(identity: snapshot?["identity"] as? JSONObject, lead: lead ?? RuneState.number(config["lead"]) ?? 10) : nil
    }
    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    private func commit(_ edit: (inout JSONObject) -> Void) throws {
        var next = state
        edit(&next)
        try store.write(next)
        state = next
    }
    private func event(_ next: inout JSONObject, _ type: String) {
        var events = next["events"] as? [JSONObject] ?? []
        events.insert(["at": now(), "type": type], at: 0)
        next["events"] = Array(events.prefix(100))
    }
    public func view() -> JSONObject {
        var displayed = config; displayed["enabled"] = enabled()
        let decision = schedule()
        return ["config": displayed, "mode": source.mode, "snapshot": snapshot as Any? ?? NSNull(),
                "consent": consent() as Any? ?? NSNull(), "status": status,
                "error": readError as Any? ?? NSNull(), "events": state["events"] ?? [],
                "lastCheckedAt": lastCheckedAt as Any? ?? NSNull(),
                "nextActionAt": decision.at as Any? ?? NSNull(), "scheduleReason": decision.reason]
    }
    public func durableState() -> JSONObject { state }
    private func revokeBinding() throws {
        bindingRevoked = true
        try commit { next in
            var c = next["config"] as! JSONObject; c["enabled"] = false; next["config"] = c
            next["liveAuthorization"] = NSNull(); event(&next, "paused")
        }
    }
    private func read() async -> Bool {
        status = "checking"
        do {
            let fresh = try await source.read()
            snapshot = fresh
            if live && enabled() && RuneState.verified(fresh["identity"] as? JSONObject)
                && !RuneState.sameIdentity(binding, fresh["identity"] as? JSONObject) { try revokeBinding() }
            lastGoodSnapshot = fresh; readError = nil; lastCheckedAt = now(); lastReadFinishedAt = now(); failures = 0
            return true
        } catch {
            snapshot = nil; status = "error"; failures += 1; lastReadFinishedAt = now()
            let code = (error as? RuneError)?.code ?? "read-failed"
            readError = ["runtime-missing", "runtime-incompatible", "timed-out", "read-failed", "protocol-error"].contains(code) ? code : "read-failed"
            return false
        }
    }
    private func bindingStatus() -> String {
        if !canConsume { return "readonly" }
        let identity = snapshot?["identity"] as? JSONObject
        if !RuneState.verified(identity) { return "identity-unknown" }
        if binding != nil && !RuneState.sameIdentity(binding, identity) { return "identity-changed" }
        if enabled() && binding == nil { return "identity-unknown" }
        return enabled() ? "ready" : "disabled"
    }
    private func observedStatus() -> String {
        let b = bindingStatus()
        guard b == "ready" else { return b }
        let operation = operations.first { unsettled.contains($0["stage"] as? String ?? "") && RuneState.sameIdentity($0["identity"] as? JSONObject, snapshot?["identity"] as? JSONObject) }
        guard let operation else { return b }
        return operation["stage"] as? String == "unconfirmed" ? "blocked" : "pending"
    }
    private func finish(_ operation: JSONObject, _ result: String) async throws -> String {
        try commit { next in
            var ops = next["operations"] as! [JSONObject]
            if let i = ops.firstIndex(where: { RuneState.jsEqual($0["key"] as? String, operation["key"] as? String) }) { ops[i]["stage"] = result }
            next["operations"] = ops
            if RuneState.jsEqual((next["plan"] as? JSONObject)?["id"] as? String, operation["id"] as? String) { next["plan"] = NSNull() }
            event(&next, result)
        }
        if config["notify"] as? Bool == true && result == "reset" { await onEvent?(result, config["language"] as? String ?? "en") }
        return result
    }
    private func maySend(startsAt: Double, expiresAt: Double) -> Bool {
        !closing && pausing == 0 && enabled() && now() >= startsAt && now() < expiresAt
    }
    private func dispatch(_ operation: JSONObject, recovering: Bool = false) async throws -> String {
        let expires = RuneState.number(operation["expiresAt"]) ?? 0
        if now() >= expires { return try await finish(operation, recovering ? "unconfirmed" : "missed") }
        let starts = expires - (RuneState.number(config["lead"]) ?? 10) * 60_000
        guard maySend(startsAt: starts, expiresAt: expires) else {
            if recovering { return "pending" }
            _ = try await finish(operation, "deferred"); return "blocked"
        }
        var request = operation; request["startsAt"] = starts; request["recovering"] = recovering
        let result: String
        do {
            result = try await source.consume(request, maySend: { await self.maySend(startsAt: starts, expiresAt: expires) })
        } catch {
            if let error = error as? RuneError, error.notSent {
                if live && error.code == "identity-changed" { try revokeBinding() }
                if recovering {
                    if ["expired", "credit-unavailable"].contains(error.code) { return try await finish(operation, "unconfirmed") }
                    return "pending"
                }
                if error.code == "expired" { return try await finish(operation, "missed") }
                _ = try await finish(operation, "deferred")
                return error.code == "identity-changed" ? "identity-changed" : "blocked"
            }
            return "pending"
        }
        if live && recovering && ["nothing-to-reset", "no-credit"].contains(result) { return try await finish(operation, "unconfirmed") }
        if ["nothing-to-reset", "no-credit"].contains(result) { return try await finish(operation, result) }
        guard ["reset", "already-redeemed"].contains(result) else { return "pending" }
        _ = try await finish(operation, "reset-unverified")
        if await read(), RuneState.sameIdentity(operation["identity"] as? JSONObject, snapshot?["identity"] as? JSONObject) { return try await finish(operation, "reset") }
        return "reset-unverified"
    }
    private func evaluate() async throws {
        status = bindingStatus()
        guard status == "ready", !closing, pausing == 0, let snapshot else { return }
        let identity = snapshot["identity"] as? JSONObject
        let accountOps = operations.filter { RuneState.sameIdentity($0["identity"] as? JSONObject, identity) }
        if let pending = accountOps.first(where: { unsettled.contains($0["stage"] as? String ?? "") }) {
            if pending["stage"] as? String == "unconfirmed" { status = "blocked"; return }
            if now() >= (RuneState.number(pending["expiresAt"]) ?? 0) { status = try await finish(pending, "unconfirmed"); return }
            if now() - (RuneState.number(pending["attemptedAt"]) ?? 0) < 30_000 { status = "pending"; return }
            try commit { next in
                var ops = next["operations"] as! [JSONObject]
                if let i = ops.firstIndex(where: { RuneState.jsEqual($0["key"] as? String, pending["key"] as? String) }) { ops[i]["attemptedAt"] = now() }
                next["operations"] = ops
            }
            status = try await dispatch(pending, recovering: true); return
        }
        if let acknowledged = accountOps.first(where: { $0["stage"] as? String == "reset-unverified" }) { status = try await finish(acknowledged, "reset"); return }
        if let plan = state["plan"] as? JSONObject, RuneState.sameIdentity(plan["identity"] as? JSONObject, identity), now() >= (RuneState.number(plan["expiresAt"]) ?? .infinity) {
            try commit { next in
                next["plan"] = NSNull()
                var missed = plan; missed["key"] = key(); missed["stage"] = "missed"
                var ops = next["operations"] as! [JSONObject]; ops.append(missed); next["operations"] = ops
                event(&next, "missed")
            }; status = "missed"; return
        }
        guard let count = RuneState.integer(snapshot["availableCount"]), count >= 0 else { status = "error"; return }
        guard count > 0 else { status = "no-credits"; return }
        let remaining = RuneState.number(snapshot.keys.contains("redeemablePercent") ? snapshot["redeemablePercent"] : snapshot["remainingPercent"])
        guard let remaining, remaining >= 0, remaining <= 100 else { status = "blocked"; return }
        let known = validCredits(snapshot)
        let revision = try RuneState.inventoryRevision(count: count, credits: known)
        if live && accountOps.contains(where: { $0["stage"] as? String == "no-credit" && $0["inventoryRevision"] as? String == revision }) { status = "no-credit"; return }
        let at = now()
        let eligible = known.filter { credit in !accountOps.contains { op in
            RuneState.jsEqual(op["id"] as? String, credit["id"] as? String) && terminal.contains(op["stage"] as? String ?? "")
        }}.sorted { (RuneState.number($0["expiresAt"]) ?? 0) < (RuneState.number($1["expiresAt"]) ?? 0) }
        if let expired = eligible.first(where: { (RuneState.number($0["expiresAt"]) ?? 0) <= at }) {
            try commit { next in
                var op = expired; op["identity"] = binding as Any? ?? NSNull(); op["key"] = key(); op["stage"] = "missed"
                var ops = next["operations"] as! [JSONObject]; ops.append(op); next["operations"] = ops; event(&next, "missed")
            }; status = "missed"; return
        }
        guard let candidate = eligible.first else { status = known.isEmpty ? "missing-expiry" : "waiting"; return }
        let oldPlan = state["plan"] as? JSONObject
        if !RuneState.jsEqual(oldPlan?["id"] as? String, candidate["id"] as? String)
            || RuneState.number(oldPlan?["expiresAt"]) != RuneState.number(candidate["expiresAt"])
            || !RuneState.sameIdentity(oldPlan?["identity"] as? JSONObject, identity) {
            try commit { next in var p = candidate; p["identity"] = binding as Any? ?? NSNull(); next["plan"] = p }
        }
        let expires = RuneState.number(candidate["expiresAt"])!
        if at < expires - (RuneState.number(config["lead"]) ?? 10) * 60_000 { status = "outside-window"; return }
        if remaining >= 100 { status = "waiting"; return }
        let prior = accountOps.first { RuneState.jsEqual($0["id"] as? String, candidate["id"] as? String) && ["nothing-to-reset", "deferred"].contains($0["stage"] as? String ?? "") }
        let quotaRevision = try (snapshot["quotaRevision"] as? String ?? RuneState.jsonString(remaining))
        if prior?["stage"] as? String == "nothing-to-reset", prior?["revision"] as? String == quotaRevision { status = "rejected"; return }
        var operation = candidate
        operation["identity"] = binding as Any? ?? NSNull(); operation["key"] = prior?["key"] ?? key()
        operation["stage"] = "intent"; operation["revision"] = quotaRevision; operation["inventoryRevision"] = revision; operation["attemptedAt"] = at
        try commit { next in
            var ops = next["operations"] as! [JSONObject]
            ops.removeAll { RuneState.jsEqual($0["key"] as? String, operation["key"] as? String) }; ops.append(operation)
            next["operations"] = ops; event(&next, "intent")
        }
        status = try await dispatch(operation)
    }
    public func tick(manual: Bool = false) async -> JSONObject {
        await acquire(); defer { release() }
        // An expired sent intent is uncertain regardless of network availability.
        // Recording that fact needs no fresh account read and must block later cards.
        if !manual, enabled(), !closing, pausing == 0,
           let pending = operations.first(where: { $0["stage"] as? String == "intent" && RuneState.sameIdentity($0["identity"] as? JSONObject, binding) }),
           now() >= (RuneState.number(pending["expiresAt"]) ?? 0) {
            do { status = try await finish(pending, "unconfirmed") }
            catch { status = "error"; lastReadFinishedAt = now() }
            return view()
        }
        if await read() {
            do {
                if manual { status = observedStatus(); try commit { event(&$0, "checked") } }
                else { try await evaluate() }
            } catch { status = "error" }
        }
        return view()
    }
    public func configure(_ request: JSONObject) async throws -> JSONObject {
        var patch = request; let suppliedConsent = patch.removeValue(forKey: "consent") as? String
        try RuneState.validateConfig(patch)
        let pause = patch["enabled"] as? Bool == false
        if pause { pausing += 1 }
        await acquire(); defer { release(); if pause { pausing -= 1 } }
        if patch["enabled"] as? Bool == true {
            guard canConsume else { throw RuneError("readonly") }
            guard await read(), RuneState.verified(snapshot?["identity"] as? JSONObject) else { throw RuneError("identity-unavailable") }
            if binding != nil && !RuneState.sameIdentity(binding, snapshot?["identity"] as? JSONObject) { status = "identity-changed"; throw RuneError("binding-required") }
            if live && (suppliedConsent == nil || !RuneState.jsEqual(suppliedConsent, consent(RuneState.number(patch["lead"])))) { throw RuneError("consent-required") }
        }
        let startupChanged = patch["startup"] != nil && (patch["startup"] as? Bool) != (config["startup"] as? Bool)
        if startupChanged { try await onConfig?(patch["startup"] as? Bool ?? false) }
        let wasEnabled = enabled()
        do {
            try commit { next in
                if patch["enabled"] as? Bool == true && next["binding"] as? JSONObject == nil {
                    next["binding"] = snapshot?["identity"] ?? NSNull(); event(&next, "bound")
                }
                if live && patch["enabled"] != nil { next["liveAuthorization"] = patch["enabled"] as? Bool == true ? RuneState.authorization(next["binding"] as? JSONObject) as Any? ?? NSNull() : NSNull() }
                if let wanted = patch["enabled"] as? Bool, wanted != wasEnabled { event(&next, wanted ? "enabled" : "paused") }
                next["config"] = (next["config"] as! JSONObject).merging(patch) { _, value in value }
            }
        } catch {
            if startupChanged { try? await onConfig?(config["startup"] as? Bool ?? false) }; throw error
        }
        if patch["enabled"] as? Bool == true { bindingRevoked = false }
        if patch["enabled"] != nil { status = observedStatus() }
        return view()
    }
    public func bind(consent suppliedConsent: String? = nil) async throws -> JSONObject {
        await acquire(); defer { release() }
        guard canConsume else { throw RuneError("readonly") }
        guard !enabled() else { throw RuneError("pause-first") }
        guard await read(), RuneState.verified(snapshot?["identity"] as? JSONObject) else { throw RuneError("identity-unavailable") }
        if live && (suppliedConsent == nil || !RuneState.jsEqual(suppliedConsent, consent())) { throw RuneError("consent-required") }
        try commit { next in
            next["binding"] = snapshot?["identity"] ?? NSNull(); next["plan"] = NSNull()
            var c = next["config"] as! JSONObject; c["enabled"] = false; next["config"] = c
            if live { next["liveAuthorization"] = NSNull() }; event(&next, "bound")
        }; status = "disabled"; return view()
    }
    public func close() async {
        closing = true; await acquire(); defer { release() }; await source.close()
    }
    private func validCredits(_ value: JSONObject) -> [JSONObject] {
        (value["credits"] as? [JSONObject] ?? []).filter { ($0["id"] as? String)?.isEmpty == false && RuneState.integer($0["expiresAt"]) != nil }
    }
    public func schedule() -> ScheduleDecision {
        guard !closing, enabled() else { return ScheduleDecision(at: nil, reason: "paused") }
        let at = now()
        let checkedAt = lastReadFinishedAt ?? at
        let accountOps = operations.filter { RuneState.sameIdentity($0["identity"] as? JSONObject, binding) }
        if accountOps.contains(where: { $0["stage"] as? String == "unconfirmed" }) { return ScheduleDecision(at: nil, reason: "unconfirmed") }
        if let pending = accountOps.first(where: { $0["stage"] as? String == "intent" }) {
            let deadline = RuneState.number(pending["expiresAt"]) ?? at
            let retry = (RuneState.number(pending["attemptedAt"]) ?? at) + 30_000
            if readError != nil || status == "error" {
                return ScheduleDecision(at: max(at, min(checkedAt + 30_000, max(checkedAt + 1_000, deadline))), reason: "pending-read-retry")
            }
            return ScheduleDecision(at: max(at, min(deadline, retry)), reason: "pending")
        }
        if readError == nil && accountOps.contains(where: { $0["stage"] as? String == "reset-unverified" }) { return ScheduleDecision(at: max(at, checkedAt + 1_000), reason: "confirm-receipt") }
        let data = snapshot ?? lastGoodSnapshot
        let savedPlan = state["plan"] as? JSONObject
        let planHint = RuneState.sameIdentity(savedPlan?["identity"] as? JSONObject, binding) ? savedPlan : nil
        let credits = data.map(validCredits) ?? planHint.map { [$0] } ?? []
        let relevant = credits.filter { credit in !accountOps.contains { op in
            RuneState.jsEqual(op["id"] as? String, credit["id"] as? String) && terminal.contains(op["stage"] as? String ?? "")
        }}
        let expiry = relevant.compactMap { RuneState.number($0["expiresAt"]) }.filter { $0 > at }.min()
        let lead = (RuneState.number(config["lead"]) ?? 10) * 60_000
        if readError != nil {
            let waits: [Double] = [60_000,120_000,300_000,900_000,1_800_000]
            var wait = waits[min(max(failures - 1, 0), waits.count - 1)]
            if let expiry, at >= expiry - lead { wait = min(wait, 60_000) }
            var target = checkedAt + wait
            if let expiry, expiry - lead > at { target = min(target, expiry - lead) }
            return ScheduleDecision(at: max(at, target), reason: "read-retry")
        }
        guard let data, let count = RuneState.integer(data["availableCount"]), count >= 0 else { return ScheduleDecision(at: max(at, checkedAt + 1_800_000), reason: "unknown-inventory") }
        if count == 0 { return ScheduleDecision(at: max(at, checkedAt + 1_800_000), reason: "discover-inventory") }
        // Compare IDs as UTF-16, avoiding Swift's canonical-equivalence Set semantics.
        let ids = credits.compactMap { $0["id"] as? String }.map { Array($0.utf16) }
        let complete = count == Double(credits.count) && Set(ids).count == credits.count
        if let expiry {
            let starts = expiry - lead
            if starts <= at {
                // A manual read/enable remains read-only, but it must not defer
                // an already-authorized automatic evaluation beyond this window.
                if status == "ready" { return ScheduleDecision(at: at, reason: "evaluate-window") }
                return ScheduleDecision(at: min(max(at, checkedAt + 60_000), expiry), reason: "in-window")
            }
            return ScheduleDecision(at: complete ? starts : max(at, min(starts, checkedAt + 1_800_000)), reason: complete ? "scheduled-expiry" : "incomplete-inventory")
        }
        // Expired unsatisfied targets need one immediate evaluation, not a tight loop.
        if relevant.contains(where: { (RuneState.number($0["expiresAt"]) ?? .infinity) <= at }) { return ScheduleDecision(at: max(at, checkedAt + 1_000), reason: "expired-target") }
        return ScheduleDecision(at: max(at, checkedAt + 1_800_000), reason: "unknown-expiry")
    }
}
