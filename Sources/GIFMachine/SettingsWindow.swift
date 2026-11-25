import AppKit
import GIFMachineCore
import SwiftUI

// The settings window, after the design language's settings window and No Orange Dot's components: a header,
// small grey section labels, grouped cards, rows with a 15 pt title, a 13 pt caption and the control on the right.

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var config: Config
    @Published private(set) var notice: String?
    var showWelcome: () -> Void = {}
    private let persists: Bool

    init(config: Config = Settings.current, notice: String? = nil, persists: Bool = true) {
        self.config = config
        self.notice = notice
        self.persists = persists
    }

    func reload() {
        guard persists else { return }
        config = Settings.reload()
        notice = StatusFile.current.configNotice
    }

    /// Writes config.json at once. A file with an error is left alone, and the window says why.
    func update(_ change: (inout Config) -> Void) {
        var next = config
        change(&next)
        guard persists else { config = next; return }
        do {
            try ConfigStore.save(next, to: Paths.config)
        } catch ConfigFile.SaveError.fileHasProblem(let problem) {
            notice = problem.notice(path: Paths.display(Paths.config))
            return
        } catch {
            notice = "\(Paths.display(Paths.config)) could not be saved: \(error.localizedDescription)"
            return
        }
        reload()
    }

    /// Sets one action's shortcut; another action with the same one loses it.
    func setShortcut(_ action: ShortcutAction, _ shortcut: Shortcut?) {
        update { config in
            if let shortcut {
                for (key, text) in config.shortcuts where key != action.rawValue && Shortcut(text) == shortcut { config.shortcuts[key] = "" }
            }
            config.shortcuts[action.rawValue] = shortcut?.text ?? ""
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where \(Paths.appName) saves recordings."
        panel.directoryURL = config.saveFolderURL ?? Paths.recordings
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update {
            $0.saveFolder = Paths.display(url)
            $0.save = true
        }
    }
}

enum ToolbarText {
    static func name(_ toolbar: Config.Toolbar) -> String {
        switch toolbar {
        case .dropDown: "Drop-down"
        case .bottomBar: "Bottom bar"
        case .none: "No toolbar"
        }
    }

    static func caption(_ toolbar: Config.Toolbar) -> String {
        switch toolbar {
        case .dropDown: "A panel under the icon offers Window, Section and Full screen."
        case .bottomBar: "A bar at the bottom of the screen, like the macOS screenshot toolbar. Choose an area, then Record."
        case .none: "Straight to the area picker. Drag for a section, click for the full screen, Space for a window."
        }
    }
}

struct SettingsContent: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var hotKeys = HotKeys.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Capture")
                Card {
                    Row(title: "Menu bar click", caption: ToolbarText.caption(model.config.toolbar)) {
                        Menu {
                            ForEach(Config.Toolbar.allCases, id: \.self) { toolbar in
                                Button {
                                    model.update { $0.toolbar = toolbar }
                                } label: {
                                    if toolbar == model.config.toolbar {
                                        Label(ToolbarText.name(toolbar), systemImage: "checkmark")
                                    } else {
                                        Text(ToolbarText.name(toolbar))
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(ToolbarText.name(model.config.toolbar))
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .menuStyle(.button).buttonStyle(PillButtonStyle()).fixedSize()
                        .accessibilityLabel("Menu bar click")
                        .accessibilityValue(ToolbarText.name(model.config.toolbar))
                    }
                    RowDivider()
                    Row(title: "Show keys", caption: KeyCastText.caption(model.config.keyCast)) {
                        HStack(spacing: 8) {
                            if model.config.keyCast != .off, !KeyCast.allowed {
                                Button("Open Settings") { PermissionGuide.shared.open(.keys) }.buttonStyle(PillButtonStyle())
                            }
                            Menu {
                                ForEach(Config.KeyCast.allCases, id: \.self) { mode in
                                    Button {
                                        model.update { $0.keyCast = mode }
                                        if mode != .off, !KeyCast.allowed { PermissionGuide.shared.open(.keys) }
                                    } label: {
                                        if mode == model.config.keyCast {
                                            Label(KeyCastText.name(mode), systemImage: "checkmark")
                                        } else {
                                            Text(KeyCastText.name(mode))
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(KeyCastText.name(model.config.keyCast))
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                }
                            }
                            .menuStyle(.button).buttonStyle(PillButtonStyle()).fixedSize()
                            .accessibilityLabel("Show keys")
                            .accessibilityValue(KeyCastText.name(model.config.keyCast))
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "After recording")
                Card {
                    Row(title: "Next action", caption: AfterText.caption(model.config.afterCapture)) {
                        Menu {
                            ForEach(Config.AfterCapture.allCases, id: \.self) { after in
                                Button {
                                    model.update { $0.afterCapture = after }
                                } label: {
                                    if after == model.config.afterCapture {
                                        Label(AfterText.name(after), systemImage: "checkmark")
                                    } else {
                                        Text(AfterText.name(after))
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(AfterText.name(model.config.afterCapture))
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .menuStyle(.button).buttonStyle(PillButtonStyle()).fixedSize()
                        .accessibilityLabel("Next action")
                        .accessibilityValue(AfterText.name(model.config.afterCapture))
                    }
                    RowDivider()
                    Row(title: "Format",
                        caption: model.config.format == .gif
                            ? "Copies the GIF when encoding finishes."
                            : "Copies an MP4. You can change the format for one clip in Preview or the editor.") {
                        Picker("Format", selection: Binding(get: { model.config.format }, set: { format in model.update { $0.format = format } })) {
                            Text("MP4").tag(Config.Format.mp4)
                            Text("GIF").tag(Config.Format.gif)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    RowDivider()
                    Row(title: "Speed",
                        caption: "Clips start at this speed. You can adjust playback for one clip in Preview or the editor.") {
                        Menu {
                            ForEach(Config.Speed.allCases, id: \.self) { speed in
                                Button {
                                    model.update { $0.speed = speed }
                                } label: {
                                    if speed == model.config.speed {
                                        Label(speed.label, systemImage: "checkmark")
                                    } else {
                                        Text(speed.label)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(model.config.speed.label).monospacedDigit()
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .menuStyle(.button).buttonStyle(PillButtonStyle()).fixedSize()
                        .accessibilityLabel("Speed")
                        .accessibilityValue(model.config.speed.label)
                    }
                    RowDivider()
                    Row(title: "Save recordings", caption: saveCaption) {
                        Toggle("Save recordings", isOn: Binding(get: { model.config.save }, set: { on in model.update { $0.save = on } }))
                            .labelsHidden().toggleStyle(.switch)
                            .accessibilityHint(saveCaption)
                    }
                    if model.config.save {
                        let folder = model.config.saveFolderURL ?? Paths.recordings
                        RowDivider()
                        Row(title: "Save to", caption: Paths.display(folder)) {
                            Button("Choose folder…") { model.chooseFolder() }.buttonStyle(PillButtonStyle())
                                .accessibilityLabel("Choose recordings folder")
                                .accessibilityValue(Paths.display(folder))
                        }
                    } else {
                        // Only with saving off is each copy a file of its own, in the Clipboard folder.
                        RowDivider()
                        Row(title: "Keep copies for") {
                            Menu {
                                ForEach(Config.KeepCopies.allCases, id: \.self) { keep in
                                    Button {
                                        model.update { $0.keepCopiesDays = keep }
                                    } label: {
                                        if keep == model.config.keepCopiesDays {
                                            Label(keep.label, systemImage: "checkmark")
                                        } else {
                                            Text(keep.label)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(model.config.keepCopiesDays.label)
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                }
                            }
                            .menuStyle(.button).buttonStyle(PillButtonStyle()).fixedSize()
                            .accessibilityLabel("Keep copies for")
                            .accessibilityValue(model.config.keepCopiesDays.label)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Shortcuts")
                Card {
                    ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                        if index > 0 { RowDivider() }
                        Row(title: action.title, caption: hotKeys.failed.contains(action)
                            ? "Another app already uses this shortcut. Choose another."
                            : ShortcutText.caption(action)) {
                            ShortcutField(shortcut: model.config.parsedShortcuts[action]) { shortcut in model.setShortcut(action, shortcut) }
                        }
                    }
                }
                Text("None are set at first. Each also stops a recording.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 6)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Settings file")
                Card {
                    Row(title: "config.json", caption: "Scripts and agents can change every setting here. Edits apply to the next recording.") {
                        Button("Show in Finder") {
                            model.reload()
                            NSWorkspace.shared.activateFileViewerSelecting([Paths.config])
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Help")
                Card {
                    Row(title: "Welcome", caption: "The short sketch, Screen Recording, and the ways to start and stop.") {
                        Button("Show Welcome") { model.showWelcome() }.buttonStyle(PillButtonStyle())
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .background(Surface.page)
    }

    private var saveCaption: String {
        if model.config.save { return "Keep a copy in the folder below." }
        let kept = "Anything you copied stays pasteable for \(model.config.keepCopiesDays.label), even after you quit."
        if model.config.afterCapture == .clipboard {
            return "The recording is deleted as soon as it's copied. \(kept)"
        }
        return "The recording is deleted when you close its window. \(kept)"
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Paths.appName).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                if let notice = model.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Ready. Changes save as you make them.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Key-cast: which keys show in a recording.
enum KeyCastText {
    static func name(_ mode: Config.KeyCast) -> String {
        switch mode {
        case .off: "Off"
        case .shortcuts: "Shortcuts"
        case .all: "Every key"
        }
    }

    @MainActor
    static func caption(_ mode: Config.KeyCast) -> String {
        if mode != .off, !KeyCast.allowed {
            return "Needs Input Monitoring. Click Open Settings and drag \(Paths.appName) into the list."
        }
        switch mode {
        case .off: return "Keys you press don't show in recordings."
        case .shortcuts: return "Shortcuts and keys like Return and the arrows show near the bottom of the recording."
        case .all: return "Everything you type shows near the bottom of the recording. Password fields never show."
        }
    }
}

enum ShortcutText {
    static func caption(_ action: ShortcutAction) -> String {
        switch action {
        case .toggle: "Does what a click on the menu bar icon does."
        case .section: "Opens the area picker to drag a section."
        case .window: "Opens the area picker to click a window."
        case .fullScreen: "Starts recording the screen the pointer is on."
        case .lastSection: "Records the last section on that screen again, at once."
        }
    }
}

/// What opens when a recording stops. The clip is on the clipboard in every case.
enum AfterText {
    static func name(_ after: Config.AfterCapture) -> String {
        switch after {
        case .clipboard: "Clipboard only"
        case .preview: "Preview"
        case .editor: "Editor"
        }
    }

    static func caption(_ after: Config.AfterCapture) -> String {
        switch after {
        case .clipboard: "Copies the clip without opening a window."
        case .preview: "A small window plays the clip with quick choices and closes on its own."
        case .editor: "Opens the editor to trim the clip or set a target file size."
        }
    }
}

// MARK: Components, from No Orange Dot

enum Surface {
    private static func pair(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    private static func hex(_ v: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }
    static let page = pair(hex(0xF4F4F5), hex(0x242527))
    static let card = pair(hex(0xFFFFFF), hex(0x2D2F32))
    static let border = pair(hex(0x000000, 0.09), hex(0x3A3C40))
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Surface.card))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Surface.border, lineWidth: 1))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
    }
}

struct Row<Trailing: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15))
                if let caption { Text(caption).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

/// A key that triggers the button it sits in, drawn as a small outlined key in the label's secondary colour.
struct KeyHint: View {
    let key: String

    var body: some View {
        Text(key).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 14) }
}

/// Every button with words on it. `prominent` inverts it: label colour fill, background-colour text.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .padding(.horizontal, 13).frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(prominent ? Color.primary.opacity(configuration.isPressed ? 0.75 : 0.9) : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Window

/// A real window: while it is open the app has a Dock icon, menus and Command-Tab, and it returns to the menu bar
/// when it closes.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = SettingsModel()
    var onShowWelcome: () -> Void {
        get { model.showWelcome }
        set { model.showWelcome = newValue }
    }

    /// Opens centred on the screen with the pointer, as tall as its settings or the screen allows; it scrolls when the
    /// screen is shorter. An open window is brought forward where it is.
    func show() {
        model.reload()
        if window == nil {
            let host = NSHostingController(rootView: ScrollView {
                SettingsContent(model: model)
            }
            .scrollBounceBehavior(.basedOnSize)
            .focusEffectDisabled()
            .background(Surface.page))
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = "\(Paths.appName) Settings"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.delegate = self
            self.window = window
        }
        if let window, !window.isVisible { place(window) }
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func place(_ window: NSWindow) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let fitting = NSHostingController(rootView: SettingsContent(model: model)).sizeThatFits(in: CGSize(width: 600, height: CGFloat.infinity))
        let size = NSSize(width: 600, height: min(fitting.height, visible.height - 48))
        window.setContentSize(size)
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                      y: max(visible.minY + 24, visible.midY - frame.height / 2)))
    }

    func windowDidBecomeKey(_ notification: Notification) { model.reload() }

    func windowWillClose(_ notification: Notification) {
        AppWindows.closed(window)
    }
}
