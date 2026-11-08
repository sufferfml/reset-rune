// INPUT: Owner-only service metadata and explicit CourierCore requests.
// OUTPUT: Authenticated courier snapshots; no desktop input or Agent execution.
// POS: Menu-side courier transport. See docs/courier-technical-design.md.
import Foundation
import CourierCore

private final class CourierSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class CourierServiceClient {
    private let discovery: PanelServiceClient
    private let session: URLSession

    init(mock: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) {
        discovery = PanelServiceClient(mock: mock, environment: environment)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 25
        session = URLSession(configuration: configuration, delegate: CourierSessionDelegate(), delegateQueue: nil)
    }

    func request<Response: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, as: Response.Type = Response.self) async throws -> Response {
        // Discover for every request so a restarted service never receives an old token.
        let connection = try discovery.discover()
        let (data, response) = try await session.data(for: connection.request(path, method: method, body: body))
        guard let response = response as? HTTPURLResponse, data.count <= CourierLimits.hardBytes else { throw PanelClientError.malformed }
        guard response.statusCode == 200 else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "service-error"
            throw PanelClientError.service(code)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    func snapshot() async throws -> CourierSnapshot { try await request("courier/status") }

    func subscribeChanges(onChange: @escaping @MainActor () -> Void) async throws {
        let connection = try discovery.discover()
        var request = try connection.request("events")
        request.timeoutInterval = 7 * 24 * 3600
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw PanelClientError.unavailable }
        var line = Data()
        var event = Data()
        var lastRevision: Int?
        var lastEpoch: String?
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                if line.isEmpty {
                    if !event.isEmpty {
                        if event.last == 10 { event.removeLast() }
                        if let root = try JSONSerialization.jsonObject(with: event) as? [String: Any],
                           let courier = root["courier"] as? [String: Any], let revision = courier["revision"] as? Int {
                            let epoch = courier["serviceEpoch"] as? String
                            if lastRevision != revision || lastEpoch != epoch {
                                lastRevision = revision; lastEpoch = epoch
                                await onChange()
                            }
                        }
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

    func save(_ draft: CourierTaskDraft, id: String? = nil, revision: Int? = nil) async throws -> CourierSnapshot {
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any] ?? [:]
        if let revision { body["expectedRevision"] = revision }
        return try await request(id.map { "courier/tasks/\($0)" } ?? "courier/tasks", method: id == nil ? "POST" : "PATCH", body: body)
    }

    func taskAction(_ task: CourierTask, action: String) async throws -> CourierSnapshot {
        let path = "courier/tasks/\(task.id)" + (action == "delete" ? "" : "/\(action)")
        var body: [String: Any] = ["expectedRevision": task.revision]
        if action == "copy" {
            let scheduledAt = (Date().addingTimeInterval(300).timeIntervalSince1970 * 1000).rounded()
            body["scheduledAt"] = scheduledAt
            body["deadlineAt"] = scheduledAt + CourierLimits.defaultDeliveryGraceMilliseconds
        }
        return try await request(path, method: action == "delete" ? "DELETE" : "POST", body: body)
    }

    func setEnabled(_ enabled: Bool) async throws -> CourierSnapshot {
        try await request("courier/settings", method: "PATCH", body: ["enabled": enabled])
    }

    func confirm(_ runID: String, sent: Bool) async throws -> CourierSnapshot {
        try await request("courier/runs/\(runID)/confirm", method: "POST", body: ["sent": sent])
    }

    func close() { discovery.close(); session.invalidateAndCancel() }
}
