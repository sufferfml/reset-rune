// Synthetic schema capability tests. No real executable or login is discovered.
import XCTest
import Foundation
import RuneCore
@testable import CodexTransport

final class CapabilityTests: XCTestCase {
    private let method = "account/rateLimitResetCredit/consume"
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reset-rune-capability-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    private func request() -> JSONObject {
        ["oneOf": [["properties": ["method": ["type": "string", "enum": [method]], "params": ["$ref": "#/definitions/Params"]]]],
         "definitions": ["Params": ["type": "object", "properties": ["creditId": ["type": ["string", "null"]], "idempotencyKey": ["type": "string"]], "required": ["idempotencyKey"]]]]
    }
    private func response() -> JSONObject {
        ["type": "object", "properties": ["outcome": ["$ref": "#/definitions/Outcome"]], "required": ["outcome"],
         "definitions": ["Outcome": ["oneOf": ["reset", "nothingToReset", "noCredit", "alreadyRedeemed"].map { ["type": "string", "enum": [$0]] }]]]
    }
    private func save(_ root: URL, request: JSONObject? = nil, response: JSONObject? = nil) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("v2"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: request ?? self.request()).write(to: root.appendingPathComponent("ClientRequest.json"))
        try JSONSerialization.data(withJSONObject: response ?? self.response()).write(to: root.appendingPathComponent("v2/ConsumeAccountRateLimitResetCreditResponse.json"))
    }
    func testStableContractAllowsAdditionalFieldsAndOutcomes() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var reply = response()
        reply["properties"] = ["outcome": ["type": "string", "enum": ["reset", "nothingToReset", "noCredit", "alreadyRedeemed", "futureOutcome"]], "newField": ["type": "string"]]
        var input = request(); input["description"] = "Additional schema metadata is harmless"
        try save(root, request: input, response: reply)
        XCTAssertNoThrow(try validateConsumeCapability(in: root))
    }
    func testMissingMethodOrTargetAndWrongTypesAreRejected() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var variants: [JSONObject] = [["oneOf": []]]
        for field in ["creditId", "idempotencyKey"] {
            var params = ["type": "object", "properties": ["creditId": ["type": "string"], "idempotencyKey": ["type": "string"]], "required": ["idempotencyKey"]] as JSONObject
            var fields = params["properties"] as! JSONObject; fields.removeValue(forKey: field); params["properties"] = fields
            var input = request(); input["definitions"] = ["Params": params]; variants.append(input)
            fields[field] = ["type": "number"]; params["properties"] = fields
            input["definitions"] = ["Params": params]; variants.append(input)
        }
        for input in variants {
            try save(root, request: input)
            XCTAssertThrowsError(try validateConsumeCapability(in: root)) { error in
                XCTAssertEqual((error as? RuneError)?.code, "runtime-incompatible")
                XCTAssertTrue((error as? RuneError)?.notSent == true)
            }
        }
    }
    func testMissingRequiredKeyAndNewRequiredParamsAreRejected() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for required in [[], ["creditId"], ["idempotencyKey", "newRequiredField"]] as [[String]] {
            var params = (request()["definitions"] as! JSONObject)["Params"] as! JSONObject
            params["required"] = required
            var input = request(); input["definitions"] = ["Params": params]
            try save(root, request: input)
            XCTAssertThrowsError(try validateConsumeCapability(in: root))
        }
    }
    func testBadAndExternalReferencesAreRejected() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for reference in ["#/definitions/missing", "../../authentication.json", "https://example.test/schema", "#/definitions/Params"] {
            var input = request(); input["definitions"] = ["Params": ["$ref": reference]]
            try save(root, request: input)
            XCTAssertThrowsError(try validateConsumeCapability(in: root))
        }
    }
    func testUnknownOutcomeShapeAndMissingKnownResultAreRejected() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for node in [["type": "number"], ["type": "string", "enum": ["reset", "noCredit"]], ["$ref": "#/definitions/missing"]] as [JSONObject] {
            var reply = response(); reply["properties"] = ["outcome": node]
            try save(root, response: reply)
            XCTAssertThrowsError(try validateConsumeCapability(in: root))
        }
    }
    func testSymlinksAndOversizedGeneratedFilesAreRejected() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try save(root)
        let link = root.appendingPathComponent("external-schema.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("ClientRequest.json"))
        XCTAssertThrowsError(try validateConsumeCapability(in: root))
        try FileManager.default.removeItem(at: link)
        try Data(repeating: 32, count: 4 * 1024 * 1024 + 1).write(to: root.appendingPathComponent("large.json"))
        XCTAssertThrowsError(try validateConsumeCapability(in: root))
    }
    func testSchemaGenerationUsesEmptyHomeAndCleansItUp() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("synthetic-codex")
        let input = String(data: try JSONSerialization.data(withJSONObject: request()), encoding: .utf8)!
        let output = String(data: try JSONSerialization.data(withJSONObject: response()), encoding: .utf8)!
        let script = """
        #!/bin/sh
        test "$1" = app-server && test "$2" = generate-json-schema && test "$3" = --out && test "$#" = 4 || exit 2
        /usr/bin/env > '\(root.appendingPathComponent("environment.txt").path)'
        /bin/mkdir -p "$4/v2"
        /bin/cat > "$4/ClientRequest.json" <<'REQUEST'
        \(input)
        REQUEST
        /bin/cat > "$4/v2/ConsumeAccountRateLimitResetCreditResponse.json" <<'RESPONSE'
        \(output)
        RESPONSE
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try await verifyConsumeCapability(executable: executable.path)
        let environment = try String(contentsOf: root.appendingPathComponent("environment.txt"), encoding: .utf8)
        XCTAssertFalse(environment.contains("OPENAI_API_KEY=")); XCTAssertFalse(environment.contains("CODEX_API_KEY="))
        let home = try XCTUnwrap(environment.split(separator: "\n").first { $0.hasPrefix("HOME=") }).dropFirst(5)
        XCTAssertNotEqual(String(home), FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: String(home)), "The schema probe must remove its temporary home")
    }
    func testFailedAndTimedOutGeneratorsAreDefinitelyUnsent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("synthetic-codex")
        for body in ["#!/bin/sh\nexit 2\n", "#!/bin/sh\nexec /bin/sleep 10\n"] {
            try body.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            do { try await verifyConsumeCapability(executable: executable.path, timeoutMs: 100); XCTFail("An invalid generator must be rejected") }
            catch let error as RuneError { XCTAssertEqual(error.code, "runtime-incompatible"); XCTAssertTrue(error.notSent) }
        }
    }
}
