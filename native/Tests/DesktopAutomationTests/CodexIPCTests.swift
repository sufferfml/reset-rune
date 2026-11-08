import XCTest
import Darwin
@testable import DesktopAutomation

private final class SyntheticDesktopRouter: @unchecked Sendable {
    let root:URL
    let socketURL:URL
    private let listener:Int32
    private let queue=DispatchQueue(label:"reset-rune.synthetic-ipc")
    private let lock=NSLock()
    private var stopped=false
    private var _starts=[CodexIPCJSON]()
    private var _ownerAvailable=true
    private var _connections=0
    private var activeClient:Int32 = -1
    private var owner="synthetic-owner"
    private var state:CodexIPCJSON = .null
    var initialBusy=false
    var pendingApproval=false
    var becomeBusyAfterSnapshot=false
    var changeOwnerAfterSnapshot=false
    var disconnectOnStart=false
    var corruptConfirmedMessage=false
    var ownerErrorMethod:String?
    init()throws{
        root=URL(fileURLWithPath:"/tmp/reset-rune-ipc-"+UUID().uuidString.prefix(8));socketURL=root.appendingPathComponent("router.sock")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        listener=Darwin.socket(AF_UNIX,SOCK_STREAM,0);guard listener>=0 else{throw DesktopBlockReason.sourceUnavailable}
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        let bytes=Array(socketURL.path.utf8)+[0];withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)}
        let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(listener,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard result==0,Darwin.listen(listener,2)==0 else{throw DesktopBlockReason.sourceUnavailable}
        chmod(socketURL.path,0o600)
    }
    var starts:[CodexIPCJSON]{lock.lock();defer{lock.unlock()};return _starts}
    var ownerAvailable:Bool{get{lock.lock();defer{lock.unlock()};return _ownerAvailable}set{lock.lock();_ownerAvailable=newValue;lock.unlock()}}
    var connections:Int{lock.lock();defer{lock.unlock()};return _connections}
    func start(){queue.async{[self]in
        while true{
            lock.lock();let done=stopped;lock.unlock();if done{return}
            let client=Darwin.accept(listener,nil,nil);if client<0{return}
            lock.lock();activeClient=client;_connections+=1;lock.unlock()
            var flag:Int32=1;setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&flag,socklen_t(MemoryLayout<Int32>.size))
            handle(client);lock.lock();activeClient = -1;lock.unlock();Darwin.close(client)
        }
    }}
    func stop(){lock.lock();stopped=true;if activeClient>=0{Darwin.shutdown(activeClient,SHUT_RDWR)};lock.unlock();Darwin.shutdown(listener,SHUT_RDWR);Darwin.close(listener);try? FileManager.default.removeItem(at:root)}
    static var executable:URL{
        var path=[CChar](repeating:0,count:4*Int(MAXPATHLEN));proc_pidpath(getpid(),&path,UInt32(path.count));return URL(fileURLWithPath:String(cString:path))
    }
    var configuration:CodexIPCConfiguration{CodexIPCConfiguration(socketURL:socketURL,expectedPeerExecutable:Self.executable,timeout:0.5)}
    private func handle(_ client:Int32){
        var codec=CodexIPCFrameCodec(),snapshots=0
        while true{
            var bytes=[UInt8](repeating:0,count:4096);let count=Darwin.recv(client,&bytes,bytes.count,0);if count<=0{return}
            guard let messages=try? codec.consume(Data(bytes.prefix(count)))else{return}
            for message in messages{
                if message["type"].string=="broadcast"{
                    if message["params"]["following"].bool==true{
                        let thread=message["params"]["conversationId"].string ?? ""
                        if state == .null{state = .object(["id":.string(thread),"hostId":.string("local"),"threadRuntimeStatus":.object(["type":.string(initialBusy ? "active":"idle")]),"requests":pendingApproval ? .array([.object(["type":.string("approval")])]):.array([]),"turns":.array([])])}
                        let event:CodexIPCJSON = .object(["type":.string("broadcast"),"method":.string("thread-stream-state-changed"),"version":.number(11),"sourceClientId":.string(owner),"params":.object(["conversationId":.string(thread),"hostId":.string("local"),"change":.object(["type":.string("snapshot"),"revision":.number(Double(snapshots+1)),"conversationState":state])])])
                        send(event,to:client);snapshots+=1
                        if becomeBusyAfterSnapshot{var object=state.object!;object["threadRuntimeStatus"] = .object(["type":.string("active")]);state = .object(object)}
                        if changeOwnerAfterSnapshot{owner="different-owner"}
                    };continue
                }
                guard let method=message["method"].string,let rid=message["requestId"].string else{return}
                var result:CodexIPCJSON = .object([:])
                switch method{
                case "initialize":result = .object(["clientId":.string("synthetic-client")])
                case "thread-owner-discovery":
                    if !ownerAvailable{
                        var error:[String:CodexIPCJSON]=["type":.string("response"),"requestId":.string(rid),"resultType":.string("error"),"error":.string("no-client-found")]
                        if let ownerErrorMethod{error["method"] = .string(ownerErrorMethod)}
                        send(.object(error),to:client);continue
                    }
                    result = .object(["supportsUntrustedAppInput":.bool(true)])
                case "thread-follower-read-model-settings":result = .object(["settings":.object(["model":.string("synthetic"),"reasoningEffort":.null])])
                case "thread-follower-start-turn":
                    lock.lock();_starts.append(message);lock.unlock()
                    if disconnectOnStart{return}
                    let request=message["params"]["turnStart"]["request"],mid=request["clientUserMessageId"],tid="synthetic-real-turn"
                    var object=state.object ?? [:]
                    object["threadRuntimeStatus"] = .object(["type":.string("active")])
                    object["turns"] = .array([.object(["turnId":.string(tid),"params":.object(["clientUserMessageId":corruptConfirmedMessage ? .string("not-our-client"):mid,"input":request["input"]])])])
                    state = .object(object);result = .object(["result":.object(["turn":.object(["id":.string(tid),"status":.string("inProgress")])])])
                default:return
                }
                send(.object(["type":.string("response"),"requestId":.string(rid),"resultType":.string("success"),"method":.string(method),"handledByClientId":.string(owner),"result":result]),to:client)
            }
        }
    }
    private func send(_ value:CodexIPCJSON,to client:Int32){
        guard let data=try? CodexIPCFrameCodec.encode(value)else{return}
        data.withUnsafeBytes{raw in
            var offset=0
            // Deliberately split both four-byte headers and JSON payloads.
            while offset<raw.count{let count=Darwin.send(client,raw.baseAddress!.advanced(by:offset),min(3,raw.count-offset),0);if count<=0{return};offset+=count}
        }
    }
}

final class CodexIPCFrameTests:XCTestCase{
    func testFragmentedFramesAndMultipleMessages()throws{
        var codec=CodexIPCFrameCodec();let first:CodexIPCJSON = .object(["type":.string("response"),"text":.string("中文 🫠\n\"quoted\"")])
        let frame=try CodexIPCFrameCodec.encode(first);var results=[CodexIPCJSON]()
        for byte in frame{results += try codec.consume(Data([byte]))}
        XCTAssertEqual(results,[first]);XCTAssertEqual(try codec.consume(frame+frame),[first,first])
    }
    func testRejectsZeroOversizeAndInvalidJSON()throws{
        for bytes in [Data([0,0,0,0]),Data([1,0,0,1]),Data([1,0,0,0,0x7b])]{
            var codec=CodexIPCFrameCodec();XCTAssertThrowsError(try codec.consume(bytes))
        }
    }
    func testUnknownSnapshotShapeAndLatentBusyStatesAreNotIdle(){
        let base:[String:CodexIPCJSON]=["threadRuntimeStatus":.object(["type":.string("idle")]),"requests":.array([]),"turns":.array([])]
        func idle(_ object:[String:CodexIPCJSON])->Bool{CodexIPCSnapshot(conversationID:"synthetic",ownerID:"owner",state:.object(object)).isIdle}
        XCTAssertTrue(idle(base))
        var value=base;value.removeValue(forKey:"turns");XCTAssertFalse(idle(value))
        value=base;value["turnHistory"] = .string("unknown");XCTAssertFalse(idle(value))
        value=base;value["resumeState"] = .string("resuming");XCTAssertFalse(idle(value))
        value=base;value["unconfirmedTurnSubmissions"] = .array([.object(["terminal":.bool(false)])]);XCTAssertFalse(idle(value))
        value=base;value["turnHistory"] = .object(["turns":.array([.object(["status":.string("inProgress")])])]);XCTAssertFalse(idle(value))
        value=base;value["threadGoal"] = .object(["status":.string("active")]);XCTAssertFalse(idle(value))
        value=base;value["turns"] = .array([.object(["turnId":.string("completed-turn"),"status":.string("completed"),"items":.array([.object(["status":.string("running"),"type":.string("historical-tool-output")])])])]);XCTAssertTrue(idle(value))
        value=base;value["turnHistory"] = .object(["kind":.string("canonical"),"history":.object(["isComplete":.bool(true),"islands":.array([.object(["newerBoundary":.object(["status":.string("exhausted")]),"entries":.array([.object(["value":.string("turn-key")])])])]),"entitiesByKey":.object(["turn-key":.object(["turnId":.string("completed-turn"),"status":.string("completed"),"items":.array([.object(["status":.string("running")])])])])])]);XCTAssertTrue(idle(value))
    }
}

@MainActor final class CodexNativeIPCTests:XCTestCase{
    private let target=DesktopTarget(agent:.codex,id:"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",title:"Synthetic only",sourceID:"synthetic",appVersion:CodexNativeIPCAdapter.supportedVersion)
    private func staged(_ adapter:CodexNativeIPCAdapter)async throws->DesktopStagedText{
        let preflight=try await adapter.preflight(target)
        return try await adapter.stageText("继续\nExact text 🫠",preflight:preflight)
    }
    func testExistingDesktopOwnerDeliveryUsesExactIDsAndInheritedPermissions()async throws{
        let router=try SyntheticDesktopRouter();defer{router.stop()};router.start()
        let adapter=CodexNativeIPCAdapter(testConfiguration:router.configuration,targets:[target])
        let value=try await staged(adapter)
        try await adapter.pressSend(value,permit:DesktopSendPermit(stageID:value.stageID,expiresAt:Int64(Date().timeIntervalSince1970*1000)+4_000),maySend:{true})
        let receipt=await adapter.verifyReceipt(value)
        XCTAssertEqual(receipt.outcome,.sent);XCTAssertEqual(router.starts.count,1)
        let request=try XCTUnwrap(router.starts.first)["params"]["turnStart"]["request"]
        XCTAssertEqual(request["threadId"].string,target.id);XCTAssertEqual(request["clientUserMessageId"].string,value.stageID.uuidString)
        XCTAssertEqual(request["input"].array?.first?["text"].string,value.text)
        for key in ["approvalPolicy","approvalsReviewer","permissions","sandboxPolicy","cwd","model"]{XCTAssertEqual(request[key],.null)}
        XCTAssertFalse(adapter.compatibility().requiresAccessibility)
    }
    func testFreshBusyAndPendingApprovalPreventSubmission()async throws{
        for approval in [false,true]{
            let router=try SyntheticDesktopRouter();router.pendingApproval=approval;router.initialBusy = !approval;router.start();defer{router.stop()}
            let adapter=CodexNativeIPCAdapter(testConfiguration:router.configuration,targets:[target])
            do{_=try await adapter.preflight(target);XCTFail("Busy target accepted")}catch{XCTAssertEqual(error as? DesktopBlockReason,.targetBusy)}
            XCTAssertEqual(router.starts.count,0)
        }
    }
    func testOwnerChangeOrBusyBetweenPreflightAndSendIsNotSent()async throws{
        for changeOwner in [false,true]{
            let router=try SyntheticDesktopRouter();router.becomeBusyAfterSnapshot = !changeOwner;router.changeOwnerAfterSnapshot=changeOwner;router.start();defer{router.stop()}
            let adapter=CodexNativeIPCAdapter(testConfiguration:router.configuration,targets:[target]);let value=try await staged(adapter)
            do{try await adapter.pressSend(value,permit:DesktopSendPermit(stageID:value.stageID,expiresAt:Int64(Date().timeIntervalSince1970*1000)+4_000),maySend:{true});XCTFail("Changed target submitted")}
            catch{XCTAssertEqual(error as? DesktopBlockReason,changeOwner ? .sourceChanged:.targetBusy)}
            XCTAssertEqual(router.starts.count,0)
        }
    }
    func testLostReceiptIsUnknownAndCannotSubmitAgain()async throws{
        let router=try SyntheticDesktopRouter();router.disconnectOnStart=true;router.start();defer{router.stop()}
        let adapter=CodexNativeIPCAdapter(testConfiguration:router.configuration,targets:[target]);let value=try await staged(adapter)
        let permit=DesktopSendPermit(stageID:value.stageID,expiresAt:Int64(Date().timeIntervalSince1970*1000)+4_000)
        do{try await adapter.pressSend(value,permit:permit,maySend:{true});XCTFail("Lost response accepted")}catch{XCTAssertEqual(error as? DesktopBlockReason,.resultUnknown)}
        do{try await adapter.pressSend(value,permit:permit,maySend:{true});XCTFail("Sent twice")}catch{XCTAssertEqual(error as? DesktopBlockReason,.cancelled)}
        let receipt=await adapter.verifyReceipt(value);XCTAssertEqual(receipt.outcome,.unknown);XCTAssertEqual(router.starts.count,1);adapter.cancel()
    }
    func testSelfGeneratedClientIDWithoutOwnerReadbackIsUnknown()async throws{
        let router=try SyntheticDesktopRouter();router.corruptConfirmedMessage=true;router.start();defer{router.stop()}
        let adapter=CodexNativeIPCAdapter(testConfiguration:router.configuration,targets:[target]);let value=try await staged(adapter)
        try await adapter.pressSend(value,permit:DesktopSendPermit(stageID:value.stageID,expiresAt:Int64(Date().timeIntervalSince1970*1000)+4_000),maySend:{true})
        let receipt=await adapter.verifyReceipt(value);XCTAssertEqual(receipt.outcome,.unknown);XCTAssertEqual(router.starts.count,1)
    }
    func testUnsafeSocketAndWrongPeerExecutableAreRejected()async throws{
        let router=try SyntheticDesktopRouter();router.start();defer{router.stop()}
        var config=router.configuration;config.expectedPeerExecutable=URL(fileURLWithPath:"/usr/bin/false")
        let wrong=CodexNativeIPCAdapter(testConfiguration:config,targets:[target])
        do{_=try await wrong.preflight(target);XCTFail("Wrong peer accepted")}catch{XCTAssertEqual(error as? DesktopBlockReason,.sourceChanged)}
        chmod(router.socketURL.path,0o666)
        let unsafe=CodexNativeIPCAdapter(testConfiguration:router.configuration,targets:[target])
        do{_=try await unsafe.preflight(target);XCTFail("Unsafe socket accepted")}catch{XCTAssertEqual(error as? DesktopBlockReason,.unsafeSource)}
        XCTAssertEqual(router.starts.count,0)
    }
    func testMissingOwnerNavigatesExactExistingThreadOnceThenRebinds()async throws{
        let router=try SyntheticDesktopRouter();router.ownerAvailable=false;router.start();defer{router.stop()}
        var urls=[URL]()
        let adapter=CodexNativeIPCAdapter(testConfiguration:router.configuration,targets:[target],navigateExisting:{url in urls.append(url);router.ownerAvailable=true})
        let preparation=try await adapter.preflight(target)
        XCTAssertEqual(preparation.target.id,target.id);XCTAssertEqual(urls.count,1)
        XCTAssertEqual(urls[0].scheme,"codex");XCTAssertEqual(urls[0].host,"threads");XCTAssertEqual(urls[0].path,"/"+target.id);XCTAssertNil(urls[0].query)
        XCTAssertEqual(router.connections,2);XCTAssertEqual(router.starts.count,0);adapter.cancel()
    }
    func testStillMissingOwnerAfterRecoveryDoesNotRepeatNavigationOrSend()async throws{
        let router=try SyntheticDesktopRouter();router.ownerAvailable=false;router.start();defer{router.stop()}
        var navigations=0
        let adapter=CodexNativeIPCAdapter(testConfiguration:router.configuration,targets:[target],navigateExisting:{_ in navigations+=1})
        do{_=try await adapter.preflight(target);XCTFail("Missing owner became ready")}catch{XCTAssertEqual(error as? DesktopBlockReason,.sourceUnavailable)}
        XCTAssertEqual(navigations,1);XCTAssertEqual(router.connections,2);XCTAssertEqual(router.starts.count,0)
    }
    func testUnsafePeerAndBusyTargetNeverTriggerNavigation()async throws{
        for unsafe in [false,true]{
            let router=try SyntheticDesktopRouter();router.initialBusy = !unsafe;router.start();defer{router.stop()}
            var config=router.configuration;if unsafe{config.expectedPeerExecutable=URL(fileURLWithPath:"/usr/bin/false")}
            var navigations=0
            let adapter=CodexNativeIPCAdapter(testConfiguration:config,targets:[target],navigateExisting:{_ in navigations+=1})
            do{_=try await adapter.preflight(target);XCTFail("Target became ready")}catch{XCTAssertEqual(error as? DesktopBlockReason,unsafe ? .sourceChanged:.targetBusy)}
            XCTAssertEqual(navigations,0);XCTAssertEqual(router.starts.count,0)
        }
    }
    func testCancellationDuringNavigationDoesNotReconnectOrSubmit()async throws{
        let router=try SyntheticDesktopRouter();router.ownerAvailable=false;router.start();defer{router.stop()}
        var adapter:CodexNativeIPCAdapter!
        adapter=CodexNativeIPCAdapter(testConfiguration:router.configuration,targets:[target],navigateExisting:{_ in adapter.cancel();router.ownerAvailable=true})
        do{_=try await adapter.preflight(target);XCTFail("Cancelled restore became ready")}catch{XCTAssertEqual(error as? DesktopBlockReason,.cancelled)}
        XCTAssertEqual(router.connections,1);XCTAssertEqual(router.starts.count,0)
    }
    func testMissingDesktopSocketWaitsWithoutNavigation()async throws{
        let router=try SyntheticDesktopRouter();defer{router.stop()}
        var configuration=router.configuration;configuration.socketURL=router.root.appendingPathComponent("not-running.sock")
        var navigations=0
        let adapter=CodexNativeIPCAdapter(testConfiguration:configuration,targets:[target],navigateExisting:{_ in navigations+=1})
        do{_=try await adapter.preflight(target);XCTFail("Missing desktop became ready")}catch{XCTAssertEqual(error as? DesktopBlockReason,.sourceUnavailable)}
        XCTAssertEqual(navigations,0);XCTAssertEqual(router.connections,0);XCTAssertEqual(router.starts.count,0)
    }
    func testWrongErrorMethodCannotTriggerRecovery()async throws{
        let router=try SyntheticDesktopRouter();router.ownerAvailable=false;router.ownerErrorMethod="unrelated-method";router.start();defer{router.stop()}
        var navigations=0
        let adapter=CodexNativeIPCAdapter(testConfiguration:router.configuration,targets:[target],navigateExisting:{_ in navigations+=1})
        do{_=try await adapter.preflight(target);XCTFail("Wrong method accepted")}catch{XCTAssertEqual(error as? DesktopBlockReason,.sourceUnavailable)}
        XCTAssertEqual(navigations,0);XCTAssertEqual(router.starts.count,0)
    }
    func testNavigationTimeoutSettlesWithoutWaitingForLateCallback()async throws{
        let router=try SyntheticDesktopRouter();router.ownerAvailable=false;router.start();defer{router.stop()}
        var callback:CheckedContinuation<Void,Error>?
        let adapter=CodexNativeIPCAdapter(testConfiguration:router.configuration,targets:[target],navigationTimeout:0.02,navigateExisting:{_ in
            try await withCheckedThrowingContinuation{callback=$0}
        })
        let begin=ProcessInfo.processInfo.systemUptime
        do{_=try await adapter.preflight(target);XCTFail("Unresponsive navigation completed")}catch{XCTAssertEqual(error as? DesktopBlockReason,.sourceUnavailable)}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-begin,1)
        XCTAssertNotNil(callback);callback?.resume(returning:());callback=nil;await Task.yield()
        XCTAssertEqual(router.connections,1);XCTAssertEqual(router.starts.count,0)
    }
    func testTaskCancellationSettlesPendingNavigationAndIgnoresLateCompletion()async throws{
        let router=try SyntheticDesktopRouter();router.ownerAvailable=false;router.start();defer{router.stop()}
        var callback:CheckedContinuation<Void,Error>?
        let adapter=CodexNativeIPCAdapter(testConfiguration:router.configuration,targets:[target],navigateExisting:{_ in
            try await withCheckedThrowingContinuation{callback=$0}
        })
        let pending=Task{@MainActor in try await adapter.preflight(self.target)}
        for _ in 0..<100 where callback==nil{await Task.yield()}
        XCTAssertNotNil(callback);pending.cancel()
        do{_=try await pending.value;XCTFail("Cancelled navigation completed")}catch{XCTAssertEqual(error as? DesktopBlockReason,.cancelled)}
        callback?.resume(returning:());callback=nil;await Task.yield()
        XCTAssertEqual(router.connections,1);XCTAssertEqual(router.starts.count,0)
    }
}
