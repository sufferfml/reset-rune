// INPUT: The menu's language/appearance model and a courier presentation model.
// OUTPUT: One reusable native management window, independent of panel visibility.
// POS: Window lifecycle only; host registration and delivery have a separate owner.
import AppKit
import Combine
import CourierCore
import SwiftUI

@MainActor
final class CourierMenuController: NSObject, NSWindowDelegate {
    let model: CourierMenuModel
    let panel: PanelModel
    private var window: NSWindow?
    private var panelChanges: AnyCancellable?
    var onWillShow: (() -> Void)?
    var isWindowVisible: Bool { window?.isVisible == true }

    init(panel: PanelModel, mock: Bool) {
        self.panel = panel
        model = CourierMenuModel(mock: mock, preview: panel.preview)
        super.init()
        panelChanges = panel.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }
    }

    func showWindow() {
        onWillShow?()
        if window == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 710),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            value.delegate = self
            value.isReleasedWhenClosed = false
            value.minSize = NSSize(width: 780, height: 600)
            value.titlebarAppearsTransparent = true
            value.contentView = NSHostingView(rootView: CourierManagementView(model: model, panel: panel))
            value.center()
            window = value
        }
        updateTitle()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.refresh()
    }

    /// Rendering fixtures are strictly in-memory and cannot discover the local service or desktop apps.
    func showPreview(editor: Bool = false) {
        guard panel.preview, panel.mock, model.mock else { return }
        do {
            let now = (Date().timeIntervalSince1970 * 1000).rounded()
            var clock = now - 180_000
            let engine = try CourierEngine(store: CourierMemoryStore(), now: { clock }, serviceEpoch: "preview-epoch",
                                           allowedBundleIDs: ["local.reset-rune.mock.codex", "local.reset-rune.mock.claude"])
            let chinese = panel.language == "zh"
            let codex = CourierTarget(agent: .codex, bundleID: "local.reset-rune.mock.codex", sourceID: "simulation",
                                      threadID: "preview-codex-chat-001", title: chinese ? "发布前检查" : "Release preparation",
                                      projectPath: "/Simulation/Example Project", appVersion: "simulation")
            let claude = CourierTarget(agent: .claude, bundleID: "local.reset-rune.mock.claude", sourceID: "simulation",
                                       threadID: "preview-claude-chat-002", title: chinese ? "发布说明" : "Release notes",
                                       projectPath: "/Simulation/Documentation", appVersion: "simulation")
            let previousText = chinese ? "整理昨日提交，列出需要继续核对的改动。" : "Summarize yesterday's commits and list changes that need another review."
            _ = try engine.create(CourierTaskDraft(name: CourierTextSummary.make(previousText),
                                                   text: previousText,
                                                   target: codex, scheduledAt: clock + 60_000))
            try engine.setEnabled(true)
            let host = try engine.registerHost(CourierHostRegistration(brokerSession: "preview-host", processID: 4242, processStartedAt: clock))
            clock += 60_000
            if let claim = try engine.claim(CourierClaimRequest(serviceEpoch: host.serviceEpoch, brokerSession: host.brokerSession)) {
                _ = try engine.beginInput(auth: claim.authorization, preflight: CourierPreflight(target: codex, messageCursor: "preview-cursor", identityVerified: true, composerEmpty: true, hostReady: true))
                _ = try engine.beginSend(auth: claim.authorization, target: codex, text: claim.run.text)
                _ = try engine.receipt(CourierReceiptRequest(authorization: claim.authorization, outcome: .unknown, reason: "receipt-unverified"))
            }
            clock = now
            let selectedText = chinese ? "请总结本周提交，按功能分组列出变化，并指出尚未验证的部分。\n只整理信息，不修改文件。" : "Summarize this week's commits by feature and identify anything that remains unverified.\nPrepare the summary without changing files."
            let selected = try engine.create(CourierTaskDraft(name: CourierTextSummary.make(selectedText),
                                                               text: selectedText,
                                                               target: codex, scheduledAt: now + 1_800_000))
            let pausedText = chinese ? "核对发布说明是否准确，列出遗漏项。" : "Check the release notes for accuracy and list any omissions."
            _ = try engine.create(CourierTaskDraft(name: CourierTextSummary.make(pausedText),
                                                   text: pausedText,
                                                   target: claude, scheduledAt: now + 5_400_000, enabled: false))
            model.accept(engine.snapshot())
            if editor { model.select(selected) }
            showWindow()
        } catch {
            // A broken fixture must not fall back to service discovery or production data.
            return
        }
    }

    @discardableResult
    func savePreviewScreenshot(to path: String) -> Bool {
        guard panel.preview, panel.mock, model.mock, path.hasPrefix("/"),
              let view = window?.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic); return true }
        catch { return false }
    }

    private func updateTitle() { window?.title = "\(CourierCopy.text("title", language: panel.language)) · Bottled Reset Rune" }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
    }

    func close() {
        window?.close()
        panelChanges?.cancel()
        model.close()
    }
}
