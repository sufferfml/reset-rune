import XCTest
import SQLite3
import CryptoKit
@testable import DesktopAutomation

@MainActor private final class FakeDriver: DesktopDeliveryDriver {
    var state=DesktopWindowContext(contextID:"window-1",targetID:"thread-1",sourceID:"synthetic")
    var evidence=[DesktopMessageEvidence]()
    var presses=0
    var reads=0
    var failAfterPress=false
    var beforeSend: (() -> Void)?
    var rewrite: ((String)->String)?
    func context(for target: DesktopTarget) throws -> DesktopWindowContext { reads += 1; return state }
    func writeText(_ text: String, contextID: String) throws { state.draft=rewrite?(text) ?? text }
    func pressSend(contextID: String, maySend: () -> Bool) throws { beforeSend?(); guard maySend() else { throw DesktopBlockReason.cancelled }; presses += 1; if failAfterPress { throw DesktopBlockReason.resultUnknown }; state.draft="" }
    func messages(after cursor: DesktopMessageCursor, target: DesktopTarget) throws -> [DesktopMessageEvidence] { evidence }
}

@MainActor final class DesktopAutomationTests: XCTestCase {
    private let target=DesktopTarget(agent:.codex,id:"thread-1",title:"Same title",sourceID:"synthetic",appVersion:"test")
    private func adapter(_ driver: FakeDriver, allowed: Bool = true) -> DesktopDeliveryAdapter {
        DesktopDeliveryAdapter(agent:.codex,compatibility:{ DesktopCompatibility(agent:.codex,version:"test",canDiscover:true,canSend:allowed,blockers:allowed ? [] : [.targetNotConfirmed]) },discover:{ [self.target] },open:{ _ in },driver:driver,now:{ 1_000 })
    }
    private func staged(_ adapter: DesktopAdapter, text: String = "继续\nKeep going 🫠") async throws -> DesktopStagedText {
        let preflight=try await adapter.preflight(target)
        return try await adapter.stageText(text,preflight:preflight)
    }
    private func assertBlock(_ expected: DesktopBlockReason, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected \(expected)",file:file,line:line) }
        catch { XCTAssertEqual(error as? DesktopBlockReason,expected,file:file,line:line) }
    }
    func testUnsupportedProductionProfileNeverReadsUI() async throws {
        let driver=FakeDriver(), adapter=adapter(driver,allowed:false)
        await assertBlock(.targetNotConfirmed) { _=try await adapter.preflight(self.target) }
        XCTAssertEqual(driver.reads,0)
    }
    func testSameTitleWrongStableIdentityBlocksBeforeInput() async throws {
        let driver=FakeDriver(); driver.state.targetID="other-thread"
        let adapter=adapter(driver)
        await assertBlock(.targetNotConfirmed) { _=try await adapter.preflight(self.target) }
        XCTAssertTrue(driver.state.draft.isEmpty); XCTAssertEqual(driver.presses,0)
    }
    func testExistingDraftIsPreserved() async throws {
        let driver=FakeDriver(); driver.state.draft="User draft"
        let adapter=adapter(driver)
        await assertBlock(.userDraft) { _=try await adapter.preflight(self.target) }
        XCTAssertEqual(driver.state.draft,"User draft")
    }
    func testCanonicalEquivalentDifferentBytesAreRejected() async throws {
        let driver=FakeDriver(); driver.rewrite={ _ in "e\u{301}" }
        let adapter=adapter(driver)
        await assertBlock(.textMismatch) { _=try await self.staged(adapter,text:"é") }
        XCTAssertEqual(driver.presses,0)
    }
    func testUserEditingAfterStageBlocksSend() async throws {
        let driver=FakeDriver(), adapter=adapter(driver)
        let value=try await staged(adapter); driver.state.draft="User changed it"
        await assertBlock(.userInterference) { try await adapter.pressSend(value,permit:DesktopSendPermit(stageID:value.stageID,expiresAt:2_000),maySend:{true}) }
        XCTAssertEqual(driver.presses,0)
    }
    func testExpiredPermitAndClosedGateNeverClick() async throws {
        let driver=FakeDriver(), adapter=adapter(driver)
        let value=try await staged(adapter)
        await assertBlock(.permitExpired) { try await adapter.pressSend(value,permit:DesktopSendPermit(stageID:value.stageID,expiresAt:1_000),maySend:{true}) }
        await assertBlock(.cancelled) { try await adapter.pressSend(value,permit:DesktopSendPermit(stageID:value.stageID,expiresAt:2_000),maySend:{false}) }
        XCTAssertEqual(driver.presses,0)
    }
    func testAXErrorCannotCauseSecondClick() async throws {
        let driver=FakeDriver(); driver.failAfterPress=true
        let adapter=adapter(driver), value=try await staged(adapter)
        let permit=DesktopSendPermit(stageID:value.stageID,expiresAt:2_000)
        await assertBlock(.resultUnknown) { try await adapter.pressSend(value,permit:permit,maySend:{true}) }
        await assertBlock(.cancelled) { try await adapter.pressSend(value,permit:permit,maySend:{true}) }
        XCTAssertEqual(driver.presses,1)
    }
    func testPermitIsCheckedAgainAfterDriverReads() async throws {
        let driver=FakeDriver(); var clock:Int64=1_000
        let adapter=DesktopDeliveryAdapter(agent:.codex,compatibility:{ DesktopCompatibility(agent:.codex,version:"test",canDiscover:true,canSend:true,blockers:[]) },discover:{[self.target]},open:{_ in},driver:driver,now:{clock})
        let value=try await staged(adapter)
        driver.beforeSend={clock=2_001}
        await assertBlock(.resultUnknown) { try await adapter.pressSend(value,permit:DesktopSendPermit(stageID:value.stageID,expiresAt:2_000),maySend:{true}) }
        XCTAssertEqual(driver.presses,0)
    }
    func testExactNewMessageWithoutSubmissionAssociationIsUnknown() async throws {
        let driver=FakeDriver(), adapter=adapter(driver), value=try await staged(adapter)
        try await adapter.pressSend(value,permit:DesktopSendPermit(stageID:value.stageID,expiresAt:2_000),maySend:{true})
        driver.evidence=[DesktopMessageEvidence(id:"new",targetID:target.id,sourceID:target.sourceID,text:value.text,timestamp:1_000)]
        let receipt=await adapter.verifyReceipt(value)
        XCTAssertEqual(receipt.outcome,.unknown)
    }
    func testOnlyTargetAndSubmissionAssociatedNewMessageIsSent() async throws {
        let driver=FakeDriver(); driver.state.seenMessageIDs=["old"]
        let adapter=adapter(driver), value=try await staged(adapter)
        try await adapter.pressSend(value,permit:DesktopSendPermit(stageID:value.stageID,expiresAt:2_000),maySend:{true})
        driver.evidence=[
            DesktopMessageEvidence(id:"old",targetID:target.id,sourceID:target.sourceID,text:value.text,timestamp:1_000,stageID:value.stageID),
            DesktopMessageEvidence(id:"other",targetID:"other-thread",sourceID:target.sourceID,text:value.text,timestamp:1_000,stageID:value.stageID),
            DesktopMessageEvidence(id:"new",targetID:target.id,sourceID:target.sourceID,text:value.text,timestamp:1_000,stageID:value.stageID)
        ]
        let receipt=await adapter.verifyReceipt(value)
        XCTAssertEqual(receipt.outcome,.sent); XCTAssertEqual(receipt.messageID,"new")
    }
    func testSimulationRejectsRealBundleIDAndSupportsBothAgents() async throws {
        for agent in DesktopAgent.allCases {
            let adapter=DesktopAdapters.make(agent:agent,mock:true)
            let discovery=try await adapter.discoverTargets(), target=try XCTUnwrap(discovery.targets.first)
            XCTAssertEqual(target.bundleID,"local.reset-rune.mock."+agent.rawValue)
            var real=target; real.bundleID=agent.bundleID
            await assertBlock(.invalidTarget) { _=try await adapter.preflight(real) }
            let preflight=try await adapter.preflight(target)
            let value=try await adapter.stageText("Test only",preflight:preflight)
            try await adapter.pressSend(value,permit:DesktopSendPermit(stageID:value.stageID,expiresAt:Int64(Date().timeIntervalSince1970*1000)+1_000),maySend:{true})
            let receipt=await adapter.verifyReceipt(value)
            XCTAssertEqual(receipt.outcome,.sent); XCTAssertTrue(receipt.messageID?.hasPrefix("simulation-")==true)
        }
    }
}

final class DesktopTargetReaderTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("reset-rune-desktop-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
    func testCodexReadsCheckpointedIndexWithoutCreatingSidecars() throws {
        let file=root.appendingPathComponent("state_5.sqlite")
        var database: OpaquePointer?; XCTAssertEqual(sqlite3_open(file.path,&database),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database,"CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,archived INTEGER,updated_at INTEGER); INSERT INTO threads VALUES('thread-1','Same title','/synthetic',0,1); INSERT INTO threads VALUES('thread-2','Archived','/synthetic',1,2);",nil,nil,nil),SQLITE_OK)
        sqlite3_close(database)
        let before=try FileManager.default.contentsOfDirectory(atPath:root.path)
        let targets=try DesktopTargetReader(root:root).codex(version:"test")
        XCTAssertEqual(targets.map(\.id),["thread-1"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),before)
    }
    func testPendingWALIsNotSilentlyIgnored() throws {
        try Data().write(to:root.appendingPathComponent("state_5.sqlite"))
        try Data([1]).write(to:root.appendingPathComponent("state_5.sqlite-wal"))
        XCTAssertThrowsError(try DesktopTargetReader(root:root).codex(version:"test")) { XCTAssertEqual($0 as? DesktopBlockReason,.sourceUnavailable) }
    }
    func testCommittedWALThreadIsVisibleAndAllSourceFilesRemainByteIdentical()throws{
        let file=root.appendingPathComponent("state_5.sqlite")
        var database:OpaquePointer?;XCTAssertEqual(sqlite3_open(file.path,&database),SQLITE_OK);defer{sqlite3_close(database)}
        XCTAssertEqual(sqlite3_exec(database,"PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,archived INTEGER,updated_at INTEGER,source TEXT); INSERT INTO threads VALUES('committed-wal','Synthetic WAL','/synthetic',0,2,'desktop'); INSERT INTO threads VALUES('hidden-subagent','Internal','/synthetic',0,3,'subagent');",nil,nil,nil),SQLITE_OK)
        let names=try FileManager.default.contentsOfDirectory(atPath:root.path).sorted()
        func hashes()throws->[String:Data]{try Dictionary(uniqueKeysWithValues:names.map{($0,Data(SHA256.hash(data:try Data(contentsOf:root.appendingPathComponent($0)))))})}
        let before=try hashes()
        XCTAssertGreaterThan(try Data(contentsOf:root.appendingPathComponent("state_5.sqlite-wal")).count,0)
        let targets=try DesktopTargetReader(root:root).codex(version:"test")
        XCTAssertEqual(targets.map(\.id),["committed-wal"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path).sorted(),names)
        XCTAssertEqual(try hashes(),before)
    }
    func testCodexSearchBeforePageLimitEscapesWildcardsAndSQL()throws{
        var database:OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path,&database),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database,"CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,archived INTEGER,updated_at INTEGER);",nil,nil,nil),SQLITE_OK)
        var statement:OpaquePointer?;XCTAssertEqual(sqlite3_prepare_v2(database,"INSERT INTO threads VALUES(?,?,?,0,?)",-1,&statement,nil),SQLITE_OK)
        let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        for index in 0..<505{
            let id="thread-\(index)",title=index==0 ? "中文 100%_项目 'quoted'" : "Recent \(index)"
            sqlite3_bind_text(statement,1,id,-1,transient);sqlite3_bind_text(statement,2,title,-1,transient);sqlite3_bind_text(statement,3,"/synthetic",-1,transient);sqlite3_bind_int(statement,4,Int32(index))
            XCTAssertEqual(sqlite3_step(statement),SQLITE_DONE);sqlite3_reset(statement)
        }
        sqlite3_finalize(statement);sqlite3_close(database)
        let reader=DesktopTargetReader(root:root),page=try reader.codexPage(version:"test")
        XCTAssertEqual(page.targets.count,500);XCTAssertTrue(page.hasMore);XCTAssertFalse(page.targets.contains{$0.id=="thread-0"})
        for query in ["中文","100%_","'quoted'","thread-0"]{
            let found=try reader.codexPage(version:"test",matching:query)
            XCTAssertEqual(found.targets.map(\.id),["thread-0"]);XCTAssertFalse(found.hasMore)
            XCTAssertEqual(found.targets.first?.sourceID,page.targets.first?.sourceID)
        }
        XCTAssertTrue(try reader.codexPage(version:"test",matching:"' OR 1=1 --").targets.isEmpty)
    }
    func testClaudeKeepsDistinctSameTitleIDsAndDoesNotReadTokens() throws {
        let folder=root.appendingPathComponent("claude-code-sessions/account")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for id in ["local_one","local_two"] {
            let data=try JSONSerialization.data(withJSONObject:["sessionId":id,"title":"Same title","cwd":"/synthetic","cliSessionId":"synthetic-cli"])
            try data.write(to:folder.appendingPathComponent(id+".json"))
        }
        try Data("not a JSON index".utf8).write(to:root.appendingPathComponent("credentials.json"))
        let targets=try DesktopTargetReader(root:root).claude(version:"test")
        XCTAssertEqual(Set(targets.map(\.id)),["local_one","local_two"])
        XCTAssertEqual(targets[0].sourceID,targets[1].sourceID)
    }
    func testSymlinkSourceIsRejected() throws {
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("claude-code-sessions"),withDestinationURL:root)
        XCTAssertThrowsError(try DesktopTargetReader(root:root).claude(version:"test")) { XCTAssertEqual($0 as? DesktopBlockReason,.unsafeSource) }
    }
    func testDuplicateClaudeIDAcrossAccountScopesIsRejected() throws {
        for account in ["account-one","account-two"] {
            let folder=root.appendingPathComponent("claude-code-sessions/"+account)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:["sessionId":"local_same","title":"Same title"]).write(to:folder.appendingPathComponent("local_same.json"))
        }
        XCTAssertThrowsError(try DesktopTargetReader(root:root).claude(version:"test")) { XCTAssertEqual($0 as? DesktopBlockReason,.sourceChanged) }
    }
}
