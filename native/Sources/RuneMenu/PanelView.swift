// INPUT: Display-only PanelModel, Dota 2 bottle art and the project's Reset Rune illustration.
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
                     : (model.language == "zh" ? "到期前 \(model.leadLabel(confirmation.lead))开始尝试，每次成功消耗一枚重置神符。" : "Attempts start \(model.leadLabel(confirmation.lead)) before expiry. Each successful redemption uses one Reset Rune."))
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
        let showingInventory = model.panel == "credits" && model.bottle == .stored
        return Button { model.togglePanel("credits") } label: {
            HStack(spacing: 12) {
                bottleArtwork
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(showingInventory ? model.text("inventory") : model.expiryHeading).font(.system(size: 11)).foregroundStyle(model.isExpiring ? palette.caution : palette.muted)
                        Spacer(minLength: 4)
                        Image(systemName: model.panel == "credits" ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(palette.brass)
                    }
                    Text(showingInventory ? model.countLabel : model.expiryLabel).font(.system(size: 20, weight: .medium)).tracking(-0.4).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    if model.panel != "credits", !model.countLabel.isEmpty { Text(model.countLabel).font(.system(size: 11)).foregroundStyle(palette.brass) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(model.panel == "credits" ? palette.well : palette.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.text("rune"))
        .accessibilityValue(showingInventory ? model.countLabel : [model.expiryLabel, model.countLabel].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(model.text(model.panel == "credits" ? "hideRunes" : "showRunes"))
    }

    private var bottleArtwork: some View {
        ZStack {
            palette.socket
            if let image = MenuArtwork.panel(model.bottle == .stored ? "bottle.png" : "bottle-empty.png") {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .opacity(model.bottle == .unknown ? 0.28 : 1)
            } else if model.bottle != .unknown {
                Image(systemName: model.bottle.fallbackSymbol).font(.title).foregroundStyle(palette.text)
            }
            if model.bottle == .unknown {
                Text("?").font(.system(size: 24, weight: .semibold)).foregroundStyle(palette.text)
            }
        }
        .frame(width: 88, height: 64)
        .border(palette.edge, width: 1)
        .accessibilityHidden(true)
    }

    private var creditDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            let rows = model.bottle == .stored ? (model.state?.inventoryRows(now: model.now) ?? []) : []
            if !rows.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            runeRow(row)
                        }
                    }
                }
                .frame(height: min(CGFloat(rows.count) * 44, 176))
            }
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
                            RoundedRectangle(cornerRadius: 2)
                                .fill(LinearGradient(colors: [Color(hex: 0x1056db), Color(hex: 0x73f5fe)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: geometry.size.width * percent / 100)
                        }
                    }.frame(height: 5).accessibilityLabel(model.text("allowance")).accessibilityValue("\(Int(percent))%")
                } else { Text(model.text("noAllowance")).font(.system(size: 11)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, alignment: .leading) }
                if !model.connectionState.isEmpty, model.state?.snapshot?.remainingPercent != nil { Text(model.text("lastReading")).font(.system(size: 11)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, alignment: .leading) }
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

    private func runeRow(_ row: PanelRuneRow) -> some View {
        HStack(spacing: 8) {
            Group {
                if let image = MenuArtwork.panel("reset-rune.png") {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                } else {
                    Image(systemName: "arrow.counterclockwise").foregroundStyle(palette.accent)
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            Text(row.count > 1 ? "\(model.text("rune")) ×\(row.count)" : model.text("rune"))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(row.expiresAt.map { PanelCopy.date($0, language: model.language, now: model.visibleNow) } ?? model.text("unknownExpiry"))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .layoutPriority(1)
        }
        .frame(height: 44)
        .help(model.text("runeEffect"))
        .overlay(alignment: .bottom) { separator }
        .accessibilityElement(children: .combine)
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
            if event.type == "reset", let image = MenuArtwork.panel("dota-success.png") {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 11, height: 11).accessibilityHidden(true)
            } else {
                Image(systemName: symbol).font(.system(size: event.type == "checked" ? 4 : 10, weight: .medium)).foregroundStyle(color).frame(width: 11).accessibilityHidden(true)
            }
            Text(PanelCopy.event(event.type, language: model.language, mock: model.mock)).font(.system(size: 12)).foregroundStyle(event.type == "reset" ? palette.accent : palette.text).fixedSize(horizontal: false, vertical: true)
            if disclosure { Spacer(minLength: 1); Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(palette.brass) }
        }
    }
}
