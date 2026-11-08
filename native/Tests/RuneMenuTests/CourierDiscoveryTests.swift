import XCTest
import CourierCore
import DesktopAutomation
@testable import RuneMenu

@MainActor
private final class DeferredDiscoveryAdapter: DesktopAdapter {
    let agent = DesktopAgent.codex
    struct Pending {
        let query: String
        let continuation: CheckedContinuation<DesktopDiscovery, Error>
    }
    var requests: [Pending] = []
    func compatibility() -> DesktopCompatibility {
        DesktopCompatibility(agent: .codex, version: "synthetic", canDiscover: true, canSend: true, blockers: [], requiresAccessibility: false)
    }
    func discoverTargets() async throws -> DesktopDiscovery { try await discoverTargets(matching: "") }
    func discoverTargets(matching query: String) async throws -> DesktopDiscovery {
        // Deliberately ignore cancellation to reproduce late, already-running database reads.
        try await withCheckedThrowingContinuation { requests.append(Pending(query: query, continuation: $0)) }
    }
    func complete(_ query: String, id: String, hasMore: Bool = false) {
        guard let index = requests.firstIndex(where: { $0.query == query }) else { XCTFail("Missing synthetic query"); return }
        let request = requests.remove(at: index)
        let target = DesktopTarget(agent: .codex, id: id, title: id, sourceID: "simulation", bundleID: "local.reset-rune.mock.codex", appVersion: "synthetic")
        request.continuation.resume(returning: DesktopDiscovery(targets: [target], compatibility: compatibility(), hasMore: hasMore))
    }
    func openTarget(_ target: DesktopTarget) async throws { throw DesktopBlockReason.cancelled }
    func preflight(_ target: DesktopTarget) async throws -> DesktopPreflight { throw DesktopBlockReason.cancelled }
    func stageText(_ text: String, preflight: DesktopPreflight) async throws -> DesktopStagedText { throw DesktopBlockReason.cancelled }
    func pressSend(_ staged: DesktopStagedText, permit: DesktopSendPermit, maySend: @escaping () -> Bool) async throws { throw DesktopBlockReason.cancelled }
    func verifyReceipt(_ staged: DesktopStagedText) async -> DesktopReceipt { DesktopReceipt(outcome: .unknown, targetID: staged.preflight.target.id) }
    func cancel() {}
}

final class CourierDiscoveryTests: XCTestCase {
    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    @MainActor
    func testAnOlderQueryCannotReplaceNewerResultsOrPaginationNotice() async {
        let adapter = DeferredDiscoveryAdapter()
        let model = CourierMenuModel(mock: true, adapterFactory: { _ in adapter })
        defer { model.close() }
        model.newTask()
        model.targetQuery = "old"
        model.discoverTargets()
        let firstStarted = await waitUntil { adapter.requests.count == 1 }
        XCTAssertTrue(firstStarted)
        model.targetQuery = "new"
        model.discoverTargets()
        let secondStarted = await waitUntil { adapter.requests.count == 2 }
        XCTAssertTrue(secondStarted)
        adapter.complete("new", id: "new-chat", hasMore: true)
        let updated = await waitUntil { model.targets.first?.threadID == "new-chat" }
        XCTAssertTrue(updated)
        XCTAssertTrue(model.hasMoreTargets)
        adapter.complete("old", id: "old-chat")
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(model.targets.map(\.threadID), ["new-chat"])
        XCTAssertTrue(model.hasMoreTargets)
        XCTAssertEqual(model.targetQuery, "new")
    }

    @MainActor
    func testSwitchingAgentInvalidatesPendingDiscoveryAndClearsSearch() async {
        let adapter = DeferredDiscoveryAdapter()
        let model = CourierMenuModel(mock: true, adapterFactory: { _ in adapter })
        defer { model.close() }
        model.newTask()
        model.targetQuery = "project"
        model.discoverTargets()
        let started = await waitUntil { adapter.requests.count == 1 }
        XCTAssertTrue(started)
        model.changeAgent(.claude)
        adapter.complete("project", id: "stale-codex-chat", hasMore: true)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(model.editor?.agent, .claude)
        XCTAssertEqual(model.targetQuery, "")
        XCTAssertTrue(model.targets.isEmpty)
        XCTAssertFalse(model.hasMoreTargets)
        XCTAssertFalse(model.discovering)
    }

    @MainActor
    func testNewTaskClearsSearchAndMoreResultsState() async {
        let adapter = DeferredDiscoveryAdapter()
        let model = CourierMenuModel(mock: true, adapterFactory: { _ in adapter })
        defer { model.close() }
        model.newTask()
        model.targetQuery = "wide match"
        model.discoverTargets()
        let started = await waitUntil { adapter.requests.count == 1 }
        XCTAssertTrue(started)
        adapter.complete("wide match", id: "a-chat", hasMore: true)
        let updated = await waitUntil { model.hasMoreTargets }
        XCTAssertTrue(updated)
        model.newTask()
        XCTAssertEqual(model.targetQuery, "")
        XCTAssertTrue(model.targets.isEmpty)
        XCTAssertFalse(model.hasMoreTargets)
        XCTAssertFalse(model.targetSearchPerformed)
    }

    func testPaginationCopyMakesTheLimitExplicitInBothLanguages() {
        XCTAssertTrue(CourierCopy.text("moreTargets", language: "zh").contains("500"))
        XCTAssertTrue(CourierCopy.text("moreTargets", language: "en").contains("Search"))
        XCTAssertTrue(CourierCopy.text("targetSearch", language: "zh").contains("聊天 ID"))
    }
}
