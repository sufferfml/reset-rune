import AppKit
import ApplicationServices
import Foundation

/// Identity-only view of an AX node. It deliberately omits text values and titles.
public struct DesktopAXNode: Sendable {
    public var role: String
    public var identifier: String?
    public var domIdentifier: String?
    public var url: String?
    public var document: String?
    public var selected: Bool
    public init(role: String, identifier: String? = nil, domIdentifier: String? = nil, url: String? = nil, document: String? = nil, selected: Bool = false) {
        self.role=role; self.identifier=identifier; self.domIdentifier=domIdentifier; self.url=url; self.document=document; self.selected=selected
    }
}

public struct DesktopResolvedIdentity: Sendable {
    public var targetID: String
    public var sourceID: String
    public init(targetID: String, sourceID: String) { self.targetID=targetID; self.sourceID=sourceID }
}

/// A profile can only be shipped after the corresponding desktop version passes P0.
/// No production profile is registered by this module at present.
@MainActor public struct DesktopAXProfile {
    public var bundleID: String
    public var appVersion: String
    public var composerIdentifier: String
    public var sendIdentifier: String
    public var busyIdentifier: String
    public var resolveIdentity: ([DesktopAXNode]) -> DesktopResolvedIdentity?
    public init(bundleID: String, appVersion: String, composerIdentifier: String, sendIdentifier: String, busyIdentifier: String, resolveIdentity: @escaping ([DesktopAXNode]) -> DesktopResolvedIdentity?) {
        self.bundleID=bundleID; self.appVersion=appVersion; self.composerIdentifier=composerIdentifier
        self.sendIdentifier=sendIdentifier; self.busyIdentifier=busyIdentifier; self.resolveIdentity=resolveIdentity
    }
}

/// Native AX implementation behind the same injected pipeline used in tests. It does
/// not activate applications, enable Electron accessibility switches, click coordinates,
/// use the clipboard, or find a target by its title. No native operation retries.
@MainActor public final class DesktopAXDriver: DesktopDeliveryDriver {
    private let profile: DesktopAXProfile
    private let readMessages: (DesktopMessageCursor, DesktopTarget) throws -> [DesktopMessageEvidence]
    private var window: AXUIElement?
    private var composer: AXUIElement?
    private var sendButton: AXUIElement?
    private var currentID: String?
    private var currentTarget: DesktopTarget?
    private var stagedText: String?
    public init(profile: DesktopAXProfile, readMessages: @escaping (DesktopMessageCursor, DesktopTarget) throws -> [DesktopMessageEvidence]) {
        self.profile=profile; self.readMessages=readMessages
    }
    public func context(for target: DesktopTarget) throws -> DesktopWindowContext {
        guard AXIsProcessTrusted() else { throw DesktopBlockReason.accessibilityRequired }
        guard target.bundleID == profile.bundleID, target.appVersion == profile.appVersion else { throw DesktopBlockReason.unsupportedVersion }
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:profile.bundleID).first,
              let bundleURL=app.bundleURL, let bundle=Bundle(url:bundleURL), bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String == profile.appVersion else { throw DesktopBlockReason.sourceChanged }
        let locked=(CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool ?? true
        guard !locked else { throw DesktopBlockReason.screenLocked }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw DesktopBlockReason.notFrontmost }
        let application=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application,0.1)
        guard let rawWindow=value(application,"AXFocusedWindow"), CFGetTypeID(rawWindow)==AXUIElementGetTypeID() else { throw DesktopBlockReason.targetNotConfirmed }
        let focused=rawWindow as! AXUIElement
        let nodes=try boundedTree(focused)
        let snapshot=nodes.map { element -> DesktopAXNode in
            DesktopAXNode(role:string(element,"AXRole") ?? "",identifier:string(element,"AXIdentifier"),domIdentifier:string(element,"AXDOMIdentifier"),url:urlString(element,"AXURL"),document:urlString(element,"AXDocument"),selected:(value(element,"AXSelected") as? Bool)==true || string(element,"AXCurrent")=="page")
        }
        guard let identity=profile.resolveIdentity(snapshot), identity.targetID == target.id, identity.sourceID == target.sourceID else { throw DesktopBlockReason.targetNotConfirmed }
        let composers=nodes.filter { string($0,"AXRole")=="AXTextArea" && matches($0,profile.composerIdentifier) }
        let senders=nodes.filter { string($0,"AXRole")=="AXButton" && matches($0,profile.sendIdentifier) }
        guard composers.count==1, senders.count==1 else { throw DesktopBlockReason.targetNotConfirmed }
        if let window, !CFEqual(window,focused) { currentID=nil }
        if currentID==nil { currentID=UUID().uuidString }
        window=focused; composer=composers[0]; sendButton=senders[0]; currentTarget=target
        let messages=try readMessages(DesktopMessageCursor(targetID:target.id,sourceID:target.sourceID,seenMessageIDs:[],capturedAt:0),target)
        return DesktopWindowContext(contextID:currentID!,targetID:identity.targetID,sourceID:identity.sourceID,
            busy:nodes.contains{matches($0,profile.busyIdentifier)},draft:string(composers[0],"AXValue") ?? "",
            sendEnabled:(value(senders[0],"AXEnabled") as? Bool)==true,seenMessageIDs:Set(messages.map(\.id)))
    }
    public func writeText(_ text: String, contextID: String) throws {
        guard let target=currentTarget else { throw DesktopBlockReason.targetNotConfirmed }
        let state=try context(for:target)
        guard state.contextID==contextID, state.draft.isEmpty, let composer else { throw DesktopBlockReason.userInterference }
        guard AXUIElementSetAttributeValue(composer,kAXValueAttribute as CFString,text as CFString) == .success else { throw DesktopBlockReason.textMismatch }
        stagedText=text
    }
    public func pressSend(contextID: String, maySend: () -> Bool) throws {
        guard let target=currentTarget else { throw DesktopBlockReason.targetNotConfirmed }
        let state=try context(for:target)
        guard state.contextID==contextID, state.sendEnabled, let sendButton else { throw DesktopBlockReason.sendUnavailable }
        guard let stagedText, state.draft.utf8.elementsEqual(stagedText.utf8) else { throw DesktopBlockReason.userInterference }
        guard maySend() else { throw DesktopBlockReason.cancelled }
        // The caller marks dispatching before invoking this method. Even a non-success
        // return can mean the app received the action, so it is never safe to retry.
        guard AXUIElementPerformAction(sendButton,kAXPressAction as CFString) == .success else { throw DesktopBlockReason.resultUnknown }
    }
    public func messages(after cursor: DesktopMessageCursor, target: DesktopTarget) throws -> [DesktopMessageEvidence] { try readMessages(cursor,target) }
    private func value(_ element: AXUIElement,_ key: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success ? value : nil
    }
    private func string(_ element: AXUIElement,_ key: String) -> String? { value(element,key) as? String }
    private func urlString(_ element: AXUIElement,_ key: String) -> String? {
        let raw=value(element,key); return (raw as? URL)?.absoluteString ?? (raw as? String)
    }
    private func matches(_ element: AXUIElement,_ id: String) -> Bool { !id.isEmpty && (string(element,"AXIdentifier")==id || string(element,"AXDOMIdentifier")==id) }
    private func boundedTree(_ root: AXUIElement) throws -> [AXUIElement] {
        var queue=[(root,0)],result=[AXUIElement](),seen=Set<CFHashCode>(),index=0
        let start=ProcessInfo.processInfo.systemUptime
        while index<queue.count {
            guard index<1_500,ProcessInfo.processInfo.systemUptime-start<2 else { throw DesktopBlockReason.limitExceeded }
            let (element,depth)=queue[index]; index+=1
            guard seen.insert(CFHash(element)).inserted else { continue }
            result.append(element)
            if let children=value(element,"AXChildren") as? [AXUIElement], !children.isEmpty {
                guard depth<24,queue.count+children.count<=1_500 else { throw DesktopBlockReason.limitExceeded }
                queue.append(contentsOf:children.map{($0,depth+1)})
            }
        }
        return result
    }
}
