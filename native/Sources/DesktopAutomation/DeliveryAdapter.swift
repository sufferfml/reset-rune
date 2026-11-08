import Foundation

/// A driver must expose machine identity from the current window, never a title match.
@MainActor public protocol DesktopDeliveryDriver: AnyObject {
    func context(for target: DesktopTarget) throws -> DesktopWindowContext
    func writeText(_ text: String, contextID: String) throws
    /// Check this gate immediately before the external action, after any UI reads.
    func pressSend(contextID: String, maySend: () -> Bool) throws
    func messages(after cursor: DesktopMessageCursor, target: DesktopTarget) throws -> [DesktopMessageEvidence]
}

public struct DesktopWindowContext: Sendable {
    public var contextID: String
    public var targetID: String?
    public var sourceID: String?
    public var frontmost: Bool
    public var locked: Bool
    public var trusted: Bool
    public var busy: Bool
    public var draft: String
    public var sendEnabled: Bool
    public var seenMessageIDs: Set<String>
    public init(contextID: String, targetID: String?, sourceID: String?, frontmost: Bool = true, locked: Bool = false, trusted: Bool = true, busy: Bool = false, draft: String = "", sendEnabled: Bool = true, seenMessageIDs: Set<String> = []) {
        self.contextID=contextID; self.targetID=targetID; self.sourceID=sourceID; self.frontmost=frontmost
        self.locked=locked; self.trusted=trusted; self.busy=busy; self.draft=draft; self.sendEnabled=sendEnabled; self.seenMessageIDs=seenMessageIDs
    }
}

public struct DesktopMessageEvidence: Sendable {
    public var id: String
    public var targetID: String
    public var sourceID: String
    public var text: String
    public var timestamp: Int64
    /// Set only when an adapter can prove this message belongs to that UI submission.
    /// Text equality and a nearby timestamp alone cannot supply this association.
    public var stageID: UUID?
    public init(id: String, targetID: String, sourceID: String, text: String, timestamp: Int64, stageID: UUID? = nil) {
        self.id=id; self.targetID=targetID; self.sourceID=sourceID; self.text=text; self.timestamp=timestamp; self.stageID=stageID
    }
}

/// Injectable pipeline used by both adapters and synthetic GUI checks. No title fallback,
/// clipboard access, key event, sleep prevention, or send retry exists in this layer.
@MainActor public final class DesktopDeliveryAdapter: DesktopAdapter {
    public let agent: DesktopAgent
    private let assessment: () -> DesktopCompatibility
    private let discover: () throws -> [DesktopTarget]
    private let opener: (DesktopTarget) throws -> Void
    private let driver: DesktopDeliveryDriver
    private let now: () -> Int64
    private var active: DesktopStagedText?
    private var pressed: UUID?
    private var cancelled = false

    public init(agent: DesktopAgent, compatibility: @escaping () -> DesktopCompatibility, discover: @escaping () throws -> [DesktopTarget], open: @escaping (DesktopTarget) throws -> Void, driver: DesktopDeliveryDriver, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.agent=agent; self.assessment=compatibility; self.discover=discover; self.opener=open; self.driver=driver; self.now=now
    }
    public func compatibility() -> DesktopCompatibility { assessment() }
    public func discoverTargets() async throws -> DesktopDiscovery {
        let status=assessment()
        guard status.canDiscover else { throw status.blockers.first ?? .sourceUnavailable }
        return DesktopDiscovery(targets: try discover(), compatibility: status)
    }
    public func openTarget(_ target: DesktopTarget) async throws { try validate(target); try opener(target) }
    public func preflight(_ target: DesktopTarget) async throws -> DesktopPreflight {
        try validate(target)
        guard assessment().canSend else { throw assessment().blockers.first ?? .unsupportedVersion }
        guard active == nil else { throw DesktopBlockReason.targetBusy }
        cancelled=false; pressed=nil
        let context=try driver.context(for: target)
        try check(context, target: target)
        guard context.draft.isEmpty else { throw DesktopBlockReason.userDraft }
        return DesktopPreflight(target: target, cursor: DesktopMessageCursor(targetID: target.id, sourceID: target.sourceID, seenMessageIDs: context.seenMessageIDs, capturedAt: now()), contextID: context.contextID)
    }
    public func stageText(_ text: String, preflight: DesktopPreflight) async throws -> DesktopStagedText {
        guard !cancelled, active == nil else { throw DesktopBlockReason.cancelled }
        try validate(preflight.target)
        guard assessment().canSend else { throw DesktopBlockReason.unsupportedVersion }
        guard !text.isEmpty, text.utf8.count <= 32 * 1024 else { throw DesktopBlockReason.limitExceeded }
        let context=try driver.context(for: preflight.target)
        try check(context, target: preflight.target, contextID: preflight.contextID)
        guard context.draft.isEmpty else { throw DesktopBlockReason.userDraft }
        try driver.writeText(text, contextID: context.contextID)
        let after=try driver.context(for: preflight.target)
        try check(after, target: preflight.target, contextID: preflight.contextID)
        guard after.draft.utf8.elementsEqual(text.utf8) else { throw DesktopBlockReason.textMismatch }
        let staged=DesktopStagedText(preflight: preflight, text: text)
        active=staged
        return staged
    }
    public func pressSend(_ staged: DesktopStagedText, permit: DesktopSendPermit, maySend: @escaping () -> Bool) async throws {
        guard !cancelled, active?.stageID == staged.stageID, pressed == nil else { throw DesktopBlockReason.cancelled }
        guard permit.stageID == staged.stageID, permit.expiresAt > now(), permit.expiresAt <= now()+5_000 else { throw DesktopBlockReason.permitExpired }
        try validate(staged.preflight.target)
        guard assessment().canSend else { throw DesktopBlockReason.unsupportedVersion }
        let context=try driver.context(for: staged.preflight.target)
        try check(context, target: staged.preflight.target, contextID: staged.preflight.contextID)
        guard context.draft.utf8.elementsEqual(staged.text.utf8) else { throw DesktopBlockReason.userInterference }
        guard context.sendEnabled else { throw DesktopBlockReason.sendUnavailable }
        guard maySend(), !cancelled, permit.expiresAt > now() else { throw DesktopBlockReason.cancelled }
        // Mark before the call. An AX failure may still mean the application handled it.
        pressed=staged.stageID
        do { try driver.pressSend(contextID: context.contextID,maySend:{ !self.cancelled && permit.expiresAt > self.now() && maySend() }) }
        catch { throw DesktopBlockReason.resultUnknown }
    }
    public func verifyReceipt(_ staged: DesktopStagedText) async -> DesktopReceipt {
        defer { active=nil }
        let target=staged.preflight.target
        guard pressed == staged.stageID else { return DesktopReceipt(outcome: .unknown, targetID: target.id, reason: .resultUnknown) }
        guard let evidence=try? driver.messages(after: staged.preflight.cursor, target: target) else {
            return DesktopReceipt(outcome: .unknown, targetID: target.id, reason: .sourceUnavailable)
        }
        let matches=evidence.filter { !$0.id.isEmpty && $0.targetID == target.id && $0.sourceID == target.sourceID && $0.text.utf8.elementsEqual(staged.text.utf8) && $0.timestamp >= staged.preflight.cursor.capturedAt && $0.timestamp <= now() && !staged.preflight.cursor.seenMessageIDs.contains($0.id) && $0.stageID == staged.stageID }
        guard matches.count == 1 else { return DesktopReceipt(outcome: .unknown, targetID: target.id, reason: .resultUnknown) }
        return DesktopReceipt(outcome: .sent, targetID: target.id, messageID: matches[0].id)
    }
    public func cancel() { cancelled=true; active=nil }
    private func validate(_ target: DesktopTarget) throws {
        guard target.agent == agent, target.bundleID == agent.bundleID, !target.id.isEmpty, !target.sourceID.isEmpty else { throw DesktopBlockReason.invalidTarget }
        guard target.appVersion == assessment().version else { throw DesktopBlockReason.sourceChanged }
    }
    private func check(_ context: DesktopWindowContext, target: DesktopTarget, contextID: String? = nil) throws {
        guard context.trusted else { throw DesktopBlockReason.accessibilityRequired }
        guard !context.locked else { throw DesktopBlockReason.screenLocked }
        guard context.frontmost else { throw DesktopBlockReason.notFrontmost }
        guard context.targetID == target.id, context.sourceID == target.sourceID else { throw DesktopBlockReason.targetNotConfirmed }
        if let contextID, context.contextID != contextID { throw DesktopBlockReason.userInterference }
        guard !context.busy else { throw DesktopBlockReason.targetBusy }
    }
}
