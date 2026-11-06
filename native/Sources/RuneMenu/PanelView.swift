// INPUT: Display-only PanelModel and original bundled bottle artwork.
// OUTPUT: The compact native settings surface; only explicit controls send actions.
// POS: Native menu UI, described in native/README.md.
import SwiftUI
import AppKit

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

private struct Palette {
    let dark: Bool
    var surface: Color { Color(hex: dark ? 0x202723 : 0xf7f5ef) }
    var well: Color { Color(hex: dark ? 0x28312b : 0xefede4) }
    var text: Color { Color(hex: dark ? 0xeceee4 : 0x26382e) }
    var muted: Color { Color(hex: dark ? 0xafb7a8 : 0x65695c) }
    var line: Color { Color(hex: dark ? 0x3b453c : 0xdcd9cb) }
    var accent: Color { Color(hex: dark ? 0xa6cb88 : 0x386440) }
    var brass: Color { Color(hex: dark ? 0xc5ab7b : 0x80673d) }
    var caution: Color { Color(hex: dark ? 0xefb386 : 0x96512c) }
    var socket: Color { Color(hex: dark ? 0x19211c : 0xe7e4d8) }
    var edge: Color { Color(hex: dark ? 0x65705b : 0xb8b29c) }
    var mana: Color { Color(hex: dark ? 0x80b6dd : 0x356c98) }
    var manaTrack: Color { Color(hex: dark ? 0x32434b : 0xdbe2e3) }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @Environment(\.colorScheme) private var colorScheme
    private var palette: Palette { Palette(dark: colorScheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            header
            protection
            if model.confirmation != nil { confirmation }
            summary
            if model.panel == "credits" { creditDetails }
            footer
            if model.panel == "settings" { settings }
            if model.panel == "activity" { activity }
            if let feedback = model.feedback {
                separator
                Text(model.text(feedback)).font(.system(size: 12)).foregroundStyle(palette.caution)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 11)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(palette.text)
        .tint(palette.accent)
        .frame(width: 368)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(palette.line, lineWidth: 1))
        .fixedSize(horizontal: true, vertical: true)
        .background(GeometryReader { geometry in Color.clear.preference(key: HeightKey.self, value: geometry.size.height) })
        .onPreferenceChange(HeightKey.self) { model.onHeightChanged?($0) }
        .environment(\.locale, Locale(identifier: model.language == "zh" ? "zh_CN" : "en_US"))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bottled Reset Rune").font(.custom("Iowan Old Style", size: 23)).tracking(-0.5)
                Spacer(minLength: 5)
                if model.mock || model.preview { Text(model.text("mock")).font(.system(size: 10)).foregroundStyle(palette.brass) }
            }
            Text(model.text("intro")).font(.system(size: 12)).foregroundStyle(palette.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.top, 20)
    }

    private var protection: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.text("automatic")).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    if model.pending == "refresh" { ProgressView().controlSize(.mini) }
                    Text(model.statusLabel).font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Toggle(model.text("automatic"), isOn: Binding(get: { model.config.enabled }, set: model.setEnabled))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(!model.canAct || !["live", "mock"].contains(model.state?.mode ?? ""))
        }
        .padding(.top, 22).padding(.bottom, 17)
        .overlay(alignment: .bottom) { palette.line.frame(height: 1) }
        .padding(.horizontal, 22)
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let confirmation = model.confirmation {
                Text(model.text(confirmation.kind == "bind" ? "bindTitle" : "enableTitle")).font(.system(size: 12, weight: .semibold))
                let account = confirmation.identity.email ?? model.text("detected")
                let scope = confirmation.identity.accountId.map { String($0.suffix(6)) } ?? "—"
                Text(model.language == "zh" ? "\(account) · 工作区 …\(scope)" : "\(account) · Workspace …\(scope)")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).textSelection(.enabled)
                Text(confirmation.kind == "bind"
                     ? (model.language == "zh" ? "绑定后可单独开启自动使用。" : "You can enable automatic use after binding.")
                     : (model.language == "zh" ? "到期前 \(model.leadLabel(confirmation.lead))开始尝试，每次成功消耗一次备用重置。" : "Attempts start \(model.leadLabel(confirmation.lead)) before expiry. Each successful redemption uses one spare reset."))
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(model.text("cancel")) { model.confirmation = nil }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    Button(model.text(confirmation.kind == "bind" ? "confirmBind" : "enable")) { model.confirm() }
                        .buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(palette.accent)
                }.font(.system(size: 12)).padding(.top, 5)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 22)
    }

    private var summary: some View {
        Button { model.togglePanel("credits") } label: {
            HStack(spacing: 12) {
                bottleArtwork
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.expiryHeading).font(.system(size: 11)).foregroundStyle(model.isExpiring ? palette.caution : palette.muted)
                        Spacer(minLength: 4)
                        Image(systemName: model.panel == "credits" ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(palette.brass)
                    }
                    Text(model.expiryLabel).font(.system(size: 20, weight: .medium)).tracking(-0.4).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    if !model.countLabel.isEmpty { Text(model.countLabel).font(.system(size: 11)).foregroundStyle(palette.brass) }
                    if model.next == nil && model.bottle != .unknown {
                        Text(model.text(model.bottle == .empty ? "noExpiry" : model.bottle == .stored ? "unknownExpiry" : "unknown"))
                            .font(.system(size: 11)).foregroundStyle(palette.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 16).padding(.trailing, 22).padding(.top, 13).padding(.bottom, 15)
            .frame(minHeight: 134)
            .background(model.panel == "credits" ? palette.well : palette.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.text("next"))
        .accessibilityValue([model.expiryLabel, model.countLabel].joined(separator: ", "))
        .accessibilityHint(model.language == "zh" ? "展开备用重置明细" : "Show banked reset details")
    }

    private var bottleArtwork: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 5).fill(palette.socket)
            if let image = artwork(model.bottle == .stored ? "bottle" : "bottle-empty") {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 86, height: 100).opacity(model.bottle == .unknown ? 0.35 : 1)
            }
            if model.bottle == .stored, let count = model.state?.snapshot?.availableCount {
                Text(String(count)).font(.custom("Iowan Old Style", size: 17).weight(.semibold)).foregroundStyle(palette.text)
                    .padding(.horizontal, 4).background(palette.socket).padding(.trailing, 4).padding(.bottom, 3)
            }
            if model.bottle == .unknown {
                Text("?").font(.custom("Georgia", size: 24)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            RoundedRectangle(cornerRadius: 5).strokeBorder(model.config.enabled && model.bottle == .stored ? palette.accent : palette.edge, lineWidth: 1)
            CornerMarks().stroke(palette.brass, lineWidth: 1)
        }
        .frame(width: 90, height: 100).accessibilityHidden(true)
    }

    private var creditDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            let others = model.bottle == .stored ? (model.state?.otherCredits(now: model.now) ?? []) : []
            if !others.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(others.enumerated()), id: \.offset) { index, credit in
                            if index > 0 { separator }
                            Text(credit.expiresAt.flatMap { validEpoch($0) ? PanelCopy.date($0, language: model.language, now: model.visibleNow) : nil }.map { model.language == "zh" ? "\($0) 到期" : "Expires \($0)" } ?? model.text("unknownExpiry"))
                                .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9)
                        }
                    }
                }.frame(height: min(CGFloat(others.count) * 36, 150))
            }
            if model.incompleteInventory || model.next == nil && others.isEmpty {
                Text(model.text(model.incompleteInventory && model.bottle == .stored ? "partial" : "noDetails"))
                    .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.bottom, 9)
            }
            separator
            VStack(spacing: 7) {
                HStack {
                    Text(model.text("allowance")).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let percent = model.state?.snapshot?.remainingPercent, percent.isFinite, (0...100).contains(percent) {
                        Text("\(percent, specifier: percent.rounded() == percent ? "%.0f" : "%.1f")%")
                            .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(palette.mana)
                    }
                }
                if let percent = model.state?.snapshot?.remainingPercent, percent.isFinite, (0...100).contains(percent) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(palette.manaTrack)
                            RoundedRectangle(cornerRadius: 2).fill(palette.mana).frame(width: geometry.size.width * percent / 100)
                        }
                    }.frame(height: 5).accessibilityLabel(model.text("allowance")).accessibilityValue("\(Int(percent))%")
                } else { Text(model.text("noAllowance")).font(.system(size: 11)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, alignment: .leading) }
                if !model.connectionState.isEmpty { Text(model.text("lastReading")).font(.system(size: 11)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(.vertical, 11)
            if model.config.enabled, model.next != nil, model.connectionState.isEmpty,
               ["ready", "waiting", "outside-window"].contains(model.state?.status ?? "") {
                separator
                HStack(alignment: .firstTextBaseline) {
                    Text(model.text("timing")).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 10)
                    Text(model.isExpiring ? model.text("windowOpen") : (model.language == "zh" ? "到期前 \(model.leadLabel(model.config.lead))开始尝试" : "Starts \(model.leadLabel(model.config.lead)) before expiry"))
                        .font(.system(size: 11)).foregroundStyle(model.isExpiring ? palette.brass : palette.muted).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 11)
            }
        }.padding(.horizontal, 22).padding(.bottom, 13)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.account).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle).help(model.account)
            Spacer(minLength: 4)
            footerButton("settings")
            footerButton("activity")
        }
        .padding(.horizontal, 22).padding(.vertical, 11)
        .overlay(alignment: .top) { separator }
    }

    private func footerButton(_ name: String) -> some View {
        Button(model.text(name)) { model.togglePanel(name) }.buttonStyle(.plain).font(.system(size: 12))
            .foregroundStyle(model.panel == name ? palette.text : palette.muted)
            .underline(model.panel == name, color: palette.brass)
            .accessibilityAddTraits(model.panel == name ? .isSelected : [])
    }

    private var settings: some View {
        VStack(spacing: 0) {
            separator
            VStack(spacing: 0) {
                settingField("lead") {
                    Picker(model.text("lead"), selection: Binding(get: { model.config.lead }, set: { model.change("lead", $0) })) {
                        ForEach([5, 10, 30, 60], id: \.self) { Text(model.leadLabel($0)).tag($0) }
                    }.labelsHidden().frame(width: 136)
                }
                settingField("appearance") {
                    Picker(model.text("appearance"), selection: Binding(get: { model.config.appearance }, set: { model.change("appearance", $0) })) {
                        ForEach(["system", "light", "dark"], id: \.self) { Text(model.text($0)).tag($0) }
                    }.labelsHidden().frame(width: 136)
                }
                settingField("language") {
                    Picker(model.text("language"), selection: Binding(get: { model.language }, set: { model.change("language", $0) })) {
                        Text("English").tag("en")
                        Text("简体中文").tag("zh")
                    }.labelsHidden().frame(width: 136)
                }
                settingField("startup") {
                    Toggle(model.text("startup"), isOn: Binding(get: { model.config.startup }, set: { model.change("startup", $0) })).labelsHidden()
                }
                settingField("notify") {
                    Toggle(model.text("notify"), isOn: Binding(get: { model.config.notify }, set: { model.change("notify", $0) })).labelsHidden()
                }
            }
            .font(.system(size: 12)).pickerStyle(.menu).toggleStyle(.switch).controlSize(.small).disabled(!model.canAct)
            separator.padding(.top, 8)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.workspace)
                    if model.identity != nil { Text(model.text("localLogin")) }
                }.font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer(minLength: 3)
                if model.pending == "refresh" { ProgressView().controlSize(.small) }
                Button(model.text("check")) { model.refresh() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.muted).disabled(model.pending != nil || model.preview)
            }.padding(.top, 10)
            if model.identity != nil && !model.config.enabled {
                Button(model.text("bind")) { model.bind() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).disabled(!model.canAct)
            }
            Text(model.text("settingsNote")).font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }.padding(.horizontal, 22).padding(.bottom, 17)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 0) {
            separator
            Text(model.text("battleLog")).font(.system(size: 12, weight: .semibold)).padding(.top, 13).padding(.bottom, 7)
            let events = model.state?.recentEvents() ?? []
            if events.isEmpty { Text(model.text("noEvents")).font(.system(size: 11)).foregroundStyle(palette.muted).padding(.bottom, 5) }
            else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(events) { row in EventRow(event: row.event, model: model, palette: palette) }
                    }
                }.frame(height: min(CGFloat(events.count) * 47, 280))
            }
            if model.mock { Text(model.text("mockNote")).font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 8) }
        }.padding(.horizontal, 22).padding(.bottom, 17)
    }

    private var separator: some View { palette.line.frame(height: 1) }

    private func settingField<Control: View>(_ key: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(model.text(key))
            Spacer(minLength: 4)
            control()
        }.frame(height: 40)
    }

    private func artwork(_ name: String) -> NSImage? {
        guard let resource = Bundle.main.resourceURL else { return nil }
        return NSImage(contentsOf: resource.appendingPathComponent("\(name).png"))
    }
}

private struct CornerMarks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 10)); path.addLine(to: .zero); path.addLine(to: CGPoint(x: 10, y: 0))
        path.move(to: CGPoint(x: rect.width - 10, y: rect.height)); path.addLine(to: CGPoint(x: rect.width, y: rect.height)); path.addLine(to: CGPoint(x: rect.width, y: rect.height - 10))
        return path
    }
}

private struct EventRow: View {
    let event: PanelEvent
    @ObservedObject var model: PanelModel
    let palette: Palette
    @State private var expanded = false
    private var symbol: String {
        switch event.type {
        case "reset": return "checkmark"
        case "intent": return "arrow.right"
        case "reset-unverified": return "clock"
        case "unconfirmed": return "questionmark"
        case "missed": return "xmark"
        case "nothing-to-reset", "no-credit": return "minus.circle"
        default: return "circle.fill"
        }
    }
    private var color: Color {
        switch event.type {
        case "reset": return palette.accent
        case "unconfirmed", "missed", "no-credit": return palette.caution
        case "reset-unverified", "nothing-to-reset": return palette.brass
        default: return palette.muted
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            palette.line.frame(height: 1)
            HStack(alignment: .top, spacing: 8) {
                Text(PanelCopy.date(event.at, language: model.language, now: model.visibleNow))
                    .font(.system(size: 11)).foregroundStyle(palette.muted).monospacedDigit().frame(width: 93, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    let detail = PanelCopy.eventDetail(event.type, language: model.language)
                    if detail != nil {
                        Button { expanded.toggle(); model.requestLayout() } label: { eventLabel(disclosure: true) }.buttonStyle(.plain)
                    } else { eventLabel(disclosure: false) }
                    if expanded, let detail { Text(detail).font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(3).padding(.leading, 17) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.vertical, 9)
        }
    }
    private func eventLabel(disclosure: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: event.type == "checked" ? 4 : 10, weight: .medium)).foregroundStyle(color).frame(width: 11)
            Text(PanelCopy.event(event.type, language: model.language, mock: model.mock)).font(.system(size: 12)).foregroundStyle(event.type == "reset" ? palette.accent : palette.text).fixedSize(horizontal: false, vertical: true)
            if disclosure { Spacer(minLength: 1); Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(palette.brass) }
        }
    }
}
