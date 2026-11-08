// INPUT: Version-locked desktop socket, kernel peer identity and explicit conversation IDs.
// OUTPUT: Bounded owner snapshots and a once-only submission to the same desktop thread.
// POS: Native Codex transport; never starts an Agent or reads login files. See README.md.
import Foundation
import Darwin

public enum CodexIPCJSON: Codable, Equatable, Sendable {
    case object([String:CodexIPCJSON]), array([CodexIPCJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil(){self = .null}
        else if let x=try? c.decode(Bool.self){self = .bool(x)}
        else if let x=try? c.decode(String.self){self = .string(x)}
        else if let x=try? c.decode(Double.self){self = .number(x)}
        else if let x=try? c.decode([String:Self].self){self = .object(x)}
        else {self = .array(try c.decode([Self].self))}
    }
    public func encode(to encoder: Encoder)throws{var c=encoder.singleValueContainer();switch self{case .object(let x):try c.encode(x);case .array(let x):try c.encode(x);case .string(let x):try c.encode(x);case .number(let x):try c.encode(x);case .bool(let x):try c.encode(x);case .null:try c.encodeNil()}}
    public subscript(_ key:String)->Self{if case .object(let x)=self{return x[key] ?? .null};return .null}
    public var string:String?{if case .string(let x)=self{return x};return nil}
    public var array:[Self]?{if case .array(let x)=self{return x};return nil}
    public var object:[String:Self]?{if case .object(let x)=self{return x};return nil}
    public var bool:Bool?{if case .bool(let x)=self{return x};return nil}
}

public struct CodexIPCFrameCodec: Sendable {
    public static let maximumFrameBytes=8*1024*1024
    private var buffer=Data()
    public init(){}
    public static func encode(_ value:CodexIPCJSON)throws->Data{
        let body=try JSONEncoder().encode(value)
        guard !body.isEmpty,body.count<=maximumFrameBytes else{throw DesktopBlockReason.limitExceeded}
        let size=UInt32(body.count);var result=Data([UInt8(size&255),UInt8((size>>8)&255),UInt8((size>>16)&255),UInt8((size>>24)&255)])
        result.append(body);return result
    }
    public mutating func consume(_ bytes:Data)throws->[CodexIPCJSON]{
        guard buffer.count+bytes.count<=Self.maximumFrameBytes+64*1024 else{throw DesktopBlockReason.limitExceeded}
        buffer.append(bytes);var result=[CodexIPCJSON]()
        while buffer.count>=4{
            let n=Int(buffer[0])|Int(buffer[1])<<8|Int(buffer[2])<<16|Int(buffer[3])<<24
            guard n>0,n<=Self.maximumFrameBytes else{throw DesktopBlockReason.limitExceeded}
            guard buffer.count>=n+4 else{break}
            let value:CodexIPCJSON
            do{value=try JSONDecoder().decode(CodexIPCJSON.self,from:buffer.subdata(in:4..<(n+4)))}catch{throw DesktopBlockReason.sourceUnavailable}
            guard value.object != nil else{throw DesktopBlockReason.sourceUnavailable}
            result.append(value);buffer=Data(buffer.dropFirst(n+4))
            guard result.count<=128 else{throw DesktopBlockReason.limitExceeded}
        }
        return result
    }
}

/// Explicit socket/executable binding. Tests inject their own socket and process;
/// the production adapter always supplies the selected signed desktop executable.
public struct CodexIPCConfiguration: Sendable {
    public var socketURL:URL
    public var expectedPeerExecutable:URL
    public var timeout:TimeInterval
    public init(socketURL:URL,expectedPeerExecutable:URL,timeout:TimeInterval=3){self.socketURL=socketURL;self.expectedPeerExecutable=expectedPeerExecutable;self.timeout=min(10,max(0.1,timeout))}
}

public struct CodexIPCSnapshot: Sendable {
    public var conversationID:String
    public var ownerID:String
    public var state:CodexIPCJSON
    public var isIdle:Bool{
        guard state["threadRuntimeStatus"]["type"].string=="idle",state["resumeState"].string != "resuming" else{return false}
        guard let liveTurns=state["turns"].array,liveTurns.count<=20_000,liveTurns.allSatisfy({$0.object != nil}) else{return false}
        if let submissions=state["unconfirmedTurnSubmissions"].array,submissions.contains(where:{$0["terminal"].bool != true}){return false}
        if state["unconfirmedTurnSubmissions"] != .null && state["unconfirmedTurnSubmissions"].array==nil{return false}
        let goal=state["threadGoal"]
        if goal != .null,!["completed","paused","cancelled","failed"].contains(goal["status"].string ?? ""){return false}
        // Match the installed manager's fM/fd rule: inspect the latest turn record,
        // not arbitrary nested tool output or business JSON containing "running".
        var turns=[CodexIPCJSON]()
        let history=state["turnHistory"]
        if history != .null{
            guard history.object != nil else{return false}
            if history["kind"].string=="canonical"{
                let canonical=history["history"]
                guard let islands=canonical["islands"].array,let entities=canonical["entitiesByKey"].object else{return false}
                if let tail=islands.last{
                    guard tail["newerBoundary"]["status"].string=="exhausted",let entries=tail["entries"].array,entries.count<=20_000 else{return false}
                    for entry in entries{
                        guard let key=entry["value"].string,let entity=entities[key],entity.object != nil else{return false}
                        turns.append(entity)
                    }
                }else if canonical["isComplete"].bool != true{return false}
            }else if history["kind"].string != "legacy"{return false}
        }
        for turn in liveTurns{
            if let id=turn["turnId"].string,let existing=turns.lastIndex(where:{$0["turnId"].string==id}){turns[existing]=turn}
            else{turns.append(turn)}
            if turns.count>20_000{return false}
        }
        if let latest=turns.last(where:{$0["turnId"] != .null || !["completed","failed"].contains($0["status"].string ?? "")}){
            return ["completed","failed","interrupted","cancelled"].contains(latest["status"].string ?? "")
        }
        return true
    }
    public var hasPendingRequests:Bool{
        if let requests=state["requests"].array{return !requests.isEmpty}
        if let requests=state["requests"].object{return !requests.isEmpty}
        return true
    }
}

public struct CodexIPCStartAcknowledgement: Sendable {
    public var requestID:String
    public var conversationID:String
    public var clientMessageID:String
    public var ownerID:String
    public var turnID:String
}

/// One bounded, sequential connection to the already-running desktop router.
/// No launch, account authentication, independent App Server, or arbitrary RPC API.
public actor CodexIPCSession {
    private let configuration:CodexIPCConfiguration
    private var fd:Int32 = -1
    private var codec=CodexIPCFrameCodec()
    private var inbox=[CodexIPCJSON]()
    private var broadcasts=[CodexIPCJSON]()
    private var clientID:String?
    private var followed:(String,String)?
    private var connectionGeneration=UUID()
    private var peerPID:pid_t?
    public init(configuration:CodexIPCConfiguration){self.configuration=configuration}
    deinit{if fd>=0{Darwin.close(fd)}}
    internal func initializedPeerPID()->pid_t?{fd>=0 && clientID != nil ? peerPID:nil}

    public func prepare(conversationID:String)throws->CodexIPCSnapshot{
        if fd<0{try connect()}
        if clientID==nil{
            let result=try request("initialize",params:.object(["clientType":.string("reset-rune-courier")]),version:0)
            guard let id=result["result"]["clientId"].string,!id.isEmpty else{throw DesktopBlockReason.targetNotConfirmed};clientID=id
        }
        let owner=try discoverOwner(conversationID)
        let settings=try request("thread-follower-read-model-settings",params:.object(["conversationId":.string(conversationID)]),version:1,owner:owner)
        guard settings["result"]["settings"].object != nil else{throw DesktopBlockReason.targetNotConfirmed}
        return try snapshot(conversationID,owner:owner)
    }
    public func refresh(conversationID:String,expectedOwner:String)throws->CodexIPCSnapshot{
        guard try discoverOwner(conversationID)==expectedOwner else{throw DesktopBlockReason.sourceChanged}
        return try snapshot(conversationID,owner:expectedOwner)
    }
    /// Calls the desktop owner's normal startTurn path, preserving inherited settings.
    /// Never retries; any failure after entering this method is conservatively unknown.
    public func start(conversationID:String,owner:String,stageID:UUID,text:String,expiresAt:Int64,maySend:@Sendable ()async->Bool)async throws->CodexIPCStartAcknowledgement{
        let before=try refresh(conversationID:conversationID,expectedOwner:owner)
        guard before.isIdle,!before.hasPendingRequests else{throw DesktopBlockReason.targetBusy}
        let generation=connectionGeneration
        let rid=UUID().uuidString,mid=stageID.uuidString
        let turn:CodexIPCJSON = .object(["request":.object(["threadId":.string(conversationID),"clientUserMessageId":.string(mid),"input":.array([.object(["type":.string("text"),"text":.string(text),"text_elements":.array([])])])]),"context":.object(["inheritThreadSettings":.bool(true)])])
        let params:CodexIPCJSON = .object(["conversationId":.string(conversationID),"turnStart":turn])
        let frame=try CodexIPCFrameCodec.encode(requestMessage("thread-follower-start-turn",params:params,version:2,owner:owner,requestID:rid))
        guard await maySend(),Int64(Date().timeIntervalSince1970*1000)<expiresAt,fd>=0,generation==connectionGeneration else{throw DesktopBlockReason.cancelled}
        let result:CodexIPCJSON
        do{result=try request("thread-follower-start-turn",params:params,version:2,owner:owner,requestID:rid,expiresAt:expiresAt,preparedFrame:frame)}
        catch{abortConnection();throw DesktopBlockReason.resultUnknown}
        guard let tid=result["result"]["result"]["turn"]["id"].string,!tid.isEmpty else{throw DesktopBlockReason.resultUnknown}
        return CodexIPCStartAcknowledgement(requestID:rid,conversationID:conversationID,clientMessageID:mid,ownerID:owner,turnID:tid)
    }
    public func close(){
        if let (conversation,owner)=followed{try? follow(conversation,owner:owner,enabled:false)}
        abortConnection()
    }
    /// Error cleanup must not append an unfollow frame behind a partial request.
    public func abortConnection(){
        if fd>=0{Darwin.close(fd);fd = -1};connectionGeneration=UUID();peerPID=nil;clientID=nil;followed=nil;inbox=[];broadcasts=[];codec=CodexIPCFrameCodec()
    }
    private func discoverOwner(_ conversation:String)throws->String{
        let result=try request("thread-owner-discovery",params:.object(["hostId":.string("local"),"conversationId":.string(conversation)]),version:1)
        guard let owner=result["handledByClientId"].string,!owner.isEmpty,result["result"]["supportsUntrustedAppInput"].bool==true else{throw DesktopBlockReason.targetNotConfirmed};return owner
    }
    private func snapshot(_ conversation:String,owner:String)throws->CodexIPCSnapshot{
        broadcasts=[];try follow(conversation,owner:owner,enabled:true);followed=(conversation,owner)
        let deadline=ProcessInfo.processInfo.systemUptime+configuration.timeout
        for _ in 0..<128{
            let value=try next(deadline:deadline)
            if value["type"].string=="client-discovery-request"{try refuseDiscovery(value);continue}
            guard value["type"].string=="broadcast",value["method"].string=="thread-stream-state-changed",value["version"] == .number(11),value["sourceClientId"].string==owner else{continue}
            let params=value["params"],change=params["change"],state=change["conversationState"]
            guard params["conversationId"].string==conversation,params["hostId"].string=="local",change["type"].string=="snapshot",state["id"].string==conversation,state["hostId"].string=="local" else{continue}
            return CodexIPCSnapshot(conversationID:conversation,ownerID:owner,state:state)
        }
        throw DesktopBlockReason.sourceUnavailable
    }
    private func follow(_ conversation:String,owner:String,enabled:Bool)throws{
        guard let clientID else{throw DesktopBlockReason.sourceUnavailable}
        try write(.object(["type":.string("broadcast"),"method":.string("thread-stream-following-changed"),"version":.number(1),"sourceClientId":.string(clientID),"targetClientIds":.array([.string(owner)]),"params":.object(["hostId":.string("local"),"conversationId":.string(conversation),"following":.bool(enabled)])]))
    }
    private func requestMessage(_ method:String,params:CodexIPCJSON,version:Int,owner:String?,requestID:String)->CodexIPCJSON{
        var request:[String:CodexIPCJSON]=["type":.string("request"),"requestId":.string(requestID),"sourceClientId":.string(clientID ?? "initializing-client"),"method":.string(method),"params":params,"version":.number(Double(version)),"timeoutMs":.number(configuration.timeout*1000)]
        if let owner{request["targetClientId"] = .string(owner)}
        return .object(request)
    }
    private func request(_ method:String,params:CodexIPCJSON,version:Int,owner:String?=nil,requestID:String=UUID().uuidString,expiresAt:Int64?=nil,preparedFrame:Data?=nil)throws->CodexIPCJSON{
        guard ["initialize","thread-owner-discovery","thread-follower-read-model-settings","thread-follower-start-turn"].contains(method) else{throw DesktopBlockReason.invalidTarget}
        let frame=try preparedFrame ?? CodexIPCFrameCodec.encode(requestMessage(method,params:params,version:version,owner:owner,requestID:requestID))
        try writeFrame(frame,expiresAt:expiresAt)
        let deadline=ProcessInfo.processInfo.systemUptime+configuration.timeout
        for _ in 0..<128{
            let value=try next(deadline:deadline)
            if value["type"].string=="client-discovery-request"{try refuseDiscovery(value);continue}
            guard value["type"].string=="response",value["requestId"].string==requestID else{continue}
            // Router errors omit method in this installed protocol; if supplied it
            // must still match our single pending request before any interpretation.
            guard value["method"] == .null || value["method"].string==method else{throw DesktopBlockReason.sourceUnavailable}
            if method=="thread-owner-discovery",value["resultType"].string=="error",value["error"].string=="no-client-found"{throw DesktopBlockReason.ownerUnavailable}
            guard value["resultType"].string=="success",value["method"].string==method else{throw DesktopBlockReason.sourceUnavailable}
            if let owner{guard value["handledByClientId"].string==owner else{throw DesktopBlockReason.sourceChanged}}
            return value
        };throw DesktopBlockReason.sourceUnavailable
    }
    private func refuseDiscovery(_ value:CodexIPCJSON)throws{
        guard let id=value["requestId"].string else{throw DesktopBlockReason.sourceUnavailable}
        try write(.object(["type":.string("client-discovery-response"),"requestId":.string(id),"response":.object(["canHandle":.bool(false)])]))
    }
    private func connect()throws{
        let path=configuration.socketURL.path
        var socketStat=stat(),directoryStat=stat()
        let socketExists=lstat(path,&socketStat)
        if socketExists != 0 && errno==ENOENT{throw DesktopBlockReason.sourceUnavailable}
        guard socketExists==0,lstat(configuration.socketURL.deletingLastPathComponent().path,&directoryStat)==0,
              socketStat.st_mode & S_IFMT == S_IFSOCK,socketStat.st_uid==getuid(),socketStat.st_mode & 0o077==0,
              directoryStat.st_mode & S_IFMT == S_IFDIR,directoryStat.st_uid==getuid(),directoryStat.st_mode & 0o077==0 else{throw DesktopBlockReason.unsafeSource}
        let connection=Darwin.socket(AF_UNIX,SOCK_STREAM,0);guard connection>=0 else{throw DesktopBlockReason.sourceUnavailable}
        var keep=false;defer{if !keep{Darwin.close(connection)}}
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        let bytes=Array(path.utf8)+[0]
        guard bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else{throw DesktopBlockReason.unsafeSource}
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)}
        let flags=fcntl(connection,F_GETFL,0)
        guard flags>=0,fcntl(connection,F_SETFL,flags|O_NONBLOCK)==0 else{throw DesktopBlockReason.sourceUnavailable}
        let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(connection,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        if result != 0{
            guard errno==EINPROGRESS || errno==EAGAIN else{throw DesktopBlockReason.sourceUnavailable}
            try Self.wait(connection,events:Int16(POLLOUT),deadline:ProcessInfo.processInfo.systemUptime+configuration.timeout)
            var error:Int32=0,size=socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(connection,SOL_SOCKET,SO_ERROR,&error,&size)==0,error==0 else{throw DesktopBlockReason.sourceUnavailable}
        }
        var uid:uid_t=0,gid:gid_t=0,pid:pid_t=0,length=socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(connection,&uid,&gid)==0,uid==getuid(),getsockopt(connection,SOL_LOCAL,LOCAL_PEERPID,&pid,&length)==0 else{throw DesktopBlockReason.unsafeSource}
        // PROC_PIDPATHINFO_MAXSIZE is the SDK macro (4 * MAXPATHLEN), which Swift
        // cannot import as a structured C macro.
        var executable=[CChar](repeating:0,count:4*Int(MAXPATHLEN))
        guard proc_pidpath(pid,&executable,UInt32(executable.count))>0,URL(fileURLWithPath:String(cString:executable)).resolvingSymlinksInPath()==configuration.expectedPeerExecutable.resolvingSymlinksInPath() else{throw DesktopBlockReason.sourceChanged}
        var after=stat();guard lstat(path,&after)==0,after.st_ino==socketStat.st_ino,after.st_dev==socketStat.st_dev else{throw DesktopBlockReason.sourceChanged}
        var noSignal:Int32=1;setsockopt(connection,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
        var timeout=timeval(tv_sec:Int(configuration.timeout),tv_usec:Int32((configuration.timeout-floor(configuration.timeout))*1_000_000))
        setsockopt(connection,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        fd=connection;peerPID=pid;connectionGeneration=UUID();keep=true
    }
    private func write(_ value:CodexIPCJSON,expiresAt:Int64?=nil)throws{
        let data=try CodexIPCFrameCodec.encode(value)
        try writeFrame(data,expiresAt:expiresAt)
    }
    private func writeFrame(_ data:Data,expiresAt:Int64?=nil)throws{
        guard fd>=0 else{throw DesktopBlockReason.sourceUnavailable}
        let deadline=ProcessInfo.processInfo.systemUptime+configuration.timeout
        try data.withUnsafeBytes{raw in
            var offset=0
            while offset<raw.count{
                guard ProcessInfo.processInfo.systemUptime<deadline else{throw DesktopBlockReason.sourceUnavailable}
                if let expiresAt,Int64(Date().timeIntervalSince1970*1000)>=expiresAt{throw DesktopBlockReason.permitExpired}
                let n=Darwin.send(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset,0)
                if n<0 && errno==EINTR{continue}
                if n<0 && (errno==EAGAIN || errno==EWOULDBLOCK){try Self.wait(fd,events:Int16(POLLOUT),deadline:deadline);continue}
                guard n>0 else{throw DesktopBlockReason.sourceUnavailable};offset+=n
            }
        }
    }
    private func next(deadline:TimeInterval)throws->CodexIPCJSON{
        if !inbox.isEmpty{return inbox.removeFirst()}
        while true{
            let remaining=deadline-ProcessInfo.processInfo.systemUptime;guard remaining>0 else{throw DesktopBlockReason.sourceUnavailable}
            try Self.wait(fd,events:Int16(POLLIN),deadline:deadline)
            var bytes=[UInt8](repeating:0,count:64*1024);let count=Darwin.recv(fd,&bytes,bytes.count,0)
            if count<0 && (errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK){continue}
            guard count>0 else{throw DesktopBlockReason.sourceUnavailable}
            inbox.append(contentsOf:try codec.consume(Data(bytes.prefix(count))))
            if !inbox.isEmpty{return inbox.removeFirst()}
        }
    }
    private static func wait(_ socket:Int32,events:Int16,deadline:TimeInterval)throws{
        while true{
            let remaining=deadline-ProcessInfo.processInfo.systemUptime;guard remaining>0 else{throw DesktopBlockReason.sourceUnavailable}
            var descriptor=pollfd(fd:socket,events:events,revents:0)
            let ready=poll(&descriptor,1,Int32(min(remaining*1000,10_000)))
            if ready<0 && errno==EINTR{continue}
            guard ready>0,descriptor.revents & Int16(POLLNVAL)==0 else{throw DesktopBlockReason.sourceUnavailable}
            return
        }
    }
}
