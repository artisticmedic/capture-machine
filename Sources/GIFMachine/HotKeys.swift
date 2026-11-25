import AppKit
import Carbon.HIToolbox
import GIFMachineCore
import SwiftUI

/// The global shortcuts, registered with the system's hot key service, which needs no permission. A shortcut another
/// app already holds can't be registered; it's listed in `failed`.
@MainActor
final class HotKeys: ObservableObject {
    static let shared = HotKeys()
    @Published private(set) var failed: Set<ShortcutAction> = []
    var onAction: (ShortcutAction) -> Void = { _ in }
    private var registered: [EventHotKeyRef] = []
    private var actions: [UInt32: ShortcutAction] = [:]
    private var current: [ShortcutAction: Shortcut] = [:]
    private var handler: EventHandlerRef?
    private var suspended = false

    func register(_ shortcuts: [ShortcutAction: Shortcut]) {
        guard shortcuts != current || registered.isEmpty else { return }
        current = shortcuts
        if !suspended { apply() }
    }

    /// While a shortcut is being typed in Settings, so typing one that's set doesn't start a recording.
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        apply()
    }

    private func apply() {
        installHandler()
        unregisterAll()
        var failures: Set<ShortcutAction> = []
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let shortcut = current[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x474D_5348, id: UInt32(index + 1))
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), Self.carbonModifiers(shortcut.modifiers), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered.append(ref)
                actions[id.id] = action
            } else {
                failures.insert(action)
            }
        }
        failed = failures
    }

    private func unregisterAll() {
        for ref in registered { UnregisterEventHotKey(ref) }
        registered = []
        actions = [:]
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let number = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.fire(number) } }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire(_ id: UInt32) {
        guard let action = actions[id] else { return }
        onAction(action)
    }

    private static func carbonModifiers(_ modifiers: Shortcut.Modifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    static func modifiers(of event: NSEvent) -> Shortcut.Modifiers {
        let flags = event.modifierFlags
        var modifiers: Shortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

/// A shortcut in Settings: click, then type it. Escape cancels, Delete clears. It needs Command, Control or Option,
/// unless it's a function key.
struct ShortcutField: View {
    let shortcut: Shortcut?
    let change: (Shortcut?) -> Void
    @State private var listening = false
    @State private var monitor: Any?
    @State private var refused = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                listening ? stop() : listen()
            } label: {
                Text(listening ? (refused ? "Add ⌘, ⌃ or ⌥" : "Type a shortcut…") : (shortcut?.display ?? "Record Shortcut"))
                    .monospacedDigit()
                    .foregroundStyle(shortcut == nil && !listening ? .secondary : .primary)
                    .frame(minWidth: 110)
            }
            .buttonStyle(PillButtonStyle())
            .accessibilityLabel(shortcut.map { "Shortcut \($0.display)" } ?? "Record shortcut")
            if shortcut != nil, !listening {
                Button {
                    change(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear shortcut")
                .help("Clear")
            }
        }
        .onDisappear { stop() }
    }

    private func listen() {
        listening = true
        refused = false
        HotKeys.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { take(event) }
            return handled ? nil : event
        }
    }

    private func take(_ event: NSEvent) -> Bool {
        let modifiers = HotKeys.modifiers(of: event)
        if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            stop()
            return true
        }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete), modifiers.isEmpty {
            change(nil)
            stop()
            return true
        }
        let typed = Shortcut(keyCode: event.keyCode, modifiers: modifiers)
        guard Shortcut.name(of: event.keyCode) != nil, typed.isAllowed else {
            refused = true
            NSSound.beep()
            return true
        }
        change(typed)
        stop()
        return true
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if listening { HotKeys.shared.resume() }
        listening = false
    }
}
