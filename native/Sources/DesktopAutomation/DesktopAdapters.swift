import AppKit
import ApplicationServices
import Foundation

@MainActor public enum DesktopAccessibility {
    public static var isTrusted: Bool { AXIsProcessTrusted() }
    public static func requestAccess() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
    }
    public static func openSettings() { if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) } }
}

@MainActor public enum DesktopAdapters {
    /// Mock never discovers local files, installed applications, or accessibility trees.
    public static func make(agent: DesktopAgent, mock: Bool = false) -> DesktopAdapter {
        if mock { return SimulatedDesktopAdapter(agent:agent) }
        if agent == .codex { return CodexNativeIPCAdapter() }
        return InstalledDesktopAdapter(agent:agent)
    }
}

/// Installed-app inventory and user-requested discovery work today. Delivery stays
/// blocked until a version has P0 evidence for both pre-send identity and receipt.
@MainActor public final class InstalledDesktopAdapter: DesktopAdapter {
    public let agent: DesktopAgent
    private let workspace: NSWorkspace
    public init(agent: DesktopAgent) { self.agent=agent; self.workspace = .shared }
    private var bundle: Bundle? { workspace.urlForApplication(withBundleIdentifier:agent.bundleID).flatMap(Bundle.init(url:)) }
    private var version: String? { bundle?.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String }
    public func compatibility() -> DesktopCompatibility {
        DesktopCompatibility(agent:agent,version:version,canDiscover:bundle != nil,canSend:false,blockers:bundle == nil ? [.appMissing] : [.targetNotConfirmed,.receiptNotSupported])
    }
    public func discoverTargets() async throws -> DesktopDiscovery {
        guard let version else { throw DesktopBlockReason.appMissing }
        let home=FileManager.default.homeDirectoryForCurrentUser
        let root=agent == .codex ? home.appendingPathComponent(".codex") : home.appendingPathComponent("Library/Application Support/Claude")
        let reader=DesktopTargetReader(root:root)
        let targets: [DesktopTarget]
        do { targets=try agent == .codex ? reader.codex(version:version) : reader.claude(version:version) }
        catch let reason as DesktopBlockReason { throw reason }
        catch { throw DesktopBlockReason.sourceUnavailable }
        return DesktopDiscovery(targets:targets,compatibility:compatibility())
    }
    public func openTarget(_ target: DesktopTarget) async throws {
        guard target.agent == agent, target.bundleID == agent.bundleID, target.appVersion == version else { throw DesktopBlockReason.sourceChanged }
        // A user-requested open is navigation only, never evidence of the active target.
        guard agent == .codex, UUID(uuidString:target.id) != nil, let url=URL(string:"codex://threads/"+target.id) else { throw DesktopBlockReason.targetNotConfirmed }
        guard workspace.open(url) else { throw DesktopBlockReason.targetNotConfirmed }
    }
    public func preflight(_ target: DesktopTarget) async throws -> DesktopPreflight { throw blocked() }
    public func stageText(_ text: String, preflight: DesktopPreflight) async throws -> DesktopStagedText { throw blocked() }
    public func pressSend(_ staged: DesktopStagedText, permit: DesktopSendPermit, maySend: @escaping () -> Bool) async throws { throw blocked() }
    public func verifyReceipt(_ staged: DesktopStagedText) async -> DesktopReceipt { DesktopReceipt(outcome:.unknown,targetID:staged.preflight.target.id,reason:.receiptNotSupported) }
    public func cancel() {}
    private func blocked() -> DesktopBlockReason { compatibility().blockers.first ?? .unsupportedVersion }
}

/// In-memory simulation: no real app, home directory, permission, or UI action.
@MainActor public final class SimulatedDesktopAdapter: DesktopAdapter {
    public let agent: DesktopAgent
    private var staged: DesktopStagedText?
    private var sent: UUID?
    public init(agent: DesktopAgent) { self.agent=agent }
    private var simulationBundleID: String { "local.reset-rune.mock."+agent.rawValue }
    public func compatibility() -> DesktopCompatibility { DesktopCompatibility(agent:agent,version:"simulation",canDiscover:true,canSend:true,blockers:[],requiresAccessibility:false) }
    public func discoverTargets() async throws -> DesktopDiscovery {
        DesktopDiscovery(targets:[DesktopTarget(agent:agent,id:"mock-"+agent.rawValue,title:agent == .codex ? "示例项目 · Codex" : "示例项目 · Claude Code",project:"Simulation",sourceID:"simulation",bundleID:simulationBundleID,appVersion:"simulation")],compatibility:compatibility())
    }
    public func openTarget(_ target: DesktopTarget) async throws { try valid(target) }
    public func preflight(_ target: DesktopTarget) async throws -> DesktopPreflight {
        try valid(target); staged=nil; sent=nil
        return DesktopPreflight(target:target,cursor:DesktopMessageCursor(targetID:target.id,sourceID:target.sourceID,seenMessageIDs:[],capturedAt:Int64(Date().timeIntervalSince1970*1000)),contextID:"simulation")
    }
    public func stageText(_ text: String, preflight: DesktopPreflight) async throws -> DesktopStagedText {
        try valid(preflight.target)
        guard !text.isEmpty, text.utf8.count <= 32*1024 else { throw DesktopBlockReason.limitExceeded }
        let value=DesktopStagedText(preflight:preflight,text:text); staged=value; return value
    }
    public func pressSend(_ value: DesktopStagedText, permit: DesktopSendPermit, maySend: @escaping () -> Bool) async throws {
        guard staged?.stageID == value.stageID, sent == nil, permit.stageID == value.stageID, permit.expiresAt > Int64(Date().timeIntervalSince1970*1000), maySend() else { throw DesktopBlockReason.cancelled }
        sent=value.stageID
    }
    public func verifyReceipt(_ value: DesktopStagedText) async -> DesktopReceipt {
        DesktopReceipt(outcome:sent == value.stageID ? .sent : .unknown,targetID:value.preflight.target.id,messageID:sent.map { "simulation-"+$0.uuidString },reason:sent == value.stageID ? nil : .resultUnknown)
    }
    public func cancel() { staged=nil }
    private func valid(_ target: DesktopTarget) throws {
        guard target.agent == agent, target.id == "mock-"+agent.rawValue, target.sourceID == "simulation", target.bundleID == simulationBundleID, target.appVersion == "simulation" else { throw DesktopBlockReason.invalidTarget }
    }
}
