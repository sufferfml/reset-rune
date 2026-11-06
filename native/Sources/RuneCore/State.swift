import Foundation
import CryptoKit
import CoreFoundation

public enum RuneState {
    public static let defaults: JSONObject = ["enabled": false, "lead": 10, "language": "en", "appearance": "system", "startup": false, "notify": true]
    public static func initial() -> JSONObject {
        ["version": 1, "config": defaults, "binding": NSNull(), "plan": NSNull(), "operations": [JSONObject](), "events": [JSONObject]()]
    }
    public static func validateConfig(_ patch: JSONObject) throws {
        for (key, value) in patch {
            let valid: Bool
            switch key {
            case "enabled", "startup", "notify": valid = isBoolean(value)
            case "lead": valid = integer(value).map { [5,10,30,60].contains(Int($0)) } ?? false
            case "language": valid = (value as? String).map { ["en","zh"].contains($0) } ?? false
            case "appearance": valid = (value as? String).map { ["system","light","dark"].contains($0) } ?? false
            default: valid = false
            }
            if !valid { throw RuneError("invalid-config", httpStatus: 400) }
        }
    }
    public static func validate(_ input: JSONObject) throws -> JSONObject {
        guard integer(input["version"]) == 1, let config = input["config"] as? JSONObject,
              input["operations"] is [JSONObject], input["events"] is [JSONObject] else { throw RuneError("unsupported-state") }
        try validateConfig(config)
        var output = input
        output["config"] = defaults.merging(config) { _, new in new }
        return output
    }
    public static func verified(_ identity: JSONObject?) -> Bool {
        guard let identity, let account = identity["accountId"] as? String, let scope = identity["scope"] as? String else { return false }
        return !account.isEmpty && !scope.isEmpty
    }
    public static func sameIdentity(_ lhs: JSONObject?, _ rhs: JSONObject?) -> Bool {
        guard verified(lhs), verified(rhs) else { return false }
        return jsEqual(lhs?["accountId"] as? String, rhs?["accountId"] as? String)
            && jsEqual(lhs?["scope"] as? String, rhs?["scope"] as? String)
    }
    public static func authorization(_ identity: JSONObject?) -> String? {
        guard verified(identity) else { return nil }
        return try? digest(["reset-rune-live-v1", identity!["accountId"]!, identity!["scope"]!])
    }
    public static func consent(identity: JSONObject?, lead: Double) -> String? {
        guard let authorization = authorization(identity) else { return nil }
        return try? digest([authorization, lead])
    }
    public static func scope(email: String) -> String { "codex:" + sha256(Data(email.utf8)) }
    public static func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        guard let result = String(data: data, encoding: .utf8) else { throw RuneError("invalid-json") }
        return result
    }
    public static func digest(_ value: Any) throws -> String { sha256(Data(try jsonString(value).utf8)) }
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func jsEqual(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.utf16.elementsEqual(b.utf16)
    }
    public static func isBoolean(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber else { return false }
        return CFGetTypeID(value) == CFBooleanGetTypeID()
    }
    public static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, !isBoolean(value), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    public static func integer(_ value: Any?) -> Double? {
        guard let n = number(value), n.rounded() == n, abs(n) <= 9_007_199_254_740_991 else { return nil }
        return n
    }
    public static func inventoryRevision(count: Double, credits: [JSONObject]) throws -> String {
        // JS localeCompare defaults to ICU English in the supported runtime.
        // Use ICU collation explicitly instead of Swift's canonical lexical order.
        let sorted = credits.sorted {
            ($0["id"] as? String ?? "").compare($1["id"] as? String ?? "", options: [], range: nil, locale: Locale(identifier: "en_US")) == .orderedAscending
        }
        let rows: [[Any]] = sorted.map { [$0["id"]!, $0["expiresAt"]!] }
        return try digest([count, rows])
    }
}

public final class MemoryStateStore: StateStore {
    public var value: JSONObject
    public var rejectWrites = false
    public var afterWrite: ((JSONObject) -> Void)?
    public init(_ value: JSONObject = RuneState.initial()) { self.value = value }
    public func read() throws -> JSONObject { value }
    public func write(_ value: JSONObject) throws {
        if rejectWrites { throw RuneError("write-failed") }
        self.value = value
        afterWrite?(value)
    }
}
