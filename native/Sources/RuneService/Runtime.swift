import Foundation
import Darwin
import RuneCore

// Serializes installer/lifecycle writers across both distribution channels.
public final class LifecycleLease {
    private var fd:Int32
    public init(directory:URL) throws {
        fd=open(directory.appendingPathComponent("lifecycle.lock").path,O_RDWR | O_CREAT | O_NOFOLLOW,0o600)
        guard fd>=0 else { throw RuneError("insecure-lifecycle-lock") }
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode & S_IFMT == S_IFREG,info.st_uid==getuid(),info.st_mode & 0o077==0 else { Darwin.close(fd);fd = -1;throw RuneError("insecure-lifecycle-lock") }
        guard flock(fd,LOCK_EX | LOCK_NB)==0 else { Darwin.close(fd);fd = -1;throw RuneError("service-update-in-progress") }
    }
    deinit { if fd>=0 { flock(fd,LOCK_UN);Darwin.close(fd) } }
}

public enum NativeRuntime {
    public static let version = "0.1.2"
    public static func executable() -> URL { URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath() }
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) throws -> Data {
        let p=Process(); p.executableURL=URL(fileURLWithPath:path); p.arguments=args
        let out=Pipe(); p.standardOutput=out; p.standardError=FileHandle.nullDevice
        try p.run()
        let drained=DispatchSemaphore(value:0), lock=NSLock()
        var captured=Data(), oversized=false
        DispatchQueue.global().async {
            while true {
                let part=out.fileHandleForReading.readData(ofLength:8192)
                if part.isEmpty { break }
                lock.lock()
                if captured.count+part.count>2*1024*1024 { oversized=true; kill(p.processIdentifier,SIGKILL) }
                else { captured.append(part) }
                lock.unlock()
            }
            drained.signal()
        }
        let done=DispatchSemaphore(value:0)
        DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
        if done.wait(timeout:.now()+timeout) == .timedOut { kill(p.processIdentifier,SIGKILL); p.waitUntilExit(); throw RuneError("process-timed-out") }
        _=drained.wait(timeout:.now()+2)
        lock.lock(); let data=captured, tooLarge=oversized; lock.unlock()
        guard !tooLarge else { throw RuneError("process-output-limit") }
        guard p.terminationStatus == 0 else { throw RuneError("process-failed") }
        return data
    }
    public static func loaded(mock:Bool) -> Bool { (try? run("/bin/launchctl",["print","gui/\(getuid())/\(Paths.label(mock:mock))"])) != nil }
    public static func plist(executable:URL, directory:URL, mock:Bool, environment:[String:String]=ProcessInfo.processInfo.environment) throws -> Data {
        let keys=["RESET_RUNE_DATA_DIR","RESET_RUNE_CODEX_PATH","CODEX_HOME","PATH","HTTPS_PROXY","HTTP_PROXY","ALL_PROXY","NO_PROXY"]
        var env=environment.filter { keys.contains($0.key) }
        // A terminal restart must not silently replace the app's pinned CLI
        // with a newer global installation. Explicit overrides still win.
        if let pin=env["RESET_RUNE_CODEX_PATH"] {
            guard validRuntimePin(pin) else { throw RuneError("invalid-runtime-pin") }
        } else if let pin=try savedRuntimePin(directory:directory,mock:mock) {
            env["RESET_RUNE_CODEX_PATH"]=pin
        }
        return try PropertyListSerialization.data(fromPropertyList:["Label":Paths.label(mock:mock),"ProgramArguments":[executable.path,"--serve"]+(mock ? ["--mock"]:[]),"EnvironmentVariables":env,"WorkingDirectory":directory.path,"RunAtLoad":true,"KeepAlive":true,"ThrottleInterval":10],format:.xml,options:0)
    }
    private static func validRuntimePin(_ value:String) -> Bool {
        value.hasPrefix("/") && !value.utf8.contains(0)
    }
    private static func savedRuntimePin(directory:URL,mock:Bool) throws -> String? {
        let file=directory.appendingPathComponent(Paths.label(mock:mock)+".plist")
        let fd=open(file.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd<0 {
            if errno==ENOENT { return nil }
            throw RuneError("insecure-service-registration")
        }
        defer { Darwin.close(fd) }
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode & S_IFMT == S_IFREG,info.st_uid==getuid(),
              info.st_mode & 0o022==0,info.st_size>0,info.st_size<=65_536 else { throw RuneError("insecure-service-registration") }
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        guard let data=try? handle.read(upToCount:65_537),data.count<=65_536,
              let value=(try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:Any],
              value["Label"] as? String==Paths.label(mock:mock),
              value["WorkingDirectory"] as? String==directory.path,
              let arguments=value["ProgramArguments"] as? [String],arguments.contains("--mock")==mock,
              let env=value["EnvironmentVariables"] as? [String:String] else { throw RuneError("invalid-service-registration") }
        guard let pin=env["RESET_RUNE_CODEX_PATH"] else { return nil }
        guard validRuntimePin(pin) else { throw RuneError("invalid-runtime-pin") }
        return pin
    }
    public static func startup(_ enabled:Bool, directory:URL, mock:Bool) throws {
        let dir=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let file=dir.appendingPathComponent(Paths.label(mock:mock)+".plist")
        if !enabled { try? FileManager.default.removeItem(at:file); return }
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        try plist(executable:executable(),directory:directory,mock:mock).write(to:file,options:.atomic)
    }
    // Stage only our helper bundle. No state snapshot is ever restored by activation/rollback.
    public static func activate(directory:URL) throws -> URL {
        let source=executable()
        let root=directory.appendingPathComponent("runtime")
        if source.path.hasPrefix(root.path+"/") { return source }
        try PrivateFiles.ensure(root)
        let helper=source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard helper.pathExtension=="app", helper.lastPathComponent=="Bottled Reset Rune Service.app" else { throw RuneError("requires-packaged-runtime") }
        _=try run("/usr/bin/codesign",["--verify","--deep","--strict",helper.path])
        let fm=FileManager.default, staging=root.appendingPathComponent("staging-"+UUID().uuidString)
        defer { try? fm.removeItem(at:staging) }
        try fm.copyItem(at:helper,to:staging)
        _=try run("/usr/bin/codesign",["--verify","--deep","--strict",staging.path])
        let current=root.appendingPathComponent("current"), previous=root.appendingPathComponent("previous")
        try? fm.removeItem(at:previous)
        if fm.fileExists(atPath:current.path) { try fm.moveItem(at:current,to:previous) }
        do { try fm.moveItem(at:staging,to:current) }
        catch { if fm.fileExists(atPath:previous.path) { try? fm.moveItem(at:previous,to:current) }; throw error }
        return current.appendingPathComponent("Contents/MacOS/reset-rune")
    }
    public static func start(directory:URL,mock:Bool, development:Bool=false) throws {
        if loaded(mock:mock) { return }
        let target=development ? executable():try activate(directory:directory)
        let path=directory.appendingPathComponent(Paths.label(mock:mock)+".plist")
        try plist(executable:target,directory:directory,mock:mock).write(to:path,options:.atomic)
        _=try run("/bin/launchctl",["bootstrap","gui/\(getuid())",path.path])
    }
    public static func stop(mock:Bool) throws {
        guard loaded(mock:mock) else { return }
        _=try run("/bin/launchctl",["bootout","gui/\(getuid())/\(Paths.label(mock:mock))"],timeout:40)
        for _ in 0..<200 {
            if !loaded(mock:mock), portReleased(mock:mock) { return }; Thread.sleep(forTimeInterval:0.05)
        }
        throw RuneError("service-still-stopping")
    }
    static func portReleased(mock:Bool) -> Bool {
        let fd=socket(AF_INET,SOCK_STREAM,0); guard fd>=0 else { return false }; defer { Darwin.close(fd) }
        var addr=sockaddr_in(); addr.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);addr.sin_family=sa_family_t(AF_INET);addr.sin_port=in_port_t(Paths.port(mock:mock)).bigEndian;addr.sin_addr.s_addr=inet_addr("127.0.0.1")
        return withUnsafePointer(to:&addr) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) != 0 && errno==ECONNREFUSED } }
    }
}
