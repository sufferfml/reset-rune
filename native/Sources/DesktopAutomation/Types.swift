// INPUT: Explicit desktop target selections and bounded adapter evidence.
// OUTPUT: Desktop delivery contracts; no model execution or authentication access.
// POS: Shared automation boundary. See README.md and docs/courier-technical-design.md.
import Foundation

public enum DesktopAgent: String, Codable, CaseIterable, Sendable {
    case codex, claude
    public var bundleID: String { self == .codex ? "com.openai.codex" : "com.anthropic.claudefordesktop" }
}

public struct DesktopTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var agent: DesktopAgent
    public var id: String
    public var title: String
    public var project: String?
    public var sourceID: String
    public var bundleID: String
    public var appVersion: String
    public init(agent: DesktopAgent, id: String, title: String, project: String? = nil, sourceID: String, bundleID: String? = nil, appVersion: String) {
        self.agent=agent; self.id=id; self.title=title; self.project=project; self.sourceID=sourceID
        self.bundleID=bundleID ?? agent.bundleID; self.appVersion=appVersion
    }
}

public enum DesktopBlockReason: String, Codable, Error, LocalizedError, Sendable {
    case appMissing, unsupportedVersion, sourceUnavailable, unsafeSource, sourceChanged, invalidTarget
    case accessibilityRequired, screenLocked, targetNotConfirmed, receiptNotSupported
    case targetBusy, userDraft, userInterference, notFrontmost, textMismatch, sendUnavailable, ownerUnavailable
    case cancelled, permitExpired, resultUnknown, limitExceeded, liveValidationRequired
    public var errorDescription: String? {
        switch self {
        case .appMissing: return "The target desktop app is not installed."
        case .unsupportedVersion: return "This desktop version has not passed compatibility checks."
        case .sourceUnavailable: return "The selected local chat index is unavailable."
        case .unsafeSource: return "The local chat source contains an unsafe link."
        case .sourceChanged: return "The selected desktop app or local source has changed."
        case .invalidTarget: return "Select a valid existing chat."
        case .accessibilityRequired: return "Enable Accessibility access for Bottled Reset Rune."
        case .screenLocked: return "Waiting for the screen to unlock."
        case .targetNotConfirmed: return "This desktop version cannot yet prove the active chat identity."
        case .receiptNotSupported: return "This desktop version cannot yet prove message delivery."
        case .targetBusy: return "The target chat is busy."
        case .userDraft: return "The target chat contains an unsent draft."
        case .userInterference: return "The target window or its text changed during preparation."
        case .notFrontmost: return "The target app is not in the foreground."
        case .textMismatch: return "The text read back from the input does not match."
        case .sendUnavailable: return "The Send button is unavailable."
        case .ownerUnavailable: return "The selected existing chat is not yet loaded in the desktop app."
        case .cancelled: return "Delivery preparation was cancelled."
        case .permitExpired: return "The delivery permit expired."
        case .resultUnknown: return "Delivery could not be confirmed. Check the target chat before sending again."
        case .limitExceeded: return "The chat index or message exceeds the supported limit."
        case .liveValidationRequired: return "The desktop channel passed read-only checks; live message delivery has not been tested."
        }
    }
}

public struct DesktopCompatibility: Codable, Equatable, Sendable {
    public var agent: DesktopAgent
    public var version: String?
    public var canDiscover: Bool
    public var canSend: Bool
    public var blockers: [DesktopBlockReason]
    public var requiresAccessibility: Bool
    public init(agent: DesktopAgent, version: String?, canDiscover: Bool, canSend: Bool, blockers: [DesktopBlockReason], requiresAccessibility: Bool = true) {
        self.agent=agent; self.version=version; self.canDiscover=canDiscover; self.canSend=canSend; self.blockers=blockers
        self.requiresAccessibility=requiresAccessibility
    }
}

public struct DesktopDiscovery: Sendable {
    public var targets: [DesktopTarget]
    public var compatibility: DesktopCompatibility
    public var hasMore:Bool
    public init(targets: [DesktopTarget], compatibility: DesktopCompatibility,hasMore:Bool=false) { self.targets=targets; self.compatibility=compatibility;self.hasMore=hasMore }
}

public struct DesktopMessageCursor: Codable, Equatable, Sendable {
    public var targetID: String
    public var sourceID: String
    public var seenMessageIDs: Set<String>
    public var capturedAt: Int64
    public init(targetID: String, sourceID: String, seenMessageIDs: Set<String>, capturedAt: Int64) {
        self.targetID=targetID; self.sourceID=sourceID; self.seenMessageIDs=seenMessageIDs; self.capturedAt=capturedAt
    }
}

public struct DesktopPreflight: Sendable {
    public var target: DesktopTarget
    public var cursor: DesktopMessageCursor
    public var contextID: String
    public init(target: DesktopTarget, cursor: DesktopMessageCursor, contextID: String) { self.target=target; self.cursor=cursor; self.contextID=contextID }
}

public struct DesktopStagedText: Sendable {
    public var preflight: DesktopPreflight
    public var text: String
    public var stageID: UUID
    public init(preflight: DesktopPreflight, text: String, stageID: UUID = UUID()) { self.preflight=preflight; self.text=text; self.stageID=stageID }
}

public struct DesktopSendPermit: Sendable {
    public var stageID: UUID
    public var expiresAt: Int64
    public init(stageID: UUID, expiresAt: Int64) { self.stageID=stageID; self.expiresAt=expiresAt }
}

public struct DesktopReceipt: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case sent, unknown }
    public var outcome: Outcome
    public var targetID: String
    public var messageID: String?
    public var reason: DesktopBlockReason?
    public init(outcome: Outcome, targetID: String, messageID: String? = nil, reason: DesktopBlockReason? = nil) {
        self.outcome=outcome; self.targetID=targetID; self.messageID=messageID; self.reason=reason
    }
}

@MainActor public protocol DesktopAdapter: AnyObject {
    var agent: DesktopAgent { get }
    func compatibility() -> DesktopCompatibility
    func discoverTargets() async throws -> DesktopDiscovery
    func discoverTargets(matching query:String) async throws -> DesktopDiscovery
    func openTarget(_ target: DesktopTarget) async throws
    func preflight(_ target: DesktopTarget) async throws -> DesktopPreflight
    func stageText(_ text: String, preflight: DesktopPreflight) async throws -> DesktopStagedText
    /// Never retries a submission. Once a native/AX submission may have happened,
    /// throw resultUnknown; other DesktopBlockReason values must prove no submission occurred.
    func pressSend(_ staged: DesktopStagedText, permit: DesktopSendPermit, maySend: @escaping () -> Bool) async throws
    func verifyReceipt(_ staged: DesktopStagedText) async -> DesktopReceipt
    func cancel()
}

public extension DesktopAdapter{
    func discoverTargets(query:String)async throws->DesktopDiscovery{try await discoverTargets(matching:query)}
    func discoverTargets(matching query:String)async throws->DesktopDiscovery{
        var result=try await discoverTargets()
        if !query.isEmpty{result.targets=result.targets.filter{$0.title.localizedCaseInsensitiveContains(query)||($0.project?.localizedCaseInsensitiveContains(query) ?? false)}}
        return result
    }
}
