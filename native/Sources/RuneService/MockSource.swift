import Foundation
import RuneCore

public final class MockSource: ResetSource {
    public let mode = "mock"
    private let file: URL
    private var model: JSONObject
    public init(directory: URL) throws {
        file = directory.appendingPathComponent("sample-inventory.json")
        let now = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        model = try PrivateFiles.read(file) ?? ["identity": ["accountId":"sample-account", "scope":"sample-workspace", "email":"demo@example.com"], "credits": [["id":"sample-1","expiresAt":now+20*60_000], ["id":"sample-2","expiresAt":now+7*86_400_000]], "remainingPercent":90, "redeemed":[:]]
    }
    public func read() async throws -> JSONObject {
        if !FileManager.default.fileExists(atPath: file.path) { try PrivateFiles.write(file, model) }
        let credits = (model["credits"] as? [JSONObject] ?? []).filter { ($0["expiresAt"] as? Double ?? 0) > Date().timeIntervalSince1970*1000 }
        return ["identity":model["identity"] ?? NSNull(), "credits":credits, "availableCount":credits.count, "creditsKnown":true, "remainingPercent":model["remainingPercent"] ?? 90]
    }
    public func consume(_ operation: JSONObject, maySend: @escaping () async -> Bool) async throws -> String {
        guard await maySend() else { throw RuneError("cancelled", notSent:true) }
        guard let id=operation["id"] as? String, let key=operation["key"] as? String else { throw RuneError("invalid-operation",notSent:true) }
        var redeemed=model["redeemed"] as? [String:String] ?? [:]
        if let prior=redeemed[key] { return prior==id ? "already-redeemed":"no-credit" }
        var credits=model["credits"] as? [JSONObject] ?? []
        guard credits.contains(where: { $0["id"] as? String == id && ($0["expiresAt"] as? Double ?? 0)>Date().timeIntervalSince1970*1000 }) else { return "no-credit" }
        credits.removeAll { $0["id"] as? String == id }; redeemed[key]=id
        var next=model; next["credits"]=credits; next["redeemed"]=redeemed; next["remainingPercent"]=100
        try PrivateFiles.write(file,next); model=next
        return "reset"
    }
}
