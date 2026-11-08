import XCTest
import CourierCore
import DesktopAutomation
@testable import RuneMenu

final class CourierEditorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func editor() -> CourierEditorDraft {
        var value = CourierEditorDraft()
        value.text = "Review these changes.\n保留原文 🧪。 e\u{301}"
        value.target = CourierTarget(agent: .codex, bundleID: "local.reset-rune.mock.codex", sourceID: "synthetic", threadID: "chat-a", title: "Same title", appVersion: "simulation")
        value.date = now.addingTimeInterval(300)
        return value
    }

    func testRelativeScheduleFixesTimeAtSaveAndUsesIntegerMilliseconds() throws {
        var value = editor()
        value.timeMode = .relative
        value.delayMinutes = 30
        let saved = try value.validated(now: now.addingTimeInterval(0.1234))
        XCTAssertEqual(saved.scheduledAt, 2_000_001_800_123)
        XCTAssertEqual(saved.deadlineAt - saved.scheduledAt, 900_000)
        XCTAssertEqual(saved.scheduledAt.rounded(), saved.scheduledAt)
        // The persisted draft contains a fixed instant, not a duration to restart.
        let restored = try JSONDecoder().decode(CourierTaskDraft.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.scheduledAt, saved.scheduledAt)
    }

    func testSaveNeedsNoNameAndEnablesTheTaskWithOriginalText() throws {
        let value = editor()
        let draft = try value.validated(now: now)
        XCTAssertEqual(Array(draft.text.utf8), Array(value.text.utf8))
        XCTAssertEqual(draft.target.threadID, "chat-a")
        XCTAssertEqual(draft.name, "Review these changes. 保留原文 🧪。 e\u{301}")
        XCTAssertTrue(draft.enabled)
    }

    func testAbsolutePickerDoesNotScheduleAtInvisibleSeconds() throws {
        var value=editor()
        value.date=now.addingTimeInterval(323.456)
        let draft=try value.validated(now:now)
        let saved=Date(timeIntervalSince1970:draft.scheduledAt/1000)
        XCTAssertEqual(Calendar.current.component(.second,from:saved),0)
        XCTAssertEqual(draft.scheduledAt.truncatingRemainder(dividingBy:1000),0)
        XCTAssertEqual(draft.deadlineAt-draft.scheduledAt,900_000)
    }

    func testPastTimeAndNonpositiveDelayAreRejected() {
        var value = editor()
        value.date = now
        XCTAssertThrowsError(try value.validated(now: now))
        value.timeMode = .relative
        value.delayMinutes = 0
        XCTAssertThrowsError(try value.validated(now: now))
    }

    func testTargetMustMatchSelectedApplication() {
        var value = editor()
        value.agent = .claude
        XCTAssertThrowsError(try value.validated(now: now))
        value.target = nil
        XCTAssertThrowsError(try value.validated(now: now))
    }

    func testSaveAlwaysUsesDefaultFifteenMinuteDeadline() throws {
        var value = editor()
        let draft = try value.validated(now: now)
        XCTAssertEqual(draft.deadlineAt - draft.scheduledAt, 900_000)
        value.timeMode = .relative
        value.delayMinutes = 60
        let relative = try value.validated(now: now)
        XCTAssertEqual(relative.deadlineAt - relative.scheduledAt, 900_000)
    }

    func testEditingLegacyTaskDerivesSummaryAndReplacesOldSixtyMinuteDeadline() throws {
        let store = CourierMemoryStore()
        let engine = try CourierEngine(store: store, now: { self.now.timeIntervalSince1970 * 1000 }, allowedBundleIDs: ["local.reset-rune.mock.codex"])
        let original = editor()
        var task = try engine.create(CourierTaskDraft(name: "Legacy manual name", text: original.text, target: original.target!, scheduledAt: now.addingTimeInterval(300).timeIntervalSince1970 * 1000, enabled: false))
        // Represent a task loaded from the previous schema without writing it to any store.
        task.deadlineAt = task.scheduledAt + 3_600_000
        let saved = try CourierEditorDraft(task: task, now: now).validated(now: now)
        XCTAssertEqual(saved.name, CourierTextSummary.make(original.text))
        XCTAssertNotEqual(saved.name, task.name)
        XCTAssertTrue(saved.enabled)
        XCTAssertEqual(Array(saved.text.utf8), Array(original.text.utf8))
        XCTAssertEqual(saved.deadlineAt - saved.scheduledAt, 900_000)
    }

    func testDeliveryCopyNeverClaimsAgentWorkFinished() {
        XCTAssertEqual(CourierCopy.text("sent", language: "zh"), "文本已发送")
        XCTAssertEqual(CourierCopy.text("unknown", language: "en"), "Delivery needs confirmation")
        XCTAssertTrue(CourierCopy.text("semantics", language: "zh").contains("不代表 Agent 已完成"))
    }

    func testCodexNativeChannelNeverRequestsAccessibility() {
        let codex = DesktopCompatibility(agent: .codex, version: "synthetic", canDiscover: true, canSend: true, blockers: [], requiresAccessibility: false)
        XCTAssertFalse(CourierPermissionPolicy.requestsAccessibility(enabling: true, mock: false, compatibility: codex))
        XCTAssertTrue(CourierCopy.text("codexPermissions", language: "zh").contains("无需辅助功能权限"))
    }

    func testAccessibilityIsOnlyRequestedForAnEnabledSendableAXRoute() {
        let claude = DesktopCompatibility(agent: .claude, version: "synthetic", canDiscover: true, canSend: true, blockers: [], requiresAccessibility: true)
        XCTAssertTrue(CourierPermissionPolicy.requestsAccessibility(enabling: true, mock: false, compatibility: claude))
        XCTAssertFalse(CourierPermissionPolicy.requestsAccessibility(enabling: false, mock: false, compatibility: claude))
        XCTAssertFalse(CourierPermissionPolicy.requestsAccessibility(enabling: true, mock: true, compatibility: claude))
        let blocked = DesktopCompatibility(agent: .claude, version: "synthetic", canDiscover: true, canSend: false, blockers: [.unsupportedVersion], requiresAccessibility: true)
        XCTAssertFalse(CourierPermissionPolicy.requestsAccessibility(enabling: true, mock: false, compatibility: blocked))
    }
}
