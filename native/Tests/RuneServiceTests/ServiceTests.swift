import XCTest
import Foundation
@testable import RuneService
import RuneCore

final class ServiceTests:XCTestCase {
    func temporary() throws -> URL {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("bottled-native-test-"+UUID().uuidString)
        try PrivateFiles.ensure(dir); return dir
    }
    func testAtomicStateAndPermissions() throws {
        let dir=try temporary(); defer { try? FileManager.default.removeItem(at:dir) }
        let store=try FileStateStore(directory:dir)
        var state=try store.read(); state["liveAuthorization"]="preserved"; state["operations"]=[["id":"old","key":"original","stage":"unconfirmed"]]
        try store.write(state)
        XCTAssertEqual(try store.read()["liveAuthorization"] as? String,"preserved")
        let permissions=try FileManager.default.attributesOfItem(atPath:dir.appendingPathComponent("state.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions,0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dir.path),["state.json"])
    }
    func testSymlinkAndMalformedStateRejected() throws {
        let dir=try temporary(); defer { try? FileManager.default.removeItem(at:dir) }
        let target=dir.appendingPathComponent("target"), file=dir.appendingPathComponent("state.json")
        try PrivateFiles.write(target,["secret":"not-readable"])
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:target)
        XCTAssertThrowsError(try PrivateFiles.read(file))
        try FileManager.default.removeItem(at:file)
        try Data("invalid".utf8).write(to:file); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        XCTAssertThrowsError(try FileStateStore(directory:dir).read())
    }
    func testMockNeverUsesLoginAndPausedSchedule() async throws {
        let dir=try temporary(); defer { try? FileManager.default.removeItem(at:dir) }
        let engine=try RuneEngine(source:MockSource(directory:dir),store:FileStateStore(directory:dir))
        _=await engine.tick(manual:true)
        let view=await engine.view(), schedule=await engine.schedule()
        XCTAssertEqual((view["snapshot"] as? JSONObject)?["availableCount"] as? Int,2)
        XCTAssertNil(schedule.at)
        XCTAssertEqual(schedule.reason,"paused")
        _=try await engine.configure(["enabled":true,"notify":false])
        let activeSchedule=await engine.schedule()
        XCTAssertEqual(activeSchedule.reason,"scheduled-expiry", "Fresh mock deadlines must be integer milliseconds")
    }
    func testImmediateResetEvaluationSurvivesScheduleActorDelay() async throws {
        let dir=try temporary(); defer { try? FileManager.default.removeItem(at:dir) }
        let engine=try RuneEngine(source:MockSource(directory:dir),store:MemoryStateStore(),now:{
            // A schedule can finish after the coordinator starts checking it.
            Thread.sleep(forTimeInterval:0.002)
            return Date().timeIntervalSince1970*1000
        })
        _=try await engine.configure(["enabled":true,"notify":false,"lead":30])
        let coordinator=ServiceCoordinator(engine:engine)
        await coordinator.systemEvent()
        let state=await engine.durableState()
        let operations=state["operations"] as? [JSONObject] ?? []
        XCTAssertEqual(operations.count,1,"An immediate evaluation must not be pushed forward by every schedule read")
        XCTAssertEqual(operations.first?["stage"] as? String,"reset")
        await coordinator.close()
    }
    func testHTTPAuthenticationAndManagementContract() async throws {
        let dir=try temporary(); defer { try? FileManager.default.removeItem(at:dir) }
        let engine=try RuneEngine(source:MockSource(directory:dir),store:FileStateStore(directory:dir))
        let coordinator=ServiceCoordinator(engine:engine), port=Int.random(in:30000..<39000), token=String(repeating:"a",count:43)
        let server=LocalHTTPServer(coordinator:coordinator,token:token,port:port)
        try await server.start()
        let url=URL(string:"http://127.0.0.1:\(port)/api/status")!
        var req=URLRequest(url:url); req.timeoutInterval=2
        let (_,denied)=try await URLSession.shared.data(for:req)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode,401)
        req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        let (data,allowed)=try await URLSession.shared.data(for:req)
        XCTAssertEqual((allowed as? HTTPURLResponse)?.statusCode,200)
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? JSONObject)
        XCTAssertEqual((json["runtime"] as? JSONObject)?["native"] as? Bool,true)
        req.setValue("https://foreign.example",forHTTPHeaderField:"Origin")
        let (_,foreign)=try await URLSession.shared.data(for:req)
        XCTAssertEqual((foreign as? HTTPURLResponse)?.statusCode,403)
        await coordinator.close(); await server.close()
        let replacement=LocalHTTPServer(coordinator:coordinator,token:token,port:port)
        try await replacement.start()
        await replacement.close()
    }
    func testLifecycleWritersAreExclusive() throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        let first=try LifecycleLease(directory:dir)
        XCTAssertThrowsError(try LifecycleLease(directory:dir))
        withExtendedLifetime(first) {}
    }
    func testDataDirectoryAndMockIsolation() {
        let env=["RESET_RUNE_DATA_DIR":"/tmp/new"]
        XCTAssertEqual(Paths.directory(mock:false,env:env).path,"/tmp/new")
        XCTAssertEqual(Paths.directory(mock:true,env:env).path,"/tmp/new/simulation")
        XCTAssertEqual(Paths.directory(mock:false,env:[:]).path,FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bottled Reset Rune").path)
        XCTAssertEqual(Paths.label(mock:false),"local.reset-rune.service")
        XCTAssertEqual(Paths.label(mock:true),"local.reset-rune.service.mock")
        XCTAssertEqual(NativeRuntime.version,"0.1.2")
    }
}
