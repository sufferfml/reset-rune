// INPUT: Explicit user drafts, authenticated snapshots and desktop discovery.
// OUTPUT: Courier window state and reviewed task mutations; never sends desktop text.
// POS: Menu presentation boundary. See docs/courier-development-plan.md.
import AppKit
import Combine
import CourierCore
import DesktopAutomation
import Foundation

struct CourierEditorDraft {
    enum TimeMode: String, CaseIterable { case absolute, relative }
    var id: String?
    var revision: Int?
    var text = ""
    var agent = CourierAgent.codex
    var target: CourierTarget?
    var timeMode = TimeMode.absolute
    var date = Date().addingTimeInterval(300)
    var delayMinutes = 30

    init() {}
    init(task: CourierTask, now: Date = Date()) {
        id = task.id; revision = task.revision; text = task.text
        agent = task.target.agent; target = task.target
        date = Date(timeIntervalSince1970: task.scheduledAt / 1000)
        if date <= now || task.needsReschedule { date = now.addingTimeInterval(300) }
    }

    func scheduledDate(now: Date) -> Date {
        if timeMode == .relative { return now.addingTimeInterval(Double(delayMinutes) * 60) }
        // The native picker shows hours/minutes; do not retain invisible seconds from its initial Date.
        return Calendar.current.dateInterval(of:.minute,for:date)?.start ?? date
    }

    func validated(now: Date) throws -> CourierTaskDraft {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= CourierLimits.maximumTextBytes else { throw CourierError("courier-text-invalid") }
        guard let target, target.agent == agent, !target.threadID.isEmpty, !target.sourceID.isEmpty else { throw CourierError("courier-target-required") }
        guard timeMode != .relative || (1...525_600).contains(delayMinutes) else { throw CourierError("courier-time-invalid") }
        let scheduled = (scheduledDate(now: now).timeIntervalSince1970 * 1000).rounded()
        guard scheduled.isFinite, scheduled > now.timeIntervalSince1970 * 1000 else { throw CourierError("courier-time-invalid") }
        return CourierTaskDraft(name: CourierTextSummary.make(text), text: text, target: target, scheduledAt: scheduled,
                                deadlineAt: scheduled + CourierLimits.defaultDeliveryGraceMilliseconds,
                                timeZoneID: TimeZone.current.identifier, enabled: true)
    }
}

enum CourierPermissionPolicy {
    static func requestsAccessibility(enabling: Bool, mock: Bool, compatibility: DesktopCompatibility) -> Bool {
        enabling && !mock && compatibility.canSend && compatibility.requiresAccessibility
    }
}

@MainActor
final class CourierMenuModel: ObservableObject {
    @Published private(set) var snapshot: CourierSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var discovering = false
    @Published private(set) var errorCode: String?
    @Published private(set) var targets: [CourierTarget] = []
    @Published private(set) var compatibility: DesktopCompatibility?
    @Published private(set) var hasMoreTargets = false
    @Published private(set) var targetSearchPerformed = false
    @Published var targetQuery = "" {
        didSet { if targetQuery != oldValue { invalidateDiscovery() } }
    }
    @Published var editor: CourierEditorDraft?
    @Published var selectedRunID: String?
    @Published var section = "tasks"
    let client: CourierServiceClient
    let mock: Bool
    let preview: Bool
    var onSnapshot: ((CourierSnapshot) -> Void)?
    private var operation: Task<Void, Never>?
    private var adapters: [String: any DesktopAdapter] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var discoveryGeneration: UInt64 = 0
    private let adapterFactory: ((CourierAgent) -> any DesktopAdapter)?

    init(mock: Bool, preview: Bool = false, adapterFactory: ((CourierAgent) -> any DesktopAdapter)? = nil) {
        self.mock = mock; self.preview = preview
        self.adapterFactory = adapterFactory
        client = CourierServiceClient(mock: mock)
    }

    var tasks: [CourierTask] { (snapshot?.tasks ?? []).sorted { $0.scheduledAt < $1.scheduledAt } }
    var runs: [CourierRun] { (snapshot?.runs ?? []).sorted { $0.updatedAt > $1.updatedAt } }
    var selectedRun: CourierRun? { runs.first { $0.id == selectedRunID } }
    var pendingTasks: [CourierTask] { tasks.filter { $0.enabled && $0.lifecycle == .scheduled } }
    var unresolvedCount: Int { runs.filter(\.unresolvedUnknown).count }
    var canEnableTarget: Bool {
        guard let target = editor?.target else { return false }
        return compatibility?.agent.rawValue == target.agent.rawValue && compatibility?.canSend == true
    }
    var showsAccessibilityNote: Bool { canEnableTarget && compatibility?.requiresAccessibility == true }
    var canSave: Bool { canEnableTarget && !busy && !discovering && !selectedTaskLocked }
    var codexNeedsLiveValidation: Bool {
        editor?.agent == .codex && compatibility?.blockers.contains(where: { $0.rawValue == "liveValidationRequired" }) == true
    }
    var selectedTaskLocked: Bool {
        guard let id = editor?.id else { return false }
        return tasks.first { $0.id == id }?.lifecycle == .completed || runs.contains { $0.taskID == id && [.preparing, .dispatching].contains($0.status) }
    }

    func accept(_ value: CourierSnapshot) {
        guard value.courierProtocol == 1 else { errorCode = "courier-protocol-mismatch"; return }
        if let current=snapshot,current.serviceEpoch==value.serviceEpoch,current.revision>value.revision { return }
        snapshot = value
        onSnapshot?(value)
    }

    func refresh() {
        guard !preview, !busy else { return }
        perform { [self] in accept(try await client.snapshot()) }
    }

    func newTask() {
        invalidateDiscovery(); targetQuery = ""
        section = "tasks"; editor = CourierEditorDraft(); targets = []; compatibility = nil; errorCode = nil
    }
    func select(_ task: CourierTask) {
        invalidateDiscovery(); targetQuery = ""
        section = "tasks"; editor = CourierEditorDraft(task: task); targets = [task.target]
        compatibility = adapter(task.target.agent).compatibility(); errorCode = nil
    }
    func clearError() { errorCode = nil }

    func discoverTargets() {
        guard !preview, let agent = editor?.agent else { return }
        invalidateDiscovery()
        let generation = discoveryGeneration
        let query = targetQuery
        discovering = true; errorCode = nil
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == discoveryGeneration { discovering = false; discoveryTask = nil }
            }
            do {
                let result = try await adapter(agent).discoverTargets(matching: query.trimmingCharacters(in: .whitespacesAndNewlines))
                guard !Task.isCancelled, generation == discoveryGeneration,
                      editor?.agent == agent, targetQuery == query else { return }
                targets = result.targets.map(Self.target)
                compatibility = result.compatibility
                hasMoreTargets = result.hasMore
                targetSearchPerformed = true
                if let current = editor?.target, !targets.contains(where: { $0.key == current.key }) { targets.insert(current, at: 0) }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, generation == discoveryGeneration else { return }
                errorCode = Self.code(error)
            }
        }
    }

    func changeAgent(_ agent: CourierAgent) {
        invalidateDiscovery(); targetQuery = ""
        editor?.agent = agent; editor?.target = nil; targets = []; compatibility = nil
    }

    private func invalidateDiscovery() {
        discoveryGeneration &+= 1
        discoveryTask?.cancel(); discoveryTask = nil
        discovering = false; hasMoreTargets = false; targetSearchPerformed = false
        targets = editor?.target.map { [$0] } ?? []
    }

    func save() {
        guard !preview, !busy, !discovering, let editor, !selectedTaskLocked else { return }
        do {
            let draft = try editor.validated(now: Date())
            let assessment = adapter(draft.target.agent).compatibility()
            if !assessment.canSend {
                throw CourierError(assessment.blockers.contains(where: { $0.rawValue == "liveValidationRequired" }) ? "liveValidationRequired" : "courier-desktop-unsupported")
            }
            // Saving explicitly authorizes this task and courier; permission follows the selected route.
            if CourierPermissionPolicy.requestsAccessibility(enabling: true, mock: mock, compatibility: assessment), !DesktopAccessibility.isTrusted {
                _ = DesktopAccessibility.requestAccess()
                throw CourierError("courier-accessibility-required")
            }
            let previousIDs = Set(tasks.map(\.id))
            perform { [self] in
                let result = try await client.save(draft, id: editor.id, revision: editor.revision)
                accept(result)
                if !result.enabled {
                    do { accept(try await client.setEnabled(true)) }
                    catch {
                        // Keep the server-assigned identity/revision, so retry updates this task.
                        let saved: CourierTask?
                        if let id = editor.id { saved = result.tasks.first { $0.id == id } }
                        else {
                            let matches = result.tasks.filter {
                                !previousIDs.contains($0.id) && $0.target.isSameConversation(as: draft.target) &&
                                Array($0.text.utf8) == Array(draft.text.utf8) && $0.scheduledAt == draft.scheduledAt && $0.deadlineAt == draft.deadlineAt
                            }
                            saved = matches.count == 1 ? matches[0] : nil
                        }
                        self.editor = saved.map { CourierEditorDraft(task: $0) }
                        errorCode = "courier-saved-paused"
                        return
                    }
                }
                self.editor = nil
            }
        } catch { errorCode = Self.code(error) }
    }

    func pause(_ task: CourierTask) {
        perform { [self] in accept(try await client.taskAction(task, action: "pause")) }
    }

    func resume(_ task: CourierTask) {
        // Re-review the target and future time instead of silently sending on resume.
        select(task)
    }

    func copy(_ task: CourierTask) {
        let existing = Set(tasks.map(\.id))
        perform { [self] in
            let result = try await client.taskAction(task, action: "copy")
            accept(result)
            if let copy = result.tasks.first(where: { !existing.contains($0.id) }) { select(copy) }
        }
    }

    func delete(_ task: CourierTask) {
        perform { [self] in
            accept(try await client.taskAction(task, action: "delete"))
            if editor?.id == task.id { editor = nil }
        }
    }

    func setEnabled(_ enabled: Bool) {
        perform { [self] in accept(try await client.setEnabled(enabled)) }
    }

    func confirm(_ run: CourierRun, sent: Bool) {
        perform { [self] in accept(try await client.confirm(run.id, sent: sent)) }
    }

    func open(_ target: CourierTarget) {
        guard !preview else { return }
        perform { [self] in try await adapter(target.agent).openTarget(Self.desktopTarget(target)) }
    }

    func requestAccessibility() {
        guard !mock, !preview, showsAccessibilityNote else { return }
        _ = DesktopAccessibility.requestAccess()
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy, !preview else { return }
        busy = true; errorCode = nil
        operation = Task { [weak self] in
            defer { self?.busy = false; self?.operation = nil }
            do { try await work() }
            catch is CancellationError { }
            catch { self?.errorCode = Self.code(error) }
        }
    }

    private func adapter(_ agent: CourierAgent) -> any DesktopAdapter {
        if let existing = adapters[agent.rawValue] { return existing }
        let value = adapterFactory?(agent) ?? DesktopAdapters.make(agent: agent == .codex ? .codex : .claude, mock: mock)
        adapters[agent.rawValue] = value
        return value
    }
    static func target(_ value: DesktopTarget) -> CourierTarget {
        CourierTarget(agent: value.agent == .codex ? .codex : .claude, bundleID: value.bundleID, sourceID: value.sourceID,
                      threadID: value.id, title: value.title, projectPath: value.project, appVersion: value.appVersion)
    }
    static func desktopTarget(_ value: CourierTarget) -> DesktopTarget {
        DesktopTarget(agent: value.agent == .codex ? .codex : .claude, id: value.threadID, title: value.title, project: value.projectPath,
                      sourceID: value.sourceID, bundleID: value.bundleID, appVersion: value.appVersion ?? "")
    }
    static func code(_ error: Error) -> String {
        if let error = error as? CourierError { return error.code }
        if let error = error as? DesktopBlockReason { return error.rawValue }
        if case PanelClientError.service(let code) = error { return code }
        return "courier-service-unavailable"
    }
    func close() { invalidateDiscovery(); operation?.cancel(); client.close() }
}
