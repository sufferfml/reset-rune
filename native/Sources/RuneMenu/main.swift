// INPUT: The native menu model, original bundle resources and local service.
// OUTPUT: A small macOS status item and disposable settings panel.
// POS: GUI entry point. The launchd service has an independent lifecycle.
import AppKit
import SwiftUI
import Darwin
import Combine

private final class RunePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
private final class MenuApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: PanelModel
    private var statusItem: NSStatusItem?
    private var window: RunePanel?
    private var observers: [NSObjectProtocol] = []
    private var lockFD: Int32 = -1
    private var peerPID: pid_t?
    private var desiredHeight: CGFloat = 340
    private var quitting = false
    private var suppressedStartupActivation = false
    private var screenshotPath: String?
    private var screenshotTask: Task<Void, Never>?
    private var hostingView: NSHostingView<PanelView>?
    private let startHidden: Bool
    private var resetScrollToTop = false
    private var modelChanges: AnyCancellable?
    private var measurement: DispatchWorkItem?

    init(mock: Bool, preview: URL?, screenshot: String?, initialPanel: String?, startHidden: Bool) {
        model = PanelModel(mock: mock, previewFile: preview)
        screenshotPath = screenshot
        self.startHidden = startHidden
        super.init()
        model.panel = initialPanel
        model.onPresentationChanged = { [weak self] in self?.updatePresentation() }
        model.onHeightChanged = { [weak self] height in self?.resize(height) }
        modelChanges = model.objectWillChange.sink { [weak self] _ in self?.queueMeasurement() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if !model.preview, !acquireLock() {
            // Activate a native peer by its explicit known executable identity.
            if let peerPID, let peer = NSRunningApplication(processIdentifier: peerPID), peerPID != getpid(),
               let url = peer.bundleURL, let bundle = Bundle(url: url), bundle.object(forInfoDictionaryKey: "BottledResetRuneNative") as? Bool == true {
                peer.activate(options: [.activateIgnoringOtherApps])
            }
            NSApp.terminate(nil)
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let applicationMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationSubmenu = NSMenu()
        let quitItem = NSMenuItem(title: model.text("quit"), action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        applicationSubmenu.addItem(quitItem)
        applicationItem.submenu = applicationSubmenu
        applicationMenu.addItem(applicationItem)
        NSApp.mainMenu = applicationMenu
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updatePresentation()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.quitting else { return }
                if self.startHidden && !self.suppressedStartupActivation { self.suppressedStartupActivation = true; return }
                if self.window?.isVisible != true { self.show() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.position() }
        })
        model.connect()
        if !startHidden { show() }
        if screenshotPath != nil, model.preview {
            screenshotTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled, let self else { return }
                savePreviewScreenshot()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return false }

    private func acquireLock() -> Bool {
        let directory = model.dataDirectory
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return false }
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o077 == 0 else { return false }
        let fd = open(directory.appendingPathComponent("menu.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return false }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(fd); return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            var bytes = [UInt8](repeating: 0, count: 32)
            let length = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if length > 0, let text = String(bytes: bytes.prefix(length), encoding: .utf8) { peerPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            close(fd)
            return false
        }
        let owner = Data("\(getpid())\n".utf8)
        _ = ftruncate(fd, 0)
        _ = owner.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        lockFD = fd
        return true
    }

    @objc private func clicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp { contextMenu(); return }
        if window?.isVisible == true { hide() } else { show() }
    }

    @objc private func openPanel(_ sender: Any?) { show() }
    @objc private func reconnect(_ sender: Any?) { model.reconnect(); show() }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    private func contextMenu() {
        let menu = NSMenu()
        for (title, selector) in [(model.text("open"), #selector(openPanel(_:))), (model.text("reconnect"), #selector(reconnect(_:)))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let detail = NSMenuItem(title: model.text("quitNote"), action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        let quitItem = NSMenuItem(title: model.text("quit"), action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func updatePresentation() {
        NSApp.mainMenu?.items.first?.submenu?.items.first?.title = model.text("quit")
        let names: [PanelState.Bottle: String] = [.stored: "trayTemplate", .empty: "trayEmptyTemplate", .unknown: "trayUnknownTemplate"]
        if let resource = Bundle.main.resourceURL,
           let image = NSImage(contentsOf: resource.appendingPathComponent("\(names[model.bottle]!).png")) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            statusItem?.button?.image = image
            statusItem?.button?.title = ""
        } else {
            statusItem?.button?.image = NSImage(systemSymbolName: model.bottle == .stored ? "drop.fill" : "drop", accessibilityDescription: "Bottled Reset Rune")
        }
        let stateLabel = model.text(model.bottle.rawValue)
        statusItem?.button?.toolTip = "Bottled Reset Rune · \(stateLabel)\(model.mock ? " · \(model.text("mock"))" : "")"
        statusItem?.button?.setAccessibilityLabel("Bottled Reset Rune")
        statusItem?.button?.setAccessibilityValue(stateLabel)
        switch model.config.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    private func makeWindow() -> RunePanel {
        let panel = RunePanel(contentRect: NSRect(x: 0, y: 0, width: 368, height: desiredHeight), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.onEscape = { [weak self] in self?.hide() }
        return panel
    }

    private func show() {
        guard !quitting else { return }
        if window == nil { window = makeWindow() }
        if hostingView == nil {
            let host = NSHostingView(rootView: PanelView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 368, height: desiredHeight)
            host.autoresizingMask = [.width]
            let scroll = NSScrollView(frame: host.frame)
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.documentView = host
            scroll.autoresizingMask = [.width, .height]
            hostingView = host
            window?.contentView = scroll
            resetScrollToTop = true
        }
        position()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.didShow()
        queueMeasurement()
        if CommandLine.arguments.contains("--diagnose-ui"), model.preview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                let report = "window=\(String(describing: self.window?.frame)) visible=\(self.window?.isVisible ?? false) view=\(String(describing: self.window?.contentView)) fitting=\(String(describing: self.window?.contentView?.fittingSize))\n"
                FileHandle.standardError.write(Data(report.utf8))
            }
        }
    }

    private func hide() {
        if CommandLine.arguments.contains("--diagnose-ui"), model.preview { FileHandle.standardError.write(Data("hide\n".utf8)) }
        model.didHide()
        window?.orderOut(nil)
        // The status item/model retain no SwiftUI tree or decoded bottle images.
        window?.contentView = nil
        hostingView = nil
        measurement?.cancel()
    }

    private func resize(_ height: CGFloat) {
        guard height.isFinite, height >= 100, height <= 2000 else { return }
        let scroll = window?.contentView as? NSScrollView
        let oldTop = hostingView?.isFlipped == true ? 0 : max(0, desiredHeight - (scroll?.contentSize.height ?? desiredHeight))
        let wasAtTop = abs((scroll?.contentView.bounds.origin.y ?? 0) - oldTop) < 1
        desiredHeight = height
        position()
        hostingView?.setFrameSize(NSSize(width: 368, height: height))
        if let scroll, resetScrollToTop || wasAtTop {
            let top = hostingView?.isFlipped == true ? 0 : max(0, height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
            scroll.reflectScrolledClipView(scroll.contentView)
            resetScrollToTop = false
        }
    }

    private func queueMeasurement() {
        measurement?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window?.isVisible == true, let host = self.hostingView else { return }
            host.layoutSubtreeIfNeeded()
            self.resize(host.fittingSize.height)
        }
        measurement = work
        DispatchQueue.main.async(execute: work)
    }

    private func position() {
        guard let window, let button = statusItem?.button, let buttonWindow = button.window else { return }
        let tray = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let work = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = min(desiredHeight, work.height - 16)
        let x = min(max(work.minX + 8, tray.midX - 184), work.maxX - 376)
        let y = max(work.minY + 8, tray.minY - height - 7)
        window.setFrame(NSRect(x: x, y: y, width: 368, height: height), display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        if !quitting { hide() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }

    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        screenshotTask?.cancel()
        measurement?.cancel()
        modelChanges?.cancel()
        model.close()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if lockFD >= 0 { close(lockFD) }
    }

    private func savePreviewScreenshot() {
        guard let path = screenshotPath, path.hasPrefix("/"), model.preview,
              let view = hostingView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        if CommandLine.arguments.contains("--quit-after-screenshot") { NSApp.terminate(nil) }
    }
}

let arguments = CommandLine.arguments
let mockOnlyBundle = Bundle.main.object(forInfoDictionaryKey: "BottledResetRuneMockOnly") as? Bool == true
let mock = arguments.contains("--mock") || mockOnlyBundle
func argument(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}
let bundledPreview = mockOnlyBundle ? Bundle.main.object(forInfoDictionaryKey: "BottledResetRunePreviewFile") as? String : nil
let previewFile = mock ? (argument(after: "--preview") ?? bundledPreview).map { URL(fileURLWithPath: $0) } : nil
let screenshot = mock ? argument(after: "--screenshot") : nil
let initialPanel = mock ? argument(after: "--panel").flatMap { ["credits", "activity", "settings"].contains($0) ? $0 : nil } : nil
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let applicationDelegate = MenuApplication(mock: mock, preview: previewFile, screenshot: screenshot, initialPanel: initialPanel, startHidden: arguments.contains("--start-hidden"))
    application.delegate = applicationDelegate
    withExtendedLifetime(applicationDelegate) { application.run() }
}
