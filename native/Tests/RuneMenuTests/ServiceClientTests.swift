import Dispatch
import Foundation
import XCTest
@testable import RuneMenu

// This box deliberately permits concurrent calls to the shared client under test.
private final class SharedDiscoveryClient: @unchecked Sendable {
    let value: PanelServiceClient
    init(_ value: PanelServiceClient) { self.value = value }
}

private final class DiscoveryRaceReport: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []
    func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        if failures.count < 8 { failures.append(message) }
    }
    var problems: [String] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }
}

final class ServiceClientTests: XCTestCase {
    func testConcurrentDiscoverCacheReadsAndResetsKeepCompleteMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reset-rune-client-concurrency-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("simulation", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let metadata = try JSONSerialization.data(withJSONObject: [
            "port": 41001,
            "token": String(repeating: "c", count: 43),
            "mode": "mock",
            "protocol": 1
        ])
        let metadataURL = directory.appendingPathComponent("connection.json")
        try metadata.write(to: metadataURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
        let expected = try JSONDecoder().decode(PanelConnection.self, from: metadata)
        let shared = SharedDiscoveryClient(PanelServiceClient(mock: true, environment: ["RESET_RUNE_DATA_DIR": root.path]))
        defer { shared.value.close() }
        let report = DiscoveryRaceReport()

        // Exercise ARC retain/release on the cached Optional/String concurrently.
        // No read(), URLSession task, helper process, or network connection is started.
        DispatchQueue.concurrentPerform(iterations: 16) { worker in
            for iteration in 0..<768 {
                switch (worker + iteration) % 3 {
                case 0:
                    do {
                        if try shared.value.discover() != expected { report.record("Discovery returned inconsistent synthetic metadata") }
                    } catch { report.record("Discovery failed for valid isolated metadata: \(error)") }
                case 1:
                    if let cached = shared.value.connection {
                        if cached != expected { report.record("Cached metadata was incomplete or inconsistent") }
                        do {
                            let request = try cached.request("status")
                            if request.value(forHTTPHeaderField: "Authorization") != "Bearer \(expected.token)" {
                                report.record("Cached token could not construct the expected request")
                            }
                        } catch { report.record("Cached metadata could not construct a request") }
                    }
                default:
                    shared.value.resetConnection()
                }
            }
        }

        let problems = report.problems
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "; "))
        shared.value.resetConnection()
        XCTAssertNil(shared.value.connection)
        XCTAssertEqual(try shared.value.discover(), expected)
        XCTAssertEqual(shared.value.connection, expected)
    }
}
