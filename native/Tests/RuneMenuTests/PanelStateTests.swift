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
        XCTAssertEqual(result.inventoryRows(now: 1000).map(\.count), [1, 2])
        XCTAssertNil(result.inventoryRows(now: 1000).last?.expiresAt)
    }

    func testEmptyAndUnknownRemainDifferent() throws {
        XCTAssertEqual(try state(count: 0).bottle(), .empty)
        XCTAssertEqual(try state(count: NSNull()).bottle(), .unknown)
        XCTAssertEqual(try state(count: 3, status: "unconfirmed").bottle(), .unknown)
        XCTAssertEqual(try state(count: 3).bottle(disconnected: true), .unknown)
    }

    func testExpiredSnapshotDoesNotClaimAnAvailableRuneUntilReadAgain() throws {
        var result = try state(count: 1, credits: [["id": "first", "expiresAt": 20000]])
        result.lastCheckedAt = 10000
        XCTAssertEqual(result.bottle(now: 19999), .stored)
        XCTAssertEqual(result.bottle(now: 20000), .unknown)
        result.lastCheckedAt = 21000
        XCTAssertEqual(result.bottle(now: 21000), .stored)
    }

    func testInventoryRowsIncludeEarliestAndGroupSameMinute() throws {
        let result = try state(count: 5, credits: [
            ["id": "later", "expiresAt": 125000], ["id": "also-later", "expiresAt": 127000],
            ["id": "first", "expiresAt": 20000], ["id": "same-minute", "expiresAt": 21000],
            ["id": "past", "expiresAt": 5000], ["id": "unknown", "expiresAt": NSNull()]
        ])
        XCTAssertEqual(result.nextCredit(now: 10000)?.id, "first")
        let rows = result.inventoryRows(now: 10000)
        XCTAssertEqual(rows.map(\.expiresAt), [20000, 125000, nil])
        XCTAssertEqual(rows.map(\.count), [2, 2, 1])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        let single = try state(count: 1, credits: [["id": "first", "expiresAt": 20000]])
        XCTAssertEqual(single.inventoryRows(now: 10000), [PanelRuneRow(id: "minute-0", expiresAt: 20000, count: 1)])
        XCTAssertEqual(single.inventoryRows(now: 20000), [PanelRuneRow(id: "unknown", expiresAt: nil, count: 1)])
    }

    func testExpiredOrInvalidDatesNeverBecomeNext() throws {
        let result = try state(credits: [["id": "expired", "expiresAt": 500], ["id": "missing", "expiresAt": NSNull()], ["id": "future", "expiresAt": 20000]])
        XCTAssertEqual(result.nextCredit(now: 1000)?.id, "future")
        XCTAssertNil(result.nextCredit(now: 20000))
        XCTAssertEqual(result.inventoryRows(now: 1000).map(\.expiresAt), [20000, nil])
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
        XCTAssertEqual(PanelCopy.text("intro", language: "zh"), "在 Codex 重置神符过期前自动使用")
        XCTAssertEqual(PanelCopy.status("reset", language: "zh", mock: true), "重置神符已使用 · 模拟兑换")
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
