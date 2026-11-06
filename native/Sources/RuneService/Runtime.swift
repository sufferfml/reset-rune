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
    public static let version = "0.1.0"
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
    public static func plist(executable:URL, directory:URL, mock:Bool) throws -> Data {
        let keys=["RESET_RUNE_DATA_DIR","RESET_RUNE_CODEX_PATH","CODEX_HOME","PATH","HTTPS_PROXY","HTTP_PROXY","ALL_PROXY","NO_PROXY"]
        let env=ProcessInfo.processInfo.environment.filter { keys.contains($0.key) }
        return try PropertyListSerialization.data(fromPropertyList:["Label":Paths.label(mock:mock),"ProgramArguments":[executable.path,"--serve"]+(mock ? ["--mock"]:[]),"EnvironmentVariables":env,"WorkingDirectory":directory.path,"RunAtLoad":true,"KeepAlive":true,"ThrottleInterval":10],format:.xml,options:0)
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
