import AppKit
import GIFMachineCore
import SwiftUI

/// Key-cast: the keys pressed while recording show as a chip near the bottom of the recorded area, drawn into the
/// recording. Ported from karaggeorge's MIT key-cast (see NOTICE), with its event
/// tap made listen-only, so no key is held up or changed; a listen-only tap needs Input Monitoring, not Accessibility.
/// Password fields turn on secure input, which keeps their keys from every tap. The chip follows KeyCats's Tag+ chip:
/// SF Mono semibold, near-black fill, white ring.
@MainActor
final class KeyCast {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var mode: Config.KeyCast = .off
    private let panel = ChipPanel()
    private let chip = ChipModel()
    private var area = CGRect.zero
    private var lastTyped = Date.distantPast
    private var clear: Timer?
    private var heldModifiers: Shortcut.Modifiers = []

    static var allowed: Bool { CGPreflightListenEventAccess() }

    /// `area` is the recorded part of the screen, in screen coordinates.
    func start(mode: Config.KeyCast, area: CGRect) {
        stop()
        guard mode != .off, Self.allowed else { return }
        self.mode = mode
        self.area = area
        chip.fontSize = min(24, max(14, area.width / 40))
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, info in
            if let info {
                let keyCast = Unmanaged<KeyCast>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { keyCast.received(type, event) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        clear?.invalidate()
        clear = nil
        chip.text = ""
        heldModifiers = []
        panel.orderOut(nil)
    }

    private func received(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let ns = NSEvent(cgEvent: event) else { return }
        let modifiers = HotKeys.modifiers(of: ns)
        if type == .flagsChanged {
            heldModifiers = modifiers
            // Modifiers held on their own show while they're down, unless a chip is still showing.
            guard clear == nil else { return }
            show(KeyLabel.symbols(modifiers), lingers: false)
            return
        }
        guard type == .keyDown, let label = KeyLabel.label(keyCode: ns.keyCode, modifiers: modifiers, characters: ns.characters,
                                                         base: ns.charactersIgnoringModifiers, mode: mode) else { return }
        if label.typing {
            let joins = chip.typing && Date().timeIntervalSince(lastTyped) < 1.2
            lastTyped = Date()
            // A space that starts a chip shows as ␣, so the chip isn't empty.
            show(joins ? String((chip.text + label.text).suffix(28)) : (label.text == " " ? "␣" : label.text), typing: true)
        } else {
            // A held shortcut repeats; only the arrows and Delete, which people hold on purpose, show again.
            guard !ns.isARepeat || [123, 124, 125, 126, 51, 117].contains(ns.keyCode) else { return }
            show(label.text)
        }
    }

    private func show(_ text: String, typing: Bool = false, lingers: Bool = true) {
        chip.typing = typing
        chip.text = text
        clear?.invalidate()
        clear = nil
        guard !text.isEmpty else {
            panel.orderOut(nil)
            return
        }
        panel.show(ChipView(model: chip), centeredAt: CGPoint(x: area.midX, y: area.minY + max(36, area.height * 0.12)), within: area)
        guard lingers else { return }
        clear = Timer.scheduledTimer(withTimeInterval: typing ? 1.6 : 1.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clear = nil
                let held = KeyLabel.symbols(self.heldModifiers)
                self.show(held, lingers: false)
            }
        }
    }
}

@MainActor
final class ChipModel: ObservableObject {
    @Published var text = ""
    @Published var fontSize: CGFloat = 22
    var typing = false
}

/// The chip: SF Mono semibold on near-black ink, with a white ring, so it reads over light and dark apps.
struct ChipView: View {
    @ObservedObject var model: ChipModel

    var body: some View {
        Text(model.text)
            .font(.system(size: model.fontSize, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, model.fontSize * 0.6)
            .padding(.vertical, model.fontSize * 0.32)
            .background(RoundedRectangle(cornerRadius: model.fontSize * 0.36, style: .continuous).fill(Color(nsColor: Theme.pillInk)))
            .overlay(RoundedRectangle(cornerRadius: model.fontSize * 0.36, style: .continuous).strokeBorder(Color.white, lineWidth: 2))
            .fixedSize()
            .padding(2)
    }
}

/// A window that never takes clicks or focus. Recordings leave out the app's windows that are on screen when they start;
/// this one only appears afterwards, so it's in the recording.
final class ChipPanel: NSPanel {
    private var hosting: NSHostingView<ChipView>?

    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ view: ChipView, centeredAt center: CGPoint, within area: CGRect) {
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            self.hosting = hosting
            contentView = hosting
        }
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let x = min(max(center.x - size.width / 2, area.minX + 4), area.maxX - size.width - 4)
        setFrame(CGRect(x: x.rounded(), y: (center.y - size.height / 2).rounded(), width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }
}
