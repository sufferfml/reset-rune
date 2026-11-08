// INPUT: Courier presentation state, explicit task selection and user edits.
// OUTPUT: A compact entry and a native task-management surface.
// POS: Courier UI; delivery is driven separately by the application host.
import AppKit
import CourierCore
import SwiftUI

struct CourierSummaryButton: View {
    @ObservedObject var model: CourierMenuModel
    @ObservedObject var panel: PanelModel
    let open: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var palette: Palette { Palette(dark: colorScheme == .dark) }
    private var summary: String {
        if model.unresolvedCount > 0 { return panel.language == "zh" ? "\(model.unresolvedCount) 条发送结果待确认" : "\(model.unresolvedCount) deliveries need confirmation" }
        if let next = model.pendingTasks.first {
            let date = PanelCopy.date(next.scheduledAt, language: panel.language, now: Date())
            return "\(date) · \(CourierTextSummary.make(next.text))"
        }
        return CourierCopy.text(model.snapshot?.enabled == false ? "pausedAll" : "select", language: panel.language)
    }
    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "paperplane").font(.system(size: 14)).foregroundStyle(palette.brass).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(CourierCopy.text("title", language: panel.language)).font(.system(size: 12, weight: .semibold))
                        if !model.pendingTasks.isEmpty {
                            Text(panel.language == "zh" ? "\(model.pendingTasks.count) 个待发送" : "\(model.pendingTasks.count) scheduled")
                                .font(.system(size: 10)).foregroundStyle(palette.muted)
                        }
                    }
                    Text(summary).font(.system(size: 11)).foregroundStyle(model.unresolvedCount > 0 ? palette.caution : palette.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(palette.brass).accessibilityHidden(true)
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .top) { palette.line.frame(height: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

struct CourierManagementView: View {
    @ObservedObject var model: CourierMenuModel
    @ObservedObject var panel: PanelModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var deletion: CourierTask?
    @State private var confirmation: (CourierRun, Bool)?
    private var palette: Palette { Palette(dark: colorScheme == .dark) }
    private var language: String { panel.language }
    private func copy(_ key: String) -> String { CourierCopy.text(key, language: language) }

    var body: some View {
        VStack(spacing: 0) {
            heading
            if let code = model.errorCode {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                    Text(CourierCopy.error(code, language: language)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.clearError() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(copy("cancel"))
                }
                .font(.system(size: 12)).foregroundStyle(palette.caution)
                .padding(.horizontal, 22).padding(.vertical, 12)
                Divider()
            }
            HSplitView {
                list.frame(minWidth: 250, idealWidth: 295, maxWidth: 350)
                detail.frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "info.circle").accessibilityHidden(true)
                Text(copy(model.mock ? "mock" : "semantics")).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.font(.system(size: 11)).foregroundStyle(palette.muted).padding(.horizontal, 22).padding(.vertical, 10)
        }
        .background(palette.surface).foregroundStyle(palette.text).tint(palette.accent)
        .frame(minWidth: 760, minHeight: 560)
        .environment(\.locale, Locale(identifier: language == "zh" ? "zh_CN" : "en_US"))
        .alert(copy("deleteTitle"), isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button(copy("cancel"), role: .cancel) { deletion = nil }
            Button(copy("delete"), role: .destructive) { if let task = deletion { model.delete(task) }; deletion = nil }
        } message: { Text(copy("deleteNote")) }
        .alert(copy("confirmTitle"), isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button(copy("cancel"), role: .cancel) { confirmation = nil }
            Button(copy("confirmTitle")) { if let (run, sent) = confirmation { model.confirm(run, sent: sent) }; confirmation = nil }
        } message: { Text(copy("confirmNote")) }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(copy("title")).font(.custom("Iowan Old Style", size: 25))
                    Text(copy("intro")).font(.system(size: 12)).foregroundStyle(palette.muted)
                }
                Spacer(minLength: 8)
                if model.busy { ProgressView().controlSize(.small).padding(.top, 7) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help(copy("refresh")).accessibilityLabel(copy("refresh")).disabled(model.busy)
                Button(copy("new")) { model.newTask() }.keyboardShortcut("n").disabled(model.busy)
            }
            HStack(spacing: 12) {
                Picker("", selection: $model.section) {
                    Text(copy("tasks")).tag("tasks")
                    Text(copy("runs")).tag("runs")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Spacer(minLength: 8)
                if let snapshot = model.snapshot {
                    if !snapshot.enabled { Text(copy("pausedAll")).font(.system(size: 11)).foregroundStyle(palette.brass) }
                    else if !snapshot.hostAvailable { Text(copy("hostWaiting")).font(.system(size: 11)).foregroundStyle(palette.muted) }
                    Button(copy(snapshot.enabled ? "pauseAll" : "enableAll")) { model.setEnabled(!snapshot.enabled) }.disabled(model.busy)
                }
            }
        }.padding(22).background(palette.well).overlay(alignment: .bottom) { palette.line.frame(height: 1) }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.section == "tasks" {
                    if model.tasks.isEmpty { emptyList }
                    ForEach(model.tasks) { task in taskRow(task) }
                } else {
                    if model.runs.isEmpty { Text(copy("noRuns")).font(.system(size: 12)).foregroundStyle(palette.muted).padding(20) }
                    ForEach(model.runs) { run in runRow(run) }
                }
            }
        }.background(palette.well).disabled(model.busy)
    }

    private var emptyList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "paperplane").font(.system(size: 23)).foregroundStyle(palette.brass).accessibilityHidden(true)
            Text(copy("empty")).font(.system(size: 15, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text(copy("emptyDetail")).font(.system(size: 12)).foregroundStyle(palette.muted).lineSpacing(3)
            Button(copy("new")) { model.newTask() }.padding(.top, 3)
        }.padding(22)
    }

    private func taskRow(_ task: CourierTask) -> some View {
        Button { model.select(task) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(CourierTextSummary.make(task.text)).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 4)
                    if !task.enabled { Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(palette.muted) }
                }
                Text(task.target.title).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                Text(taskStatus(task)).font(.system(size: 11)).foregroundStyle(palette.brass)
                Text(CourierCopy.date(task.scheduledAt, language: language, timeZoneID: task.timeZoneID))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.muted)
            }
            .padding(.horizontal, 18).padding(.vertical, 15).frame(maxWidth: .infinity, alignment: .leading)
            .background(model.editor?.id == task.id ? palette.surface : Color.clear)
            .contentShape(Rectangle()).overlay(alignment: .bottom) { palette.line.frame(height: 1) }
        }.buttonStyle(.plain).contextMenu {
            Button(copy("open")) { model.open(task.target) }
            Button(copy("copy")) { model.copy(task) }
            if task.enabled { Button(copy("pause")) { model.pause(task) }.disabled(task.lifecycle == .completed) }
            else { Button(copy("resume")) { model.resume(task) }.disabled(task.lifecycle == .completed) }
            Divider()
            Button(copy("delete"), role: .destructive) { deletion = task }
        }
    }

    private func runRow(_ run: CourierRun) -> some View {
        Button { model.selectedRunID = run.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(CourierTextSummary.make(run.text)).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(run.target.title).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                Text(runStatus(run)).font(.system(size: 11)).foregroundStyle(run.unresolvedUnknown ? palette.caution : palette.brass)
                Text(CourierCopy.date(run.updatedAt, language: language)).font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            .padding(.horizontal, 18).padding(.vertical, 15).frame(maxWidth: .infinity, alignment: .leading)
            .background(model.selectedRunID == run.id ? palette.surface : Color.clear)
            .contentShape(Rectangle()).overlay(alignment: .bottom) { palette.line.frame(height: 1) }
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var detail: some View {
        if model.section == "tasks", model.editor != nil {
            CourierEditorView(model: model, panel: panel, deletion: $deletion)
        } else if model.section == "runs", let run = model.selectedRun {
            runDetail(run)
        } else {
            VStack(spacing: 12) {
                Image(systemName: model.section == "runs" ? "tray" : "paperplane").font(.system(size: 28)).foregroundStyle(palette.brass).accessibilityHidden(true)
                Text(copy(model.section == "runs" ? "noRuns" : "select")).font(.system(size: 13)).foregroundStyle(palette.muted).multilineTextAlignment(.center).frame(maxWidth: 320)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func runDetail(_ run: CourierRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(CourierTextSummary.make(run.text)).font(.system(size: 21, weight: .medium)).textSelection(.enabled)
                Text(runStatus(run)).font(.system(size: 13, weight: .semibold)).foregroundStyle(run.unresolvedUnknown ? palette.caution : palette.accent)
                targetDetail(run.target)
                Divider()
                labeled(copy("scheduled"), CourierCopy.date(run.scheduledAt, language: language))
                labeled(copy("deadline"), CourierCopy.date(run.deadlineAt, language: language))
                if let reason = run.waitReason { labeled(copy("waiting"), CourierCopy.reason(reason, language: language)) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(copy("instruction")).font(.system(size: 12, weight: .semibold))
                    Text(run.text).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if run.unresolvedUnknown {
                    Divider()
                    Text(copy("unknownNote")).font(.system(size: 12)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 10) {
                        Button(copy("confirmSent")) { confirmation = (run, true) }
                        Button(copy("confirmNotSent")) { confirmation = (run, false) }
                    }.disabled(model.busy)
                }
            }.padding(24)
        }
    }

    private func targetDetail(_ target: CourierTarget) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(target.agent == .codex ? "Codex" : "Claude Code") · \(target.title)").font(.system(size: 13, weight: .medium)).textSelection(.enabled)
            if let project = target.projectPath { Text(project).font(.system(size: 11)).foregroundStyle(palette.muted).textSelection(.enabled) }
            Text("…\(target.threadID.suffix(12))").font(.system(size: 11)).foregroundStyle(palette.muted).help(target.threadID)
            Button(copy("open")) { model.open(target) }.disabled(model.busy)
        }
    }

    private func labeled(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundStyle(palette.muted)
            Text(text).font(.system(size: 12)).textSelection(.enabled)
        }
    }
    private func taskStatus(_ task: CourierTask) -> String {
        if let run = model.runs.first(where: { $0.taskID == task.id }), task.lifecycle == .completed { return runStatus(run) }
        return copy(task.lifecycle == .scheduled ? "scheduledStatus" : task.lifecycle.rawValue)
    }
    private func runStatus(_ run: CourierRun) -> String {
        if let sent = run.userConfirmedSent { return copy(sent ? "confirmedSent" : "confirmedNotSent") }
        return copy(run.status == .scheduled ? "scheduledStatus" : run.status.rawValue)
    }
}

private struct CourierEditorView: View {
    @ObservedObject var model: CourierMenuModel
    @ObservedObject var panel: PanelModel
    @Binding var deletion: CourierTask?
    @Environment(\.colorScheme) private var colorScheme
    private var palette: Palette { Palette(dark: colorScheme == .dark) }
    private var language: String { panel.language }
    private func copy(_ key: String) -> String { CourierCopy.text(key, language: language) }
    private var task: CourierTask? { model.tasks.first { $0.id == model.editor?.id } }
    private var locked: Bool { model.selectedTaskLocked }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                title
                targetFields
                field("text") {
                    TextEditor(text: bind(\.text, "")).font(.system(size: 13)).frame(minHeight: 145)
                        .padding(5).background(palette.well).overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(palette.line, lineWidth: 1))
                    Text("\(model.editor?.text.utf8.count ?? 0) / 32768 bytes").font(.system(size: 10)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, alignment: .trailing)
                }
                timeFields
                saveArea
            }.padding(24)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(task.map { CourierTextSummary.make($0.text) } ?? copy("new")).font(.system(size: 21, weight: .medium)).lineLimit(2)
                Spacer(minLength: 8)
                if let task {
                    Menu {
                        Button(copy("copy")) { model.copy(task) }
                        if task.enabled { Button(copy("pause")) { model.pause(task) }.disabled(locked) }
                        Button(copy("delete"), role: .destructive) { deletion = task }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28).disabled(model.busy)
                }
            }
            if locked { Text(copy("locked")).font(.system(size: 12)).foregroundStyle(palette.brass) }
        }
    }

    private var targetFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            field("agent") {
                Picker(copy("agent"), selection: Binding(get: { model.editor?.agent ?? .codex }, set: model.changeAgent)) {
                    Text("Codex").tag(CourierAgent.codex)
                    Text("Claude Code").tag(CourierAgent.claude)
                }.labelsHidden().pickerStyle(.segmented)
            }
            field("target") {
                TextField(copy("targetSearch"), text: $model.targetQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.discoverTargets() }
                    .accessibilityLabel(copy("targetSearch"))
                HStack {
                    Picker(copy("target"), selection: Binding(get: { model.editor?.target?.key ?? "" }, set: { key in model.editor?.target = model.targets.first { $0.key == key } })) {
                        Text(copy("chooseTarget")).tag("")
                        ForEach(model.targets, id: \.key) { target in
                            Text("\(target.title) · …\(target.threadID.suffix(8))").tag(target.key)
                        }
                    }.labelsHidden().frame(maxWidth: .infinity)
                    Button(copy(model.discovering ? "discovering" : "discover")) { model.discoverTargets() }.disabled(model.discovering || model.busy)
                }
                if let target = model.editor?.target {
                    if let project = target.projectPath { Text(project).font(.system(size: 11)).foregroundStyle(palette.muted).textSelection(.enabled) }
                    HStack {
                        Text("…\(target.threadID.suffix(12))").font(.system(size: 11)).foregroundStyle(palette.muted).help("\(target.sourceID)\n\(target.threadID)")
                        Spacer()
                        Button(copy("open")) { model.open(target) }.controlSize(.small)
                    }
                } else if model.targetSearchPerformed, !model.discovering, model.targets.isEmpty {
                    Text(copy(model.targetQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "noTargets" : "noMatchingTargets"))
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                if model.hasMoreTargets {
                    Text(copy(model.targetQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "moreTargets" : "moreMatches"))
                        .font(.system(size: 11)).foregroundStyle(palette.brass).fixedSize(horizontal: false, vertical: true)
                }
                Text(copy("targetHint")).font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        }.disabled(locked || model.busy)
    }

    private var timeFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            field("time") {
                Picker(copy("time"), selection: bind(\.timeMode, .absolute)) {
                    Text(copy("absolute")).tag(CourierEditorDraft.TimeMode.absolute)
                    Text(copy("relative")).tag(CourierEditorDraft.TimeMode.relative)
                }.pickerStyle(.segmented).labelsHidden()
                if model.editor?.timeMode == .relative {
                    HStack {
                        TextField("30", value: bind(\.delayMinutes, 30), formatter: NumberFormatter()).frame(width: 75).textFieldStyle(.roundedBorder)
                        Text(copy("minutes")).font(.system(size: 12)).foregroundStyle(palette.muted)
                    }
                } else {
                    DatePicker(copy("time"), selection: bind(\.date, Date().addingTimeInterval(300)), displayedComponents: [.date, .hourAndMinute]).labelsHidden().datePickerStyle(.field)
                }
                Text(copy("timeNote")).font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.disabled(locked || model.busy)
    }

    @ViewBuilder private var saveArea: some View {
        if !locked {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                if model.editor?.target != nil, !model.canEnableTarget || model.codexNeedsLiveValidation {
                    Text(copy(model.codexNeedsLiveValidation ? "codexReadOnly" : "unsupported")).font(.system(size: 12)).foregroundStyle(palette.caution).fixedSize(horizontal: false, vertical: true)
                }
                if model.editor?.agent == .codex {
                    Text(copy("codexPermissions")).font(.system(size: 12)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(copy("bringFront")).font(.system(size: 12)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                Text(copy("saveNote")).font(.system(size: 12)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                if model.showsAccessibilityNote {
                    Text(copy("accessNote")).font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Spacer(minLength: 4)
                    Button(copy("save")) { model.save() }
                        .buttonStyle(.borderedProminent).disabled(!model.canSave)
                }
            }
        }
    }

    private func field<Content: View>(_ key: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(copy(key)).font(.system(size: 12, weight: .semibold))
            content()
        }.disabled(locked || model.busy)
    }
    private func bind<Value>(_ path: WritableKeyPath<CourierEditorDraft, Value>, _ fallback: Value) -> Binding<Value> {
        Binding(get: { model.editor?[keyPath: path] ?? fallback }, set: { model.editor?[keyPath: path] = $0 })
    }
}
