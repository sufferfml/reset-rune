import Foundation
import Darwin
import RuneCore
import RuneService

private final class LocalSessionDelegate:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) { completionHandler(nil) }
}

@main struct RuneCommand {
    static func main() async {
        do { try await execute() }
        catch { fputs("Bottled Reset Rune: \((error as? RuneError)?.code ?? "local-service-error")\n",stderr); exit(1) }
    }
    static func execute() async throws {
        let args=Array(CommandLine.arguments.dropFirst()), mock=args.contains("--mock")
        let words=args.filter { $0 != "--mock" }, cmd=words.first ?? "--help", params=Array(words.dropFirst())
        if ["help","--help","-h"].contains(cmd) { print("Bottled Reset Rune 0.1.0 (native macOS)\n  reset-rune [--mock] status | start | stop | restart | upgrade | refresh | doctor | ui\n  reset-rune enable --confirm | bind --confirm | pause\n  reset-rune config <lead|language|appearance|startup|notify> <value>\n  reset-rune uninstall-service | rollback\nAutomatic use requires explicit confirmation. --mock uses separate synthetic data."); return }
        if cmd=="--version" { print(NativeRuntime.version); return }
        let directory=Paths.directory(mock:mock)
        if cmd=="--check-state" { _=try RuneState.validate(FileStateStore(directory:directory).read());print("compatible-v1");return }
        if cmd=="--serve" { try await runService(mock:mock); return }
        guard ["status","start","stop","restart","upgrade","refresh","doctor","ui","enable","bind","pause","config","uninstall-service","rollback"].contains(cmd) else { throw RuneError("unknown-command") }
        if cmd=="ui", !params.isEmpty { throw RuneError("ui-is-native-no-url") }
        if ["enable","bind"].contains(cmd), !mock, params != ["--confirm"] { throw RuneError("confirmation-required") }
        if cmd=="config", params.count != 2 { throw RuneError("expected-config-key-value") }
        try PrivateFiles.ensure(directory)
        var lifecycle:LifecycleLease?
        if ["start","restart","upgrade","rollback","uninstall-service"].contains(cmd) { lifecycle=try LifecycleLease(directory:directory) }
        defer { withExtendedLifetime(lifecycle) {} }
        if cmd=="upgrade" {
            _=try RuneState.validate(FileStateStore(directory:directory).read())
            let source=NativeRuntime.executable().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard source.lastPathComponent=="Bottled Reset Rune Service.app" else { throw RuneError("requires-packaged-runtime") }
            _=try NativeRuntime.run("/usr/bin/codesign",["--verify","--deep","--strict",source.path])
        }
        if cmd=="rollback" {
            let previous=directory.appendingPathComponent("runtime/previous")
            if FileManager.default.fileExists(atPath:previous.appendingPathComponent("Contents/MacOS/reset-rune").path) {
                _=try NativeRuntime.run("/usr/bin/codesign",["--verify","--deep","--strict",previous.path])
                _=try NativeRuntime.run(previous.appendingPathComponent("Contents/MacOS/reset-rune").path,["--check-state"]+(mock ? ["--mock"]:[]))
            } else { throw RuneError("rollback-unavailable") }
            _=try RuneState.validate(FileStateStore(directory:directory).read())
        }
        if ["stop","restart","upgrade","uninstall-service","rollback"].contains(cmd) {
            if cmd=="uninstall-service", let active=try await discover(directory,mock:mock) { _=try await request(active,"config",method:"PATCH",data:["startup":false]) }
            try NativeRuntime.stop(mock:mock)
            if cmd=="stop" { print("Bottled Reset Rune service stopped."); return }
            if cmd=="uninstall-service" {
                let store=try FileStateStore(directory:directory);var state=try RuneState.validate(store.read());var config=state["config"] as! JSONObject;config["startup"]=false;state["config"]=config;try store.write(state)
                try NativeRuntime.startup(false,directory:directory,mock:mock)
                let runtime=directory.appendingPathComponent("runtime")
                if FileManager.default.fileExists(atPath:runtime.path) { try FileManager.default.removeItem(at:runtime) }
                print("Background service removed; journal and Codex login retained."); return
            }
            if cmd=="rollback" {
                let root=directory.appendingPathComponent("runtime"), old=root.appendingPathComponent("previous"), current=root.appendingPathComponent("current"), swap=root.appendingPathComponent("swap-"+UUID().uuidString)
                guard FileManager.default.fileExists(atPath:old.path) else { throw RuneError("rollback-unavailable") }
                _=try NativeRuntime.run("/usr/bin/codesign",["--verify","--deep","--strict",old.path])
                do {
                    try FileManager.default.moveItem(at:current,to:swap)
                    do { try FileManager.default.moveItem(at:old,to:current) } catch { try? FileManager.default.moveItem(at:swap,to:current);throw error }
                    try FileManager.default.moveItem(at:swap,to:old)
                } catch { throw RuneError("rollback-swap-failed") }
                let session=directory.appendingPathComponent(Paths.label(mock:mock)+".plist")
                try NativeRuntime.plist(executable:current.appendingPathComponent("Contents/MacOS/reset-rune"),directory:directory,mock:mock).write(to:session,options:.atomic)
                _=try NativeRuntime.run("/bin/launchctl",["bootstrap","gui/\(getuid())",session.path])
                print("Previous program activated; latest journal retained."); return
            }
        }
        var connection=try await discover(directory,mock:mock)
        if connection==nil {
            if lifecycle==nil { lifecycle=try LifecycleLease(directory:directory) }
            do { try NativeRuntime.start(directory:directory,mock:mock,development:ProcessInfo.processInfo.environment["RESET_RUNE_DEVELOPMENT"]=="1") }
            catch {
                if cmd=="upgrade" { try? NativeRuntime.stop(mock:mock);try? restoreProgram(directory,mock:mock) }
                throw error
            }
            for _ in 0..<120 {
                connection=try await discover(directory,mock:mock)
                if connection != nil { break }; try await Task.sleep(nanoseconds:100_000_000)
            }
        }
        guard let conn=connection else {
            if cmd=="upgrade" { try? NativeRuntime.stop(mock:mock);try? restoreProgram(directory,mock:mock) }
            throw RuneError("service-unavailable")
        }
        if cmd=="ui" {
            // Explicit sibling bundle, never a name-based search that could open an old installation.
            let exe=NativeRuntime.executable()
            var app=exe
            while app.path != "/", !(app.pathExtension=="app" && app.lastPathComponent=="Bottled Reset Rune.app") { app.deleteLastPathComponent() }
            if app.path=="/", let provided=ProcessInfo.processInfo.environment["RESET_RUNE_APP_PATH"] { app=URL(fileURLWithPath:provided) }
            guard app.pathExtension=="app" else { throw RuneError("native-ui-not-found") }
            _=try NativeRuntime.run("/usr/bin/open",["-a",app.path,"--args"]+(mock ? ["--mock"]:[])); return
        }
        var result:JSONObject
        switch cmd {
        case "refresh","doctor": result=try await request(conn,"refresh",method:"POST",data:[:])
        case "config":
            let key=params[0], raw=params[1]; let value:Any
            if key=="lead",let number=Int(raw) { value=number }
            else if ["startup","notify"].contains(key),["true","false"].contains(raw) { value=raw=="true" }
            else { value=raw }
            result=try await request(conn,"config",method:"PATCH",data:[key:value])
        case "enable","bind":
            var view=try await request(conn,"status")
            if view["consent"] as? String == nil { view=try await request(conn,"refresh",method:"POST",data:[:]) }
            let consent=view["consent"] ?? NSNull()
            result=try await request(conn,cmd=="enable" ? "config":"bind",method:cmd=="enable" ? "PATCH":"POST",data:cmd=="enable" ? ["enabled":true,"consent":consent]:["consent":consent])
        case "pause": result=try await request(conn,"config",method:"PATCH",data:["enabled":false])
        default: result=try await request(conn,"status")
        }
        result.removeValue(forKey:"consent")
        print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]),encoding:.utf8)!)
    }
    static func restoreProgram(_ directory:URL,mock:Bool) throws {
        let fm=FileManager.default, root=directory.appendingPathComponent("runtime"), old=root.appendingPathComponent("previous"), current=root.appendingPathComponent("current"), swap=root.appendingPathComponent("recovery-"+UUID().uuidString)
        if fm.fileExists(atPath:old.appendingPathComponent("Contents/MacOS/reset-rune").path) {
            _=try NativeRuntime.run("/usr/bin/codesign",["--verify","--deep","--strict",old.path])
            try fm.moveItem(at:current,to:swap)
            do { try fm.moveItem(at:old,to:current) } catch { try? fm.moveItem(at:swap,to:current);throw error }
            try fm.moveItem(at:swap,to:old)
            let session=directory.appendingPathComponent(Paths.label(mock:mock)+".plist")
            try NativeRuntime.plist(executable:current.appendingPathComponent("Contents/MacOS/reset-rune"),directory:directory,mock:mock).write(to:session,options:.atomic)
            _=try NativeRuntime.run("/bin/launchctl",["bootstrap","gui/\(getuid())",session.path])
        } else { throw RuneError("upgrade-recovery-unavailable") }
    }
    static func discover(_ directory:URL,mock:Bool) async throws -> JSONObject? {
        guard let value=try PrivateFiles.read(directory.appendingPathComponent("connection.json")),value["protocol"] as? Int==1,value["mode"] as? String==(mock ? "mock":"readonly") else { return nil }
        guard (try? await request(value,"status",timeout:0.8)) != nil else { return nil }; return value
    }
    static func request(_ connection:JSONObject,_ path:String,method:String="GET",data:JSONObject?=nil,timeout:Double=20) async throws -> JSONObject {
        guard let port=connection["port"] as? Int,(1024...65535).contains(port),let token=connection["token"] as? String,token.count==43 else { throw RuneError("invalid-connection") }
        var req=URLRequest(url:URL(string:"http://127.0.0.1:\(port)/api/\(path)")!,timeoutInterval:timeout); req.httpMethod=method
        req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        if let data { req.setValue("application/json",forHTTPHeaderField:"Content-Type"); req.httpBody=try JSONSerialization.data(withJSONObject:data) }
        let config=URLSessionConfiguration.ephemeral;config.connectionProxyDictionary=[:];config.urlCache=nil;config.httpCookieStorage=nil
        let session=URLSession(configuration:config,delegate:LocalSessionDelegate(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let (bytes,response)=try await session.data(for:req)
        guard bytes.count<=2*1024*1024,let json=try JSONSerialization.jsonObject(with:bytes) as? JSONObject else { throw RuneError("invalid-response") }
        guard (response as? HTTPURLResponse)?.statusCode==200 else { throw RuneError(json["error"] as? String ?? "request-failed") }
        return json
    }
}
