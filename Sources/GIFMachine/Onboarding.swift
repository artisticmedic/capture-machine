import AppKit
import GIFMachineCore
import SwiftUI

// The first run: a welcome, the sketch, then Screen Recording, then how to record. It opens at launch until it is finished, and at
// the permission step whenever a recording needs Screen Recording and the app doesn't have it.

/// Screen Recording, the one system grant recording needs.
@MainActor
enum ScreenPermission {
    private static let askedKey = "askedForScreenRecording"

    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }
    static var asked: Bool { UserDefaults.standard.bool(forKey: askedKey) }

    /// Opens System Settings with the permission guide, which hands over the icon to drag into the list. macOS's own
    /// prompt would add the app switched off and send people looking for it.
    static func ask() {
        UserDefaults.standard.set(true, forKey: askedKey)
        PermissionGuide.shared.open(.screen)
    }

    /// macOS can keep refusing a grant until the app starts again.
    static func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\" --args --idle", Bundle.main.bundlePath]
        try? reopen.run()
        NSApp.terminate(nil)
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: String, CaseIterable {
        case welcome, sketch, permission, ready
        static let first = Step.welcome
    }

    private static let finishedKey = "onboardingFinished"
    private static let stepKey = "onboardingStep"

    static var finished: Bool { UserDefaults.standard.bool(forKey: finishedKey) }
    /// Where a relaunch picks up.
    static var savedStep: Step { UserDefaults.standard.string(forKey: stepKey).flatMap(Step.init) ?? .first }

    @Published private(set) var step: Step
    @Published private(set) var allowed: Bool
    @Published private(set) var asked: Bool
    /// Changes each time the window is asked for, so a page shown again starts over, the sketch from its beginning.
    @Published private(set) var visit = 0
    var onFinish: (_ recordNow: Bool) -> Void = { _ in }
    private let persists: Bool
    private var timer: Timer?

    init(step: Step, allowed: Bool = ScreenPermission.isAllowed, asked: Bool = ScreenPermission.asked, persists: Bool = true) {
        self.step = step
        self.allowed = allowed
        self.asked = asked
        self.persists = persists
    }

    func start() {
        guard persists else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func go(to next: Step) {
        step = next
        if persists { UserDefaults.standard.set(next.rawValue, forKey: Self.stepKey) }
        refresh()
    }

    func show(_ step: Step) {
        visit += 1
        go(to: step)
    }

    func next() {
        let all = Step.allCases
        guard let index = all.firstIndex(of: step), index + 1 < all.count else { return finish(recordNow: false) }
        go(to: all[index + 1])
    }

    func allow() {
        ScreenPermission.ask()
        asked = true
    }

    func reopen() {
        if persists { UserDefaults.standard.set(step.rawValue, forKey: Self.stepKey) }
        ScreenPermission.relaunch()
    }

    func finish(recordNow: Bool) {
        if persists {
            UserDefaults.standard.set(true, forKey: Self.finishedKey)
            UserDefaults.standard.removeObject(forKey: Self.stepKey)
        }
        onFinish(recordNow)
    }

    private func refresh() {
        guard persists else { return }
        allowed = ScreenPermission.isAllowed
        asked = ScreenPermission.asked
    }
}

struct OnboardingContent: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        Group {
            switch model.step {
            case .welcome: WelcomePage(model: model)
            case .sketch: SketchPage(model: model)
            case .permission: PermissionPage(model: model)
            case .ready: ReadyPage(model: model)
            }
        }
        .id(model.visit)
        .frame(width: OnboardingLayout.size.width, height: OnboardingLayout.size.height)
        .background(Surface.page)
        .focusEffectDisabled()
    }
}

/// The window is sized for the sketch: as wide as the screen comfortably allows, up to 1000 points, with the sketch
/// scaled to fill it. Tim, 2026-11-25: "The demo video window is kind of small."
@MainActor
enum OnboardingLayout {
    /// The sketch is drawn at 760 by 550 points; the buttons under it take 50.
    static let stage = CGSize(width: 760, height: 550)
    static let buttons: CGFloat = 50

    static var scale: CGFloat = fitting(NSScreen.main?.visibleFrame)

    static func fitting(_ visible: CGRect?) -> CGFloat {
        guard let visible else { return 1000 / stage.width }
        let wide = (visible.width - 160) / stage.width
        let tall = (visible.height - 80 - buttons) / stage.height
        return max(1, min(1000 / stage.width, wide, tall))
    }

    static var size: CGSize { CGSize(width: stage.width * scale, height: stage.height * scale + buttons) }
}

/// The opening page: the icon, the name and a line on what it does, then Get Started, which plays the sketch.
struct WelcomePage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            PressableKey()
            // The full name Tim gave it on 2026-11-14; Capture Machine is the short one.
            Text("Welcome to Tim\u{2019}s Magnificent\nGIF and Video Capture Machine")
                .font(.system(size: 30, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 600)
                .padding(.top, 20)
            Text("Record a window, a section or the whole screen from the menu bar. When you stop, the clip is already on your clipboard.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 10)
            Button { model.next() } label: {
                HStack(spacing: 10) {
                    Text("Get Started").font(.system(size: 15, weight: .semibold))
                    KeyHint(key: "Enter")
                }
                .frame(minWidth: 220, minHeight: 40)
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Get Started")
            .padding(.top, 32)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The icon's key, which presses down while the pointer holds it and springs back on release (Tim, 2026-11-25: "If
/// someone clicks on this, I want this button to be able to animate going up and down"). Eight renders of the icon's
/// model, rest to pressed, shaped like the app icon. Without them, as in a bare build, it shows the app icon still.
struct PressableKey: View {
    static let frames: [NSImage] = (0..<8).compactMap { index in
        Bundle.main.url(forResource: "press-\(index)", withExtension: "png", subdirectory: "WelcomeKey").flatMap(NSImage.init(contentsOf:))
    }

    var body: some View {
        if Self.frames.count == 8 {
            Button {} label: { EmptyView() }
                .buttonStyle(KeyPressStyle())
                .accessibilityHidden(true)
        } else {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 144, height: 144).accessibilityHidden(true)
        }
    }
}

private struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KeyPress(pressed: configuration.isPressed)
    }
}

private struct KeyPress: View {
    let pressed: Bool
    @State private var depth = 0.0
    @State private var downAt = Date.distantPast

    var body: some View {
        KeyFrame(depth: depth)
            .onChange(of: pressed) { _, down in
                if down {
                    downAt = Date()
                    withAnimation(.easeIn(duration: 0.07)) { depth = 1 }
                } else {
                    // A quick click still reaches the bottom before the key comes back up.
                    let wait = max(0, 0.07 - Date().timeIntervalSince(downAt))
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                        withAnimation(.spring(duration: 0.32, bounce: 0.35)) { depth = 0 }
                    }
                }
            }
    }
}

/// The frame for a depth from 0, at rest, to 1, pressed, in the app icon's shape: a 116-point squircle on a 144-point
/// canvas, as macOS draws the icon.
private struct KeyFrame: View, @preconcurrency Animatable {
    var depth: Double
    var animatableData: Double {
        get { depth }
        set { depth = newValue }
    }

    var body: some View {
        let index = Int((min(1, max(0, depth)) * 7).rounded())
        Image(nsImage: PressableKey.frames[index])
            .resizable()
            .frame(width: 116, height: 116)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
            .frame(width: 144, height: 144)
            .contentShape(Rectangle())
    }
}

/// A large symbol or the app icon, a title and a line under it, as each page opens.
private struct PageHeading: View {
    var symbol: String?
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 44, weight: .regular)).foregroundStyle(.primary)
            } else {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72).accessibilityHidden(true)
            }
            Text(title).font(.system(size: 24, weight: .semibold)).foregroundStyle(.primary)
            Text(detail).font(.system(size: 15)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
        }
    }
}

struct PermissionPage: View {
    @ObservedObject var model: OnboardingModel

    private var detail: String {
        if model.allowed {
            return "When you first record, macOS asks once more about the window picker. Click Allow."
        }
        if model.asked {
            return "In System Settings, drag \(Paths.appName) into the Screen & System Audio Recording list, then choose Quit & Reopen."
        }
        return "macOS asks before any app records your screen. Click Allow Screen Recording, then drag \(Paths.appName) into the list."
    }

    var body: some View {
        VStack(spacing: 28) {
            PageHeading(symbol: model.allowed ? "checkmark.circle" : "record.circle",
                        title: model.allowed ? "\(Paths.appName) can record your screen" : "Let \(Paths.appName) record your screen",
                        detail: detail)
            Card {
                Row(title: "Screen Recording") {
                    Label(model.allowed ? "On" : "Off", systemImage: model.allowed ? "checkmark" : "xmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(model.allowed ? .primary : .secondary)
                        .accessibilityLabel(model.allowed ? "Screen Recording is on" : "Screen Recording is off")
                }
            }
            .frame(width: 460)
            HStack(spacing: 10) {
                if model.allowed {
                    Button("Continue") { model.next() }.buttonStyle(PillButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(model.asked ? "Open System Settings" : "Allow Screen Recording") { model.allow() }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                    if model.asked {
                        Button("Reopen \(Paths.appName)") { model.reopen() }.buttonStyle(PillButtonStyle())
                    }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReadyPage: View {
    @ObservedObject var model: OnboardingModel
    var toolbar: Config.Toolbar = Settings.current.toolbar

    private var start: Text { Text("Click \(Text(Image(nsImage: MenuBarGlyph.key(size: 15)))) in the menu bar.") }

    private var choose: String {
        switch toolbar {
        case .dropDown: "Pick Window, Section or Full screen."
        case .bottomBar: "Pick an area on the bar at the bottom of the screen, then click Record."
        case .none: "Drag for a section, click for the full screen, or press Space and click a window."
        }
    }

    var body: some View {
        VStack(spacing: 28) {
            PageHeading(title: "Ready to record",
                        detail: "Every clip goes on your clipboard, ready to paste.")
            Card {
                StepRow(number: 1, title: "Start", text: start)
                RowDivider()
                StepRow(number: 2, title: "Choose", text: Text(choose))
                RowDivider()
                StepRow(number: 3, title: "Stop", text: Text("Click the icon again."))
            }
            .frame(width: 520)
            HStack(spacing: 10) {
                Button("Record Now") { model.finish(recordNow: true) }.buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                Button("Done") { model.finish(recordNow: false) }.buttonStyle(PillButtonStyle())
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let text: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(number)").font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15))
                text.font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

/// A real window, like Settings: while it is open the app has a Dock icon, menus and Command-Tab.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: OnboardingModel?
    var onRecordNow: () -> Void = {}

    var isOpen: Bool { window?.isVisible == true }

    func show(at step: OnboardingModel.Step) {
        if let model, let window {
            model.show(step)
            bringForward(window)
            return
        }
        let model = OnboardingModel(step: step)
        model.go(to: step)
        model.onFinish = { [weak self] recordNow in
            self?.window?.close()
            guard recordNow else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.onRecordNow() }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingContent(model: model)))
        window.title = "Welcome to \(Paths.appName)"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.delegate = self
        OnboardingLayout.scale = OnboardingLayout.fitting(NSScreen.main?.visibleFrame)
        window.setContentSize(OnboardingLayout.size)
        window.center()
        self.window = window
        self.model = model
        model.start()
        bringForward(window)
    }

    private func bringForward(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        model?.stop()
        model = nil
        let closing = window
        window = nil
        AppWindows.closed(closing)
    }
}

/// The app shows in the Dock while one of its real windows is open.
@MainActor
enum AppWindows {
    static func closed(_ window: NSWindow?) {
        let othersOpen = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
        if !othersOpen { NSApp.setActivationPolicy(.accessory) }
    }
}
