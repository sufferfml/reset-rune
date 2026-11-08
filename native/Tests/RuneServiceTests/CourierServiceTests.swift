import XCTest
import Foundation
@testable import RuneService
import RuneCore
import CourierCore

/// These tests only bind ephemeral loopback listeners and use synthetic sources in owner-only temporary directories.
final class CourierServiceTests: XCTestCase {
    private final class Clock {
        private let lock = NSLock()
        private var offset = 0.0
        func now() -> Double { lock.lock(); defer { lock.unlock() }; return (Date().timeIntervalSince1970 * 1000).rounded() + offset }
        func advance(_ milliseconds: Double) { lock.lock(); offset += milliseconds; lock.unlock() }
    }
    private struct Response {
        let status: Int
        let object: JSONObject
        let data: Data
        func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: data) }
    }
    private final class Fixture {
        let directory: URL
        let clock: Clock
        let rune: RuneEngine
        let courier: CourierEngine?
        let coordinator: ServiceCoordinator
        let server: LocalHTTPServer
        let port: Int
        let token = String(repeating: "c", count: 43)
        let session: URLSession

        init(corruptCourier: Bool = false) async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("courier-service-tests-" + UUID().uuidString)
            try PrivateFiles.ensure(directory)
            clock = Clock()
            rune = try RuneEngine(source: MockSource(directory: directory), store: MemoryStateStore())
            let store = try FileCourierStore(directory: directory)
            if corruptCourier {
                try Data("synthetic malformed courier state".utf8).write(to: store.file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.file.path)
            }
            var failure: String?, initializedCourier: CourierEngine?
            do {
                initializedCourier = try CourierEngine(store: store, now: { [clock] in clock.now() }, allowedBundleIDs: ["local.reset-rune.mock.codex", "local.reset-rune.mock.claude"])
                try initializedCourier?.setEnabled(true)
            } catch {
                initializedCourier = nil; failure = "courier-state-unavailable"
            }
            courier = initializedCourier
            coordinator = ServiceCoordinator(engine: rune, courier: courier, courierFailure: failure)
            port = Int.random(in: 44_000..<54_000)
            server = LocalHTTPServer(coordinator: coordinator, token: token, port: port)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 3
            session = URLSession(configuration: configuration)
            try await server.start()
            await coordinator.setPublisher { [server] value in server.publish(value) }
        }
        var target: CourierTarget {
            CourierTarget(agent: .codex, bundleID: "local.reset-rune.mock.codex", sourceID: "simulation", threadID: "synthetic-thread", title: "Synthetic test chat", appVersion: "simulation")
        }
        func draft(text: String = "private synthetic courier body", delay: Double = 60_000) -> CourierTaskDraft {
            CourierTaskDraft(name: "Synthetic courier task", text: text, target: target, scheduledAt: clock.now() + delay, timeZoneID: "Asia/Shanghai", enabled: true)
        }
        func request(_ path: String, method: String = "GET", object: JSONObject? = nil) async throws -> Response {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if let object {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: object)
            }
            let (data, response) = try await session.data(for: request)
            return Response(status: try XCTUnwrap(response as? HTTPURLResponse).statusCode,
                            object: try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONObject), data: data)
        }
        func firstEvent() async throws -> JSONObject {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 3
            let eventSession = URLSession(configuration: configuration)
            defer { eventSession.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/events")!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await eventSession.bytes(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            for try await line in bytes.lines where line.hasPrefix("data: ") {
                return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? JSONObject)
            }
            throw CourierError("synthetic-event-missing")
        }
        func close() async {
            session.invalidateAndCancel()
            await coordinator.close()
            await server.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
    private func withFixture(corruptCourier: Bool = false, _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture(corruptCourier: corruptCourier)
        do { try await body(fixture); await fixture.close() }
        catch { await fixture.close(); throw error }
    }
    private func json<T: Encodable>(_ value: T) throws -> JSONObject {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? JSONObject)
    }
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("courier-storage-tests-" + UUID().uuidString)
        try PrivateFiles.ensure(directory)
        return directory
    }

    func testCourierAcceptsFull32KiBTextWhileResetConfigKeeps4KiBLimit() async throws {
        try await withFixture { fixture in
            // Control characters force JSON escaping beyond raw-text size while remaining a valid 32 KiB body.
            let text = String(repeating: "x\n", count: 16 * 1024)
            XCTAssertEqual(text.utf8.count, CourierLimits.maximumTextBytes)
            let draft = fixture.draft(text: text)
            XCTAssertGreaterThan(try JSONEncoder().encode(draft).count, 4096)
            let saved = try await fixture.request("/api/courier/tasks", method: "POST", object: self.json(draft))
            XCTAssertEqual(saved.status, 200)
            XCTAssertEqual(try saved.decode(CourierSnapshot.self).tasks.first?.text, text)
            let ordinary = try await fixture.request("/api/config", method: "PATCH", object: ["language": String(repeating: "x", count: 5000)])
            XCTAssertEqual(ordinary.status, 413)
            XCTAssertEqual(ordinary.object["error"] as? String, "body-too-large")
            let invalidConsent = try await fixture.request("/api/courier/settings",method:"PATCH",object:["enabled":1])
            XCTAssertEqual(invalidConsent.status,400,"A number must not count as an explicit boolean setting")
        }
    }

    func testMockServiceRejectsRealDesktopBundleIDs() async throws {
        try await withFixture { fixture in
            var draft = fixture.draft(); draft.target.bundleID = "com.openai.codex"
            let rejected = try await fixture.request("/api/courier/tasks", method: "POST", object: self.json(draft))
            XCTAssertEqual(rejected.status, 400)
            XCTAssertEqual(rejected.object["error"] as? String, "courier-target-invalid")
            let snapshot = try await fixture.request("/api/courier/status")
            XCTAssertTrue(try snapshot.decode(CourierSnapshot.self).tasks.isEmpty)
        }
    }

    func testHTTPNormalizesLegacyHourDraftAndCopyToFifteenMinutes() async throws {
        try await withFixture { fixture in
            var draft = fixture.draft(delay: 120_000)
            draft.deadlineAt = draft.scheduledAt + 3_600_000
            let created = try await fixture.request("/api/courier/tasks", method: "POST", object: self.json(draft))
            XCTAssertEqual(created.status, 200)
            let first = try XCTUnwrap(try created.decode(CourierSnapshot.self).tasks.first)
            XCTAssertEqual(first.deadlineAt - first.scheduledAt, 900_000)
            XCTAssertEqual(first.text, draft.text)

            draft.scheduledAt = fixture.clock.now() + 180_000
            draft.deadlineAt = draft.scheduledAt + 3_600_000
            var updatedBody = try self.json(draft)
            updatedBody["expectedRevision"] = first.revision
            let updated = try await fixture.request("/api/courier/tasks/\(first.id)", method: "PATCH", object: updatedBody)
            XCTAssertEqual(updated.status, 200)
            let source = try XCTUnwrap(try updated.decode(CourierSnapshot.self).tasks.first { $0.id == first.id })
            XCTAssertEqual(source.deadlineAt - source.scheduledAt, 900_000)

            let copyAt = fixture.clock.now() + 240_000
            let copied = try await fixture.request("/api/courier/tasks/\(source.id)/copy", method: "POST",
                object: ["expectedRevision": source.revision, "scheduledAt": copyAt, "deadlineAt": copyAt + 3_600_000])
            XCTAssertEqual(copied.status, 200)
            let copy = try XCTUnwrap(try copied.decode(CourierSnapshot.self).tasks.first { $0.id != source.id })
            XCTAssertEqual(copy.scheduledAt, copyAt)
            XCTAssertEqual(copy.deadlineAt - copy.scheduledAt, 900_000)
            XCTAssertFalse(copy.enabled, "Copying still creates a draft; only Save authorizes it")
            XCTAssertEqual(copy.text, source.text)

            let stored = try JSONDecoder().decode(CourierEnvelope.self, from: Data(contentsOf: fixture.directory.appendingPathComponent("courier/state.json")))
            XCTAssertEqual(stored.tasks.count, 2)
            XCTAssertTrue(stored.tasks.allSatisfy { $0.deadlineAt - $0.scheduledAt == 900_000 })
            XCTAssertTrue(stored.runs.allSatisfy { $0.deadlineAt - $0.scheduledAt == 900_000 })
        }
    }

    func testExitedDeliveryHostIsNotReportedAsReady() async throws {
        try await withFixture { fixture in
            let registration=CourierHostRegistration(brokerSession:"gone-host",processID:Int32.max,
                processStartedAt:fixture.clock.now(),previousGateClosed:true)
            let registered=try await fixture.request("/api/courier/host/register",method:"POST",object:self.json(registration))
            XCTAssertEqual(registered.status,200)
            let status=try await fixture.request("/api/courier/status")
            XCTAssertFalse(try status.decode(CourierSnapshot.self).hostAvailable)
            let rune=try await fixture.request("/api/status")
            XCTAssertEqual((rune.object["config"] as? JSONObject)?["enabled"] as? Bool,false)
        }
    }

    func testHTTPDeliveryContractAndReceiptReplayWithRedactedSummaryAndSSE() async throws {
        try await withFixture { fixture in
            let registration = CourierHostRegistration(brokerSession: "synthetic-host", processID: ProcessInfo.processInfo.processIdentifier,
                                                       processStartedAt: fixture.clock.now() - 1000, previousGateClosed: true)
            let registered = try await fixture.request("/api/courier/host/register", method: "POST", object: self.json(registration))
            XCTAssertEqual(registered.status, 200)
            let host = try registered.decode(CourierHostSession.self)
            let privateText = "UNIQUE_PRIVATE_SYNTHETIC_BODY\n中文原文 👋"
            let created = try await fixture.request("/api/courier/tasks", method: "POST", object: self.json(fixture.draft(text: privateText)))
            XCTAssertEqual(created.status, 200)

            let status = try await fixture.request("/api/status")
            XCTAssertEqual(status.status, 200)
            XCTAssertFalse(String(decoding: status.data, as: UTF8.self).contains(privateText))
            XCTAssertNil((status.object["courier"] as? JSONObject)?["tasks"])
            XCTAssertNil((status.object["courier"] as? JSONObject)?["runs"])
            let event = try await fixture.firstEvent()
            let eventData = try JSONSerialization.data(withJSONObject: event)
            XCTAssertFalse(String(decoding: eventData, as: UTF8.self).contains("UNIQUE_PRIVATE_SYNTHETIC_BODY"))
            XCTAssertNil((event["courier"] as? JSONObject)?["text"])

            fixture.clock.advance(60_000)
            await fixture.coordinator.systemEvent()
            let claimed = try await fixture.request("/api/courier/claim", method: "POST", object: self.json(CourierClaimRequest(serviceEpoch: host.serviceEpoch, brokerSession: host.brokerSession)))
            XCTAssertEqual(claimed.status, 200)
            let claimObject = try XCTUnwrap(claimed.object["claim"] as? JSONObject)
            let claim = try JSONDecoder().decode(CourierClaim.self, from: JSONSerialization.data(withJSONObject: claimObject))
            XCTAssertEqual(claim.run.text, privateText)
            let preflight = CourierPreflight(target: claim.run.target, messageCursor: "synthetic-before-message", identityVerified: true, composerEmpty: true, hostReady: true)
            let input = try await fixture.request("/api/courier/begin-input", method: "POST", object: ["authorization": self.json(claim.authorization), "preflight": self.json(preflight)])
            XCTAssertEqual(input.status, 200)
            let send = try await fixture.request("/api/courier/begin-send", method: "POST", object: ["authorization": self.json(claim.authorization), "target": self.json(claim.run.target), "text": claim.run.text])
            XCTAssertEqual(send.status, 200)
            XCTAssertEqual(try send.decode(CourierSendPermit.self).authorization, claim.authorization)
            let repeatedSend = try await fixture.request("/api/courier/begin-send", method: "POST", object: ["authorization": self.json(claim.authorization), "target": self.json(claim.run.target), "text": claim.run.text])
            XCTAssertEqual(repeatedSend.status, 409)
            let receipt = CourierReceiptRequest(authorization: claim.authorization, outcome: .sent, targetKey: claim.run.target.key, messageID: "synthetic-new-user-message", evidence: "synthetic-associated-message")
            let received = try await fixture.request("/api/courier/receipt", method: "POST", object: self.json(receipt))
            let repeated = try await fixture.request("/api/courier/receipt", method: "POST", object: self.json(receipt))
            XCTAssertEqual(received.status, 200); XCTAssertEqual(repeated.status, 200)
            XCTAssertEqual(try received.decode(CourierRun.self), try repeated.decode(CourierRun.self))
            XCTAssertEqual(try repeated.decode(CourierRun.self).status, .sent)
            let final = try await fixture.request("/api/status")
            XCTAssertFalse(String(decoding: final.data, as: UTF8.self).contains("UNIQUE_PRIVATE_SYNTHETIC_BODY"))
            XCTAssertEqual(((final.object["runtime"] as? JSONObject)?["scheduledChecks"] as? Int), 0)
        }
    }

    func testCorruptCourierFailsClosedWithoutBlockingResetStatusOrRefresh() async throws {
        try await withFixture(corruptCourier: true) { fixture in
            let stateFile = fixture.directory.appendingPathComponent("courier/state.json")
            let original = try Data(contentsOf: stateFile)
            let status = try await fixture.request("/api/status")
            XCTAssertEqual(status.status, 200)
            XCTAssertEqual((status.object["courier"] as? JSONObject)?["error"] as? String, "courier-state-unavailable")
            let courier = try await fixture.request("/api/courier/status")
            XCTAssertEqual(courier.status, 503)
            XCTAssertEqual(courier.object["error"] as? String, "courier-state-unavailable")
            let refreshed = try await fixture.request("/api/refresh", method: "POST", object: [:])
            XCTAssertEqual(refreshed.status, 200)
            XCTAssertEqual((refreshed.object["snapshot"] as? JSONObject)?["availableCount"] as? Int, 2)
            XCTAssertEqual(try Data(contentsOf: stateFile), original)
        }
    }

    func testCourierTimerFiresWithResetPausedAndDoesNotSpinAfterDue() async throws {
        try await withFixture { fixture in
            let created = try await fixture.request("/api/courier/tasks", method: "POST", object: self.json(fixture.draft(delay: 500)))
            let initial = try created.decode(CourierSnapshot.self)
            let due = self.expectation(description: "independent courier timer publishes due occurrence")
            let lock = NSLock(); var fulfilled = false
            await fixture.coordinator.setPublisher { view in
                fixture.server.publish(view)
                if let courier = view["courier"] as? JSONObject, let revision = courier["revision"] as? Int, revision > initial.revision {
                    lock.lock(); let shouldFulfill = !fulfilled; fulfilled = true; lock.unlock()
                    if shouldFulfill { due.fulfill() }
                }
            }
            await self.fulfillment(of: [due], timeout: 3)
            let response = try await fixture.request("/api/courier/status")
            let snapshot = try response.decode(CourierSnapshot.self)
            XCTAssertNil(snapshot.runs.first?.nextAttemptAt)
            XCTAssertEqual(snapshot.runs.first?.waitReason, "host-unavailable")
            XCTAssertEqual(snapshot.nextActionAt, snapshot.runs.first?.deadlineAt)
            let runeSchedule = await fixture.rune.schedule()
            XCTAssertNil(runeSchedule.at)
            let status = try await fixture.request("/api/status")
            XCTAssertEqual((status.object["runtime"] as? JSONObject)?["scheduledChecks"] as? Int, 0)
        }
    }

    func testCourierStoreUsesPrivateSeparateFilesAndRejectsUnsafeReads() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let reset = try FileStateStore(directory: directory)
        try reset.write(RuneState.initial())
        let store = try FileCourierStore(directory: directory)
        let data = try JSONEncoder().encode(CourierEnvelope())
        try store.write(data)
        XCTAssertEqual(store.file.path, directory.appendingPathComponent("courier/state.json").path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.file.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try JSONDecoder().decode(CourierEnvelope.self, from: XCTUnwrap(store.read())), CourierEnvelope())
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))

        let outside = directory.appendingPathComponent("synthetic-link-target.json")
        try data.write(to: outside); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
        try FileManager.default.removeItem(at: store.file)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: outside)
        XCTAssertThrowsError(try store.read())
        // Atomic replacement may replace the link itself, but must never follow it into another file.
        try store.write(data)
        XCTAssertEqual(try Data(contentsOf: outside), data)
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: store.file.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.file.path)
        XCTAssertThrowsError(try store.read())
    }

    func testCourierStoreRejectsSymlinkedDirectory() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("synthetic-other-directory")
        try PrivateFiles.ensure(destination)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("courier"), withDestinationURL: destination)
        XCTAssertThrowsError(try FileCourierStore(directory: directory))
    }

    func testRuntimeCompatibilityChecksAreReadOnlyAndRequireCourierCapabilities() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileCourierStore(directory: directory), clock = Clock()
        let engine = try CourierEngine(store: store, now: { clock.now() }, serviceEpoch: "compatibility-test", allowedBundleIDs: ["local.reset-rune.mock.codex"])
        try engine.setEnabled(true)
        let target = CourierTarget(agent: .codex, bundleID: "local.reset-rune.mock.codex", sourceID: "simulation", threadID: "synthetic", title: "Synthetic")
        let task = try engine.create(CourierTaskDraft(name: "Compatibility", text: "synthetic", target: target, scheduledAt: clock.now() + 60_000))
        _ = try engine.registerHost(CourierHostRegistration(brokerSession: "compatibility-host", processID: 301, processStartedAt: clock.now()))
        clock.advance(60_000)
        let claim = try XCTUnwrap(engine.claim(CourierClaimRequest(serviceEpoch: "compatibility-test", brokerSession: "compatibility-host")))
        _ = try engine.beginInput(auth: claim.authorization, preflight: CourierPreflight(target: target, messageCursor: "synthetic-cursor", identityVerified: true, composerEmpty: true, hostReady: true))
        _ = try engine.beginSend(auth: claim.authorization, target: target, text: task.text)
        let original = try Data(contentsOf: store.file)
        XCTAssertNoThrow(try CourierRuntimeCompatibility.validateState(directory: directory))
        XCTAssertEqual(try Data(contentsOf: store.file), original)
        XCTAssertEqual(try JSONDecoder().decode(CourierEnvelope.self, from: original).runs.first?.status, .dispatching)

        let supported = directory.appendingPathComponent("supported-synthetic-helper.sh")
        let unsupported = directory.appendingPathComponent("old-synthetic-helper.sh")
        try "#!/bin/sh\nprintf '%s\\n' '{\"courierProtocol\":1,\"schema\":1}'\n".write(to: supported, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf '%s\\n' 'compatible-v1'\n".write(to: unsupported, atomically: true, encoding: .utf8)
        for file in [supported, unsupported] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
        XCTAssertNoThrow(try CourierRuntimeCompatibility.checkCandidate(supported, directory: directory))
        XCTAssertThrowsError(try CourierRuntimeCompatibility.checkCandidate(unsupported, directory: directory)) { error in
            XCTAssertEqual((error as? RuneError)?.code, "courier-incompatible-runtime")
        }
        XCTAssertEqual(try Data(contentsOf: store.file), original)
        try CourierRuntimeCompatibility.pauseForUninstall(directory:directory,mock:true)
        let paused=try JSONDecoder().decode(CourierEnvelope.self,from:Data(contentsOf:store.file))
        XCTAssertFalse(paused.enabled)
        XCTAssertEqual(paused.runs.first?.status,.unknown,"Uninstall preserves possible sends instead of reviving the task")
    }
}
