import AppKit
import GIFMachineCore
import SwiftUI

/// `CaptureMachine --render <directory>` writes each surface in light and dark as PNGs, off screen.
@MainActor
enum Render {
    static func run(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dropDown = DropDownModel(status: "Copies and saves to Screenshots · up to 120 fps") { _ in }
        dropDown.selected = .tool(.section)
        let bar = BarModel(tool: .section)
        bar.readout = "2400 × 1460 · 120 fps"
        let emptyBar = BarModel(tool: .window)
        var config = Config()
        config.saveFolder = "~/Pictures/Screenshots"
        let settings = SettingsModel(config: config, persists: false)
        var savingOff = Config()
        savingOff.save = false
        savingOff.keepCopiesDays = .month
        let temporary = SettingsModel(config: savingOff, persists: false)
        var bottomBar = Config()
        bottomBar.toolbar = .bottomBar
        let broken = SettingsModel(config: bottomBar, notice: ConfigFile.Problem(kind: .unknownValue, keys: ["toolbar"])
            .notice(path: "~/Library/Application Support/Capture Machine/config.json"), persists: false)
        let gif = Delivery.Output(format: .gif, speed: .half, smaller: Smaller(frames: .fifteen, halfSize: true), trim: 1.2...3.4)
        let preview = ClipModel(
            source: URL(fileURLWithPath: "/tmp/REC-20261115-170000.mp4"), output: URL(fileURLWithPath: "/tmp/REC-20261115-170000 0.5x.gif"),
            made: gif, choice: gif, recordedFPS: 120, saveFolder: URL(fileURLWithPath: "/Users/me/Pictures/Screenshots"), saveFailure: nil,
            pixelSize: CGSize(width: 1600, height: 1000), plays: false, duration: 5)
        preview.pointerInside = true
        let changed = ClipModel(
            source: URL(fileURLWithPath: "/tmp/REC-20261115-170000.mp4"), output: URL(fileURLWithPath: "/tmp/REC-20261115-170000.mp4"),
            made: Delivery.Output(format: .mp4, speed: .normal), choice: gif, recordedFPS: 120, saveFolder: nil, saveFailure: nil,
            pixelSize: CGSize(width: 1600, height: 1000), plays: false, duration: 5)
        let welcome = OnboardingModel(step: .welcome, allowed: false, asked: false, persists: false)
        let firstAsk = OnboardingModel(step: .permission, allowed: false, asked: false, persists: false)
        let askedBefore = OnboardingModel(step: .permission, allowed: false, asked: true, persists: false)
        let allowed = OnboardingModel(step: .permission, allowed: true, asked: true, persists: false)
        let ready = OnboardingModel(step: .ready, allowed: true, asked: true, persists: false)
        let guides: [(String, GuideModel)] = [("drag", .drag), ("password", .password), ("quit", .quitAlert), ("reopen", .reopen),
                                              ("enable", .enable), ("done", .done)].map { ($0, GuideModel(kind: .screen, phase: $1)) }
            + [("keys-done", GuideModel(kind: .keys, phase: .done))]
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            write(OnboardingContent(model: welcome), scheme, directory, "onboarding-welcome-\(name)", panel: false)
            write(OnboardingContent(model: firstAsk), scheme, directory, "onboarding-permission-\(name)", panel: false)
            let glyphs = HStack(spacing: 14) {
                Image(nsImage: MenuBarGlyph.key())
                HStack(spacing: 0) { Image(nsImage: MenuBarGlyph.key(dot: false, fill: 0.42)); Text(" 42%").monospacedDigit() }
                HStack(spacing: 0) { Image(nsImage: MenuBarGlyph.key(check: true)); Text(" Copied · 2.2 MB") }
                Image(nsImage: MenuBarGlyph.recording("0:12"))
            }
            .font(.system(size: 13)).padding(.horizontal, 12).frame(height: 24).scaleEffect(3).frame(width: 1300, height: 90)
            write(glyphs, scheme, directory, "menubar-glyphs-\(name)", panel: true)
            write(OnboardingContent(model: askedBefore), scheme, directory, "onboarding-permission-asked-\(name)", panel: false)
            write(OnboardingContent(model: allowed), scheme, directory, "onboarding-permission-allowed-\(name)", panel: false)
            write(OnboardingContent(model: ready), scheme, directory, "onboarding-ready-\(name)", panel: false)
            for time in sketchTimes {
                let stage = SketchStage(frame: Sketch.frame(at: time), allowed: false).background(Surface.page)
                write(stage, scheme, directory, String(format: "sketch-%05.1f-\(name)", time), panel: false)
            }
            for (phase, model) in guides {
                write(GuideView(model: model, close: {}, reopen: {}).frame(width: 440), scheme, directory, "guide-\(phase)-\(name)", panel: true)
            }
            write(DropDownContent(model: dropDown), scheme, directory, "dropdown-\(name)", panel: true)
            write(BarContent(model: bar), scheme, directory, "bottom-bar-\(name)", panel: true)
            write(BarContent(model: emptyBar), scheme, directory, "bottom-bar-empty-\(name)", panel: true)
            write(SettingsContent(model: settings), scheme, directory, "settings-\(name)", panel: false)
            write(SettingsContent(model: broken), scheme, directory, "settings-notice-\(name)", panel: false)
            write(SettingsContent(model: temporary), scheme, directory, "settings-saving-off-\(name)", panel: false)
            write(PreviewContent(model: preview), scheme, directory, "preview-\(name)", panel: true)
            write(PreviewContent(model: changed), scheme, directory, "preview-changed-\(name)", panel: true)
            write(EditorContent(model: changed) {}.frame(width: 1080, height: 700), scheme, directory, "editor-\(name)", panel: false)
        }
    }

    /// A moment from each beat of the sketch.
    static let sketchTimes: [Double] = [0.9, 2.2, 3.2, 3.55, 4.4, 5.5, 6.8, 8.0, 10.0, 11.0, 11.6, 11.9, 13.6, 14.4, 15.1, 15.9, 16.4,
                                        17.0, 17.6, 18.8, 20.9, 21.8, 22.5, 23.3, 24.2, 26.2, 28.6, 31.4, 33.95, 35.2, 35.8, 36.3,
                                        36.6, 37.0, 37.9, 38.7, 39.2, 40.8, 43.0, 43.6, 45.6, 48.4]

    private static func write<V: View>(_ view: V, _ scheme: ColorScheme, _ directory: URL, _ name: String, panel: Bool) {
        let backed = AnyView(panel
            ? AnyView(view.background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor))))
            : AnyView(view))
        let hosting = NSHostingView(rootView: backed.environment(\.colorScheme, scheme))
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        if let rep { hosting.cacheDisplay(in: hosting.bounds, to: rep) }
        let url = directory.appendingPathComponent("\(name).png")
        guard let png = rep?.representation(using: .png, properties: [:]) else {
            print("Not rendered: \(name)")
            return
        }
        try? png.write(to: url)
        print(url.path)
    }
}
