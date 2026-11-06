// INPUT: Synthetic or official normalized snapshots and private v1 journals.
// OUTPUT: Shared native contracts; no login storage or networking lives here.
// POS: Native core, documented in native/README.md.
import Foundation

public typealias JSONObject = [String: Any]

public struct RuneError: Error, LocalizedError {
    public let code: String
    public let httpStatus: Int
    public let notSent: Bool
    public init(_ code: String, httpStatus: Int = 409, notSent: Bool = false) {
        self.code = code; self.httpStatus = httpStatus; self.notSent = notSent
    }
    public var errorDescription: String? { code }
}

public protocol ResetSource: AnyObject {
    var mode: String { get }
    func read() async throws -> JSONObject
    func consume(_ operation: JSONObject, maySend: @escaping () async -> Bool) async throws -> String
    func close() async
}
public extension ResetSource {
    func consume(_ operation: JSONObject, maySend: @escaping () async -> Bool) async throws -> String { throw RuneError("readonly", notSent: true) }
    func close() async {}
}

public protocol StateStore: AnyObject {
    func read() throws -> JSONObject
    func write(_ value: JSONObject) throws
}

public struct ScheduleDecision: Equatable {
    public let at: Double?
    public let reason: String
    public init(at: Double?, reason: String) { self.at = at; self.reason = reason }
}
