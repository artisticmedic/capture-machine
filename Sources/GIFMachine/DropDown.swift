import AppKit
import GIFMachineCore
import SwiftUI

// The drop-down toolbar style: the design language's glass panel, anchored to the menu bar icon.

enum DropDownItem: Hashable {
    case tool(Tool)
    case settings
    case welcome

    static let all: [DropDownItem] = Tool.allCases.map { .tool($0) } + [.settings, .welcome]
}

final class DropDownModel: ObservableObject {
    @Published var selected: DropDownItem?
    let status: String
    let choose: (DropDownItem) -> Void

    init(status: String, choose: @escaping (DropDownItem) -> Void) {
        self.status = status
        self.choose = choose
    }

    func move(_ delta: Int) {
        let items = DropDownItem.all
        let index = selected.flatMap { items.firstIndex(of: $0) } ?? (delta > 0 ? -1 : items.count)
        selected = items[(index + delta + items.count) % items.count]
    }
}

struct DropDownContent: View {
    @ObservedObject var model: DropDownModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Paths.appName).font(.system(size: 15, weight: .semibold))
                Text(model.status).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
            VStack(spacing: 2) {
                ForEach(Tool.allCases, id: \.self) { tool in
                    row(.tool(tool), title: tool.title, symbol: tool.symbol, shortcut: tool.key)
                }
            }
            Divider().padding(.horizontal, 10)
            VStack(spacing: 2) {
                row(.settings, title: "Settings…", symbol: "gearshape", shortcut: "⌘,")
                row(.welcome, title: "Show Welcome", symbol: "hand.wave", shortcut: nil)
            }
        }
        .padding(10)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.primary)
    }

    private func row(_ item: DropDownItem, title: String, symbol: String, shortcut: String?) -> some View {
        Button { model.choose(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 22)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 8)
                if let shortcut { Text(shortcut).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
            .background {
                if model.selected == item {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Theme.rowSelection))
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { inside in
            if inside { model.selected = item } else if model.selected == item { model.selected = nil }
        }
        .accessibilityLabel(title)
        .accessibilityHint(shortcut.map { "Keyboard shortcut \($0)" } ?? "")
    }
}

@MainActor
final class DropDown {
    private let panel = GlassPanel(level: .popUpMenu)
    private var model: DropDownModel?
    private weak var button: NSStatusBarButton?
    private var monitors: [Any] = []
    private(set) var isOpen = false
    var onClose: (() -> Void)?

    func open(from button: NSStatusBarButton, status: String, choose: @escaping (DropDownItem) -> Void) {
        guard let window = button.window else { return }
        let model = DropDownModel(status: status) { [weak self] item in
            self?.close()
            choose(item)
        }
        self.model = model
        self.button = button
        let content = glassSurface(DropDownContent(model: model))
        let size = content.frame.size
        panel.contentView = content
        // An icon that has no place in the menu bar, such as one hidden by the menu bar's overflow, has no height. The
        // drop-down then hangs from the right end of the menu bar on the pointer's screen.
        let placed = window.frame.height > 0 && window.screen != nil
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let screen = placed ? window.screen?.visibleFrame ?? pointerScreen.visibleFrame : pointerScreen.visibleFrame
        let anchor = placed
            ? window.convertToScreen(button.convert(button.bounds, to: nil))
            : CGRect(x: screen.maxX - 8, y: screen.maxY, width: 0, height: 0)
        let x = min(max(anchor.maxX - size.width + 12, screen.minX + 8), screen.maxX - size.width - 8)
        let y = max(screen.minY + 8, anchor.minY - size.height - 6)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        isOpen = true
        button.highlight(true)
        panel.orderFrontRegardless()
        panel.makeKey()
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel, event.window !== self.button?.window { self.close() }
            }
            return event
        } as Any)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        panel.orderOut(nil)
        button?.highlight(false)
        model = nil
        panel.contentView = nil
        onClose?()
    }

    func key(_ event: NSEvent) -> Bool {
        guard isOpen, let model else { return false }
        switch event.keyCode {
        case KeyCode.escape: close()
        case KeyCode.up: model.move(-1)
        case KeyCode.down: model.move(1)
        case KeyCode.tab: model.move(event.modifierFlags.contains(.shift) ? -1 : 1)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if let item = model.selected { model.choose(item) }
        default:
            let key = event.charactersIgnoringModifiers?.lowercased()
            if event.modifierFlags.contains(.command) {
                guard key == "," else { return false }
                model.choose(.settings)
                return true
            }
            guard let tool = Tool.allCases.first(where: { $0.key.lowercased() == key }) else { return false }
            model.choose(.tool(tool))
        }
        return true
    }
}
