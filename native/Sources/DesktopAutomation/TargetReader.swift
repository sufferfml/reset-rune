import Foundation
import CryptoKit
import SQLite3

public struct DesktopTargetPage:Sendable{
    public var targets:[DesktopTarget]
    public var hasMore:Bool
}

/// Reads only explicitly selected local index roots. It never opens authentication
/// files, logs, messages or a database for writing. Limits fail visibly, not by truncation.
public struct DesktopTargetReader {
    public static let maximumTargets=500
    public let root: URL
    public init(root: URL) { self.root=root.standardizedFileURL }

    public func codex(version: String) throws -> [DesktopTarget] {
        let page=try codexPage(version:version)
        guard !page.hasMore else{throw DesktopBlockReason.limitExceeded}
        return page.targets
    }
    public func codexTarget(id:String,version:String)throws->DesktopTarget?{try codexPage(version:version,exactID:id).targets.first}
    public func codexPage(version:String,matching query:String="",exactID:String?=nil)throws->DesktopTargetPage{
        guard query.utf8.count<=1024 else{throw DesktopBlockReason.limitExceeded}
        if let exactID{guard validID(exactID)else{throw DesktopBlockReason.invalidTarget}}
        try safe(root)
        let file=root.appendingPathComponent("state_5.sqlite")
        try safe(file)
        guard let size=try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 128*1024*1024 else { throw DesktopBlockReason.limitExceeded }
        // Never ask SQLite to touch the source's WAL/SHM. Both checkpointed and
        // WAL-backed indexes are read through a consistency-checked private copy.
        let wal=root.appendingPathComponent("state_5.sqlite-wal")
        if FileManager.default.fileExists(atPath:wal.path) {
            try safe(wal)
        }
        let privateSnapshot=try CodexIndexSnapshot(root:root)
        // Keep the snapshot owner alive until SQLite and its statements are closed.
        defer{withExtendedLifetime(privateSnapshot){}}
        var components=URLComponents(url:privateSnapshot.database,resolvingAgainstBaseURL:false)!
        components.queryItems=[URLQueryItem(name:"mode",value:"ro")]
        var database: OpaquePointer?
        guard sqlite3_open_v2(components.string, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; throw DesktopBlockReason.sourceUnavailable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 50)
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 1024*1024)
        var statement: OpaquePointer?
        var columns:OpaquePointer?
        guard sqlite3_prepare_v2(database,"PRAGMA table_info(threads)",-1,&columns,nil)==SQLITE_OK else{throw DesktopBlockReason.sourceUnavailable}
        var hasSource=false
        while sqlite3_step(columns)==SQLITE_ROW{if let name=sqlite3_column_text(columns,1),String(cString:name)=="source"{hasSource=true}}
        sqlite3_finalize(columns)
        let sourceFilter=hasSource ? " AND (source IS NULL OR source NOT LIKE '%subagent%')" : ""
        let filter=query.isEmpty ? "" : " AND (title LIKE ? ESCAPE '\\' OR cwd LIKE ? ESCAPE '\\' OR id LIKE ? ESCAPE '\\')"
        // Desktop may use an entire first prompt as its provisional title. The picker
        // is a metadata summary, so bound this display field and mark clipping visibly.
        let exactFilter=exactID==nil ? "":" AND id=?"
        let sql="SELECT id,CASE WHEN length(title)>512 THEN substr(title,1,512)||'…' ELSE title END,cwd FROM threads WHERE archived=0"+sourceFilter+filter+exactFilter+" ORDER BY updated_at DESC LIMIT 501"
        guard sqlite3_prepare_v2(database,sql,-1,&statement,nil) == SQLITE_OK else { throw DesktopBlockReason.sourceUnavailable }
        defer { sqlite3_finalize(statement) }
        if !query.isEmpty{
            let pattern="%"+query.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"%",with:"\\%").replacingOccurrences(of:"_",with:"\\_")+"%"
            let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement,1,pattern,-1,transient)==SQLITE_OK,sqlite3_bind_text(statement,2,pattern,-1,transient)==SQLITE_OK,sqlite3_bind_text(statement,3,pattern,-1,transient)==SQLITE_OK else{throw DesktopBlockReason.sourceUnavailable}
        }
        if let exactID{
            guard sqlite3_bind_text(statement,query.isEmpty ? 1:4,exactID,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))==SQLITE_OK else{throw DesktopBlockReason.sourceUnavailable}
        }
        var result=[DesktopTarget](), seen=Set<String>()
        while true {
            let code=sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw DesktopBlockReason.sourceUnavailable }
            func string(_ index: Int32) -> String { sqlite3_column_text(statement,index).map { String(cString:$0) } ?? "" }
            let id=string(0)
            guard validID(id), seen.insert(id).inserted else { throw DesktopBlockReason.invalidTarget }
            let rawTitle=string(1),title=rawTitle.isEmpty ? "Untitled chat":rawTitle,project=string(2)
            guard title.utf8.count<=8*1024,project.utf8.count<=16*1024 else { throw DesktopBlockReason.limitExceeded }
            result.append(DesktopTarget(agent:.codex,id:id,title:title,project:project,sourceID:sourceID(root.path),appVersion:version))
            if result.count>Self.maximumTargets{return DesktopTargetPage(targets:Array(result.prefix(Self.maximumTargets)),hasMore:true)}
        }
        return DesktopTargetPage(targets:result,hasMore:false)
    }

    public func claude(version: String) throws -> [DesktopTarget] {
        try safe(root)
        var result=[DesktopTarget](), seen=[String:DesktopTarget](), visited=0, totalBytes=0
        for directory in ["claude-code-sessions","local-agent-mode-sessions"] {
            let base=root.appendingPathComponent(directory)
            guard FileManager.default.fileExists(atPath:base.path) else { continue }
            try safe(base)
            guard let enumerator=FileManager.default.enumerator(at:base,includingPropertiesForKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.fileSizeKey],options:[.skipsHiddenFiles]) else { throw DesktopBlockReason.sourceUnavailable }
            for case let file as URL in enumerator {
                visited += 1
                guard visited <= 2_000 else { throw DesktopBlockReason.limitExceeded }
                try safe(file)
                let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isDirectoryKey,.fileSizeKey])
                if values.isDirectory == true {
                    guard file.pathComponents.count - base.pathComponents.count <= 4 else { throw DesktopBlockReason.limitExceeded }
                    continue
                }
                guard values.isRegularFile == true, file.pathExtension == "json", file.lastPathComponent.hasPrefix("local_") else { continue }
                guard (values.fileSize ?? Int.max) <= 1024*1024 else { throw DesktopBlockReason.limitExceeded }
                totalBytes += values.fileSize ?? 0
                guard totalBytes<=8*1024*1024 else { throw DesktopBlockReason.limitExceeded }
                let data=try Data(contentsOf:file,options:.mappedIfSafe)
                guard let record=try JSONSerialization.jsonObject(with:data) as? [String:Any], let id=record["sessionId"] as? String, validID(id) else { throw DesktopBlockReason.sourceUnavailable }
                if (record["isArchived"] as? Bool) == true { continue }
                let title=(record["title"] as? String) ?? ""
                let project=record["cwd"] as? String
                guard title.utf8.count<=8*1024,(project?.utf8.count ?? 0)<=16*1024 else { throw DesktopBlockReason.limitExceeded }
                let target=DesktopTarget(agent:.claude,id:id,title:title,project:project,sourceID:sourceID(file.deletingLastPathComponent().path),appVersion:version)
                // An ID seen in two different source scopes is ambiguous; do not silently
                // choose the first account or legacy copy encountered by the filesystem.
                if let previous=seen[id] { guard previous==target else { throw DesktopBlockReason.sourceChanged }; continue }
                seen[id]=target; result.append(target)
                guard result.count <= Self.maximumTargets else { throw DesktopBlockReason.limitExceeded }
            }
        }
        return result.sorted { $0.title < $1.title }
    }
    private func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }
    }
    public static func sourceIdentifier(for root:URL)->String{ "desktop:"+SHA256.hash(data:Data(root.standardizedFileURL.path.utf8)).map { String(format:"%02x",$0) }.joined() }
    private func sourceID(_ path: String) -> String { Self.sourceIdentifier(for:URL(fileURLWithPath:path)) }
    private func safe(_ url: URL) throws {
        let normalized=url.standardizedFileURL
        guard normalized.path == root.path || normalized.path.hasPrefix(root.path+"/") else { throw DesktopBlockReason.unsafeSource }
        var current=normalized
        while true {
            let values=try current.resourceValues(forKeys:[.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw DesktopBlockReason.unsafeSource }
            if current == root { break }
            current.deleteLastPathComponent()
        }
    }
}
