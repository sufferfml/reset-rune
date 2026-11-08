import XCTest
@testable import CourierCore

final class CourierCoreTests: XCTestCase {
    final class Clock { var at = 1_000_000.0 }
    final class Harness {
        let clock = Clock()
        let store = CourierMemoryStore()
        var sequence = 0
        var engine: CourierEngine!
        init() throws {
            engine = try CourierEngine(store: store, now: { [clock] in clock.at }, makeID: { [weak self] in self!.sequence += 1; return "id-\(self!.sequence)" }, serviceEpoch: "epoch-1")
            try engine.setEnabled(true)
        }
        var target: CourierTarget { CourierTarget(agent: .codex, bundleID: "com.openai.codex", sourceID: "synthetic-source", threadID: "thread-1", title: "Synthetic thread") }
        func draft(delay: Double = 1_000, target: CourierTarget? = nil, text: String = "中文\nRun tests 👋\n'quoted'", enabled: Bool = true) -> CourierTaskDraft {
            CourierTaskDraft(name: "Daily check", text: text, target: target ?? self.target, scheduledAt: clock.at + delay, timeZoneID: "Asia/Shanghai", enabled: enabled)
        }
        func host(_ session: String = "host-1") throws {
            _ = try engine.registerHost(CourierHostRegistration(brokerSession: session, processID: 101, processStartedAt: 100))
        }
        func ready(target: CourierTarget? = nil) throws -> CourierClaim {
            try host()
            let task = try engine.create(draft(target: target))
            clock.at = task.scheduledAt
            try engine.tick()
            return try XCTUnwrap(engine.claim(CourierClaimRequest(serviceEpoch: "epoch-1", brokerSession: "host-1")))
        }
        func input(_ claim: CourierClaim) throws {
            _ = try engine.beginInput(auth: claim.authorization, preflight: CourierPreflight(target: claim.run.target, messageCursor: "cursor-before", identityVerified: true, composerEmpty: true, hostReady: true))
        }
        func send(_ claim: CourierClaim) throws -> CourierSendPermit {
            try input(claim)
            return try engine.beginSend(auth: claim.authorization, target: claim.run.target, text: claim.run.text)
        }
    }

    func expect(_ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in XCTAssertEqual((error as? CourierError)?.code, code, file: file, line: line) }
    }

    func testInputPreservationAndSingleShotTimes() throws {
        let h = try Harness()
        let text = "  中文 e\u{301}\n\"quote\" 👨‍👩‍👧‍👦\n  "
        let task = try h.engine.create(h.draft(text: text))
        XCTAssertEqual(Array(task.text.utf8), Array(text.utf8))
        XCTAssertEqual(task.deadlineAt - task.scheduledAt, 900_000)
        h.clock.at += 500
        XCTAssertEqual(h.engine.snapshot().tasks.first?.scheduledAt, task.scheduledAt)
        expect("courier-reschedule-required") { _ = try h.engine.create(h.draft(delay: 0)) }
    }

    func testNewDefinitionsFixGraceWindowAcrossSaveCopyAndReschedule() throws {
        let h = try Harness()
        XCTAssertEqual(CourierLimits.defaultDeliveryGraceMilliseconds, 900_000)
        var draft = h.draft()
        draft.deadlineAt = draft.scheduledAt + 3_600_000
        let created = try h.engine.create(draft)
        XCTAssertEqual(created.deadlineAt, created.scheduledAt + 900_000)
        XCTAssertEqual(draft.deadlineAt, draft.scheduledAt + 3_600_000)

        var edit = created.draft
        edit.scheduledAt += 10_000
        edit.deadlineAt = edit.scheduledAt + 10_000
        let updated = try h.engine.update(id: created.id, expectedRevision: created.revision, draft: edit)
        XCTAssertEqual(updated.deadlineAt, updated.scheduledAt + 900_000)
        let copied = try h.engine.copy(id: updated.id, scheduledAt: h.clock.at + 20_000, deadlineAt: h.clock.at + 3_620_000)
        XCTAssertEqual(copied.deadlineAt, copied.scheduledAt + 900_000)

        let paused = try h.engine.setTaskEnabled(id: updated.id, expectedRevision: updated.revision, enabled: false)
        let rescheduled = try h.engine.setTaskEnabled(id: paused.id, expectedRevision: paused.revision, enabled: true,
                                                     scheduledAt: h.clock.at + 30_000, deadlineAt: h.clock.at + 3_630_000)
        XCTAssertEqual(rescheduled.deadlineAt, rescheduled.scheduledAt + 900_000)
        XCTAssertTrue(h.engine.snapshot().runs.allSatisfy { $0.deadlineAt - $0.scheduledAt == 900_000 })
        XCTAssertNoThrow(try CourierEngine.validate(XCTUnwrap(h.store.data)))
    }

    func testLegacyHourWindowSurvivesReadAndPauseButNewDefinitionsUseFifteenMinutes() throws {
        let h = try Harness()
        let task = try h.engine.create(h.draft())
        var envelope = try JSONDecoder().decode(CourierEnvelope.self, from: XCTUnwrap(h.store.data))
        envelope.tasks[0].deadlineAt = task.scheduledAt + 3_600_000
        envelope.runs[0].deadlineAt = task.scheduledAt + 3_600_000
        let legacyData = try JSONEncoder().encode(envelope)
        h.store.data = legacyData
        let writes = h.store.writes
        XCTAssertNoThrow(try CourierEngine.validate(legacyData))
        let restored = try CourierEngine(store: h.store, now: { h.clock.at })
        XCTAssertEqual(h.store.data, legacyData)
        XCTAssertEqual(h.store.writes, writes)
        XCTAssertEqual(restored.snapshot().tasks.first?.deadlineAt, task.scheduledAt + 3_600_000)
        XCTAssertEqual(restored.snapshot().runs.first?.deadlineAt, task.scheduledAt + 3_600_000)

        try restored.setEnabled(false)
        try restored.setEnabled(true)
        let original = try XCTUnwrap(restored.snapshot().tasks.first)
        XCTAssertEqual(original.deadlineAt, task.scheduledAt + 3_600_000)
        XCTAssertEqual(restored.snapshot().runs.first?.deadlineAt, task.scheduledAt + 3_600_000)

        let copied = try restored.copy(id: original.id)
        XCTAssertEqual(copied.deadlineAt, copied.scheduledAt + 900_000)
        XCTAssertEqual(restored.snapshot().tasks.first(where: { $0.id == original.id })?.deadlineAt, original.deadlineAt)
        let saved = try restored.update(id: original.id, expectedRevision: original.revision, draft: original.draft)
        XCTAssertEqual(saved.deadlineAt, saved.scheduledAt + 900_000)
        let historical = try XCTUnwrap(restored.snapshot().runs.first(where: { $0.scheduleRevision == 1 && $0.taskID == task.id }))
        XCTAssertEqual(historical.status, .cancelled)
        XCTAssertEqual(historical.deadlineAt, task.scheduledAt + 3_600_000)
        XCTAssertNoThrow(try CourierEngine.validate(XCTUnwrap(h.store.data)))
    }

    func testCrashRecoveryPreservesLegacyWindowAndDispatchEvidence() throws {
        let h = try Harness(), claim = try h.ready()
        _ = try h.send(claim)
        var envelope = try JSONDecoder().decode(CourierEnvelope.self, from: XCTUnwrap(h.store.data))
        envelope.tasks[0].deadlineAt = claim.run.scheduledAt + 3_600_000
        envelope.runs[0].deadlineAt = claim.run.scheduledAt + 3_600_000
        h.store.data = try JSONEncoder().encode(envelope)

        let restored = try CourierEngine(store: h.store, now: { h.clock.at }, serviceEpoch: "epoch-restarted")
        let run = try XCTUnwrap(restored.snapshot().runs.first)
        XCTAssertEqual(run.status, .unknown)
        XCTAssertEqual(run.deadlineAt, claim.run.scheduledAt + 3_600_000)
        XCTAssertEqual(run.attempts.first?.authorization, claim.authorization)
        XCTAssertEqual(restored.snapshot().tasks.first?.deadlineAt, run.deadlineAt)
        XCTAssertNoThrow(try CourierEngine.validate(XCTUnwrap(h.store.data)))
    }

    func testTextSummaryCollapsesMultilineAndUnicodeWhitespace() {
        let text = "\t \r\n部署\u{00A0}\u{2003}前\u{2028}\u{3000}先跑测试\u{0085} \n"
        XCTAssertEqual(CourierTextSummary.make(text), "部署 前 先跑测试")
        XCTAssertEqual(CourierTextSummary.make("\t\r\n\u{00A0}\u{2003}\u{2028}\u{3000}"), "")
    }

    func testTextSummaryBoundaryCountsWholeUnicodeCharactersAndEllipsis() {
        let decomposed = String(repeating: "e\u{301}", count: 118)
        let atLimit = decomposed + "👨‍👩‍👧‍👦🇨🇳"
        XCTAssertEqual(atLimit.count, 120)
        XCTAssertEqual(Array(CourierTextSummary.make(atLimit).utf8), Array(atLimit.utf8))
        let shortened = CourierTextSummary.make(atLimit + "尾")
        XCTAssertEqual(shortened.count, 120)
        XCTAssertEqual(Array(shortened.utf8), Array((decomposed + "👨‍👩‍👧‍👦…").utf8))
    }

    func testTextDerivedInternalNameDoesNotChangePersistedOrPermittedSendingText() throws {
        let h = try Harness()
        let text = " \r\n" + String(repeating: "检查 👨‍👩‍👧‍👦 e\u{301}\n", count: 40) + "\t "
        let original = Array(text.utf8)
        var draft = h.draft(text: text)
        draft.name = CourierTextSummary.make(text)
        let task = try h.engine.create(draft)
        XCTAssertEqual(task.name.count, 120)
        XCTAssertTrue(task.name.hasSuffix("…"))
        let stored = try JSONDecoder().decode(CourierEnvelope.self, from: XCTUnwrap(h.store.data))
        XCTAssertEqual(Array(try XCTUnwrap(stored.tasks.first).text.utf8), original)
        try h.host(); h.clock.at = task.scheduledAt
        let claim = try XCTUnwrap(h.engine.claim(CourierClaimRequest(serviceEpoch: "epoch-1", brokerSession: "host-1")))
        let permit = try h.send(claim)
        XCTAssertEqual(Array(permit.text.utf8), original)
        XCTAssertEqual(Array(text.utf8), original)
    }

    func testDraftValidationAndTargetWhitelist() throws {
        let h = try Harness()
        var draft = h.draft(); draft.text = String(repeating: "x", count: CourierLimits.maximumTextBytes + 1)
        expect("courier-task-invalid") { _ = try h.engine.create(draft) }
        draft = h.draft(); draft.name = String(repeating: "字", count: 121)
        expect("courier-task-invalid") { _ = try h.engine.create(draft) }
        draft = h.draft(); draft.target.bundleID = "com.unrelated.application"
        expect("courier-target-invalid") { _ = try h.engine.create(draft) }
        draft = h.draft(); draft.scheduledAt = .nan
        expect("courier-task-invalid") { _ = try h.engine.create(draft) }
        let mockStore = CourierMemoryStore()
        let mock = try CourierEngine(store: mockStore, now: { h.clock.at }, allowedBundleIDs: ["local.reset-rune.mock.codex"])
        draft = h.draft(); draft.target.bundleID = "local.reset-rune.mock.codex"
        XCTAssertNoThrow(try mock.create(draft))
        expect("courier-target-invalid") { _ = try mock.create(h.draft()) }
    }

    func testReadOnlyValidationDoesNotRecoverOrWrite() throws {
        let h = try Harness(), claim = try h.ready()
        _ = try h.send(claim)
        let bytes = try XCTUnwrap(h.store.data), writes = h.store.writes
        XCTAssertNoThrow(try CourierEngine.validate(bytes))
        XCTAssertEqual(h.store.writes, writes)
        XCTAssertEqual(try JSONDecoder().decode(CourierEnvelope.self, from: bytes).runs.first?.status, .dispatching)
        expect("courier-state-invalid") { try CourierEngine.validate(Data("invalid".utf8)) }
        var state = try JSONDecoder().decode(CourierEnvelope.self, from: bytes); state.version = 999
        expect("courier-state-unsupported") { try CourierEngine.validate(try JSONEncoder().encode(state)) }
    }

    func testDueTickPublishesOnceWithoutTimerSpinOrHost() throws {
        let h = try Harness(), task = try h.engine.create(h.draft())
        XCTAssertEqual(h.engine.nextActionAt(), task.scheduledAt)
        h.clock.at = task.scheduledAt
        try h.engine.tick()
        XCTAssertEqual(h.engine.nextActionAt(), task.deadlineAt)
        XCTAssertEqual(h.engine.snapshot().runs.first?.waitReason, "host-unavailable")
        let writes = h.store.writes
        try h.engine.tick()
        XCTAssertEqual(h.store.writes, writes)
        try h.host()
        XCTAssertNotNil(try h.engine.claim(CourierClaimRequest(serviceEpoch: "epoch-1", brokerSession: "host-1")))
    }

    func testClaimReplayReturnsSameAttemptAndGlobalExclusion() throws {
        let h = try Harness(), first = try h.ready()
        let replay = try XCTUnwrap(h.engine.claim(CourierClaimRequest(serviceEpoch: "epoch-1", brokerSession: "host-1")))
        XCTAssertEqual(first.authorization, replay.authorization)
        let other = try h.engine.create(h.draft())
        h.clock.at = other.scheduledAt
        expect("courier-delivery-busy") { _ = try h.engine.claim(CourierClaimRequest(serviceEpoch: "epoch-1", brokerSession: "host-1", runID: "\(other.id):1")) }
        expect("courier-stale-epoch") { _ = try h.engine.claim(CourierClaimRequest(serviceEpoch: "old", brokerSession: "host-1")) }
        expect("courier-host-unavailable") { _ = try h.engine.claim(CourierClaimRequest(serviceEpoch: "epoch-1", brokerSession: "different")) }
    }

    func testBeginInputRequiresStableTargetEmptyComposerAndCursor() throws {
        let h = try Harness(), claim = try h.ready()
        var preflight = CourierPreflight(target: claim.run.target, messageCursor: "cursor", identityVerified: true, composerEmpty: false, hostReady: true)
        expect("courier-preflight-rejected") { _ = try h.engine.beginInput(auth: claim.authorization, preflight: preflight) }
        preflight.composerEmpty = true; preflight.target.threadID = "another-thread"
        expect("courier-preflight-rejected") { _ = try h.engine.beginInput(auth: claim.authorization, preflight: preflight) }
        preflight.target = claim.run.target; preflight.messageCursor = ""
        expect("courier-preflight-rejected") { _ = try h.engine.beginInput(auth: claim.authorization, preflight: preflight) }
        preflight.messageCursor = "cursor"
        _ = try h.engine.beginInput(auth: claim.authorization, preflight: preflight)
        XCTAssertNoThrow(try h.engine.beginInput(auth: claim.authorization, preflight: preflight))
        preflight.messageCursor = "different"
        expect("courier-preflight-conflict") { _ = try h.engine.beginInput(auth: claim.authorization, preflight: preflight) }
    }

    func testCodexDesktopIPCPreflightDoesNotPretendComposerWasInspected() throws {
        let h = try Harness(), claim = try h.ready()
        let native = CourierPreflight(target: claim.run.target, messageCursor: "owner-snapshot-cursor", identityVerified: true,
                                      composerEmpty: false, hostReady: true, inputMode: .desktopIPC)
        var invalid = native; invalid.identityVerified = false
        expect("courier-preflight-rejected") { _ = try h.engine.beginInput(auth: claim.authorization, preflight: invalid) }
        invalid = native; invalid.hostReady = false
        expect("courier-preflight-rejected") { _ = try h.engine.beginInput(auth: claim.authorization, preflight: invalid) }
        invalid = native; invalid.messageCursor = ""
        expect("courier-preflight-rejected") { _ = try h.engine.beginInput(auth: claim.authorization, preflight: invalid) }
        invalid = native; invalid.target.threadID = "another-conversation"
        expect("courier-preflight-rejected") { _ = try h.engine.beginInput(auth: claim.authorization, preflight: invalid) }
        let approved = try h.engine.beginInput(auth: claim.authorization, preflight: native)
        XCTAssertEqual(approved.run.attempts.last?.preflight?.inputMode, .desktopIPC)
        XCTAssertEqual(approved.run.attempts.last?.preflight?.composerEmpty, false)
        XCTAssertNoThrow(try h.engine.beginSend(auth: claim.authorization, target: claim.run.target, text: claim.run.text))
    }

    func testLegacyPreflightWithoutInputModeRetainsComposerRequirements() throws {
        let h = try Harness(), claim = try h.ready()
        let modern = CourierPreflight(target: claim.run.target, messageCursor: "legacy-cursor", identityVerified: true, composerEmpty: false, hostReady: true)
        XCTAssertEqual(modern.inputMode, .composer)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(modern)) as? [String: Any])
        object.removeValue(forKey: "inputMode")
        var legacy = try JSONDecoder().decode(CourierPreflight.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.inputMode)
        expect("courier-preflight-rejected") { _ = try h.engine.beginInput(auth: claim.authorization, preflight: legacy) }
        legacy.composerEmpty = true
        _ = try h.engine.beginInput(auth: claim.authorization, preflight: legacy)
        XCTAssertNoThrow(try CourierEngine.validate(XCTUnwrap(h.store.data)))
        let durable = try JSONDecoder().decode(CourierEnvelope.self, from: XCTUnwrap(h.store.data))
        XCTAssertNil(durable.runs.first?.attempts.last?.preflight?.inputMode)
    }

    func testDesktopIPCModeCannotExemptClaudeOrMockComposerChecks() throws {
        let cases: [(CourierAgent, String)] = [(.claude, "com.anthropic.claudefordesktop"), (.codex, "local.reset-rune.mock.codex")]
        for (agent, bundleID) in cases {
            let clock = Clock(), store = CourierMemoryStore()
            let engine = try CourierEngine(store: store, now: { clock.at }, serviceEpoch: "mode-test", allowedBundleIDs: [bundleID])
            try engine.setEnabled(true)
            let target = CourierTarget(agent: agent, bundleID: bundleID, sourceID: "synthetic-source", threadID: "synthetic-thread", title: "Synthetic")
            let task = try engine.create(CourierTaskDraft(name: "Mode gate", text: "synthetic", target: target, scheduledAt: clock.at + 1000))
            _ = try engine.registerHost(CourierHostRegistration(brokerSession: "mode-host", processID: 101, processStartedAt: 100))
            clock.at = task.scheduledAt
            let claim = try XCTUnwrap(engine.claim(CourierClaimRequest(serviceEpoch: "mode-test", brokerSession: "mode-host")))
            for composerEmpty in [false, true] {
                let attempted = CourierPreflight(target: target, messageCursor: "cursor", identityVerified: true, composerEmpty: composerEmpty, hostReady: true, inputMode: .desktopIPC)
                expect("courier-preflight-rejected") { _ = try engine.beginInput(auth: claim.authorization, preflight: attempted) }
            }
            XCTAssertNil(engine.snapshot().runs.first?.attempts.last?.inputAuthorizedAt)
        }
    }

    func testPermitIsPersistedBeforeReturnAndNeverReissued() throws {
        let h = try Harness(), claim = try h.ready()
        expect("courier-preflight-rejected") { _ = try h.engine.beginSend(auth: claim.authorization, target: claim.run.target, text: claim.run.text) }
        try h.input(claim)
        expect("courier-preflight-rejected") { _ = try h.engine.beginSend(auth: claim.authorization, target: claim.run.target, text: "different") }
        let permit = try h.engine.beginSend(auth: claim.authorization, target: claim.run.target, text: claim.run.text)
        XCTAssertEqual(permit.expiresAt, h.clock.at + 5_000)
        let durable = try JSONDecoder().decode(CourierEnvelope.self, from: XCTUnwrap(h.store.data))
        XCTAssertEqual(durable.runs.first?.status, .dispatching)
        expect("courier-send-already-authorized") { _ = try h.engine.beginSend(auth: claim.authorization, target: claim.run.target, text: claim.run.text) }
    }

    func testWriteFailureNeverGrantsPermitAndClosesGate() throws {
        let h = try Harness(), claim = try h.ready()
        try h.input(claim)
        let before = h.store.data
        h.store.rejectWrites = true
        expect("courier-write-failed") { _ = try h.engine.beginSend(auth: claim.authorization, target: claim.run.target, text: claim.run.text) }
        XCTAssertEqual(h.store.data, before)
        XCTAssertEqual(h.engine.snapshot().runs.first?.status, .preparing)
        XCTAssertFalse(h.engine.snapshot().enabled)
        XCTAssertNil(h.engine.nextActionAt())
        h.store.rejectWrites = false
        expect("courier-store-unavailable") { _ = try h.engine.beginSend(auth: claim.authorization, target: claim.run.target, text: claim.run.text) }
    }

    func testClaimWriteFailureHasNoAttempt() throws {
        let h = try Harness(); try h.host()
        let task = try h.engine.create(h.draft()); h.clock.at = task.scheduledAt; try h.engine.tick()
        h.store.rejectWrites = true
        expect("courier-write-failed") { _ = try h.engine.claim(CourierClaimRequest(serviceEpoch: "epoch-1", brokerSession: "host-1")) }
        XCTAssertTrue(h.engine.snapshot().runs[0].attempts.isEmpty)
        XCTAssertEqual(h.engine.snapshot().runs[0].status, .scheduled)
    }

    func testVerifiedReceiptIsIdempotentAndDoesNotMeanWorkFinished() throws {
        let h = try Harness(), claim = try h.ready(); _ = try h.send(claim)
        let unverified = CourierReceiptRequest(authorization: claim.authorization, outcome: .sent)
        expect("courier-receipt-unverified") { _ = try h.engine.receipt(unverified) }
        let receipt = CourierReceiptRequest(authorization: claim.authorization, outcome: .sent, targetKey: claim.run.target.key, messageID: "new-user-message", evidence: "associated user message")
        let run = try h.engine.receipt(receipt), writes = h.store.writes
        XCTAssertEqual(run.status, .sent)
        XCTAssertEqual(try h.engine.receipt(receipt), run)
        XCTAssertEqual(h.store.writes, writes)
        XCTAssertEqual(h.engine.snapshot().tasks.first?.lifecycle, .completed)
        XCTAssertNil(try h.engine.claim(CourierClaimRequest(serviceEpoch: "epoch-1", brokerSession: "host-1")))
    }

    func testDeadlineBeforePermitAndUnknownAfterPermitAreDifferent() throws {
        let h = try Harness(), claim = try h.ready(); try h.input(claim)
        h.clock.at = claim.run.deadlineAt
        expect("courier-deadline-passed") { _ = try h.engine.beginSend(auth: claim.authorization, target: claim.run.target, text: claim.run.text) }
        try h.engine.tick()
        XCTAssertEqual(h.engine.snapshot().runs.first?.status, .missed)
        let other = try Harness(), active = try other.ready(); let permit = try other.send(active)
        other.clock.at = permit.expiresAt + CourierLimits.receiptMilliseconds
        try other.engine.tick()
        XCTAssertEqual(other.engine.snapshot().runs.first?.status, .unknown)
        other.clock.at = active.run.deadlineAt + 1
        try other.engine.tick()
        XCTAssertEqual(other.engine.snapshot().runs.first?.status, .unknown)
    }

    func testDefinitelyNotSentRetriesWithFixedDeadlineAndNewAttempt() throws {
        let h = try Harness(), claim = try h.ready()
        let retry = try h.engine.receipt(CourierReceiptRequest(authorization: claim.authorization, outcome: .definitelyNotSent, retryable: true, reason: "user-draft"))
        XCTAssertEqual(retry.status, .scheduled)
        XCTAssertEqual(retry.nextAttemptAt, h.clock.at + 30_000)
        XCTAssertEqual(retry.deadlineAt, claim.run.deadlineAt)
        XCTAssertNil(try h.engine.claim(CourierClaimRequest(serviceEpoch: "epoch-1", brokerSession: "host-1")))
        h.clock.at += 30_000
        let next = try XCTUnwrap(h.engine.claim(CourierClaimRequest(serviceEpoch: "epoch-1", brokerSession: "host-1")))
        XCTAssertNotEqual(next.authorization.attemptID, claim.authorization.attemptID)
        expect("courier-attempt-mismatch") { _ = try h.engine.beginSend(auth: claim.authorization, target: claim.run.target, text: claim.run.text) }
    }

    func testUnknownBlocksOnlySameConversationUntilExplicitConfirmation() throws {
        let h = try Harness(), first = try h.ready(); _ = try h.send(first)
        _ = try h.engine.receipt(CourierReceiptRequest(authorization: first.authorization, outcome: .unknown, reason: "no-message-evidence"))
        let same = try h.engine.create(h.draft())
        var target = h.target; target.threadID = "thread-2"
        let different = try h.engine.create(h.draft(target: target))
        h.clock.at = same.scheduledAt
        let claim = try XCTUnwrap(h.engine.claim(CourierClaimRequest(serviceEpoch: "epoch-1", brokerSession: "host-1")))
        XCTAssertEqual(claim.run.taskID, different.id)
        _ = try h.engine.receipt(CourierReceiptRequest(authorization: claim.authorization, outcome: .definitelyNotSent))
        XCTAssertNil(try h.engine.claim(CourierClaimRequest(serviceEpoch: "epoch-1", brokerSession: "host-1")))
        let confirmed = try h.engine.confirm(runID: first.run.id, sent: false)
        XCTAssertEqual(confirmed.status, .unknown)
        XCTAssertNotNil(confirmed.attempts.first?.becameUnknownAt)
        XCTAssertEqual(try h.engine.claim(CourierClaimRequest(serviceEpoch: "epoch-1", brokerSession: "host-1"))?.run.taskID, same.id)
    }

    func testGlobalPauseCannotSilentlyCatchUpAndIndividualPauseIsIndependent() throws {
        let h = try Harness()
        let due = try h.engine.create(h.draft()), future = try h.engine.create(h.draft(delay: 100_000))
        var individual = try h.engine.create(h.draft(delay: 200_000))
        individual = try h.engine.setTaskEnabled(id: individual.id, expectedRevision: individual.revision, enabled: false)
        try h.engine.setEnabled(false)
        h.clock.at = due.scheduledAt + 1
        try h.engine.setEnabled(true)
        let tasks = h.engine.snapshot().tasks
        let overdue = try XCTUnwrap(tasks.first { $0.id == due.id })
        XCTAssertTrue(overdue.needsReschedule); XCTAssertFalse(overdue.enabled); XCTAssertEqual(overdue.lifecycle, .paused)
        XCTAssertEqual(tasks.first { $0.id == future.id }?.lifecycle, .scheduled)
        XCTAssertFalse(try XCTUnwrap(tasks.first { $0.id == individual.id }).enabled)
        expect("courier-reschedule-required") { _ = try h.engine.setTaskEnabled(id: overdue.id, expectedRevision: overdue.revision, enabled: true) }
        let restored = try h.engine.setTaskEnabled(id: overdue.id, expectedRevision: overdue.revision, enabled: true, scheduledAt: h.clock.at + 10_000)
        XCTAssertGreaterThan(restored.scheduleRevision, due.scheduleRevision)
    }

    func testPauseDuringPreparationClosesSendGate() throws {
        let h = try Harness(), claim = try h.ready(); try h.input(claim)
        try h.engine.setEnabled(false)
        expect("courier-paused") { _ = try h.engine.beginSend(auth: claim.authorization, target: claim.run.target, text: claim.run.text) }
        let run = try h.engine.receipt(CourierReceiptRequest(authorization: claim.authorization, outcome: .definitelyNotSent, retryable: true))
        XCTAssertEqual(run.status, .paused)
    }

    func testPauseAndResumePreparingRequiresNewScheduleAfterStopReceipt() throws {
        let h = try Harness(), claim = try h.ready(); try h.input(claim)
        try h.engine.setEnabled(false)
        try h.engine.setEnabled(true)
        expect("courier-task-paused") { _ = try h.engine.beginSend(auth: claim.authorization, target: claim.run.target, text: claim.run.text) }
        _ = try h.engine.receipt(CourierReceiptRequest(authorization: claim.authorization, outcome: .definitelyNotSent, retryable: true))
        let task = try XCTUnwrap(h.engine.snapshot().tasks.first)
        XCTAssertTrue(task.needsReschedule)
        let updated = try h.engine.setTaskEnabled(id: task.id, expectedRevision: task.revision, enabled: true, scheduledAt: h.clock.at + 10_000)
        XCTAssertGreaterThan(updated.scheduleRevision, task.scheduleRevision)
        XCTAssertEqual(h.engine.snapshot().runs.first { $0.id == claim.run.id }?.status, .cancelled)
    }

    func testLateUnsentStopReceiptAddsEvidenceWithoutRevivingDeletedTask() throws {
        let h = try Harness(), claim = try h.ready(); try h.input(claim)
        let task = try XCTUnwrap(h.engine.snapshot().tasks.first)
        try h.engine.delete(id: task.id, expectedRevision: task.revision)
        let receipt = CourierReceiptRequest(authorization: claim.authorization, outcome: .definitelyNotSent, retryable: true)
        XCTAssertEqual(try h.engine.receipt(receipt).status, .cancelled)
        XCTAssertEqual(try h.engine.receipt(receipt).status, .cancelled)
        XCTAssertTrue(h.engine.snapshot().tasks.isEmpty)
    }

    func testRevisionAndReadonlyBoundariesAndCopy() throws {
        let h = try Harness(), task = try h.engine.create(h.draft())
        expect("courier-revision-conflict") { _ = try h.engine.update(id: task.id, expectedRevision: 99, draft: h.draft()) }
        let updated = try h.engine.update(id: task.id, expectedRevision: task.revision, draft: h.draft(delay: 2_000))
        XCTAssertEqual(updated.scheduleRevision, 2)
        XCTAssertEqual(h.engine.snapshot().runs.first { $0.scheduleRevision == 1 }?.status, .cancelled)
        let copied = try h.engine.copy(id: task.id)
        XCTAssertNotEqual(copied.id, task.id); XCTAssertFalse(copied.enabled); XCTAssertEqual(copied.lifecycle, .draft)
        try h.host(); h.clock.at = updated.scheduledAt
        let claim = try XCTUnwrap(h.engine.claim(CourierClaimRequest(serviceEpoch: "epoch-1", brokerSession: "host-1")))
        expect("courier-task-readonly") { _ = try h.engine.update(id: updated.id, expectedRevision: updated.revision, draft: h.draft()) }
        try h.engine.delete(id: updated.id, expectedRevision: updated.revision)
        XCTAssertEqual(h.engine.snapshot().runs.first { $0.id == claim.run.id }?.status, .cancelled)
        expect("courier-send-already-authorized") { _ = try h.engine.beginSend(auth: claim.authorization, target: claim.run.target, text: claim.run.text) }
    }

    func testRestartMakesDispatchUnknownAndAcceptsOnlyMatchingOldReceipt() throws {
        let h = try Harness(), claim = try h.ready(); _ = try h.send(claim)
        let restarted = try CourierEngine(store: h.store, now: { h.clock.at }, serviceEpoch: "epoch-2")
        XCTAssertEqual(restarted.snapshot().runs.first?.status, .unknown)
        XCTAssertFalse(restarted.snapshot().hostAvailable)
        expect("courier-stale-epoch") { _ = try restarted.beginSend(auth: claim.authorization, target: claim.run.target, text: claim.run.text) }
        var receipt = CourierReceiptRequest(authorization: claim.authorization, outcome: .sent, targetKey: claim.run.target.key, messageID: "actual-user-message")
        receipt.authorization.nonce = "other"
        expect("courier-attempt-mismatch") { _ = try restarted.receipt(receipt) }
        receipt.authorization = claim.authorization
        XCTAssertEqual(try restarted.receipt(receipt).status, .sent)
    }

    func testRestartPreparingRequiresOldHostGateClosedOrProvenExit() throws {
        let h = try Harness(), claim = try h.ready(); try h.input(claim)
        let restarted = try CourierEngine(store: h.store, now: { h.clock.at }, serviceEpoch: "epoch-2")
        let registration = CourierHostRegistration(brokerSession: "host-2", processID: 101, processStartedAt: 100, previousGateClosed: true)
        expect("courier-host-recovery-wait") { _ = try restarted.registerHost(registration) }
        h.clock.at += 5_000
        _ = try restarted.registerHost(registration)
        XCTAssertEqual(restarted.snapshot().runs.first?.status, .scheduled)
        XCTAssertNotNil(try restarted.claim(CourierClaimRequest(serviceEpoch: "epoch-2", brokerSession: "host-2")))
        let replacement = CourierHostRegistration(brokerSession: "host-3", processID: 102, processStartedAt: 200)
        expect("courier-old-host-active") { _ = try restarted.registerHost(replacement) }
        XCTAssertNoThrow(try restarted.registerHost(replacement, previousHostStopped: true))
    }

    func testHostDisconnectDoesNotMeanSafeHandoff() throws {
        let h = try Harness(), claim = try h.ready(); try h.input(claim)
        try h.engine.hostDisconnected(brokerSession: "host-1")
        XCTAssertFalse(h.engine.snapshot().hostAvailable)
        XCTAssertEqual(h.engine.snapshot().runs.first?.status, .preparing)
        expect("courier-old-host-active") { _ = try h.engine.registerHost(CourierHostRegistration(brokerSession: "another", processID: 222, processStartedAt: 200)) }
        XCTAssertNoThrow(try h.engine.registerHost(CourierHostRegistration(brokerSession: "another", processID: 222, processStartedAt: 200), previousHostStopped: true))
    }

    func testDeletedDispatchRetainsUnknownEvidence() throws {
        let h = try Harness(), claim = try h.ready(); _ = try h.send(claim)
        let task = try XCTUnwrap(h.engine.snapshot().tasks.first)
        try h.engine.delete(id: task.id, expectedRevision: task.revision)
        XCTAssertTrue(h.engine.snapshot().tasks.isEmpty)
        XCTAssertEqual(h.engine.snapshot().runs.first?.status, .unknown)
        XCTAssertEqual(h.engine.snapshot().runs.first?.attempts.first?.authorization, claim.authorization)
    }

    func testCapacityNeverDiscardsUnknownAndCriticalConfirmationUsesReserve() throws {
        let h = try Harness(), claim = try h.ready(); _ = try h.send(claim)
        _ = try h.engine.receipt(CourierReceiptRequest(authorization: claim.authorization, outcome: .unknown))
        var envelope = try JSONDecoder().decode(CourierEnvelope.self, from: XCTUnwrap(h.store.data))
        let task = try XCTUnwrap(envelope.tasks.first), run = try XCTUnwrap(envelope.runs.first)
        envelope.tasks = []; envelope.runs = []
        let text = String(repeating: "x", count: 32 * 1024)
        for index in 0..<195 {
            var t = task; t.id = "large-task-\(index)"; t.text = text
            var r = run; r.id = "large-run-\(index)"; r.taskID = t.id; r.text = text
            r.attempts[0].authorization.runID = r.id
            envelope.tasks.append(t); envelope.runs.append(r)
        }
        let bytes = try JSONEncoder().encode(envelope)
        XCTAssertGreaterThan(bytes.count, CourierLimits.ordinaryBytes)
        XCTAssertLessThan(bytes.count, CourierLimits.hardBytes)
        let store = CourierMemoryStore(data: bytes), engine = try CourierEngine(store: store, now: { h.clock.at })
        expect("courier-state-capacity") { _ = try engine.create(h.draft()) }
        XCTAssertEqual(engine.snapshot().runs.count, 195)
        XCTAssertNoThrow(try engine.confirm(runID: "large-run-0", sent: false))
        XCTAssertLessThanOrEqual(try XCTUnwrap(store.data).count, CourierLimits.hardBytes)
    }

    func testTargetIdentityIgnoresTitleButDoesNotNormalizeUnicodeIdentifiers() throws {
        let h = try Harness()
        var renamed = h.target; renamed.title = "Renamed"
        XCTAssertTrue(h.target.isSameConversation(as: renamed))
        var first = h.target, second = h.target
        first.threadID = "é"; second.threadID = "e\u{301}"
        XCTAssertFalse(first.isSameConversation(as: second))
    }

    func testDefaultClockProducesRestartableWholeMillisecondAttempts() throws {
        let h = try Harness()
        _ = try h.engine.create(h.draft())
        var envelope = try JSONDecoder().decode(CourierEnvelope.self, from: XCTUnwrap(h.store.data))
        let at = (Date().timeIntervalSince1970 * 1000).rounded()
        envelope.tasks[0].scheduledAt = at - 1_000; envelope.tasks[0].deadlineAt = at + 899_000
        envelope.runs[0].scheduledAt = at - 1_000; envelope.runs[0].deadlineAt = at + 899_000; envelope.runs[0].nextAttemptAt = at - 1_000
        let store = CourierMemoryStore(data: try JSONEncoder().encode(envelope))
        let engine = try CourierEngine(store: store, serviceEpoch: "default-clock")
        _ = try engine.registerHost(CourierHostRegistration(brokerSession: "default-host", processID: 301, processStartedAt: at - 10_000))
        let claim = try XCTUnwrap(engine.claim(CourierClaimRequest(serviceEpoch: "default-clock", brokerSession: "default-host")))
        XCTAssertEqual(claim.run.attempts[0].claimedAt.rounded(), claim.run.attempts[0].claimedAt)
        XCTAssertNoThrow(try CourierEngine.validate(XCTUnwrap(store.data)))
        XCTAssertNoThrow(try CourierEngine(store: store))
    }

    func testReceiptConflictCannotDowngradeSentOrReuseFinishedAttempt() throws {
        let h = try Harness(), claim = try h.ready(); _ = try h.send(claim)
        let sent = CourierReceiptRequest(authorization: claim.authorization, outcome: .sent, targetKey: claim.run.target.key, messageID: "message")
        _ = try h.engine.receipt(sent)
        expect("courier-receipt-conflict") { _ = try h.engine.receipt(CourierReceiptRequest(authorization: claim.authorization, outcome: .unknown)) }
        expect("courier-receipt-conflict") { _ = try h.engine.receipt(CourierReceiptRequest(authorization: claim.authorization, outcome: .definitelyNotSent, retryable: true)) }
        XCTAssertEqual(h.engine.snapshot().runs.first?.status, .sent)
    }
}
