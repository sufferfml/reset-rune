import XCTest
@testable import RuneCore

private final class Clock {
    var at: Double = 100 * 60_000
    func minute(_ value: Double) { at = value * 60_000 }
}
private final class FakeSource: ResetSource {
    var mode: String
    var snapshot: JSONObject
    var result = "reset"
    var failRead = false
    var loseResponse = false
    var notSent: String?
    var beforeSend: (() async -> Void)?
    var onPreflight: ((@escaping () async -> Bool) async -> Void)?
    var onConsume: (() -> Void)?
    var reads = 0
    var requests: [JSONObject] = []
    init(mode: String = "mock") {
        self.mode = mode
        snapshot = ["identity": ["accountId":"account-a", "scope":"workspace-a", "email":"demo@example.test"],
                    "availableCount":2,"remainingPercent":90,
                    "credits":[["id":"a","expiresAt":120 * 60_000],["id":"b","expiresAt":125 * 60_000]]]
    }
    func read() async throws -> JSONObject { reads += 1; if failRead { throw RuneError("read-failed") }; return snapshot }
    func consume(_ operation: JSONObject, maySend: @escaping () async -> Bool) async throws -> String {
        await beforeSend?()
        await onPreflight?(maySend)
        if let notSent { throw RuneError(notSent, notSent: true) }
        guard await maySend() else { throw RuneError("cancelled", notSent: true) }
        requests.append(operation); onConsume?()
        if loseResponse { throw RuneError("timed-out") }
        return result
    }
}
private final class Harness {
    let clock = Clock()
    let store: MemoryStateStore
    let source: FakeSource
    var sequence = 0
    init(mode: String = "mock", state: JSONObject = RuneState.initial()) { source = FakeSource(mode: mode); store = MemoryStateStore(state) }
    func engine() throws -> RuneEngine {
        try RuneEngine(source: source, store: store, now: { self.clock.at }, key: { self.sequence += 1; return "key-\(self.sequence)" })
    }
    func enable(_ engine: RuneEngine) async throws {
        if source.mode == "live" {
            let view = await engine.tick(manual: true)
            _ = try await engine.configure(["enabled":true,"consent":view["consent"]!])
        } else { _ = try await engine.configure(["enabled":true]) }
    }
    func setIdentity(scope: String) {
        var identity = source.snapshot["identity"] as! JSONObject; identity["scope"] = scope; source.snapshot["identity"] = identity
    }
}

final class CoreTests: XCTestCase {
    func testManualRefreshAndWindowBoundary() async throws {
        let h = Harness(); let e = try h.engine(); h.clock.minute(110)
        var v = await e.tick(); XCTAssertEqual(v["status"] as? String,"disabled")
        try await h.enable(e); _ = await e.tick(manual:true)
        h.clock.minute(109.99); v = await e.tick(); XCTAssertEqual(v["status"] as? String,"outside-window"); XCTAssertTrue(h.source.requests.isEmpty)
        h.clock.minute(110); v = await e.tick(); XCTAssertEqual(v["status"] as? String,"reset")
        XCTAssertEqual(h.source.requests.count,1); XCTAssertEqual(h.source.requests[0]["id"] as? String,"a")
    }
    func testFarExpiryHasNoPollingAndExactSchedule() async throws {
        let h=Harness();let e=try h.engine(); try await h.enable(e); _=await e.tick()
        let schedule=await e.schedule(); XCTAssertEqual(schedule.at,110 * 60_000);XCTAssertEqual(schedule.reason,"scheduled-expiry")
        let reads=h.source.reads
        for _ in 0..<1000 { _=await e.schedule(); _=await e.view() }
        XCTAssertEqual(h.source.reads,reads)
    }
    func testPausedAndReadonlyHaveNoSchedule() async throws {
        for mode in ["mock","readonly"] {
            let h=Harness(mode:mode);let e=try h.engine();_ = await e.tick()
            let s=await e.schedule();XCTAssertNil(s.at)
            XCTAssertTrue(h.source.requests.isEmpty)
        }
    }
    func testEmptyAndIncompleteUseDiscovery() async throws {
        let h=Harness();let e=try h.engine();try await h.enable(e)
        h.source.snapshot["availableCount"]=0;h.source.snapshot["credits"]=[JSONObject]()
        _=await e.tick();var s=await e.schedule();XCTAssertEqual(s.reason,"discover-inventory");XCTAssertEqual(s.at,h.clock.at+1_800_000)
        h.source.snapshot["availableCount"]=2;h.source.snapshot["credits"]=[["id":"later","expiresAt":h.clock.at+86_400_000]]
        _=await e.tick();s=await e.schedule();XCTAssertEqual(s.reason,"incomplete-inventory");XCTAssertEqual(s.at,h.clock.at+1_800_000)
    }
    func testCanonicalEquivalentIdsAreNotDuplicates() async throws {
        let h=Harness();let e=try h.engine();try await h.enable(e)
        h.source.snapshot["credits"]=[["id":"é","expiresAt":120 * 60_000],["id":"e\u{301}","expiresAt":125 * 60_000]]
        _=await e.tick();let s=await e.schedule();XCTAssertEqual(s.reason,"scheduled-expiry")
        XCTAssertFalse(RuneState.sameIdentity(["accountId":"é","scope":"x"],["accountId":"e\u{301}","scope":"x"]))
    }
    func testLostResultRestartsWithSameKey() async throws {
        let h=Harness();var e=try h.engine();try await h.enable(e);h.clock.minute(110);h.source.loseResponse=true
        var v=await e.tick();XCTAssertEqual(v["status"] as? String,"pending")
        let s=await e.schedule();XCTAssertEqual(s.at,110 * 60_000+30_000)
        e=try h.engine();h.clock.minute(111);h.source.loseResponse=false;h.source.result="already-redeemed"
        v=await e.tick();XCTAssertEqual(v["status"] as? String,"reset")
        XCTAssertEqual(h.source.requests.count,2)
        XCTAssertEqual(h.source.requests[0]["key"] as? String,h.source.requests[1]["key"] as? String)
        XCTAssertEqual(h.source.requests[1]["id"] as? String,"a")
    }
    func testUnconfirmedBlocksFollowingTargetsAndTimers() async throws {
        let h=Harness();let e=try h.engine();try await h.enable(e);h.clock.minute(110);h.source.loseResponse=true
        _=await e.tick();h.clock.minute(120);var v=await e.tick();XCTAssertEqual(v["status"] as? String,"unconfirmed")
        h.clock.minute(121);v=await e.tick();XCTAssertEqual(v["status"] as? String,"blocked")
        let s=await e.schedule();XCTAssertNil(s.at);XCTAssertEqual(h.source.requests.count,1)
    }
    func testNothingToResetRetriesOnlyOnNewUsageWithOriginalKey() async throws {
        let h=Harness();let e=try h.engine();try await h.enable(e);h.clock.minute(110);h.source.result="nothing-to-reset"
        _=await e.tick();var v=await e.tick();XCTAssertEqual(v["status"] as? String,"rejected");XCTAssertEqual(h.source.requests.count,1)
        h.source.snapshot["remainingPercent"]=89;h.source.result="reset";v=await e.tick();XCTAssertEqual(v["status"] as? String,"reset")
        XCTAssertEqual(h.source.requests[0]["key"] as? String,h.source.requests[1]["key"] as? String)
    }
    func testWriteFailureCannotSend() async throws {
        let h=Harness();let e=try h.engine();try await h.enable(e);h.clock.minute(110);h.store.rejectWrites=true
        let v=await e.tick();XCTAssertEqual(v["status"] as? String,"error");XCTAssertTrue(h.source.requests.isEmpty)
    }
    func testExpiryDuringDurableIntentCannotSend() async throws {
        let h=Harness();let e=try h.engine();try await h.enable(e);h.clock.minute(119)
        h.store.afterWrite = { value in if (value["operations"] as? [JSONObject] ?? []).contains(where:{$0["stage"] as? String == "intent"}) { h.clock.minute(120) } }
        let v=await e.tick();XCTAssertEqual(v["status"] as? String,"missed");XCTAssertTrue(h.source.requests.isEmpty)
    }
    func testConfirmedResultSurvivesReadbackFailure() async throws {
        let h=Harness();let e=try h.engine();try await h.enable(e);h.clock.minute(110)
        h.source.onConsume = {h.source.failRead=true}
        var v=await e.tick();XCTAssertEqual(v["status"] as? String,"reset-unverified")
        h.source.failRead=false;h.source.onConsume=nil
        let restarted=try h.engine();v=await restarted.tick();XCTAssertEqual(v["status"] as? String,"reset");XCTAssertEqual(h.source.requests.count,1)
    }
    func testEnabledConfigAloneDoesNotGrantLiveAuthorization() async throws {
        var state=RuneState.initial();var config=state["config"] as! JSONObject;config["enabled"]=true;state["config"]=config
        state["binding"]=["accountId":"account-a","scope":"workspace-a"]
        let h=Harness(mode:"live",state:state);let e=try h.engine();let v=await e.tick()
        XCTAssertEqual((v["config"] as? JSONObject)?["enabled"] as? Bool,false)
        do { _=try await e.configure(["enabled":true]);XCTFail("missing consent accepted") } catch {XCTAssertEqual((error as? RuneError)?.code,"consent-required")}
        XCTAssertTrue(h.source.requests.isEmpty)
    }
    func testChangedLeadInvalidatesConsent() async throws {
        let h=Harness(mode:"live");let e=try h.engine();let v=await e.tick(manual:true)
        _=try await e.configure(["lead":30])
        do { _=try await e.configure(["enabled":true,"consent":v["consent"]!]);XCTFail("old consent accepted") } catch {XCTAssertEqual((error as? RuneError)?.code,"consent-required")}
    }
    func testLiveAccountRoundTripRemainsRevoked() async throws {
        let h=Harness(mode:"live");let e=try h.engine();try await h.enable(e);h.setIdentity(scope:"other")
        var v=await e.tick();XCTAssertEqual(v["status"] as? String,"identity-changed")
        XCTAssertEqual((v["config"] as? JSONObject)?["enabled"] as? Bool,false)
        h.setIdentity(scope:"workspace-a");let restarted=try h.engine();v=await restarted.tick();XCTAssertEqual(v["status"] as? String,"disabled")
    }
    func testNegativeLiveRetryRemainsAmbiguous() async throws {
        let h=Harness(mode:"live");var e=try h.engine();try await h.enable(e);h.clock.minute(115);h.source.loseResponse=true
        _=await e.tick();e=try h.engine();h.clock.minute(116);h.source.loseResponse=false;h.source.result="no-credit"
        let v=await e.tick();XCTAssertEqual(v["status"] as? String,"unconfirmed");let s=await e.schedule();XCTAssertNil(s.at)
    }
    func testMissingLiveTargetRetryBlocksWithoutNewSend() async throws {
        let h=Harness(mode:"live");var e=try h.engine();try await h.enable(e);h.clock.minute(115);h.source.loseResponse=true
        _=await e.tick();e=try h.engine();h.clock.minute(116);h.source.loseResponse=false;h.source.notSent="credit-unavailable"
        let v=await e.tick();XCTAssertEqual(v["status"] as? String,"unconfirmed");XCTAssertEqual(h.source.requests.count,1)
    }
    func testReadFailureKeepsDeadlineHintAndNoConsume() async throws {
        let h=Harness();let e=try h.engine();try await h.enable(e);_=await e.tick();h.clock.minute(109.5);h.source.failRead=true
        let v=await e.tick();let s=await e.schedule();XCTAssertEqual(v["status"] as? String,"error");XCTAssertEqual(s.at,110 * 60_000)
        XCTAssertTrue(h.source.requests.isEmpty)
    }
    func testPendingTakesPriorityOverEmptyDiscovery() async throws {
        let h=Harness();let e=try h.engine();try await h.enable(e);h.clock.minute(110);h.source.loseResponse=true;_=await e.tick()
        h.source.snapshot["availableCount"]=0;h.source.snapshot["credits"]=[JSONObject]()
        _=await e.tick(manual:true);let s=await e.schedule();XCTAssertEqual(s.reason,"pending");XCTAssertEqual(s.at,h.clock.at+30_000)
    }
    func testCorruptStateRejectedRatherThanReset() throws {
        let h=Harness(state:["version":2,"config":RuneState.defaults,"operations":[],"events":[]])
        XCTAssertThrowsError(try h.engine())
        XCTAssertThrowsError(try RuneState.validateConfig(["enabled":1]))
    }
    func testPendingReadFailureDoesNotSpinAndExpiryNeedsNoNetwork() async throws {
        let h=Harness();let e=try h.engine();try await h.enable(e);h.clock.minute(110);h.source.loseResponse=true;_=await e.tick()
        h.clock.minute(111);h.source.failRead=true;_=await e.tick()
        let schedule=await e.schedule();XCTAssertEqual(schedule.at,h.clock.at+30_000)
        let reads=h.source.reads;h.clock.minute(120);let v=await e.tick()
        XCTAssertEqual(v["status"] as? String,"unconfirmed");XCTAssertEqual(h.source.reads,reads)
        XCTAssertEqual(h.source.requests.count,1)
    }
    func testRestartReadFailureStillHonorsSavedPlanBoundary() async throws {
        let h=Harness();let e=try h.engine();try await h.enable(e);_=await e.tick()
        let restarted=try h.engine();h.source.failRead=true;h.clock.minute(109.5)
        _=await restarted.tick();let schedule=await restarted.schedule()
        XCTAssertEqual(schedule.at,110 * 60_000)
    }
    func testIntentIsDurableBeforeSourceSeesRequest() async throws {
        let h=Harness();let e=try h.engine();try await h.enable(e);h.clock.minute(110)
        h.source.beforeSend = {
            let ops=h.store.value["operations"] as! [JSONObject]
            XCTAssertEqual(ops.count,1);XCTAssertEqual(ops[0]["stage"] as? String,"intent")
            XCTAssertEqual(ops[0]["key"] as? String,"key-1")
        }
        _=await e.tick();XCTAssertEqual(h.source.requests.count,1)
    }
    func testTwentyFourHourFarExpiryMakesNoPeriodicReads() async throws {
        let h=Harness();h.source.snapshot["availableCount"]=1
        h.source.snapshot["credits"]=[["id":"later","expiresAt":h.clock.at+7*86_400_000]]
        let e=try h.engine();try await h.enable(e);_=await e.tick();let reads=h.source.reads
        for _ in 0..<1440 { h.clock.at += 60_000;let scheduled=await e.schedule();XCTAssertGreaterThan(scheduled.at!,h.clock.at) }
        XCTAssertEqual(h.source.reads,reads);XCTAssertTrue(h.source.requests.isEmpty)
    }
    func testPauseAndCloseCancelSuspendedPreflight() async throws {
        for action in ["pause","close"] {
            let h=Harness(mode:"live");let e=try h.engine();try await h.enable(e);h.clock.minute(110)
            var stopping: Task<Void,Never>?
            h.source.onPreflight = { maySend in
                stopping=Task {
                    if action == "pause" { _=try? await e.configure(["enabled":false]) }
                    else { await e.close() }
                }
                for _ in 0..<5000 {
                    if !(await maySend()) { return }
                    await Task.yield()
                }
                XCTFail("stop gate was not observable during suspended preflight")
            }
            _=await e.tick();await stopping?.value
            XCTAssertTrue(h.source.requests.isEmpty,action)
            let schedule=await e.schedule();XCTAssertNil(schedule.at)
        }
    }
    func testShippingJavaScriptEngineBehaviorVectors() async throws {
        let root=URL(fileURLWithPath:#filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data=try Data(contentsOf:root.appendingPathComponent("test/contracts/native-engine-vectors.json"))
        let cases=try JSONSerialization.jsonObject(with:data) as! [JSONObject]
        for scenario in cases {
            let h=Harness(mode:scenario["mode"] as! String);h.source.snapshot=scenario["initialSnapshot"] as! JSONObject
            var engine=try h.engine()
            for (index,step) in (scenario["steps"] as! [JSONObject]).enumerated() {
                let label="\(scenario["name"]!) step \(index)"
                if let at=RuneState.number(step["at"]) {h.clock.minute(at)}
                switch step["op"] as? String {
                case "source":
                    if let scope=step["scope"] as? String {h.setIdentity(scope:scope)}
                    if step["dropFirst"] as? Bool == true {
                        var credits=h.source.snapshot["credits"] as! [JSONObject];credits.removeFirst()
                        h.source.snapshot["credits"]=credits;h.source.snapshot["availableCount"]=credits.count
                    }
                    if let remaining=step["remainingPercent"] {h.source.snapshot["remainingPercent"]=remaining}
                    if let result=step["result"] as? String {h.source.result=result}
                    if let lost=step["loseResponse"] as? Bool {h.source.loseResponse=lost}
                    if let failed=step["failRead"] as? Bool {h.source.failRead=failed}
                    if let after=step["failAfterConsume"] as? Bool {h.source.onConsume=after ? {h.source.failRead=true} : nil}
                case "restart": engine=try h.engine()
                case "configure":
                    var patch=step["patch"] as! JSONObject
                    if step["autoConsent"] as? Bool == true {let view=await engine.view();patch["consent"]=view["consent"]}
                    _=try await engine.configure(patch)
                case "tick": _=await engine.tick(manual:step["manual"] as? Bool ?? false)
                default: XCTFail("unknown contract action")
                }
                let expected=step["expected"] as! JSONObject
                var view=await engine.view();view.removeValue(forKey:"nextActionAt");view.removeValue(forKey:"scheduleReason")
                XCTAssertTrue(NSDictionary(dictionary:view).isEqual(to:expected["view"] as! JSONObject),label+" view")
                XCTAssertTrue(NSDictionary(dictionary:h.store.value).isEqual(to:expected["state"] as! JSONObject),label+" state")
                let requests=h.source.requests.map { request in request.filter {["id","key","startsAt","expiresAt","recovering"].contains($0.key)} }
                XCTAssertTrue(NSArray(array:requests).isEqual(to:expected["requests"] as! [Any]),label+" requests")
            }
        }
    }
    func testObservingStatusDoesNotPostponeDiscoveryOrWindowRetry() async throws {
        let h=Harness();let e=try h.engine();try await h.enable(e)
        h.source.snapshot["availableCount"]=0;h.source.snapshot["credits"]=[JSONObject]();_=await e.tick()
        let initial=await e.schedule();h.clock.at+=10_000
        let later=await e.schedule();XCTAssertEqual(later.at,initial.at)
        h.source.snapshot["availableCount"]=1;h.source.snapshot["credits"]=[["id":"a","expiresAt":120*60_000]]
        h.source.snapshot["remainingPercent"]=100;h.clock.minute(110);_=await e.tick()
        let retry=await e.schedule();h.clock.at+=10_000
        let retryLater=await e.schedule();XCTAssertEqual(retryLater.at,retry.at)
    }
    func testLastSecondManualRefreshLeavesImmediateAutomaticOpportunity() async throws {
        let h=Harness();let e=try h.engine();try await h.enable(e);h.clock.at=120*60_000-1000
        _=await e.tick(manual:true);XCTAssertTrue(h.source.requests.isEmpty)
        let schedule=await e.schedule();XCTAssertEqual(schedule.at,h.clock.at);XCTAssertEqual(schedule.reason,"evaluate-window")
        let view=await e.tick();XCTAssertEqual(view["status"] as? String,"reset");XCTAssertEqual(h.source.requests.count,1)
    }
    func testHashGoldenVectors() throws {
        let here=URL(fileURLWithPath:#filePath).resolvingSymlinksInPath()
        let root=here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data=try Data(contentsOf:root.appendingPathComponent("test/contracts/native-hash-vectors.json"))
        let entries=try JSONSerialization.jsonObject(with:data) as! [JSONObject]
        for entry in entries {
            let identity=entry["identity"] as! JSONObject
            XCTAssertEqual(RuneState.scope(email:identity["email"] as! String),identity["scope"] as? String)
            XCTAssertEqual(RuneState.authorization(identity),entry["authorization"] as? String)
            XCTAssertEqual(RuneState.consent(identity:identity,lead:RuneState.number(entry["lead"])!),entry["consent"] as? String)
            let credits=entry["credits"] as! [JSONObject]
            XCTAssertEqual(try RuneState.inventoryRevision(count:Double(credits.count),credits:credits),entry["inventoryRevision"] as? String)
        }
    }
}
