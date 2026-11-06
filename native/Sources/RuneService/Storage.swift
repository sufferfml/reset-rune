// INPUT: Private user-owned v1 state; OUTPUT: durable compatible journal.
// POS: Native filesystem boundary; see native/README.md.
import Foundation
import Darwin
import RuneCore

public enum Paths {
    public static func directory(mock: Bool, env: [String:String] = ProcessInfo.processInfo.environment) -> URL {
        let base = env["RESET_RUNE_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let url = base.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bottled Reset Rune")
        return mock ? url.appendingPathComponent("simulation") : url
    }
    public static func port(mock: Bool) -> Int { 41000 + (Int(getuid()) % 6000) * 2 + (mock ? 1 : 0) }
    public static func label(mock: Bool) -> String { "local.reset-rune.service" + (mock ? ".mock" : "") }
}

public enum PrivateFiles {
    public static func ensure(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(directory.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
              st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { throw RuneError("insecure-data-directory") }
    }
    public static func read(_ file: URL) throws -> JSONObject? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return nil }; throw RuneError("insecure-state-file") }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0,
              st.st_size <= 16 * 1024 * 1024 else { throw RuneError("insecure-state-file") }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        guard let json = try JSONSerialization.jsonObject(with: data) as? JSONObject else { throw RuneError("unsupported-state") }
        return json
    }
    public static func write(_ file: URL, _ value: JSONObject) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RuneError("state-write-failed") }
        var closed = false
        defer { if !closed { Darwin.close(fd) }; unlink(tmp.path) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw RuneError("state-write-failed") }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw RuneError("state-write-failed") }
        Darwin.close(fd); closed = true
        guard rename(tmp.path, file.path) == 0 else { throw RuneError("state-write-failed") }
        let parent = open(file.deletingLastPathComponent().path, O_RDONLY)
        guard parent >= 0 else { throw RuneError("state-write-failed") }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw RuneError("state-write-failed") }
    }
}
public final class FileStateStore: StateStore {
    let directory: URL
    public init(directory: URL) throws { try PrivateFiles.ensure(directory); self.directory = directory }
    public func read() throws -> JSONObject { try PrivateFiles.read(directory.appendingPathComponent("state.json")) ?? ["version": 1, "config": ["enabled": false, "lead": 10, "language": "en", "appearance": "system", "startup": false, "notify": true], "binding": NSNull(), "plan": NSNull(), "operations": [], "events": []] }
    public func write(_ value: JSONObject) throws { try PrivateFiles.write(directory.appendingPathComponent("state.json"), value) }
}
