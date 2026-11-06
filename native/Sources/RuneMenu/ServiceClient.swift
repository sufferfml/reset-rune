// INPUT: Owner-only connection metadata and the authenticated v1 loopback API.
// OUTPUT: Snapshot reads, explicit mutations and bounded state subscriptions.
// POS: Native menu client; no access to Codex authentication or redemption RPCs.
import Foundation
import Darwin
import Combine

private final class LoopbackSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum PanelClientError: Error {
    case unavailable, insecure, protocolMismatch, malformed, service(String), cancelled
}

struct PanelConnection: Decodable, Equatable {
    let port: Int
    let token: String
    let mode: String
    let `protocol`: Int

    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/\(path)") else { throw PanelClientError.malformed }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed]) }
        return request
    }
}

final class PanelServiceClient {
    let mock: Bool
    let directory: URL
    private(set) var connection: PanelConnection?
    private let session: URLSession

    init(mock: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.mock = mock
        let base: URL
        if let explicit = environment["RESET_RUNE_DATA_DIR"].flatMap({ $0.isEmpty ? nil : $0 }) {
            base = URL(fileURLWithPath: explicit, isDirectory: true).standardizedFileURL
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bottled Reset Rune", isDirectory: true)
        }
        directory = mock ? base.appendingPathComponent("simulation", isDirectory: true) : base
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: LoopbackSessionDelegate(), delegateQueue: nil)
    }

    func discover() throws -> PanelConnection {
        var directoryStat = stat()
        guard lstat(directory.path, &directoryStat) == 0 else { throw PanelClientError.unavailable }
        guard directoryStat.st_mode & S_IFMT == S_IFDIR, directoryStat.st_uid == getuid(), directoryStat.st_mode & 0o077 == 0 else { throw PanelClientError.insecure }
        let path = directory.appendingPathComponent("connection.json").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw PanelClientError.unavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 8192 else { throw PanelClientError.insecure }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let capacity = bytes.count
        var offset = 0
        while offset < capacity {
            let count = bytes.withUnsafeMutableBytes { pointer in
                Darwin.read(fd, pointer.baseAddress!.advanced(by: offset), capacity - offset)
            }
            guard count > 0 else { throw PanelClientError.malformed }
            offset += count
        }
        let result = try JSONDecoder().decode(PanelConnection.self, from: Data(bytes))
        guard result.protocol == 1, (1024...65535).contains(result.port), result.mode == (mock ? "mock" : "readonly"),
              result.token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { throw PanelClientError.protocolMismatch }
        connection = result
        return result
    }

    func read(_ path: String = "status", method: String = "GET", body: [String: Any]? = nil) async throws -> PanelState {
        let active = try connection ?? discover()
        let (data, response) = try await session.data(for: active.request(path, method: method, body: body))
        guard let response = response as? HTTPURLResponse, data.count <= 1_048_576 else { throw PanelClientError.malformed }
        guard response.statusCode == 200 else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "service-error"
            throw PanelClientError.service(code)
        }
        return try JSONDecoder().decode(PanelState.self, from: data)
    }

    func subscribe(receive: @escaping @MainActor (PanelState) -> Void) async throws {
        let active = try discover()
        var request = try active.request("events")
        request.timeoutInterval = 7 * 24 * 3600
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw PanelClientError.malformed }
        guard response.statusCode == 200 else {
            if response.statusCode == 404 { throw PanelClientError.protocolMismatch }
            throw PanelClientError.unavailable
        }
        var line = Data()
        var event = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                if line.isEmpty {
                    if !event.isEmpty {
                        if event.last == 10 { event.removeLast() }
                        let state = try JSONDecoder().decode(PanelState.self, from: event)
                        await receive(state)
                        event.removeAll(keepingCapacity: true)
                    }
                } else if line.starts(with: Data("data:".utf8)) {
                    var payload = line.dropFirst(5)
                    if payload.first == 32 { payload = payload.dropFirst() }
                    event.append(contentsOf: payload)
                    event.append(10)
                    guard event.count <= 1_048_576 else { throw PanelClientError.malformed }
                }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
                guard line.count <= 1_048_576 else { throw PanelClientError.malformed }
            }
        }
        throw PanelClientError.unavailable
    }

    func startHelper() async throws {
        let explicit = ProcessInfo.processInfo.environment["RESET_RUNE_HELPER_PATH"].map { URL(fileURLWithPath: $0) }
        let helper = explicit ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Bottled Reset Rune Service.app/Contents/MacOS/reset-rune")
        guard helper.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: helper.path) else { throw PanelClientError.unavailable }
        let isMock = mock
        try await Task.detached {
            let child = Process()
            child.executableURL = helper
            child.arguments = (isMock ? ["--mock"] : []) + ["start"]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            let timeout = DispatchWorkItem { if child.isRunning { child.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
            child.waitUntilExit()
            timeout.cancel()
            guard child.terminationStatus == 0 else { throw PanelClientError.unavailable }
        }.value
        connection = nil
    }

    func resetConnection() { connection = nil }
    func close() { session.invalidateAndCancel() }
}

@MainActor
final class PanelModel: ObservableObject {
    struct Confirmation {
        let kind: String
        let consent: String
        let identity: PanelIdentity
        let lead: Int
    }

    @Published private(set) var state: PanelState?
    @Published var panel: String?
    @Published private(set) var connectionState = "connecting"
    @Published private(set) var pending: String?
    @Published var confirmation: Confirmation?
    @Published private(set) var feedback: String?
    @Published private(set) var visibleNow = Date()
    var onPresentationChanged: (() -> Void)?
    var onHeightChanged: ((CGFloat) -> Void)?
    let mock: Bool
    let preview: Bool
    private let client: PanelServiceClient
    private var subscription: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var refreshInFlight = false
    private var timeBoundary: Task<Void, Never>?
    private var visible = false

    init(mock: Bool, previewFile: URL? = nil) {
        self.mock = mock
        preview = previewFile != nil
        client = PanelServiceClient(mock: mock)
        if mock, let previewFile, let data = try? Data(contentsOf: previewFile), let result = try? JSONDecoder().decode(PanelState.self, from: data) {
            state = result
            connectionState = ""
        }
    }

    var config: PanelConfig { state?.config ?? PanelConfig() }
    var dataDirectory: URL { client.directory }
    var language: String { config.language == "zh" ? "zh" : "en" }
    var bottle: PanelState.Bottle { state?.bottle(disconnected: !connectionState.isEmpty, now: now) ?? .unknown }
    var canAct: Bool { state != nil && connectionState.isEmpty && pending == nil && !preview }
    var now: Double { visibleNow.timeIntervalSince1970 * 1000 }
    var next: PanelCredit? { bottle == .stored ? state?.nextCredit(now: now) : nil }
    var isExpiring: Bool { next.map { $0.expiresAt! - now <= Double(config.lead) * 60_000 } ?? false }
    var identity: PanelIdentity? { state?.snapshot?.identity }
    var account: String { identity?.email ?? text(identity == nil ? "noIdentity" : "detected") }
    var workspace: String {
        guard let id = identity?.accountId, !id.isEmpty else { return text("localLogin") }
        return language == "zh" ? "工作区 …\(id.suffix(6))" : "Workspace …\(id.suffix(6))"
    }
    var statusLabel: String {
        if pending == "refresh" { return PanelCopy.status("checking", language: language) }
        if !connectionState.isEmpty { return text(connectionState) }
        guard let state else { return text("connecting") }
        if state.status == "error", let error = state.error { return PanelCopy.status(error, language: language) }
        let normal: Set<String> = ["idle", "ready", "disabled", "waiting", "outside-window"]
        let key = !config.enabled && normal.contains(state.status) ? "disabled" : state.status
        return PanelCopy.status(key, language: language, mock: mock)
    }
    var countLabel: String {
        guard bottle == .stored, let count = state?.snapshot?.availableCount else { return "" }
        return language == "zh" ? "\(count) 枚重置神符" : "\(count) Reset Rune\(count == 1 ? "" : "s")"
    }
    var expiryLabel: String {
        guard let expiry = next?.expiresAt else { return text(bottle == .stored ? "unknownExpiry" : bottle.rawValue) }
        return PanelCopy.date(expiry, language: language, now: visibleNow)
    }
    var expiryHeading: String {
        guard next != nil else { return text("rune") }
        return text(isExpiring ? "fading" : incompleteInventory ? "knownNext" : "next")
    }
    var incompleteInventory: Bool {
        guard let count = state?.snapshot?.availableCount else { return true }
        return (state?.snapshot?.credits ?? []).filter { validEpoch($0.expiresAt) && $0.expiresAt! > now }.count < count
    }
    func text(_ key: String) -> String { PanelCopy.text(key, language: language) }
    func leadLabel(_ value: Int) -> String { language == "zh" ? (value == 60 ? "1 小时" : "\(value) 分钟") : (value == 60 ? "1 hour" : "\(value) minutes") }

    func connect() {
        guard !preview, startup == nil else { return }
        startup = Task { [weak self] in
            guard let self else { return }
            defer { startup = nil }
            do {
                do { accept(try await client.read()) }
                catch PanelClientError.insecure { throw PanelClientError.insecure }
                catch {
                    try await client.startHelper()
                    accept(try await client.read())
                }
                startSubscription()
            } catch { connectionState = state == nil ? "disconnected" : "stale"; presentationChanged() }
        }
    }

    func reconnect() {
        guard !preview else { return }
        subscription?.cancel()
        client.resetConnection()
        connectionState = state == nil ? "connecting" : "stale"
        connect()
    }

    func didShow() {
        visible = true
        visibleNow = Date()
        if state == nil || !connectionState.isEmpty { connect() }
        else if !preview { refresh() }
        scheduleVisibleBoundary()
    }

    func didHide() {
        visible = false
        timeBoundary?.cancel()
        timeBoundary = nil
        confirmation = nil
    }

    func togglePanel(_ name: String) { panel = panel == name ? nil : name }
    func requestLayout() { objectWillChange.send() }
    func change(_ field: String, _ value: Any) { mutate(path: "config", method: "PATCH", body: [field: value], kind: "save") }
    func refresh() {
        guard !refreshInFlight, pending == nil, !preview else { return }
        if state == nil || !connectionState.isEmpty { reconnect(); return }
        mutate(path: "refresh", method: "POST", body: nil, kind: "refresh")
    }

    func setEnabled(_ value: Bool) {
        guard canAct else { return }
        if !value { change("enabled", false); return }
        if state?.mode == "mock" { change("enabled", true); return }
        askConsent("enable")
    }

    func bind() {
        guard canAct else { return }
        if config.enabled { feedback = "pauseFirst"; return }
        if state?.mode == "mock" { mutate(path: "bind", method: "POST", body: nil, kind: "bind"); return }
        askConsent("bind")
    }

    private func askConsent(_ kind: String) {
        guard state?.mode == "live", let consent = state?.consent, let identity,
              !(identity.accountId ?? "").isEmpty, !(identity.scope ?? "").isEmpty else { feedback = "identityUnavailable"; return }
        feedback = nil
        confirmation = Confirmation(kind: kind, consent: consent, identity: identity, lead: config.lead)
    }

    func confirm() {
        guard let confirmation else { return }
        self.confirmation = nil
        guard canAct, state?.consent == confirmation.consent, identity == confirmation.identity, config.lead == confirmation.lead else { feedback = "consentRequired"; return }
        if confirmation.kind == "bind" { mutate(path: "bind", method: "POST", body: ["consent": confirmation.consent], kind: "bind") }
        else { mutate(path: "config", method: "PATCH", body: ["enabled": true, "consent": confirmation.consent], kind: "save") }
    }

    private func mutate(path: String, method: String, body: [String: Any]?, kind: String) {
        guard !preview, pending == nil else { return }
        pending = kind
        feedback = nil
        refreshInFlight = kind == "refresh"
        Task { [weak self] in
            guard let self else { return }
            defer { pending = nil; refreshInFlight = false }
            do { accept(try await client.read(path, method: method, body: body)) }
            catch PanelClientError.service(let code) {
                let messages = ["binding-required": "bindRequired", "identity-unavailable": "identityUnavailable", "consent-required": "consentRequired", "pause-first": "pauseFirst"]
                feedback = messages[code] ?? (kind == "refresh" ? "refreshFailed" : "saveFailed")
            } catch { feedback = kind == "refresh" ? "refreshFailed" : "saveFailed" }
        }
    }

    private func accept(_ result: PanelState) {
        state = result
        connectionState = ""
        visibleNow = Date()
        if let confirmation, result.consent != confirmation.consent || result.snapshot?.identity != confirmation.identity || result.config.lead != confirmation.lead {
            self.confirmation = nil
            feedback = "consentRequired"
        }
        presentationChanged()
        scheduleVisibleBoundary()
    }

    private func startSubscription() {
        subscription?.cancel()
        subscription = Task { [weak self] in
            guard let self else { return }
            // Only connection failures schedule retries; no steady-state heartbeat/poll.
            for delay in [0, 1, 5, 15] {
                if Task.isCancelled { return }
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
                if Task.isCancelled { return }
                do { try await client.subscribe { [weak self] state in self?.accept(state) } }
                catch is CancellationError { return }
                catch PanelClientError.protocolMismatch { feedback = "upgrade"; presentationChanged(); return }
                catch { connectionState = "stale"; presentationChanged() }
            }
        }
    }

    private func presentationChanged() { onPresentationChanged?() }

    private func scheduleVisibleBoundary() {
        timeBoundary?.cancel()
        timeBoundary = nil
        guard visible, let expiry = next?.expiresAt else { return }
        let start = expiry - Double(config.lead) * 60_000
        let midnight = Calendar.current.startOfDay(for: visibleNow).addingTimeInterval(24 * 3600).timeIntervalSince1970 * 1000
        let nextBoundary = [start, expiry, midnight].filter { $0 > now }.min()
        guard let nextBoundary else { return }
        let wait = max(0.1, (nextBoundary - now) / 1000)
        timeBoundary = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self, visible else { return }
            visibleNow = Date()
            presentationChanged()
            scheduleVisibleBoundary()
        }
    }

    func close() { subscription?.cancel(); startup?.cancel(); timeBoundary?.cancel(); client.close() }
}
