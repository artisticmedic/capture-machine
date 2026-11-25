import AppKit
import SwiftUI

// The bottom bar toolbar style: a floating bar at the bottom of the screen, as macOS's screenshot toolbar (⌘⇧5) does.
// Choose a tool, adjust the area, then Record.

final class BarModel: ObservableObject {
    @Published var tool: Tool
    @Published var readout: String?
    @Published var hovered: Tool?
    var onTool: (Tool) -> Void = { _ in }
    var onRecord: () -> Void = {}
    var onClose: () -> Void = {}

    init(tool: Tool) { self.tool = tool }

    var prompt: String {
        switch tool {
        case .window: "Click a window"
        case .section: "Drag a section"
        case .fullScreen: ""
        }
    }
}

struct BarContent: View {
    @ObservedObject var model: BarModel

    var body: some View {
        HStack(spacing: 4) {
            Button(action: model.onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 32, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel("Close")
            .help("Close (Esc)")

            divider
            ForEach(Tool.allCases, id: \.self) { tool in toolButton(tool) }
            divider

            Button(action: model.onRecord) {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle").font(.system(size: 15))
                    Text("Record").font(.system(size: 13, weight: .semibold))
                    Text(model.readout ?? model.prompt)
                        .font(.system(size: 12)).monospacedDigit().opacity(0.7)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(width: 190, alignment: .leading)
                }
                .foregroundStyle(model.readout == nil ? Color.secondary : Color.white)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .contentShape(Rectangle())
                .background {
                    // Red is kept for recording in the design language, so Record is the one red thing on the bar.
                    if model.readout != nil { RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .systemRed)) }
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(model.readout == nil)
            .opacity(model.readout == nil ? 0.6 : 1)
            .accessibilityLabel(model.readout.map { "Record \($0)" } ?? "Record")
            .help("Record (Return)")
        }
        .padding(8)
        .fixedSize()
        .foregroundStyle(.primary)
    }

    private var divider: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 20).padding(.horizontal, 4)
    }

    private func toolButton(_ tool: Tool) -> some View {
        Button { model.onTool(tool) } label: {
            HStack(spacing: 7) {
                Image(systemName: tool.symbol).font(.system(size: 15))
                    .foregroundStyle(model.tool == tool ? .primary : .secondary)
                Text(tool.title).font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .contentShape(Rectangle())
            .background {
                if model.tool == tool {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Theme.toolSelection))
                } else if model.hovered == tool {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Theme.rowHover))
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { inside in
            if inside { model.hovered = tool } else if model.hovered == tool { model.hovered = nil }
        }
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
        .help("\(tool.title) (\(tool.key))")
    }
}

@MainActor
final class BottomBar {
    private let panel = GlassPanel(level: .overOverlay)
    private let model: BarModel
    private let picker: SectionPicker
    var onRecord: ((Capture) -> Void)?
    var onClose: (() -> Void)?

    init(tool: Tool) {
        let screen = pointerScreen()
        model = BarModel(tool: tool)
        picker = SectionPicker(screen: screen, tool: tool, style: PickerStyle(
            commitsOnRelease: false, clickMeansFullScreen: false, cursorChip: false, hint: { _ in nil }))
        picker.view.onSelection = { [weak self] capture in self?.model.readout = capture?.label }
        picker.view.onCancel = { [weak self] in self?.close() }
        model.readout = picker.view.selection?.label
        model.onTool = { [weak self] tool in self?.select(tool) }
        model.onRecord = { [weak self] in self?.record() }
        model.onClose = { [weak self] in self?.close() }

        let content = glassSurface(BarContent(model: model))
        let size = content.frame.size
        panel.contentView = content
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 24, width: size.width, height: size.height), display: true)
    }

    var tool: Tool { model.tool }

    /// The menu bar icon's frame in screen coordinates, so a click on it closes the bar.
    func setCancelZone(_ icon: CGRect) {
        let origin = picker.view.screen.frame.origin
        picker.view.cancelZone = icon.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    func show() {
        picker.show()
        panel.orderFrontRegardless()
    }

    func select(_ tool: Tool) {
        model.tool = tool
        picker.view.tool = tool
        model.readout = picker.view.selection?.label
    }

    func record() {
        guard let capture = picker.view.selection else { return }
        teardown()
        onRecord?(capture)
    }

    func close() {
        teardown()
        onClose?()
    }

    private func teardown() {
        picker.close()
        panel.orderOut(nil)
        panel.contentView = nil
    }

    func key(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyCode.escape: close()
        case KeyCode.returnKey, KeyCode.keypadEnter: record()
        default:
            guard let tool = Tool.allCases.first(where: { $0.key.lowercased() == event.charactersIgnoringModifiers?.lowercased() })
            else { return false }
            select(tool)
        }
        return true
    }
}
