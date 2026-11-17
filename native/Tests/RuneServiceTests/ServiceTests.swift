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
    private func registration(_ dir:URL,mock:Bool=false,environment:[String:String]=[:]) throws -> [String:Any] {
        let data=try NativeRuntime.plist(executable:dir.appendingPathComponent("helper"),directory:dir,mock:mock,environment:environment)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any])
    }
    private func saveRegistration(_ value:[String:Any],_ dir:URL,mock:Bool=false) throws {
        let data=try PropertyListSerialization.data(fromPropertyList:value,format:.xml,options:0)
        try data.write(to:dir.appendingPathComponent(Paths.label(mock:mock)+".plist"),options:.atomic)
    }
    func testRuntimePinSurvivesServiceRegistrationRewrite() throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        let pin=dir.appendingPathComponent("private codex/0.153.0/codex").path
        try saveRegistration(registration(dir,environment:["RESET_RUNE_CODEX_PATH":pin,"CODEX_HOME":"/old/home"]),dir)
        let updated=try registration(dir,environment:["PATH":"/new/path"])
        let env=try XCTUnwrap(updated["EnvironmentVariables"] as? [String:String])
        XCTAssertEqual(env["RESET_RUNE_CODEX_PATH"],pin)
        XCTAssertEqual(env["PATH"],"/new/path")
        XCTAssertNil(env["CODEX_HOME"],"Only the runtime pin is inherited; unrelated old environment is not restored")
    }
    func testExplicitRuntimePinOverridesPreviousRegistration() throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        try saveRegistration(registration(dir,environment:["RESET_RUNE_CODEX_PATH":"/old/codex"]),dir)
        var updated=try registration(dir,environment:["RESET_RUNE_CODEX_PATH":"/new/codex"])
        XCTAssertEqual((updated["EnvironmentVariables"] as? [String:String])?["RESET_RUNE_CODEX_PATH"],"/new/codex")
        // An explicit valid override can also repair malformed old metadata.
        try Data("broken".utf8).write(to:dir.appendingPathComponent(Paths.label(mock:false)+".plist"))
        updated=try registration(dir,environment:["RESET_RUNE_CODEX_PATH":"/new/codex"])
        XCTAssertEqual((updated["EnvironmentVariables"] as? [String:String])?["RESET_RUNE_CODEX_PATH"],"/new/codex")
    }
    func testUnpinnedRegistrationKeepsExistingDiscoveryBehavior() throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        let fresh=try registration(dir)
        XCTAssertNil((fresh["EnvironmentVariables"] as? [String:String])?["RESET_RUNE_CODEX_PATH"])
        try saveRegistration(fresh,dir)
        let restarted=try registration(dir)
        XCTAssertNil((restarted["EnvironmentVariables"] as? [String:String])?["RESET_RUNE_CODEX_PATH"])
    }
    func testRuntimePinRejectsRegistrationFromAnotherScope() throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        let original=try registration(dir,environment:["RESET_RUNE_CODEX_PATH":"/private/codex"])
        for (key,value) in [("Label","foreign.service" as Any),("WorkingDirectory","/another/directory" as Any),
                            ("ProgramArguments",["/helper","--serve","--mock"] as Any),("EnvironmentVariables",["RESET_RUNE_CODEX_PATH":42] as Any)] {
            var invalid=original;invalid[key]=value
            try saveRegistration(invalid,dir)
            XCTAssertThrowsError(try registration(dir),"Reject invalid \(key) instead of silently losing the pin")
        }
    }
    func testRuntimePinRejectsMalformedAndUnsafeRegistration() throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        let file=dir.appendingPathComponent(Paths.label(mock:false)+".plist")
        try Data("invalid plist".utf8).write(to:file)
        XCTAssertThrowsError(try registration(dir))
        try Data(repeating:32,count:65_537).write(to:file)
        XCTAssertThrowsError(try registration(dir))
        try FileManager.default.removeItem(at:file)
        let target=dir.appendingPathComponent("symlink-target")
        try Data("not a registration".utf8).write(to:target)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:target)
        XCTAssertThrowsError(try registration(dir))
        try FileManager.default.removeItem(at:file)
        try saveRegistration(registration(dir,environment:["RESET_RUNE_CODEX_PATH":"/private/codex"]),dir)
        try FileManager.default.setAttributes([.posixPermissions:0o666],ofItemAtPath:file.path)
        XCTAssertThrowsError(try registration(dir))
    }
    func testInvalidRuntimePinCannotSilentlyFallBackToGlobalCodex() throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        let original=try registration(dir)
        for pin in ["relative/codex",""] {
            XCTAssertThrowsError(try registration(dir,environment:["RESET_RUNE_CODEX_PATH":pin]))
            var invalid=original;invalid["EnvironmentVariables"]=["RESET_RUNE_CODEX_PATH":pin]
            try saveRegistration(invalid,dir)
            XCTAssertThrowsError(try registration(dir))
        }
        XCTAssertThrowsError(try registration(dir,environment:["RESET_RUNE_CODEX_PATH":"/codex\0injected"]))
    }
    func testMockRuntimePinDoesNotInheritLiveRegistration() throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        try saveRegistration(registration(dir,environment:["RESET_RUNE_CODEX_PATH":"/live/codex"]),dir)
        var mock=try registration(dir,mock:true)
        XCTAssertNil((mock["EnvironmentVariables"] as? [String:String])?["RESET_RUNE_CODEX_PATH"])
        mock=try registration(dir,mock:true,environment:["RESET_RUNE_CODEX_PATH":"/mock/codex"])
        try saveRegistration(mock,dir,mock:true)
        mock=try registration(dir,mock:true)
        XCTAssertEqual((mock["EnvironmentVariables"] as? [String:String])?["RESET_RUNE_CODEX_PATH"],"/mock/codex")
        XCTAssertEqual((try registration(dir)["EnvironmentVariables"] as? [String:String])?["RESET_RUNE_CODEX_PATH"],"/live/codex")
    }
    func testDataDirectoryAndMockIsolation() {
        let env=["RESET_RUNE_DATA_DIR":"/tmp/new"]
        XCTAssertEqual(Paths.directory(mock:false,env:env).path,"/tmp/new")
        XCTAssertEqual(Paths.directory(mock:true,env:env).path,"/tmp/new/simulation")
        XCTAssertEqual(Paths.directory(mock:false,env:[:]).path,FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bottled Reset Rune").path)
        XCTAssertEqual(Paths.label(mock:false),"local.reset-rune.service")
        XCTAssertEqual(Paths.label(mock:true),"local.reset-rune.service.mock")
        XCTAssertEqual(NativeRuntime.version,"0.1.3")
    }
}
