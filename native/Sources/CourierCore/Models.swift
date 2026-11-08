// INPUT: Explicit task definitions and normalized desktop delivery attestations.
// OUTPUT: Versioned Codable contracts; UTC times are milliseconds.
// POS: Pure courier domain. See docs/courier-technical-design.md; no desktop or credential access.
import Foundation

public enum CourierAgent: String, Codable, CaseIterable { case codex, claude }
public enum CourierTaskLifecycle: String, Codable { case draft, scheduled, paused, completed }
public enum CourierRunStatus: String, Codable {
    case scheduled, paused, preparing, dispatching, sent, failed, missed, cancelled, unknown
    public var terminal: Bool { [.sent, .failed, .missed, .cancelled, .unknown].contains(self) }
}
public enum CourierReceiptOutcome: String, Codable { case sent, definitelyNotSent, unknown }
public enum CourierInputMode: String, Codable { case composer, desktopIPC }

/// A display summary and v1-compatible internal name. The original sending text is never rewritten.
public enum CourierTextSummary {
    public static func make(_ text: String) -> String {
        let summary = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard summary.count > 120 else { return summary }
        return String(summary.prefix(119)) + "…"
    }
}

public struct CourierError: Error, LocalizedError, Equatable {
    public let code: String
    public let httpStatus: Int
    public init(_ code: String, httpStatus: Int = 409) { self.code = code; self.httpStatus = httpStatus }
    public var errorDescription: String? { code }
}

public struct CourierTarget: Codable, Equatable {
    public var agent: CourierAgent
    public var bundleID: String
    public var sourceID: String
    public var threadID: String
    public var title: String
    public var projectPath: String?
    public var appVersion: String?
    public init(agent: CourierAgent, bundleID: String, sourceID: String, threadID: String, title: String, projectPath: String? = nil, appVersion: String? = nil) {
        self.agent = agent; self.bundleID = bundleID; self.sourceID = sourceID; self.threadID = threadID; self.title = title; self.projectPath = projectPath; self.appVersion = appVersion
    }
    /// Stable identity, independent of a display title or project hint. Length-prefixing avoids delimiter collisions.
    public var key: String { [agent.rawValue, bundleID, sourceID, threadID].map { "\($0.utf8.count):\($0)" }.joined() }
    public func isSameConversation(as other: CourierTarget) -> Bool { Array(key.utf8) == Array(other.key.utf8) }
}

public struct CourierTaskDraft: Codable, Equatable {
    public var name: String
    public var text: String
    public var target: CourierTarget
    public var scheduledAt: Double
    public var deadlineAt: Double
    public var timeZoneID: String
    public var enabled: Bool
    public init(name: String, text: String, target: CourierTarget, scheduledAt: Double, deadlineAt: Double? = nil, timeZoneID: String = "UTC", enabled: Bool = true) {
        self.name = name; self.text = text; self.target = target; self.scheduledAt = scheduledAt; self.deadlineAt = deadlineAt ?? scheduledAt + CourierLimits.defaultDeliveryGraceMilliseconds; self.timeZoneID = timeZoneID; self.enabled = enabled
    }
}

public struct CourierTask: Codable, Equatable, Identifiable {
    public var id: String
    public var revision: Int
    public var scheduleRevision: Int
    public var name: String
    public var text: String
    public var target: CourierTarget
    public var scheduledAt: Double
    public var deadlineAt: Double
    public var timeZoneID: String
    public var enabled: Bool
    public var lifecycle: CourierTaskLifecycle
    public var createdAt: Double
    public var updatedAt: Double
    public var needsReschedule: Bool
    public var draft: CourierTaskDraft { CourierTaskDraft(name: name, text: text, target: target, scheduledAt: scheduledAt, deadlineAt: deadlineAt, timeZoneID: timeZoneID, enabled: enabled) }
}

public struct CourierHostRegistration: Codable, Equatable {
    public var brokerSession: String
    public var processID: Int32
    public var processStartedAt: Double
    public var courierProtocol: Int
    public var previousGateClosed: Bool
    public init(brokerSession: String, processID: Int32, processStartedAt: Double, courierProtocol: Int = 1, previousGateClosed: Bool = false) {
        self.brokerSession = brokerSession; self.processID = processID; self.processStartedAt = processStartedAt; self.courierProtocol = courierProtocol; self.previousGateClosed = previousGateClosed
    }
}
public struct CourierHostSession: Codable, Equatable {
    public var serviceEpoch: String
    public var brokerSession: String
    public var processID: Int32
    public var processStartedAt: Double
    public var courierProtocol: Int
    public var registeredAt: Double
}

public struct CourierClaimRequest: Codable, Equatable {
    public var serviceEpoch: String
    public var brokerSession: String
    public var runID: String?
    public init(serviceEpoch: String, brokerSession: String, runID: String? = nil) { self.serviceEpoch = serviceEpoch; self.brokerSession = brokerSession; self.runID = runID }
}
public struct CourierAuthorization: Codable, Equatable {
    public var serviceEpoch: String
    public var brokerSession: String
    public var runID: String
    public var attemptID: String
    public var nonce: String
    public init(serviceEpoch: String, brokerSession: String, runID: String, attemptID: String, nonce: String) { self.serviceEpoch = serviceEpoch; self.brokerSession = brokerSession; self.runID = runID; self.attemptID = attemptID; self.nonce = nonce }
}

public struct CourierPreflight: Codable, Equatable {
    public var target: CourierTarget
    public var messageCursor: String
    public var identityVerified: Bool
    public var composerEmpty: Bool
    public var hostReady: Bool
    /// Absent in older ledgers; nil retains the composer safety requirements.
    public var inputMode: CourierInputMode?
    public init(target: CourierTarget, messageCursor: String, identityVerified: Bool, composerEmpty: Bool, hostReady: Bool, inputMode: CourierInputMode? = .composer) {
        self.target = target; self.messageCursor = messageCursor; self.identityVerified = identityVerified; self.composerEmpty = composerEmpty; self.hostReady = hostReady; self.inputMode = inputMode
    }
}

public struct CourierReceiptRequest: Codable, Equatable {
    public var authorization: CourierAuthorization
    public var outcome: CourierReceiptOutcome
    public var retryable: Bool
    public var reason: String?
    public var targetKey: String?
    public var messageID: String?
    public var evidence: String?
    public init(authorization: CourierAuthorization, outcome: CourierReceiptOutcome, retryable: Bool = false, reason: String? = nil, targetKey: String? = nil, messageID: String? = nil, evidence: String? = nil) {
        self.authorization = authorization; self.outcome = outcome; self.retryable = retryable; self.reason = reason; self.targetKey = targetKey; self.messageID = messageID; self.evidence = evidence
    }
}

public struct CourierAttempt: Codable, Equatable, Identifiable {
    public var id: String
    public var authorization: CourierAuthorization
    public var claimedAt: Double
    public var preparationExpiresAt: Double
    public var inputAuthorizedAt: Double?
    public var preflight: CourierPreflight?
    public var sendAuthorizedAt: Double?
    public var permitExpiresAt: Double?
    public var receipt: CourierReceiptRequest?
    public var receiptAt: Double?
    public var becameUnknownAt: Double?
}

public struct CourierRun: Codable, Equatable, Identifiable {
    public var id: String
    public var taskID: String
    public var taskName: String
    public var scheduleRevision: Int
    public var target: CourierTarget
    public var text: String
    public var scheduledAt: Double
    public var deadlineAt: Double
    public var status: CourierRunStatus
    public var waitReason: String?
    public var nextAttemptAt: Double?
    public var attempts: [CourierAttempt]
    public var createdAt: Double
    public var updatedAt: Double
    public var userConfirmedSent: Bool?
    public var userConfirmedAt: Double?
    public var unresolvedUnknown: Bool { status == .unknown && userConfirmedAt == nil }
}

public struct CourierClaim: Codable, Equatable {
    public var authorization: CourierAuthorization
    public var run: CourierRun
}
public struct CourierSendPermit: Codable, Equatable {
    public var authorization: CourierAuthorization
    public var expiresAt: Double
    public var target: CourierTarget
    public var text: String
}

public struct CourierSnapshot: Codable, Equatable {
    public var courierProtocol: Int
    public var revision: Int
    public var enabled: Bool
    public var pausedAt: Double?
    public var serviceEpoch: String
    public var hostAvailable: Bool
    public var host: CourierHostSession?
    public var tasks: [CourierTask]
    public var runs: [CourierRun]
    public var nextActionAt: Double?
}

public struct CourierEnvelope: Codable, Equatable {
    public var version: Int
    public var courierProtocol: Int
    public var revision: Int
    public var enabled: Bool
    public var pausedAt: Double?
    public var host: CourierHostSession?
    public var tasks: [CourierTask]
    public var runs: [CourierRun]
    public init() { version = 1; courierProtocol = 1; revision = 0; enabled = false; tasks = []; runs = [] }
}

public protocol CourierStore: AnyObject {
    func read() throws -> Data?
    /// Atomically replace and persist. A failure may occur after replacement; callers
    /// must close the send gate and recover from the disk journal rather than retry a UI send.
    func write(_ data: Data) throws
}

public final class CourierMemoryStore: CourierStore {
    public var data: Data?
    public var rejectWrites = false
    public var writes = 0
    public init(data: Data? = nil) { self.data = data }
    public func read() throws -> Data? { data }
    public func write(_ data: Data) throws { if rejectWrites { throw CourierError("courier-write-failed", httpStatus: 503) }; self.data = data; writes += 1 }
}

public enum CourierLimits {
    public static let defaultDeliveryGraceMilliseconds = 900_000.0
    public static let maximumTextBytes = 32 * 1024
    public static let maximumEvidenceBytes = 8 * 1024
    public static let maximumActiveTasks = 100
    public static let maximumHistory = 500
    public static let ordinaryBytes = 12 * 1024 * 1024
    public static let hardBytes = 16 * 1024 * 1024
    public static let preparationMilliseconds = 60_000.0
    public static let permitMilliseconds = 5_000.0
    public static let receiptMilliseconds = 30_000.0
}
