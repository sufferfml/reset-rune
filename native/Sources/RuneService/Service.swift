import Foundation
import AppKit
import Network
import Security
import RuneCore
import CodexTransport
import CourierCore

public actor ServiceCoordinator {
    public let engine: RuneEngine
    let courier: CourierEngine?
    var courierFailure: String?
    private var timer: Task<Void,Never>?
    private var working: Task<JSONObject,Never>?
    private var closing=false
    private var failures=0
    private var armedAt:Double?
    private var autoDue=false
    private var scheduledChecks=0, manualChecks=0
    public var publish: ((JSONObject)->Void)?
    public init(engine:RuneEngine, courier:CourierEngine?=nil, courierFailure:String?=nil) {
        self.engine=engine; self.courier=courier; self.courierFailure=courierFailure
    }
    public func setPublisher(_ value:@escaping (JSONObject)->Void) { publish=value }
    var closingForCourier:Bool { closing }
    func courierChanged() async { publish?(await status()); await reschedule() }
    public func status() async -> JSONObject {
        var view=await engine.view()
        let next=await engine.schedule()
        view["runtime"]=["version":NativeRuntime.version,"native":true,"protocol":1,"courierProtocol":1,"scheduledChecks":scheduledChecks,"manualChecks":manualChecks]
        view["nextActionAt"]=next.at ?? NSNull(); view["nextActionReason"]=next.reason
        view["courier"]=courierSummary()
        return view
    }
    public func refresh(manual:Bool) async -> JSONObject {
        if let current=working {
            if !manual { autoDue=true }
            _=await current.value
            return await status()
        }
        guard !closing else { return await status() }
        timer?.cancel()
        if manual { manualChecks += 1 } else { scheduledChecks += 1 }
        let job=Task { await engine.tick(manual:manual) }; working=job
        await reschedule()
        _=await job.value; working=nil
        let view=await status()
        failures=(view["status"] as? String)=="error" ? failures+1:0
        publish?(view); await reschedule()
        return view
    }
    public func configure(_ request:JSONObject) async throws -> JSONObject {
        guard !closing else { throw RuneError("service-stopping",httpStatus:503) }
        _=try await engine.configure(request); let view=await status(); publish?(view); await reschedule(); return view
    }
    public func bind(_ consent:String?) async throws -> JSONObject {
        guard !closing else { throw RuneError("service-stopping",httpStatus:503) }
        _=try await engine.bind(consent:consent); let view=await status(); publish?(view); await reschedule(); return view
    }
    public func reschedule() async {
        timer?.cancel(); timer=nil
        guard !closing else { return }
        let decision=await engine.schedule()
        let runeAt = working == nil ? decision.at : nil
        let courierAt = courierFailure == nil ? courier?.nextActionAt() : nil
        guard let planned=[runeAt,courierAt].compactMap({ $0 }).min() else { armedAt=nil;autoDue=false;return }
        let now=Date().timeIntervalSince1970*1000
        let at=autoDue ? now:planned
        autoDue=false;armedAt=at
        let wait=max(0.05,(at-now)/1000)
        timer=Task { [weak self] in
            do { try await Task.sleep(nanoseconds:UInt64(min(wait,365*86400)*1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
    }
    public func systemEvent() async {
        guard !closing else { return }
        await timerFired(systemEvent:true)
    }
    private func timerFired(systemEvent:Bool=false) async {
        guard !closing else { return }
        refreshCourierHostLiveness()
        do { try courier?.tick() } catch { courierFailure="courier-persistence-failed" }
        // Wake the desktop host before waiting for unrelated Codex account I/O.
        publish?(await status())
        let decision=await engine.schedule()
        // Immediate decisions use the engine's current time; compare only after
        // that actor call returns, otherwise every read moves the target ahead.
        let now=Date().timeIntervalSince1970*1000
        if working == nil, let at=decision.at, at<=now || (systemEvent && failures>0) {
            _=await refresh(manual:false)
        } else {
            await reschedule()
        }
    }
    public func close() async {
        closing=true; timer?.cancel()
        if let host=courier?.snapshot().host { try? courier?.unregisterHost(brokerSession:host.brokerSession,gateStopped:false) }
        await engine.close()
    }
}

public final class ServiceEvents {
    private let monitor=NWPathMonitor(), queue=DispatchQueue(label:"reset-rune.network")
    private var tokens:[NSObjectProtocol]=[]
    public init(coordinator:ServiceCoordinator) {
        let callback: (Notification)->Void={ _ in Task { await coordinator.systemEvent() } }
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:nil,using:callback))
        tokens.append(NotificationCenter.default.addObserver(forName:NSNotification.Name("NSSystemClockDidChangeNotification"),object:nil,queue:nil,using:callback))
        var hadPath=false
        monitor.pathUpdateHandler={ path in
            if hadPath && path.status == .satisfied { Task { await coordinator.systemEvent() } }
            hadPath=true
        }
        monitor.start(queue:queue)
    }
    deinit { monitor.cancel(); for t in tokens { NotificationCenter.default.removeObserver(t); NSWorkspace.shared.notificationCenter.removeObserver(t) } }
}

public func runService(mock:Bool) async throws {
    let directory=Paths.directory(mock:mock)
    let store=try FileStateStore(directory:directory)
    let source:ResetSource=mock ? try MockSource(directory:directory):CodexSource(allowConsume:true)
    let engine=try RuneEngine(source:source,store:store,onConfig:{ enabled in try NativeRuntime.startup(enabled,directory:directory,mock:mock) },onEvent:{ _, language in
        let text = mock
            ? (language == "zh" ? "已使用一枚重置神符，模拟重置完成。" : "Reset Rune used. Simulated reset complete.")
            : (language == "zh" ? "已使用一枚重置神符，Codex 额度已重置。" : "Reset Rune used. Your Codex quota was reset.")
        _=try? NativeRuntime.run("/usr/bin/osascript",["-e","display notification \"\(text)\" with title \"Bottled Reset Rune\""],timeout:3)
    })
    var courier:CourierEngine?, courierFailure:String?
    do {
        courier=try CourierEngine(store:FileCourierStore(directory:directory),
            allowedBundleIDs:mock ? ["local.reset-rune.mock.codex","local.reset-rune.mock.claude"] : ["com.openai.codex","com.anthropic.claudefordesktop"])
    } catch { courierFailure="courier-state-unavailable" }
    let coordinator=ServiceCoordinator(engine:engine,courier:courier,courierFailure:courierFailure)
    var bytes=[UInt8](repeating:0,count:32)
    guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else { throw RuneError("random-failed") }
    let token=Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    let server=LocalHTTPServer(coordinator:coordinator,token:token,port:Paths.port(mock:mock))
    try await server.start()
    try PrivateFiles.write(directory.appendingPathComponent("connection.json"),["port":Paths.port(mock:mock),"token":token,"mode":mock ? "mock":"readonly","protocol":1,"version":NativeRuntime.version])
    let events=ServiceEvents(coordinator:coordinator)
    await coordinator.setPublisher { view in server.publish(view) }
    let finish=AsyncStream<Void> { continuation in
        for sig in [SIGTERM,SIGINT] {
            signal(sig,SIG_IGN)
            let source=DispatchSource.makeSignalSource(signal:sig,queue:.global())
            source.setEventHandler { continuation.yield(()) }; source.resume()
            server.signals.append(source)
        }
    }
    let initial=Task { _=await coordinator.refresh(manual:false) }
    let view=await coordinator.status()
    if (view["config"] as? JSONObject)?["startup"] as? Bool == true { try NativeRuntime.startup(true,directory:directory,mock:mock) }
    for await _ in finish { break }
    initial.cancel()
    await server.quiesce()
    await coordinator.close()
    try? FileManager.default.removeItem(at:directory.appendingPathComponent("connection.json"))
    await server.close()
    withExtendedLifetime(events) {}
}
