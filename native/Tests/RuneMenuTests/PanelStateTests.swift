import XCTest
@testable import RuneMenu

final class PanelStateTests: XCTestCase {
    private func state(count: Any = 3, status: String = "outside-window", credits: [[String: Any]] = []) throws -> PanelState {
        let json: [String: Any] = [
            "config": ["enabled": true, "lead": 10, "language": "en", "appearance": "system", "startup": false, "notify": true],
            "mode": "mock", "status": status, "consent": NSNull(), "error": NSNull(), "events": [],
            "snapshot": ["availableCount": count, "credits": credits, "remainingPercent": 18,
                         "identity": ["accountId": "synthetic-account", "scope": "synthetic-pool", "email": "hero@example.invalid"]]
        ]
        return try JSONDecoder().decode(PanelState.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testAuthorityCountDoesNotUseTruncatedRows() throws {
        let result = try state(credits: [["id": "visible", "expiresAt": 10000]])
        XCTAssertEqual(result.bottle(), .stored)
        XCTAssertEqual(result.snapshot?.availableCount, 3)
        XCTAssertEqual(result.snapshot?.credits?.count, 1)
    }

    func testEmptyAndUnknownRemainDifferent() throws {
        XCTAssertEqual(try state(count: 0).bottle(), .empty)
        XCTAssertEqual(try state(count: NSNull()).bottle(), .unknown)
        XCTAssertEqual(try state(count: 3, status: "unconfirmed").bottle(), .unknown)
        XCTAssertEqual(try state(count: 3).bottle(disconnected: true), .unknown)
    }

    func testDetailsOmitExactlyTheSummaryCredit() throws {
        let result = try state(credits: [
            ["id": "second", "expiresAt": 30000], ["id": "first", "expiresAt": 20000],
            ["id": "same-time", "expiresAt": 20000], ["id": "unknown", "expiresAt": NSNull()]
        ])
        let next = try XCTUnwrap(result.nextCredit(now: 10000))
        let others = result.otherCredits(now: 10000)
        XCTAssertEqual(next.expiresAt, 20000)
        XCTAssertEqual(others.count, 3)
        XCTAssertFalse(others.contains(where: { $0.id == next.id }))
        XCTAssertTrue(others.contains(where: { $0.expiresAt == 20000 }))
        XCTAssertEqual(others.last?.id, "unknown")
    }

    func testExpiredOrInvalidDatesNeverBecomeNext() throws {
        let result = try state(credits: [["id": "expired", "expiresAt": 500], ["id": "missing", "expiresAt": NSNull()], ["id": "future", "expiresAt": 20000]])
        XCTAssertEqual(result.nextCredit(now: 1000)?.id, "future")
        XCTAssertNil(result.nextCredit(now: 20000))
        XCTAssertFalse(validEpoch(.infinity))
        XCTAssertFalse(validEpoch(-1))
    }

    func testPrivateConnectionRejectsOtherPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reset-rune-ui-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let connection = directory.appendingPathComponent("connection.json")
        let data = try JSONSerialization.data(withJSONObject: ["port": 41001, "token": String(repeating: "a", count: 43), "mode": "readonly", "protocol": 1])
        try data.write(to: connection)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: connection.path)
        let client = PanelServiceClient(mock: false, environment: ["RESET_RUNE_DATA_DIR": directory.path])
        defer { client.close() }
        XCTAssertThrowsError(try client.discover())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: connection.path)
        XCTAssertEqual(try client.discover().port, 41001)
    }

    func testConnectionAlwaysUsesLiteralLoopbackOrigin() throws {
        let connection = PanelConnection(port: 41001, token: String(repeating: "a", count: 43), mode: "readonly", protocol: 1)
        let request = try connection.request("config", method: "PATCH", body: ["language": "zh"])
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        XCTAssertEqual(request.url?.port, 41001)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testChineseCopyAndEnglishDefaultAreExplicit() {
        XCTAssertEqual(PanelConfig().language, "en")
        XCTAssertEqual(PanelCopy.text("appearance", language: "zh"), "外观")
        XCTAssertEqual(PanelCopy.text("intro", language: "zh"), "在 Codex 备用重置过期前自动使用")
        XCTAssertEqual(PanelCopy.status("reset", language: "zh", mock: true), "恢复符已使用 · 模拟兑换")
    }

    func testBattleLogIdentitySurvivesPrependingAndDuplicateTimes() throws {
        var result = try state()
        result.events = [PanelEvent(at: 1000, type: "reset"), PanelEvent(at: 1000, type: "reset"), PanelEvent(at: 500, type: "intent")]
        let before = result.recentEvents().map(\.id)
        XCTAssertEqual(Set(before).count, 3)
        result.events.insert(PanelEvent(at: 2000, type: "checked"), at: 0)
        XCTAssertEqual(Array(result.recentEvents().map(\.id).dropFirst()), before)
        result.events.insert(PanelEvent(at: 3000, type: "deferred"), at: 0)
        XCTAssertEqual(result.recentEvents().count, 4, "Internal stages must not appear as misleading battle-log errors")
    }
}
