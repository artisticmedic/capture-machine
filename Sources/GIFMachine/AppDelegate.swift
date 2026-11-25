import AppKit
import GIFMachineCore
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let recorder = Recorder()
    private let dropDown = DropDown()
    private let settings = SettingsWindowController()
    private let onboarding = OnboardingWindowController()
    private let outline = RecordingOutline()
    private let keyCast = KeyCast()
    private var bar: BottomBar?
    private var preview: PreviewWindow?
    private var editor: EditorWindow?
    /// The last recording's clip, for Edit Last Recording.
    private var session: ClipModel?
    private var picker: SectionPicker?
    private var pickerStyle: Config.Toolbar?
    private var lastBarTool: Tool = .section
    private var startedAt: Date?
    /// The newest recording handed out. A clip made from an older one leaves the menu bar and status.json alone.
    private var latestSource: URL?
    private var ticker: Timer?
    private var busy = false
    private var keyMonitor: Any?

    /// The drop-down's Section and Window tools: release or click starts the recording.
    private let pickFromDropDown = PickerStyle(commitsOnRelease: true, clickMeansFullScreen: false, cursorChip: false) { tool in
        tool == .window ? "Click a window to record it" : "Drag to record a section"
    }
    /// No toolbar: the picker opens in Section, and the keys and a chip at the pointer switch modes.
    private let pickWithoutToolbar = PickerStyle(commitsOnRelease: true, clickMeansFullScreen: true, cursorChip: true) { _ in nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = mainMenu()
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        showIdle()
        StatusFile.update { $0.state = "idle" }
        Settings.reload()
        // Recordings made with saving off end with their windows; none is open at launch.
        Paths.tidyTemporary()
        Clipboard.tidy()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
        onboarding.onRecordNow = { [weak self] in self?.startOrStop(closingChoosers: false) }
        HotKeys.shared.onAction = { [weak self] action in self?.perform(action) }
        recorder.onEndedBySystem = { [weak self] error, recording in self?.endedBySystem(error, recording) }
        HotKeys.shared.register(Settings.current.parsedShortcuts)
        watchConfig()
        settings.onShowWelcome = { [weak self] in self?.showWelcome() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.noteIconPlace() }
        let arguments = CommandLine.arguments
        // Quit & Reopen after a grant relaunches the app; the guide says it worked instead of a chooser opening.
        let resumedGuide = PermissionGuide.shared.resumeAfterRelaunch()
        if arguments.contains("--onboarding") {
            onboarding.show(at: .first)
        } else if !OnboardingModel.finished {
            onboarding.show(at: OnboardingModel.savedStep)
        } else if !resumedGuide, !arguments.contains("--idle"), !launchedAsLoginItem() {
            startWhenPlaced(tries: 100)
        }
    }

    /// Recordings made with saving off go with the app; their clipboard copies stay.
    func applicationWillTerminate(_ notification: Notification) {
        Paths.tidyTemporary(quitting: true)
    }

    /// Opening the app while it runs, from Raycast, Spotlight or Finder, does what a click on the icon does.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        startOrStop(closingChoosers: false)
        return false
    }

    /// At launch the icon has no place in the menu bar yet, and the drop-down hangs from it. Waits up to a second; the
    /// other choosers don't wait. Notes the time from the process starting to the chooser in `status.json`.
    private func startWhenPlaced(tries: Int, since asked: ContinuousClock.Instant = .now) {
        if tries > 0, Settings.current.toolbar == .dropDown, (statusItem.button?.window?.frame.height ?? 0) == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.startWhenPlaced(tries: tries - 1, since: asked) }
            return
        }
        let (seconds, attoseconds) = (ContinuousClock.now - asked).components
        startOrStop(closingChoosers: false)
        guard let age = Self.processAge() else { return }
        StatusFile.update {
            $0.launch = Status.Launch(toChooserMilliseconds: (age * 1000).rounded(),
                                      iconWaitMilliseconds: (Double(seconds) * 1000 + Double(attoseconds) / 1e15).rounded(),
                                      toolbar: Settings.current.toolbar.rawValue)
        }
    }

    /// Seconds since this process started, from the kernel's record of it.
    private static func processAge() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    private func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        startOrStop(closingChoosers: true)
    }

    private func startOrStop(closingChoosers: Bool) {
        guard !busy else { return }
        if recorder.isRecording {
            busy = true
            Task {
                await stop()
                busy = false
            }
        } else if isChoosing {
            if closingChoosers { closeChoosers() }
        } else if !ScreenPermission.isAllowed {
            onboarding.show(at: .permission)
        } else {
            open(Settings.reload().toolbar)
        }
    }

    /// A global shortcut. Each stops a recording that's running.
    private func perform(_ action: ShortcutAction) {
        guard !busy else { return }
        if recorder.isRecording || action == .toggle {
            startOrStop(closingChoosers: true)
            return
        }
        guard ScreenPermission.isAllowed else {
            onboarding.show(at: .permission)
            return
        }
        closeChoosers()
        let screen = pointerScreen()
        switch action {
        case .toggle: break
        case .section: openPicker(.section, style: pickFromDropDown, for: .dropDown)
        case .window: openPicker(.window, style: pickFromDropDown, for: .dropDown)
        case .fullScreen:
            record(Capture(screen: screen, rect: CGRect(origin: .zero, size: screen.frame.size), label: "Full screen", isFullScreen: true))
        case .lastSection:
            guard let rect = LastSection.load(for: screen) else {
                openPicker(.section, style: pickFromDropDown, for: .dropDown)
                return
            }
            record(Capture(screen: screen, rect: rect, label: Readout.size(screen, rect.size)))
        }
    }

    private var configWatch: DispatchSourceFileSystemObject?

    /// Re-reads config.json when it changes, by hand or from Settings, so shortcuts apply at once. The file is replaced
    /// on each save, so its folder is watched.
    private func watchConfig() {
        let folder = Darwin.open(Paths.support.path, O_EVTONLY)
        guard folder >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard self != nil else { return }
                HotKeys.shared.register(Settings.reload().parsedShortcuts)
            }
        }
        source.setCancelHandler { Darwin.close(folder) }
        source.resume()
        configWatch = source
    }

    // MARK: Choosing what to record

    private var isChoosing: Bool { dropDown.isOpen || bar != nil || picker != nil }

    private func open(_ toolbar: Config.Toolbar) {
        switch toolbar {
        case .dropDown:
            guard let button = statusItem.button else { return }
            dropDown.open(from: button, status: statusLine()) { [weak self] item in
                guard let self else { return }
                switch item {
                case .settings: settings.show()
                case .welcome: showWelcome()
                case .tool(.fullScreen):
                    let screen = pointerScreen()
                    let rect = CGRect(origin: .zero, size: screen.frame.size)
                    record(Capture(screen: screen, rect: rect, label: "Full screen", isFullScreen: true))
                case .tool(let tool): openPicker(tool, style: pickFromDropDown, for: .dropDown)
                }
            }
        case .bottomBar:
            let bar = BottomBar(tool: lastBarTool)
            bar.onRecord = { [weak self, weak bar] capture in
                if let bar { self?.lastBarTool = bar.tool }
                self?.bar = nil
                self?.record(capture)
            }
            bar.onClose = { [weak self, weak bar] in
                if let bar { self?.lastBarTool = bar.tool }
                self?.bar = nil
            }
            if let button = statusItem.button, let window = button.window {
                bar.setCancelZone(window.convertToScreen(button.convert(button.bounds, to: nil)))
            }
            self.bar = bar
            bar.show()
        case .none:
            openPicker(.section, style: pickWithoutToolbar, for: .none)
        }
    }

    private func openPicker(_ tool: Tool, style: PickerStyle, for toolbar: Config.Toolbar) {
        let screen = pointerScreen()
        let picker = SectionPicker(screen: screen, tool: tool, style: style)
        picker.view.onCommit = { [weak self] capture in
            self?.closePicker()
            self?.record(capture)
        }
        picker.view.onCancel = { [weak self] in self?.closePicker() }
        if let button = statusItem.button, let window = button.window {
            let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
            picker.view.cancelZone = icon.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        }
        self.picker = picker
        pickerStyle = toolbar
        picker.show()
    }

    private func closePicker() {
        picker?.close()
        picker = nil
        pickerStyle = nil
    }

    private func closeChoosers() {
        dropDown.close()
        bar?.close()
        bar = nil
        closePicker()
    }

    private func handle(_ event: NSEvent) -> Bool {
        if dropDown.isOpen { return dropDown.key(event) }
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if let bar { return plain && bar.key(event) }
        guard let picker, plain else { return false }
        if event.keyCode == KeyCode.escape {
            closePicker()
            return true
        }
        guard pickerStyle == Config.Toolbar.none else { return false }
        let view = picker.view
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (KeyCode.space, _): view.tool = view.tool == .section ? .window : .section
        case (_, "w"): view.tool = .window
        case (_, "s"): view.tool = .section
        case (KeyCode.returnKey, _), (KeyCode.keypadEnter, _):
            if !view.commitRemembered() { view.onCommit?(view.fullScreenCapture()) }
        case (_, "f"): view.onCommit?(view.fullScreenCapture())
        default: return false
        }
        return true
    }

    // MARK: Recording

    private func record(_ capture: Capture) {
        preview?.close()
        busy = true
        Task {
            defer { busy = false }
            do {
                // The recording leaves out windows that are on screen as it starts, so the outline goes first.
                outline.show(capture.rect, on: capture.screen)
                try await recorder.start(screen: capture.screen, section: capture.isFullScreen ? nil : capture.rect,
                                         hiding: outline.windowNumber.map { [$0] } ?? [], temporary: !Settings.reload().save)
                let origin = capture.screen.frame.origin
                keyCast.start(mode: Settings.current.keyCast, area: capture.rect.offsetBy(dx: origin.x, dy: origin.y))
                startedAt = Date()
                showRecording()
                StatusFile.update { $0.state = "recording"; $0.lastError = nil }
            } catch {
                report(error)
            }
        }
    }

    private func stop() async {
        keyCast.stop()
        outline.hide()
        do {
            let recording = try await recorder.stop()
            await deliver(recording)
        } catch RecorderError.notRecording {
            // macOS ended it a moment before Stop; `endedBySystem` hands it out.
        } catch {
            report(error)
        }
    }

    /// macOS ended the recording: the app goes back to idle and hands out what was recorded, when it can be played.
    private func endedBySystem(_ error: Error, _ recording: Recorder.Recording?) {
        keyCast.stop()
        outline.hide()
        guard let recording else {
            report(error)
            return
        }
        StatusFile.update { $0.lastError = "Recording ended by macOS: \(error.localizedDescription)" }
        Task { await deliver(recording, endedBy: error) }
    }

    private func deliver(_ recording: Recorder.Recording, endedBy error: Error? = nil) async {
        let config = Settings.reload()
        // Saving can be switched on or off while it records.
        var recording = recording
        do {
            recording = recording.moved(to: try Paths.relocate(recording.url, temporary: !config.save))
            latestSource = recording.url
            showIdle(note: config.speed == .normal || config.format == .gif ? nil : "Making \(config.speed.label)…")
            var result = try await Delivery.finish(recording, config: config)
            if let error {
                let reason = error as NSError
                // SCStreamErrorInsufficientStorage is reported by macOS 27 and later.
                result.captureNotice = reason.domain == SCStreamError.errorDomain && reason.code == -3822
                    ? "macOS stopped recording because storage was low."
                    : "macOS ended this recording."
            }
            // The time from Stop stays in the menu, as "Last: copied … after Stop".
            showIdle(note: result.captureNotice ?? result.stopToClipboardMilliseconds.map { _ in
                result.saveFailure == nil ? "Copied · \(Self.size(of: URL(fileURLWithPath: result.path)))" : "Copied · not saved"
            })
            StatusFile.update {
                $0.state = "idle"
                $0.lastRecording = result
                $0.lastError = error.map { "Recording ended by macOS: \($0.localizedDescription)" }
            }
            let made = Delivery.Output(format: .mp4, speed: Config.Speed(rawValue: result.speed ?? 1) ?? .normal)
            let wanted = Delivery.Output(format: config.format, speed: config.speed)
            let missedTemporaryMP4 = config.format == .mp4 && result.stopToClipboardMilliseconds == nil && !config.save
            if config.afterCapture != .clipboard || missedTemporaryMP4 {
                openClip(result, recording: recording, made: made, wanted: wanted, saveFolder: config.saveFolderURL,
                         inEditor: config.afterCapture == .editor, copied: result.stopToClipboardMilliseconds != nil)
            } else if wanted != made {
                makeGIF(recording: recording, output: wanted, saveFolder: config.saveFolderURL, captureNotice: result.captureNotice)
            } else {
                discardUnshown(recording.url)
            }
            let inspected = await Delivery.inspect(result)
            StatusFile.update { if $0.lastRecording?.path == inspected.path { $0.lastRecording = inspected } }
        } catch {
            discardUnshown(recording.url)
            report(error)
        }
    }

    /// With saving off and no window for it, the recording goes once its clip is on the clipboard.
    private func discardUnshown(_ source: URL) {
        guard Paths.isTemporary(source) else { return }
        Paths.discard(source)
        StatusFile.update { if $0.lastRecording?.sourcePath == source.path { $0.lastRecording?.sourcePath = nil } }
    }

    /// Opens the preview window or the editor on the recording. `made` is what Stop put on the clipboard, when `copied`;
    /// the window makes `wanted` at once when it differs, a GIF for the GIF format.
    private func openClip(_ result: RecordingResult, recording: Recorder.Recording, made: Delivery.Output, wanted: Delivery.Output,
                          saveFolder: URL?, inEditor: Bool, copied: Bool) {
        preview?.close()
        let model = ClipModel(
            source: recording.url, output: URL(fileURLWithPath: result.path), made: made, choice: wanted, recordedFPS: recording.fps,
            saveFolder: saveFolder, saveFailure: result.saveFailure,
            pixelSize: CGSize(width: recording.pixelWidth, height: recording.pixelHeight), temporary: Paths.isTemporary(recording.url),
            copied: copied, handedOut: copied || wanted == made, captureNotice: result.captureNotice)
        show(model, inEditor: inEditor)
        model.makeIfNeeded()
    }

    private func show(_ model: ClipModel, inEditor: Bool) {
        session = model
        // A clip finished after a newer recording took over leaves status.json and the menu bar to the newer one.
        model.onHandout = { [weak self, weak model] url, output in
            guard let self, let model, session === model else { return }
            handedOut(url, output)
        }
        model.onProgress = { [weak self, weak model] fraction in
            guard let self, let model, session === model else { return }
            showMaking(fraction)
        }
        model.onOpenEditor = { [weak self, weak model] in
            guard let self, let model else { return }
            // The editor opens first, so the clip always has a window.
            openEditor(model)
            preview?.close()
            // Closing the preview stopped the player the editor shares.
            model.start()
        }
        if inEditor {
            openEditor(model)
            return
        }
        let window = PreviewWindow(model: model)
        window.onClose = { [weak self, weak window, weak model] in
            guard let self else { return }
            if preview === window { preview = nil }
            if let model { closed(model) }
        }
        preview = window
        window.show(on: pointerScreen())
    }

    private func openEditor(_ model: ClipModel) {
        if let editor, editor.model === model {
            editor.show()
            return
        }
        editor?.close()
        let window = EditorWindow(model: model)
        window.onClose = { [weak self, weak window, weak model] in
            guard let self else { return }
            if editor === window { editor = nil }
            if let model { closed(model) }
        }
        editor = window
        window.show()
    }

    /// A clip's window closed. With saving off, closing its last window discards the recording and the clips made from
    /// it, and Edit Last Recording with them; the clipboard's copy stays.
    private func closed(_ model: ClipModel) {
        guard model.temporary, preview?.model !== model, editor?.model !== model else { return }
        model.discard()
        StatusFile.update { if $0.lastRecording?.sourcePath == model.source.path { $0.lastRecording?.sourcePath = nil } }
        if session === model { session = nil }
    }

    /// The editor on the last recording: this run's, or the one status.json remembers, while its file is still there.
    @objc private func editLastRecording() {
        if let session {
            openEditor(session)
            return
        }
        guard let last = StatusFile.current.lastRecording, let sourcePath = last.sourcePath,
              FileManager.default.fileExists(atPath: sourcePath) else { return }
        let format = last.format.flatMap(Config.Format.init(rawValue:)) ?? .mp4
        let made = Delivery.Output(format: format, speed: Config.Speed(rawValue: last.speed ?? 1) ?? .normal)
        let config = Settings.reload()
        let model = ClipModel(
            source: URL(fileURLWithPath: sourcePath), output: URL(fileURLWithPath: last.path), made: made, choice: made,
            recordedFPS: last.requestedFPS, saveFolder: config.saveFolderURL, saveFailure: nil,
            pixelSize: CGSize(width: last.pixelWidth, height: last.pixelHeight), copied: Clipboard.holds(URL(fileURLWithPath: last.path)),
            captureNotice: last.captureNotice)
        show(model, inEditor: true)
    }

    /// With no window open, makes the GIF the format setting asks for and shows its progress in the menu bar. Something
    /// copied in the meantime stays on the clipboard.
    private func makeGIF(recording: Recorder.Recording, output: Delivery.Output, saveFolder: URL?, captureNotice: String?) {
        busy = true
        Task { [self] in
            defer { busy = false }
            do {
                let handout = try await Delivery.handOut(source: recording.url, output: output, recordedFPS: recording.fps,
                                                         saveFolder: saveFolder, temporary: Paths.isTemporary(recording.url)) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        if self?.latestSource == recording.url { self?.showMaking(fraction) }
                    }
                }
                guard latestSource == recording.url else {
                    discardUnshown(recording.url)
                    return
                }
                showMaking(nil)
                if !handout.copied, Paths.isTemporary(recording.url) {
                    showIdle(note: "Clipboard changed · ready to copy")
                    let model = ClipModel(source: recording.url, output: handout.url, made: output, choice: output,
                                          recordedFPS: recording.fps, saveFolder: nil, saveFailure: handout.saveFailure,
                                          pixelSize: CGSize(width: recording.pixelWidth, height: recording.pixelHeight),
                                          temporary: true, copied: false, handedOut: true, captureNotice: captureNotice)
                    show(model, inEditor: false)
                    return
                }
                discardUnshown(recording.url)
                if handout.copied || saveFolder != nil { handedOut(handout.url, output) }
                let size = Self.size(of: handout.url)
                showIdle(note: captureNotice ?? (handout.copied
                    ? "Copied GIF · \(size)" + (handout.saveFailure == nil ? "" : " · not saved")
                    : saveFolder != nil && handout.saveFailure == nil ? "Saved GIF · not copied" : "GIF not copied"))
            } catch {
                discardUnshown(recording.url)
                guard latestSource == recording.url else { return }
                showMaking(nil)
                showIdle(note: "GIF failed")
                StatusFile.update { $0.lastError = error.localizedDescription }
            }
        }
    }

    /// A file's size as Finder shows it: 2.2 MB.
    private static func size(of url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The menu bar shows a GIF's progress while one is made.
    /// The key fills from the bottom as the GIF is made, with the percentage beside it in tabular figures.
    private func showMaking(_ fraction: Double?) {
        guard !recorder.isRecording, let button = statusItem.button else { return }
        button.image = fraction.map { MenuBarGlyph.key(dot: false, fill: $0) } ?? MenuBarGlyph.key()
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.title = fraction.map { String(format: " %d%%", Int($0 * 100)) } ?? ""
    }

    private func handedOut(_ url: URL, _ output: Delivery.Output) {
        StatusFile.update {
            $0.lastRecording?.path = url.path
            $0.lastRecording?.format = output.format.rawValue
            $0.lastRecording?.speed = output.speed.rawValue
            $0.lastRecording?.durationSeconds = nil
            $0.lastRecording?.frameCount = nil
            $0.lastRecording?.averageFPS = nil
            $0.lastRecording?.fileBytes = nil
        }
        Task {
            guard let last = StatusFile.current.lastRecording else { return }
            let inspected = await Delivery.inspect(last)
            if StatusFile.current.lastRecording?.path == inspected.path { StatusFile.update { $0.lastRecording = inspected } }
        }
    }

    private func report(_ error: Error) {
        outline.hide()
        // ScreenCaptureKit names the refused grant TCC; macOS can refuse until a relaunch even after it is switched on.
        if !ScreenPermission.isAllowed || error.localizedDescription.contains("TCC") {
            showIdle(note: "Needs Screen Recording")
            onboarding.show(at: .permission)
        } else {
            showIdle(note: "Recording failed")
        }
        StatusFile.update { $0.state = "idle"; $0.lastError = error.localizedDescription }
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    }

    // MARK: Menu bar

    private func statusLine() -> String {
        let config = Settings.current
        let screen = statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let fps = min(max(1, screen.maximumFramesPerSecond), FrameRate.smallRecordingMaximum)
        let destination = config.saveFolderURL.map { "Copies and saves to \($0.lastPathComponent)" } ?? "Copies to the clipboard"
        let speed = config.speed == .normal ? "" : " · plays at \(config.speed.label)"
        return "\(destination) · up to \(fps) fps\(speed)"
    }

    private func showIdle(note: String? = nil) {
        ticker?.invalidate()
        ticker = nil
        startedAt = nil
        guard let button = statusItem.button else { return }
        // A copied clip shows a check in the key for as long as its note shows.
        button.image = MenuBarGlyph.key(check: note?.hasPrefix("Copied") == true)
        button.title = note.map { " \($0)" } ?? ""
        button.imagePosition = .imageLeading
        if let note {
            Task {
                try? await Task.sleep(for: .seconds(4))
                guard let button = statusItem.button, button.title == " \(note)" else { return }
                button.title = ""
                button.image = MenuBarGlyph.key()
            }
        }
    }

    private func showRecording() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        updateElapsed()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.updateElapsed() }
        }
    }

    private func updateElapsed() {
        guard let startedAt else { return }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        statusItem.button?.image = MenuBarGlyph.recording(String(format: "%d:%02d", seconds / 60, seconds % 60))
    }

    private func showMenu() {
        let menu = NSMenu()
        if let milliseconds = StatusFile.current.lastRecording?.stopToClipboardMilliseconds {
            menu.addItem(withTitle: String(format: "Last: copied %.0f ms after Stop", milliseconds), action: nil, keyEquivalent: "")
            menu.addItem(.separator())
        }
        if StatusFile.current.configNotice != nil {
            menu.addItem(withTitle: "config.json has an error", action: nil, keyEquivalent: "")
        }
        if session != nil || StatusFile.current.lastRecording?.sourcePath.map({ FileManager.default.fileExists(atPath: $0) }) == true {
            let edit = menu.addItem(withTitle: "Edit Last Recording…", action: #selector(editLastRecording), keyEquivalent: "e")
            edit.target = self
        }
        let folder = menu.addItem(withTitle: "Show Recordings in Finder", action: #selector(showRecordings), keyEquivalent: "")
        folder.target = self
        let settingsItem = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        let welcome = menu.addItem(withTitle: "Show Welcome", action: #selector(showWelcome), keyEquivalent: "")
        welcome.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(Paths.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Where the icon sits, for status.json. macOS hides icons that don't fit beside the notch, and a hidden icon
    /// either has no window frame or one off the menu bar's visible part.
    private func noteIconPlace() {
        let place: String
        if let window = statusItem.button?.window, window.frame.height > 0, let screen = window.screen {
            let frame = window.frame
            var parts = ["x \(Int(frame.minX))–\(Int(frame.maxX)), y \(Int(frame.minY)) on a \(Int(screen.frame.width))×\(Int(screen.frame.height)) screen"]
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                parts.append("notch \(Int(left.maxX))–\(Int(right.minX))")
            }
            place = parts.joined(separator: ", ")
        } else {
            place = "no place in the menu bar"
        }
        StatusFile.update { $0.menuBarIcon = place }
    }

    /// The menus the app shows while the settings window is open.
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: Paths.appName)
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        let welcome = appMenu.addItem(withTitle: "Show Welcome", action: #selector(showWelcome), keyEquivalent: "")
        welcome.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(Paths.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        return main
    }

    @objc private func showSettings() { settings.show() }

    @objc private func showWelcome() { onboarding.show(at: .first) }

    @objc private func showRecordings() {
        let folder = Settings.reload().saveFolderURL ?? Paths.recordings
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
