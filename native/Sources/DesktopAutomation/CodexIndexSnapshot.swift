import Foundation
import Darwin

/// Creates a private, short-lived DB+WAL snapshot without opening the source in SQLite.
/// A source change during copying invalidates the attempt; no source checkpoint or
/// SHM creation is performed. SQLite recovers only the private copy's WAL index.
internal final class CodexIndexSnapshot {
    let directory:URL
    let database:URL
    init(root:URL)throws{
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("reset-rune-index-"+UUID().uuidString)
        database=directory.appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do{
            var copied=false
            for _ in 0..<3{
                let before=try Self.files(root)
                for name in ["state_5.sqlite","state_5.sqlite-wal"]{try? FileManager.default.removeItem(at:directory.appendingPathComponent(name))}
                for (name,_) in before{try Self.copy(root.appendingPathComponent(name),to:directory.appendingPathComponent(name))}
                if before == (try Self.files(root)){copied=true;break}
            }
            guard copied else{throw DesktopBlockReason.sourceUnavailable}
        }catch{try? FileManager.default.removeItem(at:directory);throw error}
    }
    deinit{try? FileManager.default.removeItem(at:directory)}
    private struct Fingerprint:Equatable{
        var inode:ino_t,device:dev_t,size:off_t,seconds:Int,nanos:Int,changeSeconds:Int,changeNanos:Int
    }
    private static func files(_ root:URL)throws->[String:Fingerprint]{
        var result=[String:Fingerprint]()
        for name in ["state_5.sqlite","state_5.sqlite-wal"]{
            var info=stat();let code=lstat(root.appendingPathComponent(name).path,&info)
            if code != 0 && errno==ENOENT && name.hasSuffix("-wal"){continue}
            guard code==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_nlink==1 else{throw DesktopBlockReason.unsafeSource}
            guard info.st_size>=0,info.st_size<=128*1024*1024 else{throw DesktopBlockReason.limitExceeded}
            result[name]=Fingerprint(inode:info.st_ino,device:info.st_dev,size:info.st_size,seconds:info.st_mtimespec.tv_sec,nanos:info.st_mtimespec.tv_nsec,changeSeconds:info.st_ctimespec.tv_sec,changeNanos:info.st_ctimespec.tv_nsec)
        }
        return result
    }
    private static func copy(_ source:URL,to destination:URL)throws{
        let input=Darwin.open(source.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard input>=0 else{throw DesktopBlockReason.sourceUnavailable};defer{Darwin.close(input)}
        let output=Darwin.open(destination.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard output>=0 else{throw DesktopBlockReason.sourceUnavailable};defer{Darwin.close(output)}
        var buffer=[UInt8](repeating:0,count:128*1024),total=0
        while true{
            let count=Darwin.read(input,&buffer,buffer.count)
            if count<0 && errno==EINTR{continue};guard count>=0 else{throw DesktopBlockReason.sourceUnavailable};if count==0{break}
            total+=count;guard total<=128*1024*1024 else{throw DesktopBlockReason.limitExceeded}
            try buffer.withUnsafeBytes{bytes in
                var offset=0
                while offset<count{
                    let written=Darwin.write(output,bytes.baseAddress!.advanced(by:offset),count-offset)
                    if written<0 && errno==EINTR{continue};guard written>0 else{throw DesktopBlockReason.sourceUnavailable};offset+=written
                }
            }
        }
    }
}
