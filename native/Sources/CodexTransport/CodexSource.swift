// INPUT: Official Codex executable and its own credential storage; synthetic runtimes in tests.
// OUTPUT: Bounded, short-lived account/quota sessions and explicit, guarded redemption.
// POS: Native transport; no credential file or raw RPC output is read/logged by the app.
import Foundation
import Darwin
import RuneCore

public let supportedCodexVersion = "0.153.0"
private let maxFrameBytes = 1024 * 1024
private let backendOverride = "chatgpt_base_url=\"https://chatgpt.com/backend-api/\""

public final class CodexSource: ResetSource, @unchecked Sendable {
    public let mode: String
    private let resolver: RuntimeResolver
    private let environment: [String: String]
    private let timeoutMs: Int
    private let now: () -> Double
    private let lock = NSLock()
    private var inFlight: Task<JSONObject, Error>?
    private var generation: UUID?
    private var sessions: [UUID: AppServerSession] = [:]
    private var closed = false

    public init(executable: String? = nil, timeoutMs: Int = 15_000,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                allowConsume: Bool = false,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.mode = allowConsume ? "live" : "readonly"
        self.timeoutMs = max(1, timeoutMs); self.now = now
        self.environment = Self.childEnvironment(environment)
        self.resolver = RuntimeResolver(executable: executable ?? environment["RESET_RUNE_CODEX_PATH"], environment: self.environment)
    }

    public func read() async throws -> JSONObject {
        let (task, id) = try lock.withLock { () throws -> (Task<JSONObject, Error>, UUID) in
            if closed { throw RuneError("read-failed") }
            if let inFlight, let generation { return (inFlight, generation) }
            let id = UUID()
            let task = Task<JSONObject, Error> { [self] in
                let path = try await resolver.resolve()
                let result = try await run(path: path, operation: nil, maySend: nil)
                guard case .snapshot(let snapshot) = result else { throw RuneError("protocol-error") }
                return snapshot
            }
            inFlight = task; generation = id
            return (task, id)
        }
        defer { lock.withLock { if generation == id { inFlight = nil; generation = nil } } }
        return try await task.value
    }

    public func consume(_ operation: JSONObject, maySend: @escaping () async -> Bool) async throws -> String {
        guard mode == "live", safeText(operation["id"]) != nil,
              let key = operation["key"] as? String,
              key.range(of: "^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$", options: [.regularExpression, .caseInsensitive]) != nil,
              validIdentity(operation["identity"] as? JSONObject),
              let expiry = wholeNumber(operation["expiresAt"], min: -9_007_199_254_740_991), let start = wholeNumber(operation["startsAt"], min: -9_007_199_254_740_991), start < expiry else {
            throw RuneError("preflight-ineligible", notSent: true)
        }
        let path: String
        do { path = try await resolver.resolve() }
        catch { throw RuneError((error as? RuneError)?.code ?? "runtime-missing", notSent: true) }
        let result = try await run(path: path, operation: operation, maySend: maySend)
        guard case .outcome(let outcome) = result else { throw RuneError("protocol-error") }
        return outcome
    }

    public func close() async {
        let current = lock.withLock { () -> [AppServerSession] in
            closed = true; inFlight?.cancel()
            return Array(sessions.values)
        }
        current.forEach { $0.cancel() }
    }

    private func run(path: String, operation: JSONObject?, maySend: (() async -> Bool)?) async throws -> SessionResult {
        let id = UUID()
        let session = AppServerSession(executable: path, environment: environment, timeoutMs: timeoutMs,
                                       operation: operation, maySend: maySend, now: now)
        try lock.withLock {
            if closed { throw RuneError("read-failed", notSent: operation != nil) }
            sessions[id] = session
        }
        defer { _ = lock.withLock { sessions.removeValue(forKey: id) } }
        do { return try await session.run() }
        catch {
            if ["protocol-error", "read-failed"].contains((error as? RuneError)?.code ?? "") { await resolver.invalidate() }
            throw error
        }
    }

    static func childEnvironment(_ input: [String: String]) -> [String: String] {
        let allowed = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME",
                       "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "all_proxy", "no_proxy",
                       "SSL_CERT_FILE", "SSL_CERT_DIR"]
        var result = input.filter { allowed.contains($0.key) }
        result["HOME"] = result["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        result["PATH"] = ([result["PATH"]].compactMap { $0 } + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]).joined(separator: ":")
        return result
    }
}

private func validIdentity(_ identity: JSONObject?) -> Bool {
    guard let account = identity?["accountId"] as? String, !account.isEmpty,
          let scope = identity?["scope"] as? String, !scope.isEmpty else { return false }
    return true
}
private func identitiesEqual(_ left: JSONObject?, _ right: JSONObject?) -> Bool {
    guard validIdentity(left), validIdentity(right) else { return false }
    return rawEqual(left!["accountId"] as! String, right!["accountId"] as! String)
        && rawEqual(left!["scope"] as! String, right!["scope"] as! String)
}

private actor RuntimeResolver {
    let explicit: String?
    let environment: [String: String]
    var cached: (entry: String, resolved: String, fingerprint: String)?
    init(executable: String?, environment: [String: String]) { explicit = executable; self.environment = environment }
    func invalidate() { cached = nil }
    func resolve() async throws -> String {
        if let explicit, !explicit.hasPrefix("/") { throw RuneError("runtime-missing") }
        if let cached, let value = inspect(cached.entry), value.path == cached.resolved, value.fingerprint == cached.fingerprint { return cached.resolved }
        cached = nil
        let candidates = explicit.map { [$0] } ?? (environment["PATH", default: ""].split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }.map { $0 + "/codex" }
            + [environment["HOME", default: ""] + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"])
        var inspected = Set<String>()
        for entry in candidates {
            guard let value = inspect(entry), !inspected.contains(value.path) else { continue }
            inspected.insert(value.path)
            if let text = try? await probeVersion(executable: value.path, environment: environment), text == "codex-cli \(supportedCodexVersion)" {
                cached = (entry, value.path, value.fingerprint)
                return value.path
            }
        }
        throw RuneError(inspected.isEmpty ? "runtime-missing" : "runtime-incompatible")
    }
    private func inspect(_ entry: String) -> (path: String, fingerprint: String)? {
        var path = URL(fileURLWithPath: entry).resolvingSymlinksInPath().path
        if path.hasSuffix("/@openai/codex/bin/codex.js") {
            #if arch(arm64)
            let arch = "arm64", target = "aarch64-apple-darwin"
            #else
            let arch = "x64", target = "x86_64-apple-darwin"
            #endif
            let scope = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let native = scope.appendingPathComponent("codex-darwin-\(arch)/vendor/\(target)/bin/codex").path
            if FileManager.default.isExecutableFile(atPath: native) { path = URL(fileURLWithPath: native).resolvingSymlinksInPath().path }
        }
        guard FileManager.default.isExecutableFile(atPath: path), let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fingerprint = [attributes[.systemNumber], attributes[.systemFileNumber], attributes[.size]].map { String(describing: $0) }.joined(separator: ":") + ":" + String(modified)
        return (path, fingerprint)
    }
}

private func probeVersion(executable: String, environment: [String: String]) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["--version"]
            process.currentDirectoryURL = URL(fileURLWithPath: "/"); process.environment = environment
            process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
                defer { timeout.cancel(); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; try? output.fileHandleForReading.close() }
                var bytes = Data()
                while let data = try output.fileHandleForReading.read(upToCount: 8193), !data.isEmpty {
                    bytes.append(data)
                    if bytes.count > 8192 { throw RuneError("runtime-incompatible") }
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0, let text = String(data: bytes, encoding: .utf8) else { throw RuneError("runtime-incompatible") }
                continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch { continuation.resume(throwing: RuneError("runtime-incompatible")) }
        }
    }
}

private enum SessionResult { case snapshot(JSONObject), outcome(String) }

private final class AppServerSession: @unchecked Sendable {
    let process = Process(), input = Pipe(), output = Pipe()
    let queue = DispatchQueue(label: "local.reset-rune.codex-session", qos: .utility)
    let timeoutMs: Int, operation: JSONObject?, now: () -> Double
    let maySend: (() async -> Bool)?
    var continuation: CheckedContinuation<SessionResult, Error>?
    var timer: DispatchSourceTimer?
    var reader: DispatchSourceRead?
    var pending = Data(), expectedId = 1
    var account: JSONObject?, quota: JSONObject?
    var sent = false, settled = false
    init(executable: String, environment: [String: String], timeoutMs: Int, operation: JSONObject?, maySend: (() async -> Bool)?, now: @escaping () -> Double) {
        self.timeoutMs = timeoutMs; self.operation = operation; self.maySend = maySend; self.now = now
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://", "-c", backendOverride, "-c", "analytics.enabled=false", "-c", "mcp_servers={}"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/"); process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    }
    func run() async throws -> SessionResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    self.continuation = continuation
                    guard !self.settled else { continuation.resume(throwing: RuneError("read-failed", notSent: self.operation != nil)); return }
                    let handle = self.output.fileHandleForReading, fd = handle.fileDescriptor
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                    let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
                    reader.setEventHandler { [weak self] in self?.readOutput(fd) }
                    reader.setCancelHandler { try? handle.close() }
                    reader.resume(); self.reader = reader
                    self.process.terminationHandler = { [weak self] _ in
                        guard let self else { return }; self.queue.async { self.finish("read-failed") }
                    }
                    do { try self.process.run() } catch { self.finish("read-failed"); return }
                    self.startDeadline()
                    self.send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "reset-rune", "title": "Bottled Reset Rune", "version": "0.1.0"], "capabilities": ["experimentalApi": true]]])
                }
            }
        }, onCancel: { self.cancel() })
    }
    func cancel() { queue.async { self.finish("read-failed") } }
    func startDeadline() {
        timer?.cancel()
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + .milliseconds(timeoutMs))
        deadline.setEventHandler { [weak self] in self?.finish("timed-out") }
        deadline.resume(); timer = deadline
    }
    func finish(_ code: String? = nil, result: SessionResult? = nil) {
        guard !settled else { return }; settled = true
        timer?.cancel(); timer = nil
        reader?.cancel(); reader = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let callback = continuation; continuation = nil
        if let code { callback?.resume(throwing: RuneError(code, notSent: operation != nil && !sent)) }
        else if let result { callback?.resume(returning: result) }
    }
    func send(_ message: JSONObject) {
        guard !settled else { return }
        do { var bytes = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]); bytes.append(0x0a); try input.fileHandleForWriting.write(contentsOf: bytes) }
        catch { finish("read-failed") }
    }
    func readOutput(_ fd: Int32) {
        guard !settled else { return }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count > 0 { feed(Data(bytes.prefix(count))) }
        else if count == 0 { finish("read-failed") }
        else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { finish("read-failed") }
    }
    func feed(_ data: Data) {
        guard !settled else { return }; pending.append(data)
        while !settled, let end = pending.firstIndex(of: 0x0a) {
            let line = pending.prefix(upTo: end)
            if line.count > maxFrameBytes { finish("protocol-error"); return }
            guard let message = try? JSONSerialization.jsonObject(with: line) as? JSONObject else { finish("protocol-error"); return }
            pending.removeSubrange(...end)
            receive(message)
        }
        if !settled && pending.count > maxFrameBytes { finish("protocol-error") }
    }
    func receive(_ message: JSONObject) {
        if let method = message["method"] as? String {
            if message["id"] != nil { finish("protocol-error"); return }
            if expectedId >= 3 && method == "account/updated" { finish(operation != nil ? "identity-changed" : "read-failed") }
            return
        }
        guard wholeNumber(message["id"]) == Double(expectedId), !(expectedId == 5 && !sent) else { finish("protocol-error"); return }
        if message["error"] != nil { finish("read-failed"); return }
        guard let result = message["result"] as? JSONObject else { finish("protocol-error"); return }
        switch expectedId {
        case 1:
            expectedId = 2; send(["method": "initialized"])
            send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
        case 2:
            if let value = result["account"], !(value is NSNull), (value as? JSONObject)?["type"] as? String == nil { finish("protocol-error"); return }
            account = result["account"] as? JSONObject
            guard account?["type"] as? String == "chatgpt" else {
                if operation != nil { finish("identity-unavailable") } else { finish(result: .snapshot(normalizeCodexSnapshot(account: account, usage: nil))) }; return
            }
            expectedId = 3; send(["id": 3, "method": "account/rateLimits/read"])
        case 3:
            guard result["rateLimits"] is JSONObject else { finish("protocol-error"); return }
            if operation == nil { finish(result: .snapshot(normalizeCodexSnapshot(account: account, usage: result))); return }
            quota = result; expectedId = 4
            send(["id": 4, "method": "account/read", "params": ["refreshToken": false]])
        case 4:
            guard let current = result["account"] as? JSONObject, current["type"] as? String == "chatgpt", let email = safeText(current["email"]) else { finish("identity-unavailable"); return }
            guard let prior = account?["email"] as? String, rawEqual(email, prior) else { finish("identity-changed"); return }
            let snapshot = normalizeCodexSnapshot(account: current, usage: quota)
            expectedId = 5
            // The queued task runs only after this complete frame batch, so an
            // account-change notification already in the batch invalidates it.
            queue.async { [weak self] in
                guard let self, !self.settled else { return }
                Task {
                    let allowed = await self.maySend?() ?? false
                    self.queue.async { self.preflightAndSend(snapshot, allowed: allowed) }
                }
            }
        default:
            let outcomes = ["reset": "reset", "alreadyRedeemed": "already-redeemed", "nothingToReset": "nothing-to-reset", "noCredit": "no-credit"]
            guard let wire = result["outcome"] as? String, let outcome = outcomes[wire] else { finish("protocol-error"); return }
            finish(result: .outcome(outcome))
        }
    }
    func preflightAndSend(_ snapshot: JSONObject, allowed: Bool) {
        guard !settled, let operation else { return }
        guard validIdentity(snapshot["identity"] as? JSONObject) else { finish("identity-unavailable"); return }
        guard identitiesEqual(snapshot["identity"] as? JSONObject, operation["identity"] as? JSONObject) else { finish("identity-changed"); return }
        guard let expiry = wholeNumber(operation["expiresAt"], min: -9_007_199_254_740_991), let starts = wholeNumber(operation["startsAt"], min: -9_007_199_254_740_991) else { finish("preflight-ineligible"); return }
        let at = now()
        if at >= expiry { finish("expired"); return }; if at < starts { finish("preflight-ineligible"); return }
        let target = operation["id"] as! String
        let exists = (snapshot["credits"] as? [JSONObject] ?? []).contains { credit in
            guard let id = credit["id"] as? String else { return false }; return rawEqual(id, target) && wholeNumber(credit["expiresAt"]) == expiry
        }
        guard (wholeNumber(snapshot["availableCount"]) ?? 0) > 0, exists else { finish("credit-unavailable"); return }
        guard let remaining = wholeNumber(snapshot["redeemablePercent"], max: 100), remaining < 100 else { finish("preflight-ineligible"); return }
        guard allowed else { finish("cancelled"); return }
        sent = true; startDeadline()
        send(["id": 5, "method": "account/rateLimitResetCredit/consume", "params": ["creditId": target, "idempotencyKey": operation["key"]!]])
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
