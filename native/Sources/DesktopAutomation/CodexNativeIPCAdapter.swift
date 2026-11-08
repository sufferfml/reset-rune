// INPUT: Explicit existing chat, inherited desktop permissions and a one-use send permit.
// OUTPUT: Same-desktop delivery with owner/turn/client-message/text receipt correlation.
// POS: Version-locked adapter; see README.md and docs/courier-compatibility.md.
import Foundation
import AppKit
import Security

/// Version-locked desktop-owner IPC adapter. The selected existing thread is sent
/// through the running desktop manager, never through a new CLI/App Server process.
@MainActor public final class CodexNativeIPCAdapter: DesktopAdapter {
    public let agent:DesktopAgent = .codex
    public static let supportedVersion="26.1103.41825"
    public static let supportedBuild="25679"
    private let suppliedConfiguration:CodexIPCConfiguration?
    private let suppliedTargets:[DesktopTarget]?
    private let suppliedNavigation:(@MainActor (URL)async throws->Void)?
    private let navigationTimeout:TimeInterval
    private var navigationWaiter:CodexNavigationWaiter?
    private var session:CodexIPCSession?
    private var preparation:DesktopPreflight?
    private var active:DesktopStagedText?
    private var acknowledgement:CodexIPCStartAcknowledgement?
    private var consumed=false
    private var generation=UUID()
    public init(){suppliedConfiguration=nil;suppliedTargets=nil;suppliedNavigation=nil;navigationTimeout=3}
    internal init(testConfiguration:CodexIPCConfiguration,targets:[DesktopTarget],navigationTimeout:TimeInterval=3,navigateExisting:(@MainActor (URL)async throws->Void)?=nil){suppliedConfiguration=testConfiguration;suppliedTargets=targets;suppliedNavigation=navigateExisting;self.navigationTimeout=min(3,max(0.01,navigationTimeout))}
    private var installedBundle:Bundle?{NSWorkspace.shared.urlForApplication(withBundleIdentifier:agent.bundleID).flatMap(Bundle.init(url:))}
    public func compatibility()->DesktopCompatibility{
        if suppliedConfiguration != nil{return DesktopCompatibility(agent:.codex,version:Self.supportedVersion,canDiscover:true,canSend:true,blockers:[.liveValidationRequired],requiresAccessibility:false)}
        guard let bundle=installedBundle,let version=bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString")as?String else{return DesktopCompatibility(agent:.codex,version:nil,canDiscover:false,canSend:false,blockers:[.appMissing],requiresAccessibility:false)}
        let supported=version==Self.supportedVersion && bundle.object(forInfoDictionaryKey:"CFBundleVersion")as?String==Self.supportedBuild
        return DesktopCompatibility(agent:.codex,version:version,canDiscover:true,canSend:supported,blockers:supported ? [.liveValidationRequired]:[.unsupportedVersion],requiresAccessibility:false)
    }
    public func discoverTargets()async throws->DesktopDiscovery{
        try await discoverTargets(matching:"")
    }
    public func discoverTargets(matching query:String)async throws->DesktopDiscovery{
        let status=compatibility();guard let version=status.version else{throw DesktopBlockReason.appMissing}
        let targets:[DesktopTarget]
        if let suppliedTargets{targets=suppliedTargets.filter{query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)||($0.project?.localizedCaseInsensitiveContains(query) ?? false)}}
        else{
            do{
                let page=try DesktopTargetReader(root:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")).codexPage(version:version,matching:query)
                return DesktopDiscovery(targets:page.targets,compatibility:status,hasMore:page.hasMore)
            }catch let reason as DesktopBlockReason{throw reason}catch{throw DesktopBlockReason.sourceUnavailable}
        }
        return DesktopDiscovery(targets:targets,compatibility:status)
    }
    public func openTarget(_ target:DesktopTarget)async throws{
        try validate(target)
        guard suppliedConfiguration==nil,let url=URL(string:"codex://threads/"+target.id),NSWorkspace.shared.open(url)else{throw DesktopBlockReason.targetNotConfirmed}
    }
    public func preflight(_ target:DesktopTarget)async throws->DesktopPreflight{
        guard compatibility().canSend else{throw DesktopBlockReason.unsupportedVersion}
        try validate(target)
        guard active==nil else{throw DesktopBlockReason.targetBusy}
        let token=UUID();generation=token
        if let previous=session{await previous.close()}
        let configuration=try configuration()
        var connection=CodexIPCSession(configuration:configuration);session=connection
        do{
            let snapshot:CodexIPCSnapshot
            do{snapshot=try await connection.prepare(conversationID:target.id)}
            catch DesktopBlockReason.ownerUnavailable{
                guard generation==token,!Task.isCancelled,let peerPID=await connection.initializedPeerPID()else{throw DesktopBlockReason.cancelled}
                try validateExistingTarget(target)
                try await restoreExistingTarget(target,peerPID:peerPID)
                guard generation==token,!Task.isCancelled else{throw DesktopBlockReason.cancelled}
                await connection.close()
                guard generation==token,!Task.isCancelled else{throw DesktopBlockReason.cancelled}
                connection=CodexIPCSession(configuration:try self.configuration());session=connection
                snapshot=try await waitForRestoredOwner(target,connection:connection,generation:token)
            }
            guard generation==token else{throw DesktopBlockReason.cancelled}
            guard snapshot.isIdle,!snapshot.hasPendingRequests else{throw DesktopBlockReason.targetBusy}
            let result=DesktopPreflight(target:target,cursor:DesktopMessageCursor(targetID:target.id,sourceID:target.sourceID,seenMessageIDs:[],capturedAt:Int64(Date().timeIntervalSince1970*1000)),contextID:snapshot.ownerID)
            preparation=result;active=nil;acknowledgement=nil;consumed=false;return result
        }catch{await connection.abortConnection();if generation==token{session=nil};throw normalized(error)}
    }
    private func waitForRestoredOwner(_ target:DesktopTarget,connection:CodexIPCSession,generation token:UUID)async throws->CodexIPCSnapshot{
        for attempt in 0..<3{
            guard generation==token,!Task.isCancelled else{throw DesktopBlockReason.cancelled}
            try validate(target)
            do{return try await connection.prepare(conversationID:target.id)}
            catch DesktopBlockReason.ownerUnavailable{
                if attempt==2{throw DesktopBlockReason.sourceUnavailable}
                do{try await Task.sleep(nanoseconds:UInt64(attempt+1)*200_000_000)}catch{throw DesktopBlockReason.cancelled}
            }
        }
        throw DesktopBlockReason.sourceUnavailable
    }
    private func validateExistingTarget(_ target:DesktopTarget)throws{
        try validate(target)
        if suppliedConfiguration != nil{return}
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let existing=try DesktopTargetReader(root:root).codexTarget(id:target.id,version:target.appVersion),existing.id==target.id,existing.sourceID==target.sourceID else{throw DesktopBlockReason.invalidTarget}
    }
    private func restoreExistingTarget(_ target:DesktopTarget,peerPID:pid_t)async throws{
        guard UUID(uuidString:target.id) != nil,let url=URL(string:"codex://threads/"+target.id)else{throw DesktopBlockReason.invalidTarget}
        if suppliedConfiguration != nil{
            guard let suppliedNavigation else{throw DesktopBlockReason.sourceUnavailable}
            try await awaitNavigation{finish,waiter in
                waiter.operation=Task{@MainActor in
                    do{try await suppliedNavigation(url);finish(.success(()))}catch{finish(.failure(error))}
                }
            };return
        }
        guard compatibility().canSend,let bundle=installedBundle,
              let running=NSRunningApplication(processIdentifier:peerPID),!running.isTerminated,running.bundleIdentifier==agent.bundleID,
              running.bundleURL?.standardizedFileURL==bundle.bundleURL.standardizedFileURL else{throw DesktopBlockReason.sourceUnavailable}
        // Recheck the pinned signature before asking LaunchServices to navigate.
        _=try configuration()
        let options=NSWorkspace.OpenConfiguration();options.activates=false;options.createsNewApplicationInstance=false;options.allowsRunningApplicationSubstitution=false;options.addsToRecentItems=false
        try await awaitNavigation{finish,_ in
            NSWorkspace.shared.open([url],withApplicationAt:bundle.bundleURL,configuration:options){app,error in
                Task{@MainActor in
                    if error != nil{finish(.failure(DesktopBlockReason.sourceUnavailable))}
                    else if let app,app.processIdentifier==peerPID,!app.isTerminated{finish(.success(()))}
                    else{finish(.failure(DesktopBlockReason.sourceChanged))}
                }
            }
        }
    }
    private func awaitNavigation(_ start:@escaping @MainActor (@escaping @MainActor (Result<Void,Error>)->Void,CodexNavigationWaiter)->Void)async throws{
        let waiter=CodexNavigationWaiter();navigationWaiter=waiter
        defer{if navigationWaiter===waiter{navigationWaiter=nil};waiter.stopTasks()}
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation{continuation in
                waiter.install(continuation)
                guard !Task.isCancelled else{waiter.finish(.failure(DesktopBlockReason.cancelled));return}
                waiter.timeout=Task{@MainActor [weak waiter]in
                    do{try await Task.sleep(nanoseconds:UInt64(self.navigationTimeout*1_000_000_000))}catch{return}
                    waiter?.finish(.failure(DesktopBlockReason.sourceUnavailable))
                }
                start({result in waiter.finish(result)},waiter)
            }
        },onCancel:{Task{@MainActor in waiter.finish(.failure(DesktopBlockReason.cancelled))}})
    }
    public func stageText(_ text:String,preflight:DesktopPreflight)async throws->DesktopStagedText{
        guard let preparation,preparation.contextID==preflight.contextID,preparation.target==preflight.target,session != nil,!consumed,active==nil else{throw DesktopBlockReason.cancelled}
        guard !text.isEmpty,text.utf8.count<=32*1024 else{throw DesktopBlockReason.limitExceeded}
        let staged=DesktopStagedText(preflight:preflight,text:text);active=staged;return staged
    }
    public func pressSend(_ staged:DesktopStagedText,permit:DesktopSendPermit,maySend:@escaping ()->Bool)async throws{
        guard active?.stageID==staged.stageID,!consumed,let connection=session else{throw DesktopBlockReason.cancelled}
        guard compatibility().canSend else{throw DesktopBlockReason.unsupportedVersion}
        let now=Int64(Date().timeIntervalSince1970*1000)
        guard permit.stageID==staged.stageID,permit.expiresAt>now,permit.expiresAt<=now+5_000 else{throw DesktopBlockReason.permitExpired}
        guard maySend()else{throw DesktopBlockReason.cancelled}
        consumed=true
        let token=generation
        // Preserve the last local gate across the actor hop. No message is sent until
        // it is checked again after the fresh owner/idle snapshot, immediately at write.
        do{
            acknowledgement=try await connection.start(conversationID:staged.preflight.target.id,owner:staged.preflight.contextID,stageID:staged.stageID,text:staged.text,expiresAt:permit.expiresAt,maySend:{@MainActor in
                    self.generation==token && self.active?.stageID==staged.stageID && self.compatibility().canSend && maySend()
                })
        }catch{
            await connection.abortConnection();throw normalized(error)
        }
    }
    public func verifyReceipt(_ staged:DesktopStagedText)async->DesktopReceipt{
        let target=staged.preflight.target
        guard consumed,active?.stageID==staged.stageID,let ack=acknowledgement,let connection=session,
              ack.conversationID==target.id,ack.clientMessageID==staged.stageID.uuidString,ack.ownerID==staged.preflight.contextID else{return DesktopReceipt(outcome:.unknown,targetID:target.id,reason:.resultUnknown)}
        defer{active=nil;preparation=nil;acknowledgement=nil;session=nil}
        do{
            let snapshot=try await connection.refresh(conversationID:target.id,expectedOwner:ack.ownerID)
            let matched=Self.matchesAcceptedTurn(snapshot.state,turnID:ack.turnID,clientMessageID:ack.clientMessageID,text:staged.text)
            await connection.close()
            return matched ? DesktopReceipt(outcome:.sent,targetID:target.id,messageID:"turn:"+ack.turnID+":client:"+ack.clientMessageID) : DesktopReceipt(outcome:.unknown,targetID:target.id,reason:.resultUnknown)
        }catch{await connection.abortConnection();return DesktopReceipt(outcome:.unknown,targetID:target.id,reason:.resultUnknown)}
    }
    public func cancel(){
        generation=UUID();active=nil;preparation=nil;acknowledgement=nil
        navigationWaiter?.finish(.failure(DesktopBlockReason.cancelled));navigationWaiter=nil
        let connection=session;session=nil
        if let connection{Task{await connection.close()}}
    }
    private func validate(_ target:DesktopTarget)throws{
        guard target.agent == .codex,target.bundleID==agent.bundleID,target.appVersion==compatibility().version,UUID(uuidString:target.id) != nil else{throw DesktopBlockReason.invalidTarget}
        if let suppliedTargets{guard suppliedTargets.contains(target)else{throw DesktopBlockReason.sourceChanged}}
        else{
            let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            guard target.sourceID==DesktopTargetReader.sourceIdentifier(for:root)else{throw DesktopBlockReason.sourceChanged}
        }
    }
    internal func configuration()throws->CodexIPCConfiguration{
        if let suppliedConfiguration{return suppliedConfiguration}
        guard compatibility().canSend,let bundle=installedBundle,let executable=bundle.executableURL else{throw DesktopBlockReason.unsupportedVersion}
        var code:SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL,[],&code)==errSecSuccess,let code,SecStaticCodeCheckValidity(code,[],nil)==errSecSuccess else{throw DesktopBlockReason.sourceChanged}
        var info:CFDictionary?
        guard SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
              let dictionary=info as? [String:Any],dictionary[kSecCodeInfoTeamIdentifier as String]as?String=="2DC432GLL2" else{throw DesktopBlockReason.sourceChanged}
        return CodexIPCConfiguration(socketURL:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/ipc/ipc.sock"),expectedPeerExecutable:executable)
    }
    private func normalized(_ error:Error)->DesktopBlockReason{error as? DesktopBlockReason ?? .sourceUnavailable}
    /// The owner snapshot must contain the real acknowledged turn and our client ID;
    /// an optimistic unsent turn or merely similar text cannot pass this check.
    internal static func matchesAcceptedTurn(_ state:CodexIPCJSON,turnID:String,clientMessageID:String,text:String)->Bool{
        var queue=[state],index=0
        while index<queue.count,index<20_000{
            let value=queue[index];index+=1
            if let object=value.object{
                let id=object["turnId"]?.string ?? object["id"]?.string
                let params=value["params"]
                if id==turnID,params["clientUserMessageId"].string==clientMessageID,
                   let input=params["input"].array,input.count==1,input[0]["type"].string=="text",
                   let received=input[0]["text"].string,received.utf8.elementsEqual(text.utf8){return true}
                queue.append(contentsOf:object.values)
            }else if let array=value.array{queue.append(contentsOf:array)}
            if queue.count>20_000{return false}
        }
        return false
    }
}

/// Unstructured timeout/cancellation settles the outer continuation once; it never
/// waits for an unresponsive system callback. Late callbacks only see a settled box.
@MainActor private final class CodexNavigationWaiter{
    private var continuation:CheckedContinuation<Void,Error>?
    private var result:Result<Void,Error>?
    var timeout:Task<Void,Never>?
    var operation:Task<Void,Never>?
    func install(_ continuation:CheckedContinuation<Void,Error>){if let result{continuation.resume(with:result)}else{self.continuation=continuation}}
    func finish(_ result:Result<Void,Error>){guard self.result==nil else{return};self.result=result;let continuation=self.continuation;self.continuation=nil;stopTasks();continuation?.resume(with:result)}
    func stopTasks(){timeout?.cancel();timeout=nil;operation?.cancel();operation=nil}
}
