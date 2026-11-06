// Synthetic transport tests only. HOME/CODEX_HOME and executable are isolated.
import XCTest
import Foundation
import CryptoKit
import RuneCore
@testable import CodexTransport

private let expiry: Double = 1_794_000_000_000
private var identity: JSONObject {
    ["accountId": "mock-account", "email": "mock@example.test",
     "scope": "codex:" + SHA256.hash(data: Data("mock@example.test".utf8)).map { String(format: "%02x", $0) }.joined()]
}
private var operation: JSONObject {
    ["id": "mock-credit", "key": "8ae96ff3-3425-4f4c-8772-b6fd61502868", "identity": identity,
     "expiresAt": expiry, "startsAt": expiry - 600_000]
}
private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

private final class Fixture {
    let home: URL, executable: URL, source: CodexSource
    init(mode: String = "normal", timeoutMs: Int = 3000, consume: Bool = false,
         now: @escaping () -> Double = { expiry - 1000 }) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("reset-rune-native-codex-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        executable = home.appendingPathComponent("codex")
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("test/reference/codex/fixtures/app-server.mjs").path), root.path != "/" {
            root.deleteLastPathComponent()
        }
        let fixture = root.appendingPathComponent("test/reference/codex/fixtures/app-server.mjs")
        let nodePaths = ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":").map { String($0) + "/node" }
        let node = (nodePaths + ["/opt/homebrew/bin/node", "/usr/local/bin/node"]).first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let node else { throw XCTSkip("Node is required only to run the synthetic App Server fixture") }
        let body = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo probe >> \(shellQuote(home.appendingPathComponent("probes.txt").path)); fi\nexec \(shellQuote(node)) \(shellQuote(fixture.path)) \"$@\"\n"
        try body.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        source = CodexSource(executable: executable.path, timeoutMs: timeoutMs,
            environment: ["HOME": home.path, "CODEX_HOME": home.appendingPathComponent(mode).path,
                          "OPENAI_API_KEY": "synthetic-must-not-be-inherited", "CODEX_API_KEY": "synthetic-must-not-be-inherited"],
            allowConsume: consume, now: now)
    }
    deinit { try? FileManager.default.removeItem(at: home) }
    func requests() throws -> [JSONObject] {
        let data = try String(contentsOf: home.appendingPathComponent("rpc.jsonl"), encoding: .utf8)
        return try data.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! JSONObject }
    }
}

final class ProtocolTests: XCTestCase {
    func testPinnedReadAndConcurrentCoalescing() async throws {
        let f = try Fixture()
        async let a = f.source.read()
        async let b = f.source.read()
        let snapshots = try await [a, b]
        XCTAssertEqual(f.source.mode, "readonly")
        for snapshot in snapshots {
            XCTAssertEqual((snapshot["identity"] as? JSONObject)?["scope"] as? String, identity["scope"] as? String)
            XCTAssertEqual(snapshot["availableCount"] as? Double, 2)
            XCTAssertEqual(snapshot["remainingPercent"] as? Double, 90)
            XCTAssertEqual(snapshot["redeemablePercent"] as? Double, 90)
            XCTAssertEqual((snapshot["credits"] as? [JSONObject])?.first?["expiresAt"] as? Double, expiry)
            XCTAssertEqual(snapshot["quotaRevision"] as? String, "[{\"remainingPercent\":90,\"durationMinutes\":300,\"resetsAt\":null},{\"remainingPercent\":100,\"durationMinutes\":10080,\"resetsAt\":null}]")
        }
        XCTAssertEqual(try f.requests().compactMap { $0["method"] as? String }, ["initialize", "initialized", "account/read", "account/rateLimits/read"])
        await f.source.close()
    }

    func testSignedOutDoesNotReadQuota() async throws {
        let f = try Fixture(mode: "signed-out")
        let snapshot = try await f.source.read()
        XCTAssertTrue(snapshot["identity"] is NSNull)
        XCTAssertTrue(snapshot["availableCount"] is NSNull)
        XCTAssertEqual(try f.requests().count, 3)
    }

    func testVersionCacheAndInvalidation() async throws {
        let f = try Fixture()
        _ = try await f.source.read(); _ = try await f.source.read()
        let probes = try String(contentsOf: f.home.appendingPathComponent("probes.txt"), encoding: .utf8)
        XCTAssertEqual(probes.split(separator: "\n").count, 1)
        try "#!/bin/sh\necho codex-cli 999.0.0\n".write(to: f.executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.executable.path)
        do { _ = try await f.source.read(); XCTFail("changed binary must be reprobed") }
        catch let error as RuneError { XCTAssertEqual(error.code, "runtime-incompatible") }
    }

    func testMalformedAndTimedOutSessions() async throws {
        for (mode, code, timeout) in [("wrong-version", "runtime-incompatible", 3000), ("stall", "timed-out", 150),
                                      ("oversized", "protocol-error", 3000), ("server-request", "protocol-error", 3000)] {
            let f = try Fixture(mode: mode, timeoutMs: timeout)
            do { _ = try await f.source.read(); XCTFail("expected \(code)") }
            catch let error as RuneError { XCTAssertEqual(error.code, code); XCTAssertFalse(error.notSent) }
        }
    }

    func testExplicitTargetKeyAndAllOutcomes() async throws {
        for (wire, outcome) in [("reset", "reset"), ("alreadyRedeemed", "already-redeemed"), ("nothingToReset", "nothing-to-reset"), ("noCredit", "no-credit"), ("secondary", "reset")] {
            let f = try Fixture(mode: "live-" + wire, consume: true)
            let actual = try await f.source.consume(operation, maySend: { true })
            XCTAssertEqual(actual, outcome)
            let requests = try f.requests()
            XCTAssertEqual(requests.compactMap { $0["method"] as? String }, ["initialize", "initialized", "account/read", "account/rateLimits/read", "account/read", "account/rateLimitResetCredit/consume"])
            let params = requests.last?["params"] as? JSONObject
            XCTAssertEqual(params?["creditId"] as? String, "mock-credit")
            XCTAssertEqual(params?["idempotencyKey"] as? String, operation["key"] as? String)
        }
    }

    func testPreflightNeverSendsForChangedIdentityOrIneligibleTarget() async throws {
        let cases: [(String, String, JSONObject, Double, Bool)] = [
            ("other-workspace", "identity-changed", [:], expiry - 1000, true),
            ("member-changed", "identity-changed", [:], expiry - 1000, true),
            ("notified", "identity-changed", [:], expiry - 1000, true),
            ("missing-credit", "credit-unavailable", [:], expiry - 1000, true),
            ("reset", "credit-unavailable", ["id": "wrong-id"], expiry - 1000, true),
            ("full", "preflight-ineligible", [:], expiry - 1000, true),
            ("reset", "expired", [:], expiry, true),
            ("reset", "preflight-ineligible", [:], expiry - 600_001, true),
            ("reset", "cancelled", [:], expiry - 1000, false)
        ]
        for (mode, code, override, at, allowed) in cases {
            let f = try Fixture(mode: "live-" + mode, consume: true, now: { at })
            var op = operation; op.merge(override) { _, replacement in replacement }
            do { _ = try await f.source.consume(op, maySend: { allowed }); XCTFail("expected \(code)") }
            catch let error as RuneError { XCTAssertEqual(error.code, code); XCTAssertTrue(error.notSent) }
            XCTAssertFalse(try f.requests().contains { $0["method"] as? String == "account/rateLimitResetCredit/consume" })
        }
    }

    func testResponseLossIsAmbiguousAndSanitized() async throws {
        let f = try Fixture(mode: "live-ambiguous", consume: true)
        do { _ = try await f.source.consume(operation, maySend: { true }); XCTFail("ambiguous result must fail") }
        catch let error as RuneError { XCTAssertEqual(error.code, "read-failed"); XCTAssertFalse(error.notSent); XCTAssertEqual(error.localizedDescription, "read-failed") }
        XCTAssertEqual(try f.requests().last?["method"] as? String, "account/rateLimitResetCredit/consume")
    }

    func testInventoryAndUnicodeNormalization() throws {
        let account: JSONObject = ["type": "chatgpt", "email": "mock@example.test"]
        let unknown = normalizeCodexSnapshot(account: account, usage: ["rateLimitResetCredits": ["availableCount": 3, "credits": NSNull()]])
        XCTAssertEqual(unknown["availableCount"] as? Double, 3)
        XCTAssertEqual(unknown["creditsKnown"] as? Bool, false)
        XCTAssertTrue((unknown["identity"] as? JSONObject)?["scope"] is NSNull)
        let credit: JSONObject = ["status": "available", "resetType": "codexRateLimits"]
        func row(_ values: JSONObject) -> JSONObject { credit.merging(values) { _, new in new } }
        let snapshot = normalizeCodexSnapshot(account: account, usage: ["rateLimits": ["limitId": "unrelated"], "rateLimitResetCredits": ["availableCount": 7, "credits": [
            row(["id": "unknown", "expiresAt": "1794000000"]), row(["id": "duplicate", "expiresAt": 1_794_000_000]),
            row(["id": "duplicate", "status": "redeeming"]), row(["id": "control\u{0}character"]), row(["id": "wrong-type", "resetType": "other"])
        ]]])
        let credits = snapshot["credits"] as? [JSONObject]
        XCTAssertEqual(credits?.count, 1); XCTAssertEqual(credits?.first?["id"] as? String, "unknown")
        XCTAssertTrue(credits?.first?["expiresAt"] is NSNull)
        let usage: JSONObject = ["accountId": "test", "rateLimits": ["limitId": "codex"]]
        let composed = normalizeCodexSnapshot(account: ["type": "chatgpt", "email": "é@example.test"], usage: usage)
        let decomposed = normalizeCodexSnapshot(account: ["type": "chatgpt", "email": "e\u{301}@example.test"], usage: usage)
        XCTAssertNotEqual((composed["identity"] as? JSONObject)?["scope"] as? String, (decomposed["identity"] as? JSONObject)?["scope"] as? String)
    }
}
