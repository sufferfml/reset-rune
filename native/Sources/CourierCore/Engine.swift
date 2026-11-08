// INPUT: A private atomic CourierStore, an injected clock, and explicit host attestations.
// OUTPUT: Durable single-shot scheduling and one-use delivery authorization.
// POS: Synchronous domain engine; its owner must serialize every call. See docs/courier-technical-design.md.
import Foundation

public final class CourierEngine {
    public let serviceEpoch: String
    private let store: CourierStore
    private let now: () -> Double
    private let makeID: () -> String
    private let allowedBundleIDs: Set<String>
    private var state: CourierEnvelope
    private var hostConnected = false
    private var faulted = false
    private var closing = false
    private let recoveryNotBefore: Double

    public init(store: CourierStore,
                now: @escaping () -> Double = { (Date().timeIntervalSince1970 * 1000).rounded() },
                makeID: @escaping () -> String = { UUID().uuidString.lowercased() },
                serviceEpoch: String = UUID().uuidString.lowercased(),
                allowedBundleIDs: Set<String> = ["com.openai.codex", "com.anthropic.claudefordesktop"]) throws {
        self.store = store; self.now = now; self.makeID = makeID; self.serviceEpoch = serviceEpoch; self.allowedBundleIDs = allowedBundleIDs
        if let data = try store.read() {
            try Self.validate(data)
            self.state = try JSONDecoder().decode(CourierEnvelope.self, from: data)
        } else { self.state = CourierEnvelope() }
        for task in state.tasks where task.lifecycle != .completed { try Self.validateTarget(task.target, allowedBundleIDs: allowedBundleIDs) }
        for run in state.runs where [.scheduled, .paused, .preparing, .dispatching].contains(run.status) { try Self.validateTarget(run.target, allowedBundleIDs: allowedBundleIDs) }
        recoveryNotBefore = state.host == nil ? now() : now() + CourierLimits.permitMilliseconds
        // A previous send permit may have reached the host even when its response was lost.
        if state.runs.contains(where: { $0.status == .dispatching }) {
            try commit(critical: true) { next in
                for index in next.runs.indices where next.runs[index].status == .dispatching {
                    Self.markUnknown(&next.runs[index], at: now(), reason: "service-restarted")
                    Self.finishTask(for: next.runs[index], in: &next, at: now())
                }
            }
        }
    }

    /// Read-only schema/invariant check for maintenance tools. Never recovers or rewrites state.
    public static func validate(_ data: Data) throws {
        guard data.count <= CourierLimits.hardBytes else { throw CourierError("courier-state-too-large", httpStatus: 503) }
        let value: CourierEnvelope
        do { value = try JSONDecoder().decode(CourierEnvelope.self, from: data) }
        catch { throw CourierError("courier-state-invalid", httpStatus: 503) }
        guard value.version == 1, value.courierProtocol == 1, value.revision >= 0, value.revision < 9_007_199_254_740_991,
              Set(value.tasks.map(\.id)).count == value.tasks.count,
              Set(value.runs.map(\.id)).count == value.runs.count else { throw CourierError("courier-state-unsupported", httpStatus: 503) }
        for task in value.tasks {
            guard !task.id.isEmpty, task.revision > 0, task.revision < 9_007_199_254_740_991,
                  task.scheduleRevision > 0, task.scheduleRevision < 9_007_199_254_740_991,
                  task.lifecycle != .completed || !task.enabled,
                  task.lifecycle != .scheduled || task.enabled else { throw CourierError("courier-state-invalid", httpStatus: 503) }
            try validateDraft(task.draft, futureThan: nil, allowedBundleIDs: nil)
        }
        for run in value.runs {
            guard !run.id.isEmpty, !run.taskID.isEmpty, run.scheduleRevision > 0,
                  validTime(run.scheduledAt), validTime(run.deadlineAt), run.deadlineAt > run.scheduledAt,
                  !run.text.isEmpty, run.text.utf8.count <= CourierLimits.maximumTextBytes,
                  Set(run.attempts.map(\.id)).count == run.attempts.count,
                  run.status != .dispatching || run.attempts.last?.sendAuthorizedAt != nil,
                  run.status != .preparing || run.attempts.last != nil else { throw CourierError("courier-state-invalid", httpStatus: 503) }
            try validateTarget(run.target, allowedBundleIDs: nil)
            for attempt in run.attempts {
                guard attempt.authorization.runID == run.id, attempt.authorization.attemptID == attempt.id,
                      !attempt.authorization.nonce.isEmpty, validTime(attempt.claimedAt), validTime(attempt.preparationExpiresAt),
                      (attempt.sendAuthorizedAt == nil) == (attempt.permitExpiresAt == nil) else {
                    throw CourierError("courier-state-invalid", httpStatus: 503)
                }
                if let sent = attempt.sendAuthorizedAt, let expires = attempt.permitExpiresAt {
                    guard validTime(sent), validTime(expires), expires > sent, expires <= run.deadlineAt,
                          attempt.inputAuthorizedAt != nil else { throw CourierError("courier-state-invalid", httpStatus: 503) }
                }
            }
            if [.scheduled, .paused, .preparing, .dispatching].contains(run.status) {
                guard let task = value.tasks.first(where: { $0.id == run.taskID && $0.scheduleRevision == run.scheduleRevision }),
                      task.target.isSameConversation(as: run.target), Array(task.text.utf8) == Array(run.text.utf8),
                      task.scheduledAt == run.scheduledAt, task.deadlineAt == run.deadlineAt else { throw CourierError("courier-state-invalid", httpStatus: 503) }
            }
        }
        guard value.runs.filter({ [.preparing, .dispatching].contains($0.status) }).count <= 1 else { throw CourierError("courier-state-invalid", httpStatus: 503) }
    }

    public func snapshot() -> CourierSnapshot {
        CourierSnapshot(courierProtocol: 1, revision: state.revision, enabled: state.enabled && !faulted && !closing,
                        pausedAt: state.pausedAt, serviceEpoch: serviceEpoch,
                        hostAvailable: hostConnected && !faulted && !closing, host: state.host,
                        tasks: state.tasks, runs: state.runs.sorted { $0.createdAt > $1.createdAt }, nextActionAt: nextActionAt())
    }

    /// Due work is published once by tick. It then waits for claim/reconnect or its deadline, avoiding a zero-delay loop.
    public func nextActionAt() -> Double? {
        guard !faulted, !closing else { return nil }
        let at = now()
        var candidates: [Double] = []
        for run in state.runs {
            if run.status == .dispatching, let permit = run.attempts.last?.permitExpiresAt { candidates.append(permit + CourierLimits.receiptMilliseconds) }
            if run.status == .preparing { candidates.append(run.deadlineAt) }
            guard state.enabled, run.status == .scheduled else { continue }
            candidates.append(run.deadlineAt)
            if let next = run.nextAttemptAt { candidates.append(next) }
        }
        return candidates.min().map { max(at, $0) }
    }

    public func tick() throws {
        try writable()
        let at = now()
        var next = state
        for index in next.runs.indices {
            var run = next.runs[index]
            if run.status == .dispatching, let permit = run.attempts.last?.permitExpiresAt,
               at >= permit + CourierLimits.receiptMilliseconds {
                Self.markUnknown(&run, at: at, reason: "receipt-timeout")
            } else if [.scheduled, .preparing].contains(run.status), at >= run.deadlineAt {
                run.status = .missed; run.waitReason = "deadline-passed"; run.nextAttemptAt = nil; run.updatedAt = at
            } else if state.enabled, run.status == .scheduled, let due = run.nextAttemptAt, due <= at {
                run.nextAttemptAt = nil; run.waitReason = hostConnected ? "ready" : "host-unavailable"; run.updatedAt = at
            }
            next.runs[index] = run
            if run.status.terminal { Self.finishTask(for: run, in: &next, at: at) }
        }
        if next != state { try commitValue(next, critical: true) }
    }

    @discardableResult public func create(_ draft: CourierTaskDraft) throws -> CourierTask {
        let draft = Self.fixedWindowDraft(draft)
        try writable(); try Self.validateDraft(draft, futureThan: now(), allowedBundleIDs: allowedBundleIDs)
        guard state.tasks.filter({ $0.lifecycle != .completed }).count < CourierLimits.maximumActiveTasks else { throw CourierError("courier-task-capacity", httpStatus: 413) }
        let at = now(), id = makeID()
        guard !id.isEmpty, !state.tasks.contains(where: { $0.id == id }) else { throw CourierError("courier-id-conflict") }
        let task = CourierTask(id: id, revision: 1, scheduleRevision: 1, name: draft.name, text: draft.text, target: draft.target,
                               scheduledAt: draft.scheduledAt, deadlineAt: draft.deadlineAt, timeZoneID: draft.timeZoneID,
                               enabled: draft.enabled, lifecycle: draft.enabled ? .scheduled : .draft, createdAt: at, updatedAt: at, needsReschedule: false)
        try commit { next in next.tasks.append(task); if task.enabled { next.runs.append(Self.newRun(task, at: at)) } }
        return task
    }

    @discardableResult public func update(id: String, expectedRevision: Int, draft: CourierTaskDraft) throws -> CourierTask {
        let draft = Self.fixedWindowDraft(draft)
        try writable(); try Self.validateDraft(draft, futureThan: now(), allowedBundleIDs: allowedBundleIDs)
        let index = try taskIndex(id, revision: expectedRevision)
        try editable(state.tasks[index])
        var task = state.tasks[index]
        task.revision += 1; task.scheduleRevision += 1; task.name = draft.name; task.text = draft.text; task.target = draft.target
        task.scheduledAt = draft.scheduledAt; task.deadlineAt = draft.deadlineAt; task.timeZoneID = draft.timeZoneID; task.enabled = draft.enabled
        task.lifecycle = draft.enabled ? .scheduled : .draft; task.needsReschedule = false; task.updatedAt = now()
        try commit { next in
            Self.cancelPendingRuns(taskID: id, in: &next, at: now(), reason: "schedule-replaced")
            next.tasks[index] = task
            if task.enabled { next.runs.append(Self.newRun(task, at: now())) }
        }
        return task
    }

    @discardableResult public func setTaskEnabled(id: String, expectedRevision: Int, enabled: Bool, scheduledAt: Double? = nil, deadlineAt: Double? = nil) throws -> CourierTask {
        try writable()
        let index = try taskIndex(id, revision: expectedRevision)
        let original = state.tasks[index]
        guard original.lifecycle != .completed else { throw CourierError("courier-task-readonly") }
        if enabled {
            var draft = original.draft
            draft.enabled = true
            // The legacy deadlineAt argument is accepted; update fixes the new delivery window.
            if let scheduledAt { draft.scheduledAt = scheduledAt }
            guard draft.scheduledAt > now() else { throw CourierError("courier-reschedule-required") }
            return try update(id: id, expectedRevision: expectedRevision, draft: draft)
        }
        var task = original; task.enabled = false; task.lifecycle = .paused; task.revision += 1; task.updatedAt = now()
        try commit(critical: true) { next in
            next.tasks[index] = task
            for i in next.runs.indices where next.runs[i].taskID == id && next.runs[i].scheduleRevision == original.scheduleRevision {
                if next.runs[i].status == .scheduled { next.runs[i].status = .paused; next.runs[i].nextAttemptAt = nil; next.runs[i].waitReason = "task-paused"; next.runs[i].updatedAt = now() }
            }
        }
        return task
    }

    public func delete(id: String, expectedRevision: Int) throws {
        try writable(); let index = try taskIndex(id, revision: expectedRevision)
        try commit(critical: true) { next in
            next.tasks.remove(at: index)
            for i in next.runs.indices where next.runs[i].taskID == id {
                if next.runs[i].status == .dispatching { Self.markUnknown(&next.runs[i], at: now(), reason: "deleted-after-permit") }
                else if [.scheduled, .paused, .preparing].contains(next.runs[i].status) { next.runs[i].status = .cancelled; next.runs[i].nextAttemptAt = nil; next.runs[i].waitReason = "task-deleted"; next.runs[i].updatedAt = now() }
            }
        }
    }

    @discardableResult public func copy(id: String, scheduledAt: Double? = nil, deadlineAt: Double? = nil) throws -> CourierTask {
        let index = try taskIndex(id)
        var draft = state.tasks[index].draft; draft.enabled = false
        // Copies are new definitions, so create fixes the window instead of inheriting it.
        if let scheduledAt { draft.scheduledAt = scheduledAt }
        guard draft.scheduledAt > now() else { throw CourierError("courier-reschedule-required") }
        return try create(draft)
    }

    public func setEnabled(_ enabled: Bool) throws {
        try writable(); guard enabled != state.enabled else { return }
        try commit(critical: true) { next in
            next.enabled = enabled
            if !enabled {
                next.pausedAt = now()
                for i in next.tasks.indices where next.tasks[i].enabled && next.tasks[i].lifecycle != .completed {
                    next.tasks[i].lifecycle = .paused; next.tasks[i].revision += 1; next.tasks[i].updatedAt = now()
                }
                for i in next.runs.indices where next.runs[i].status == .scheduled { next.runs[i].status = .paused; next.runs[i].waitReason = "courier-paused"; next.runs[i].nextAttemptAt = nil; next.runs[i].updatedAt = now() }
            } else {
                for i in next.tasks.indices where next.tasks[i].enabled && next.tasks[i].lifecycle != .completed {
                    let past = next.tasks[i].scheduledAt <= now()
                    next.tasks[i].lifecycle = past ? .paused : .scheduled; next.tasks[i].needsReschedule = past
                    if past { next.tasks[i].enabled = false }
                    next.tasks[i].revision += 1; next.tasks[i].updatedAt = now()
                    for j in next.runs.indices where next.runs[j].taskID == next.tasks[i].id && next.runs[j].scheduleRevision == next.tasks[i].scheduleRevision && [.paused, .scheduled].contains(next.runs[j].status) {
                        next.runs[j].status = past ? .paused : .scheduled; next.runs[j].waitReason = past ? "reschedule-required" : nil
                        next.runs[j].nextAttemptAt = past ? nil : next.runs[j].scheduledAt; next.runs[j].updatedAt = now()
                    }
                }
                next.pausedAt = nil
            }
        }
    }

    @discardableResult public func registerHost(_ registration: CourierHostRegistration, previousHostStopped: Bool = false) throws -> CourierHostSession {
        try writable()
        guard registration.courierProtocol == 1, !registration.brokerSession.isEmpty, registration.brokerSession.utf8.count <= 256,
              registration.processID > 0, Self.validTime(registration.processStartedAt) else { throw CourierError("courier-host-invalid", httpStatus: 400) }
        if let old = state.host {
            let sameProcess = old.processID == registration.processID && old.processStartedAt == registration.processStartedAt
            if hostConnected, old.serviceEpoch == serviceEpoch, old.brokerSession == registration.brokerSession {
                guard sameProcess else { throw CourierError("courier-host-mismatch") }
                return old
            }
            guard previousHostStopped || (sameProcess && registration.previousGateClosed) else { throw CourierError("courier-old-host-active") }
            if !previousHostStopped, now() < recoveryNotBefore { throw CourierError("courier-host-recovery-wait") }
        }
        let session = CourierHostSession(serviceEpoch: serviceEpoch, brokerSession: registration.brokerSession, processID: registration.processID,
                                         processStartedAt: registration.processStartedAt, courierProtocol: 1, registeredAt: now())
        try commit(critical: true) { next in
            for i in next.runs.indices where next.runs[i].status == .preparing {
                var run = next.runs[i]; Self.releasePreparation(&run, in: next, at: now(), reason: "old-host-stopped"); next.runs[i] = run
                if run.status.terminal { Self.finishTask(for: run, in: &next, at: now()) }
            }
            next.host = session
        }
        hostConnected = true
        return session
    }

    public func unregisterHost(brokerSession: String, gateStopped: Bool = true) throws {
        try writable()
        guard state.host?.brokerSession == brokerSession else { throw CourierError("courier-host-mismatch") }
        try commit(critical: true) { next in
            for i in next.runs.indices {
                if next.runs[i].status == .dispatching { Self.markUnknown(&next.runs[i], at: now(), reason: "host-disconnected"); Self.finishTask(for: next.runs[i], in: &next, at: now()) }
                else if next.runs[i].status == .preparing, gateStopped {
                    var run = next.runs[i]; Self.releasePreparation(&run, in: next, at: now(), reason: "host-stopped"); next.runs[i] = run
                    if run.status.terminal { Self.finishTask(for: run, in: &next, at: now()) }
                }
            }
            if gateStopped { next.host = nil }
        }
        hostConnected = false
    }

    public func hostDisconnected(brokerSession: String) throws { try unregisterHost(brokerSession: brokerSession, gateStopped: false) }
    public func close() { closing = true; hostConnected = false }

    public func claim(_ request: CourierClaimRequest) throws -> CourierClaim? {
        try writable(); try requireHost(epoch: request.serviceEpoch, session: request.brokerSession)
        guard state.enabled else { throw CourierError("courier-paused") }
        try tick()
        if let active = state.runs.first(where: { [.preparing, .dispatching].contains($0.status) }) {
            guard active.status == .preparing, let attempt = active.attempts.last,
                  attempt.authorization.brokerSession == request.brokerSession,
                  request.runID == nil || request.runID == active.id else { throw CourierError("courier-delivery-busy") }
            return CourierClaim(authorization: attempt.authorization, run: active)
        }
        let candidates = state.runs.filter { run in
            run.status == .scheduled && run.scheduledAt <= now() && run.deadlineAt > now()
                && (run.nextAttemptAt == nil || run.nextAttemptAt! <= now())
                && (request.runID == nil || request.runID == run.id)
                && !state.runs.contains(where: { $0.unresolvedUnknown && $0.target.isSameConversation(as: run.target) })
                && state.tasks.contains(where: { $0.id == run.taskID && $0.scheduleRevision == run.scheduleRevision && $0.enabled && !$0.needsReschedule })
        }.sorted { $0.scheduledAt == $1.scheduledAt ? $0.id < $1.id : $0.scheduledAt < $1.scheduledAt }
        guard var run = candidates.first else { return nil }
        let attemptID = makeID(), nonce = makeID()
        guard !attemptID.isEmpty, !nonce.isEmpty, !run.attempts.contains(where: { $0.id == attemptID }) else { throw CourierError("courier-id-conflict") }
        let auth = CourierAuthorization(serviceEpoch: serviceEpoch, brokerSession: request.brokerSession, runID: run.id, attemptID: attemptID, nonce: nonce)
        run.status = .preparing; run.waitReason = nil; run.nextAttemptAt = nil; run.updatedAt = now()
        run.attempts.append(CourierAttempt(id: attemptID, authorization: auth, claimedAt: now(), preparationExpiresAt: min(now() + CourierLimits.preparationMilliseconds, run.deadlineAt)))
        try commit { next in next.runs[try Self.runIndex(run.id, in: next)] = run }
        return CourierClaim(authorization: auth, run: run)
    }

    @discardableResult public func beginInput(auth: CourierAuthorization, preflight: CourierPreflight) throws -> CourierClaim {
        try writable(); let (ri, ai) = try authorize(auth)
        var run = state.runs[ri]
        guard run.status == .preparing, run.attempts[ai].sendAuthorizedAt == nil else { throw CourierError("courier-send-already-authorized") }
        try requireSendGates(run)
        let desktopIPC = preflight.inputMode == .desktopIPC
        // This path submits to the selected desktop owner without inspecting or touching its composer.
        // No other agent or simulation bundle inherits this exception.
        guard !desktopIPC || (run.target.agent == .codex && run.target.bundleID == "com.openai.codex") else { throw CourierError("courier-preflight-rejected") }
        guard now() < run.attempts[ai].preparationExpiresAt, preflight.identityVerified, desktopIPC || preflight.composerEmpty, preflight.hostReady,
              preflight.target.isSameConversation(as: run.target), !preflight.messageCursor.isEmpty,
              preflight.messageCursor.utf8.count <= CourierLimits.maximumEvidenceBytes else { throw CourierError("courier-preflight-rejected") }
        if let existing = run.attempts[ai].preflight {
            guard existing == preflight else { throw CourierError("courier-preflight-conflict") }
            return CourierClaim(authorization: auth, run: run)
        }
        run.attempts[ai].preflight = preflight; run.attempts[ai].inputAuthorizedAt = now(); run.updatedAt = now()
        try commit { next in next.runs[ri] = run }
        return CourierClaim(authorization: auth, run: run)
    }

    public func beginSend(auth: CourierAuthorization, target: CourierTarget, text: String) throws -> CourierSendPermit {
        try writable(); let (ri, ai) = try authorize(auth)
        var run = state.runs[ri]
        guard run.status == .preparing, run.attempts[ai].sendAuthorizedAt == nil else { throw CourierError("courier-send-already-authorized") }
        try requireSendGates(run)
        guard now() < run.attempts[ai].preparationExpiresAt, run.attempts[ai].inputAuthorizedAt != nil,
              target.isSameConversation(as: run.target), Array(text.utf8) == Array(run.text.utf8) else { throw CourierError("courier-preflight-rejected") }
        let expiry = min(now() + CourierLimits.permitMilliseconds, run.deadlineAt)
        run.status = .dispatching; run.attempts[ai].sendAuthorizedAt = now(); run.attempts[ai].permitExpiresAt = expiry; run.updatedAt = now()
        try commit(critical: true) { next in next.runs[ri] = run }
        return CourierSendPermit(authorization: auth, expiresAt: expiry, target: run.target, text: run.text)
    }

    @discardableResult public func receipt(_ request: CourierReceiptRequest) throws -> CourierRun {
        try writable()
        let ri = try Self.runIndex(request.authorization.runID, in: state)
        var run = state.runs[ri]
        guard let ai = run.attempts.firstIndex(where: { $0.id == request.authorization.attemptID }),
              run.attempts[ai].authorization == request.authorization else { throw CourierError("courier-attempt-mismatch") }
        guard (request.evidence?.utf8.count ?? 0) <= CourierLimits.maximumEvidenceBytes,
              (request.reason?.utf8.count ?? 0) <= 512, (request.messageID?.utf8.count ?? 0) <= 1024 else { throw CourierError("courier-evidence-too-large", httpStatus: 413) }
        if let previous = run.attempts[ai].receipt {
            if previous == request { return run }
            guard previous.outcome == .unknown, request.outcome == .sent else { throw CourierError("courier-receipt-conflict") }
        }
        // Receipts can reconcile old epochs, but never issue a new send authorization.
        if request.outcome == .sent {
            guard run.attempts[ai].sendAuthorizedAt != nil,
                  request.targetKey.map({ Array($0.utf8) == Array(run.target.key.utf8) }) == true,
                  let messageID = request.messageID, !messageID.isEmpty,
                  [.dispatching, .unknown].contains(run.status) else { throw CourierError("courier-receipt-unverified") }
            run.status = .sent; run.waitReason = nil; run.nextAttemptAt = nil
        } else if request.outcome == .unknown {
            guard run.attempts[ai].sendAuthorizedAt != nil else { throw CourierError("courier-not-dispatched") }
            Self.markUnknown(&run, at: now(), reason: request.reason ?? "receipt-unverified")
        } else {
            guard ai == run.attempts.count - 1 else { throw CourierError("courier-receipt-stale") }
            if [.missed, .cancelled].contains(run.status), run.attempts[ai].sendAuthorizedAt == nil {
                // A late stop acknowledgement may add evidence, but cannot revive a cancelled/expired plan.
                run.attempts[ai].receipt = request; run.attempts[ai].receiptAt = now(); run.updatedAt = now()
                try commit(critical: true) { next in next.runs[ri] = run }
                return run
            }
            guard [.preparing, .dispatching].contains(run.status) else { throw CourierError("courier-receipt-stale") }
            let task = state.tasks.first { $0.id == run.taskID && $0.scheduleRevision == run.scheduleRevision }
            if now() >= run.deadlineAt { run.status = .missed; run.nextAttemptAt = nil; run.waitReason = "deadline-passed" }
            else if task == nil { run.status = .cancelled; run.nextAttemptAt = nil; run.waitReason = "task-deleted" }
            else if task?.enabled != true || !state.enabled { run.status = .paused; run.nextAttemptAt = nil; run.waitReason = "courier-paused" }
            else if request.retryable {
                run.status = .scheduled
                let waits: [Double] = [30_000, 60_000, 120_000, 300_000]
                run.nextAttemptAt = min(run.deadlineAt, now() + waits[min(run.attempts.count - 1, waits.count - 1)])
                run.waitReason = request.reason ?? "retry-wait"
            } else { run.status = .failed; run.nextAttemptAt = nil; run.waitReason = request.reason ?? "not-sent" }
        }
        run.attempts[ai].receipt = request; run.attempts[ai].receiptAt = now(); run.updatedAt = now()
        try commit(critical: true) { next in next.runs[ri] = run; if run.status.terminal { Self.finishTask(for: run, in: &next, at: now()) } }
        return run
    }

    @discardableResult public func confirm(runID: String, sent: Bool) throws -> CourierRun {
        try writable(); let ri = try Self.runIndex(runID, in: state)
        var run = state.runs[ri]
        guard run.status == .unknown else { throw CourierError("courier-not-unknown") }
        if let previous = run.userConfirmedSent { guard previous == sent else { throw CourierError("courier-confirmation-conflict") }; return run }
        run.userConfirmedSent = sent; run.userConfirmedAt = now(); run.updatedAt = now()
        // Preserve the original unknown status and evidence; confirmation only unblocks this conversation.
        try commit(critical: true) { next in next.runs[ri] = run }
        return run
    }

    private func writable() throws { if faulted { throw CourierError("courier-store-unavailable", httpStatus: 503) }; if closing { throw CourierError("courier-service-stopping", httpStatus: 503) } }
    private func taskIndex(_ id: String, revision: Int? = nil) throws -> Int {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw CourierError("courier-task-not-found", httpStatus: 404) }
        if let revision, state.tasks[index].revision != revision { throw CourierError("courier-revision-conflict") }
        return index
    }
    private static func runIndex(_ id: String, in state: CourierEnvelope) throws -> Int {
        guard let index = state.runs.firstIndex(where: { $0.id == id }) else { throw CourierError("courier-run-not-found", httpStatus: 404) }; return index
    }
    private func editable(_ task: CourierTask) throws {
        guard task.lifecycle != .completed,
              !state.runs.contains(where: { $0.taskID == task.id && $0.scheduleRevision == task.scheduleRevision && ($0.status == .preparing || $0.status == .dispatching || $0.status.terminal && $0.status != .cancelled) }) else { throw CourierError("courier-task-readonly") }
    }
    private func requireHost(epoch: String, session: String) throws {
        guard epoch == serviceEpoch else { throw CourierError("courier-stale-epoch") }
        guard hostConnected, state.host?.serviceEpoch == serviceEpoch, state.host?.brokerSession == session else { throw CourierError("courier-host-unavailable") }
    }
    private func authorize(_ auth: CourierAuthorization) throws -> (Int, Int) {
        try requireHost(epoch: auth.serviceEpoch, session: auth.brokerSession)
        let ri = try Self.runIndex(auth.runID, in: state)
        guard let ai = state.runs[ri].attempts.firstIndex(where: { $0.id == auth.attemptID }), state.runs[ri].attempts[ai].authorization == auth,
              ai == state.runs[ri].attempts.count - 1 else { throw CourierError("courier-attempt-mismatch") }
        return (ri, ai)
    }
    private func requireSendGates(_ run: CourierRun) throws {
        try Self.validateTarget(run.target, allowedBundleIDs: allowedBundleIDs)
        guard state.enabled else { throw CourierError("courier-paused") }
        guard let task = state.tasks.first(where: { $0.id == run.taskID && $0.scheduleRevision == run.scheduleRevision }), task.enabled, !task.needsReschedule else { throw CourierError("courier-task-paused") }
        guard now() >= run.scheduledAt, now() < run.deadlineAt else { throw CourierError("courier-deadline-passed") }
        guard !state.runs.contains(where: { $0.id != run.id && $0.unresolvedUnknown && $0.target.isSameConversation(as: run.target) }) else { throw CourierError("courier-conversation-blocked") }
    }

    private static func newRun(_ task: CourierTask, at: Double) -> CourierRun {
        CourierRun(id: "\(task.id):\(task.scheduleRevision)", taskID: task.id, taskName: task.name, scheduleRevision: task.scheduleRevision,
                   target: task.target, text: task.text, scheduledAt: task.scheduledAt, deadlineAt: task.deadlineAt, status: .scheduled,
                   nextAttemptAt: task.scheduledAt, attempts: [], createdAt: at, updatedAt: at)
    }
    private static func markUnknown(_ run: inout CourierRun, at: Double, reason: String) {
        run.status = .unknown; run.waitReason = reason; run.nextAttemptAt = nil; run.updatedAt = at
        if !run.attempts.isEmpty, run.attempts[run.attempts.count - 1].becameUnknownAt == nil { run.attempts[run.attempts.count - 1].becameUnknownAt = at }
    }
    private static func finishTask(for run: CourierRun, in state: inout CourierEnvelope, at: Double) {
        guard let index = state.tasks.firstIndex(where: { $0.id == run.taskID && $0.scheduleRevision == run.scheduleRevision }), state.tasks[index].lifecycle != .completed else { return }
        state.tasks[index].lifecycle = .completed; state.tasks[index].enabled = false; state.tasks[index].updatedAt = at; state.tasks[index].revision += 1
    }
    private static func releasePreparation(_ run: inout CourierRun, in state: CourierEnvelope, at: Double, reason: String) {
        guard run.status == .preparing else { return }
        if at >= run.deadlineAt { run.status = .missed; run.waitReason = "deadline-passed"; run.nextAttemptAt = nil }
        else if let task = state.tasks.first(where: { $0.id == run.taskID && $0.scheduleRevision == run.scheduleRevision }) {
            run.status = task.enabled && state.enabled ? .scheduled : .paused; run.waitReason = reason; run.nextAttemptAt = run.status == .scheduled ? at : nil
        } else { run.status = .cancelled; run.waitReason = "task-deleted"; run.nextAttemptAt = nil }
        run.updatedAt = at
    }
    private static func cancelPendingRuns(taskID: String, in state: inout CourierEnvelope, at: Double, reason: String) {
        for i in state.runs.indices where state.runs[i].taskID == taskID && [.scheduled, .paused].contains(state.runs[i].status) {
            state.runs[i].status = .cancelled; state.runs[i].nextAttemptAt = nil; state.runs[i].waitReason = reason; state.runs[i].updatedAt = at
        }
    }
    private func commit(critical: Bool = false, _ edit: (inout CourierEnvelope) throws -> Void) throws {
        var next = state; try edit(&next); try commitValue(next, critical: critical)
    }
    private func commitValue(_ value: CourierEnvelope, critical: Bool) throws {
        var next = value; next.revision = state.revision + 1
        let budget = critical ? CourierLimits.hardBytes : CourierLimits.ordinaryBytes - 65_536
        // Only ordinary terminal history is disposable. A task's completed lifecycle is its permanent no-resend marker.
        let disposable = next.runs.filter { $0.status.terminal && $0.status != .unknown }.sorted { $0.updatedAt < $1.updatedAt }.map(\.id)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(next), removed = Set<String>(), cursor = 0
        while (next.runs.filter { $0.status.terminal && $0.status != .unknown }.count > CourierLimits.maximumHistory || bytes.count > budget), cursor < disposable.count {
            removed.insert(disposable[cursor]); cursor += 1; next.runs.removeAll { removed.contains($0.id) }; bytes = try encoder.encode(next)
        }
        guard bytes.count <= budget else { throw CourierError("courier-state-capacity", httpStatus: 413) }
        do { try store.write(bytes) }
        catch { faulted = true; throw CourierError("courier-write-failed", httpStatus: 503) }
        state = next
    }

    private static func validTime(_ value: Double) -> Bool { value.isFinite && abs(value) <= 9_007_199_254_740_991 && value.rounded() == value }
    private static func validateTarget(_ target: CourierTarget, allowedBundleIDs: Set<String>?) throws {
        let fields = [target.bundleID, target.sourceID, target.threadID, target.title]
        guard fields.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") }),
              (target.projectPath?.utf8.count ?? 0) <= 8192, (target.appVersion?.utf8.count ?? 0) <= 256,
              allowedBundleIDs == nil || allowedBundleIDs!.contains(target.bundleID) else { throw CourierError("courier-target-invalid", httpStatus: 400) }
    }
    private static func fixedWindowDraft(_ original: CourierTaskDraft) -> CourierTaskDraft {
        var draft = original
        draft.deadlineAt = draft.scheduledAt + CourierLimits.defaultDeliveryGraceMilliseconds
        return draft
    }

    // Preserve valid v1 ledgers with a 60-minute window. Only explicit new definitions
    // pass through fixedWindowDraft; validation and crash recovery never migrate them.
    private static func validateDraft(_ draft: CourierTaskDraft, futureThan: Double?, allowedBundleIDs: Set<String>?) throws {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.name.count <= 120,
              !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.text.utf8.count <= CourierLimits.maximumTextBytes,
              validTime(draft.scheduledAt), validTime(draft.deadlineAt),
              [CourierLimits.defaultDeliveryGraceMilliseconds, 3_600_000.0].contains(draft.deadlineAt - draft.scheduledAt),
              TimeZone(identifier: draft.timeZoneID) != nil else { throw CourierError("courier-task-invalid", httpStatus: 400) }
        if let futureThan, draft.scheduledAt <= futureThan { throw CourierError("courier-reschedule-required") }
        try validateTarget(draft.target, allowedBundleIDs: allowedBundleIDs)
    }
}
