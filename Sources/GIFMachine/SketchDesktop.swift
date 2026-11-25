import AppKit
import GIFMachineCore
import SwiftUI

// The Mac the sketch films: the team chat and the staging checkout side by side on one desktop, laid out so both read
// when the whole desktop is in view. Targets for the cursor are placed by measuring the real text, so `point(_:_:)`
// lands on what is drawn.

/// The filmed desktop's layout, in its own points. On a 22-point margin: the chat and the browser start 14 below the
/// menu bar and 22 in from the sides, the chat ends 22 above the bottom, and the Apple logo and the clock sit the same
/// distance from their edges.
enum SketchDesk {
    static let size = CGSize(width: 760, height: 475)
    static let menuBar: CGFloat = 26
    static let font: CGFloat = 12
    static let appleX: CGFloat = 22
    static let appX: CGFloat = 42
    static let menuGap: CGFloat = 17
    static let edge: CGFloat = 15
    static let menus = ["File", "Edit", "View", "Window"]
    /// The system's icons, by distance left of the clock. Capture Machine's sits between them and the clock.
    static let systemIcons: [(symbol: String, offset: CGFloat, size: CGFloat)] =
        [("battery.75percent", 116, 14), ("wifi", 89, 12.5), ("magnifyingglass", 66, 12), ("switch.2", 44, 12)]
    static let statusGap: CGFloat = 10
    static let statusSize: CGFloat = 13
    static let chat = CGRect(x: 22, y: 40, width: 292, height: 413)
    static let window = CGRect(x: 338, y: 40, width: 400, height: 233)
    static let toolbar: CGFloat = 30
    static let radius: CGFloat = 12
    static var page: CGRect { CGRect(x: window.minX, y: window.minY + toolbar, width: window.width, height: window.height - toolbar) }
    /// The checkout is laid out at this size and drawn at the window's width.
    static let checkoutSize = CGSize(width: 370, height: 188)
    /// The Pay button, in the checkout's own points.
    static let payButton = CGRect(x: 194, y: 132, width: 150, height: 28)
    static let pageScale = window.width / checkoutSize.width
    static let converterScale: CGFloat = 0.81
    /// Centre of the recording's icon on the desktop.
    static let file = CGPoint(x: 580, y: 360)
    static let fileScale: CGFloat = 0.75
    /// QuickTime's menu and Capture Machine's drop-down, at their real size times this.
    static let menuScale: CGFloat = 0.85
    static let cardScale: CGFloat = 0.75
    static let rest = CGPoint(x: 620, y: 180)

    static func width(_ text: String, _ size: CGFloat = font, _ weight: NSFont.Weight = .regular, digits: Bool = false) -> CGFloat {
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    static func front(_ frame: Sketch.Frame) -> String {
        switch frame.mac {
        case .quickTimeMenu, .quickTimeRecording: "QuickTime Player"
        case .savedFile, .draggingFile: "Finder"
        default: "Safari"
        }
    }

    /// Left edges of the menus after the app's name.
    static func menuX(_ frame: Sketch.Frame) -> [CGFloat] {
        var x = appX + width(front(frame), font, .semibold) + menuGap
        return menus.map { item in
            defer { x += width(item) + menuGap }
            return x
        }
    }

    static func clockText(_ frame: Sketch.Frame) -> String { "Fri Nov 20  \(frame.clock)" }
    static func clockX(_ frame: Sketch.Frame) -> CGFloat { size.width - edge - width(clockText(frame), font, digits: true) }

    static func recordingText(_ frame: Sketch.Frame) -> String? {
        switch frame.mac {
        case .quickTimeRecording(let seconds), .recording(let seconds): String(format: "0:%02d", seconds)
        default: nil
        }
    }

    /// Whether anything sits in the status slot by the clock: QuickTime's stop button while it records, and Capture Machine
    /// once it's installed.
    static func hasStatusItem(_ frame: Sketch.Frame) -> Bool {
        if case .quickTimeRecording = frame.mac { return true }
        return frame.half == .with
    }

    /// Centre of the status icon. It sits left of a running timer, as a status item's image leads its title.
    static func statusIcon(_ frame: Sketch.Frame) -> CGPoint {
        let text = recordingText(frame).map { width($0, font, digits: true) + 5 } ?? 0
        return CGPoint(x: clockX(frame) - statusGap - text - statusSize * 0.65, y: menuBar / 2)
    }

    static let dropDownWidth: CGFloat = 320

    static func dropDownOrigin(_ frame: Sketch.Frame) -> CGPoint {
        CGPoint(x: statusIcon(frame).x + 21 * menuScale - dropDownWidth * menuScale, y: menuBar + 6 * menuScale)
    }

    static func fileMenuOrigin(_ frame: Sketch.Frame) -> CGPoint { CGPoint(x: menuX(frame)[0] - 9 * menuScale, y: menuBar) }

    static func point(_ target: Sketch.Target, _ frame: Sketch.Frame) -> CGPoint {
        switch target {
        case .rest: rest
        case .pay:
            CGPoint(x: page.minX + payButton.midX * pageScale, y: page.minY + payButton.midY * pageScale)
        case .fileMenu: CGPoint(x: menuX(frame)[0] + width("File") / 2, y: menuBar / 2)
        case .newScreenRecording:
            CGPoint(x: fileMenuOrigin(frame).x + 70 * menuScale, y: fileMenuOrigin(frame).y + (5 + 22 * 2 + 11) * menuScale)
        case .quickTimeStop, .menuIcon: statusIcon(frame)
        case .desktopFile: file
        case .chatDrop: CGPoint(x: chat.minX + chat.width * 0.62, y: chat.maxY - 110)
        case .section: CGPoint(x: dropDownOrigin(frame).x + 90 * menuScale, y: dropDownOrigin(frame).y + 120 * menuScale)
        case .selectionStart: CGPoint(x: page.minX, y: page.minY)
        case .selectionEnd: CGPoint(x: page.maxX, y: page.maxY)
        }
    }
}

/// The desktop at `frame.time`.
struct DeskScene: View {
    let frame: Sketch.Frame

    private var t: Double { frame.time }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            switch frame.mac {
            case .savedFile: DeskFileIcon(selected: false).scaleEffect(SketchDesk.fileScale).position(SketchDesk.file)
            case .draggingFile: DeskFileIcon(selected: true).opacity(0.5).scaleEffect(SketchDesk.fileScale).position(SketchDesk.file)
            default: EmptyView()
            }
            ChatCard(frame: frame, width: SketchDesk.chat.width, height: SketchDesk.chat.height)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                .shadow(color: .black.opacity(0.25), radius: 26, y: 12)
                .blur(radius: frame.rewind.map { 3 * sin(.pi * $0) } ?? 0)
                .offset(x: SketchDesk.chat.minX, y: SketchDesk.chat.minY)
            // Safari opens after you answer Jay, the way a window opens: up from slightly smaller, fading in.
            let opened = Motion.easeOut(frame.browser)
            SafariWindow(url: converterOpen ? "free-gif-converter.online" : "staging.shop.dev/checkout",
                         bar: SketchDesk.toolbar, radius: SketchDesk.radius) { page }
                .frame(width: SketchDesk.window.width, height: SketchDesk.window.height)
                .scaleEffect(0.92 + 0.08 * opened)
                .opacity(opened)
                .offset(x: SketchDesk.window.minX, y: SketchDesk.window.minY)
            overlay
            DeskMenuBar(frame: frame)
            menus
        }
        .frame(width: SketchDesk.size.width, height: SketchDesk.size.height, alignment: .topLeading)
        .clipped()
    }

    /// The converter's tab is closed once its GIF is posted to the chat.
    private var converterOpen: Bool {
        switch frame.mac {
        case .converter: true
        case .converterDone: t < Sketch.gifPosted
        default: false
        }
    }

    @ViewBuilder private var page: some View {
        let page = SketchDesk.page
        switch frame.mac {
        case .converter(let progress) where converterOpen: scaled(ConverterPage(progress: progress, done: false), SketchDesk.converterScale, page)
        case .converterDone where converterOpen: scaled(ConverterPage(progress: 1, done: true), SketchDesk.converterScale, page)
        default: scaled(CheckoutPage(time: t, fixed: frame.mac == .fixed), SketchDesk.pageScale, page)
        }
    }

    private func scaled(_ content: some View, _ scale: CGFloat, _ page: CGRect) -> some View {
        content.frame(width: page.width / scale, height: page.height / scale, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: page.width, height: page.height, alignment: .topLeading)
    }

    @ViewBuilder private var overlay: some View {
        switch frame.mac {
        case .call:
            // In from the right; out the same way as the rewind starts.
            let shown = Motion.easeOut((t - Sketch.callStart) / 0.35)
            let gone = Motion.easeOut((frame.rewind ?? 0) / 0.18)
            CallBanner()
                .offset(x: SketchDesk.size.width - 12 - CallBanner.width + 40 * (1 - shown) + 60 * gone, y: SketchDesk.menuBar + 8)
                .opacity(shown * (1 - gone))
        case .selecting(let progress):
            DeskSelection(progress: progress, recording: false)
        case .recording:
            DeskSelection(progress: 1, recording: true)
        case .copied:
            let shown = Motion.easeOut((t - Sketch.copiedStart) / 0.25)
            VStack(alignment: .leading, spacing: 8) {
                CheckoutPage(time: t, fixed: false, loops: true)
                    .frame(width: SketchDesk.checkoutSize.width, height: SketchDesk.checkoutSize.height)
                    .scaleEffect(240 / SketchDesk.checkoutSize.width, anchor: .topLeading)
                    .frame(width: 240, height: 240 * SketchDesk.checkoutSize.height / SketchDesk.checkoutSize.width, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("Copied · 1.4 MB").font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
            .scaleEffect(SketchDesk.cardScale, anchor: .topLeading)
            .offset(x: SketchDesk.size.width - (12 + 264) * SketchDesk.cardScale,
                    y: SketchDesk.menuBar + 10 * SketchDesk.cardScale - 12 * (1 - shown))
            .opacity(shown)
        default:
            EmptyView()
        }
    }

    /// Menus open over everything, the menu bar included.
    @ViewBuilder private var menus: some View {
        switch frame.mac {
        case .quickTimeMenu(let open, let chosen):
            if open {
                QuickTimeFileMenu(chosen: chosen).scaleEffect(SketchDesk.menuScale, anchor: .topLeading)
                    .offset(x: SketchDesk.fileMenuOrigin(frame).x, y: SketchDesk.fileMenuOrigin(frame).y)
            }
        case .dropDown(let chosen):
            GIFMachineDropDown(chosen: chosen).scaleEffect(SketchDesk.menuScale, anchor: .topLeading)
                .offset(x: SketchDesk.dropDownOrigin(frame).x, y: SketchDesk.dropDownOrigin(frame).y)
        default:
            EmptyView()
        }
    }
}

/// The macOS 27 menu bar: no backdrop, the wallpaper shows through.
private struct DeskMenuBar: View {
    let frame: Sketch.Frame
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let xs = SketchDesk.menuX(frame)
        let textY = (SketchDesk.menuBar - SketchDesk.font * 1.24) / 2
        let clockX = SketchDesk.clockX(frame)
        // A timer widens the item by the clock and pushes the system icons left; with no item there, they close up.
        let pushed = !SketchDesk.hasStatusItem(frame) ? -(SketchDesk.statusSize * 1.3 + 6)
            : SketchDesk.recordingText(frame).map { SketchDesk.width($0, SketchDesk.font, digits: true) + 5 } ?? 0
        ZStack(alignment: .topLeading) {
            Image(systemName: "apple.logo").font(.system(size: SketchDesk.font + 2)).position(x: SketchDesk.appleX, y: SketchDesk.menuBar / 2 - 0.5)
            Text(SketchDesk.front(frame)).font(.system(size: SketchDesk.font, weight: .semibold)).fixedSize().offset(x: SketchDesk.appX, y: textY)
            ForEach(Array(SketchDesk.menus.enumerated()), id: \.offset) { index, item in
                Text(item).font(.system(size: SketchDesk.font)).fixedSize().offset(x: xs[index], y: textY)
            }
            status(textY)
            ForEach(Array(SketchDesk.systemIcons.enumerated()), id: \.offset) { _, icon in
                Image(systemName: icon.symbol).font(.system(size: icon.size)).position(x: clockX - icon.offset - pushed, y: SketchDesk.menuBar / 2)
            }
            Text(SketchDesk.clockText(frame)).font(.system(size: SketchDesk.font)).monospacedDigit().fixedSize().offset(x: clockX, y: textY)
        }
        .foregroundStyle(scheme == .dark ? Color.white : Color.black)
        .shadow(color: (scheme == .dark ? Color.black : Color.white).opacity(0.25), radius: 2)
        .frame(width: SketchDesk.size.width, height: SketchDesk.menuBar, alignment: .topLeading)
    }

    @ViewBuilder private func status(_ textY: CGFloat) -> some View {
        let icon = SketchDesk.statusIcon(frame)
        let size = SketchDesk.statusSize
        if case .quickTimeRecording = frame.mac, let text = SketchDesk.recordingText(frame) {
            Image(systemName: "stop.circle.fill").font(.system(size: size)).foregroundStyle(.red).position(icon)
            Text(text).font(.system(size: SketchDesk.font)).monospacedDigit().foregroundStyle(.red).fixedSize()
                .offset(x: icon.x + size * 0.7, y: textY)
        } else if frame.half == .with {
            let open: Bool = { if case .dropDown = frame.mac { true } else { false } }()
            RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(open ? 0.18 : 0))
                .frame(width: size * 1.85, height: SketchDesk.menuBar - 4).position(icon)
            // The app's own menu bar item: the key, then the red capsule with the time while it records.
            if let text = SketchDesk.recordingText(frame) {
                let capsule = MenuBarGlyph.recording(text, height: size * 1.1)
                Image(nsImage: capsule).position(x: icon.x - size * 0.55 + capsule.size.width / 2, y: icon.y)
            } else {
                Image(nsImage: MenuBarGlyph.key(size: size * 1.1)).foregroundStyle(Color.primary).position(icon)
            }
        }
    }
}

/// QuickTime's File menu, at the size macOS draws it.
private struct QuickTimeFileMenu: View {
    let chosen: Bool

    private let items: [(String, String)?] = [("New Movie Recording", "⌥⌘N"), ("New Audio Recording", "⌃⌥⌘N"),
                                              ("New Screen Recording", "⌃⌘N"), nil, ("Open File…", "⌘O"), ("Open Recent", "›"),
                                              nil, ("Close", "⌘W")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if let (title, key) = item {
                    let on = chosen && index == 2
                    HStack {
                        Text(title)
                        Spacer()
                        Text(key).foregroundStyle(on ? Color.white : .secondary)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(on ? Color.white : .primary)
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : .clear))
                } else {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
        }
        .padding(5)
        .frame(width: 262)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }
}

/// Capture Machine's drop-down, as the app draws it: 320 points wide, its rows 40 tall.
private struct GIFMachineDropDown: View {
    let chosen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Capture Machine").font(.system(size: 15, weight: .semibold))
                Text("Copies to the clipboard · up to 120 fps").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 42, alignment: .leading)
            VStack(spacing: 2) {
                row("Window", "macwindow", "W", on: false)
                row("Section", "rectangle.dashed", "S", on: chosen)
                row("Full screen", "display", "F", on: false)
            }
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.horizontal, 10)
            row("Settings…", "gearshape", "⌘,", on: false)
        }
        .padding(10)
        .frame(width: SketchDesk.dropDownWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private func row(_ title: String, _ symbol: String, _ key: String, on: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 22)
            Text(title).font(.system(size: 13))
            Spacer()
            Text(key).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(on ? 0.12 : 0)))
    }
}

/// The staging shop's checkout, the bug in the sketch: Pay spins forever. Pay follows the sketch's clicks, or loops as
/// a clip of it does.
struct CheckoutPage: View {
    let time: Double
    let fixed: Bool
    var loops = false

    var body: some View {
        let pressed = loops ? time.truncatingRemainder(dividingBy: 2.4) >= 0.8 : Sketch.sincePayClick(at: time) != nil
        let pay = SketchDesk.payButton
        ZStack(alignment: .topLeading) {
            Color(nsColor: .textBackgroundColor)
            HStack {
                Label("staging shop", systemImage: "diamond.fill").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("Cart (2)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(width: SketchDesk.checkoutSize.width, height: 26)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: SketchDesk.checkoutSize.width, height: 1).offset(y: 26)
            VStack(alignment: .leading, spacing: 9) {
                Text("Your order").font(.system(size: 10.5, weight: .semibold))
                item("Canvas tote", "Qty 1", "$32.00", [Color(red: 0.9, green: 0.78, blue: 0.6), Color(red: 0.75, green: 0.6, blue: 0.42)])
                item("Enamel pin", "Qty 2", "$12.00", [Color(red: 0.55, green: 0.7, blue: 1), Color(red: 0.35, green: 0.45, blue: 0.9)])
            }
            .frame(width: 156, alignment: .leading)
            .offset(x: 14, y: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text("Order summary").font(.system(size: 12, weight: .semibold))
                line("Subtotal", "$44.00")
                line("Shipping", "$4.00")
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                line("Total", "$48.00").fontWeight(.semibold)
            }
            .padding(12)
            .frame(width: 174, height: 142, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .offset(x: 182, y: 34)
            PayButton(state: !pressed ? .ready : fixed ? .paid : .spinning(time), height: pay.height)
                .frame(width: pay.width)
                .offset(x: pay.minX, y: pay.minY)
        }
        .foregroundStyle(.primary)
    }

    private func item(_ name: String, _ detail: String, _ price: String, _ colors: [Color]) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 10.5, weight: .medium))
                Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(price).font(.system(size: 10.5)).monospacedDigit()
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 10.5))
    }
}

/// The online converter.
private struct ConverterPage: View {
    let progress: Double
    let done: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text("FREE GIF CONVERTER!!!").font(.system(size: 24, weight: .black))
            Label("Your Mac is infected! Clean now", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.yellow)
            HStack(spacing: 10) {
                ForEach(0..<2) { _ in
                    Text("DOWNLOAD ▼").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.green))
                }
            }
            if done {
                Text("Your GIF is ready! 38.2 MB · 4 fps").font(.system(size: 14, weight: .semibold))
                Text("Remove watermark: $9.99").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(Color.primary.opacity(0.7)).frame(width: max(6, 300 * progress))
                }
                .frame(width: 300, height: 8)
                Text(progress < 0.5 ? "Uploading… \(Int(progress * 100))%" : "Converting… \(Int(progress * 100))%")
                    .font(.system(size: 13)).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Capture Machine's picker over the page, then its red dashed outline while it records. The corner follows the cursor
/// dragging it: the same easing over the same time.
private struct DeskSelection: View {
    let progress: Double
    let recording: Bool

    var body: some View {
        let target = SketchDesk.page
        let grown = Motion.easeOut(progress)
        let rect = CGRect(x: target.minX, y: target.minY, width: target.width * grown, height: target.height * grown)
        ZStack(alignment: .topLeading) {
            if !recording {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.28)))
                    context.blendMode = .clear
                    context.fill(Path(rect), with: .color(.black))
                }
                Rectangle().strokeBorder(Color.white, lineWidth: 1)
                    .frame(width: max(1, rect.width), height: max(1, rect.height))
                    .offset(x: rect.minX, y: rect.minY)
                if progress > 0.15 {
                    Text(verbatim: "\(Int(rect.width * 2)) × \(Int(rect.height * 2)) · 120 fps")
                        .font(.system(size: SketchDesk.font - 1, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .fixedSize()
                        .offset(x: rect.minX, y: rect.maxY + 8)
                }
            } else {
                Rectangle()
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: rect.width + 6, height: rect.height + 6)
                    .offset(x: rect.minX - 3, y: rect.minY - 3)
            }
        }
        .frame(width: SketchDesk.size.width, height: SketchDesk.size.height, alignment: .topLeading)
    }
}

/// The recording on the desktop: a movie document with its name under it.
private struct DeskFileIcon: View {
    let selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                DocumentShape().fill(Color.white).overlay(DocumentShape().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
                    .frame(width: 44, height: 56)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                Text("MOV").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.35, green: 0.35, blue: 0.4)))
                    .padding(.bottom, 8)
                Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(Color(white: 0.55)).offset(y: -24)
            }
            Text("Screen Recording 2026-11-20 at 4.31.07 PM.mov").font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.center).lineLimit(2)
                .foregroundStyle(selected ? Color.white : .primary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor : .clear))
                .frame(width: 118)
                .shadow(color: .black.opacity(selected ? 0 : 0.35), radius: 2)
        }
        .frame(width: 120)
    }
}

private struct DocumentShape: Shape {
    func path(in rect: CGRect) -> Path {
        let fold = rect.width * 0.28
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The sketch's one cursor, carrying the recording on the drag. A move eases in and out; a drag eases out, as the
/// selection it draws does, and bows up a little on its way across; the cursor dips as it clicks.
struct SketchCursor: View {
    let cursor: Sketch.Cursor
    let place: (Sketch.Target) -> CGPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let from = place(cursor.from), to = place(cursor.to)
        let k = reduceMotion ? (cursor.progress < 1 ? 0 : 1) : cursor.drag ? Motion.easeOut(cursor.progress) : Motion.easeInOut(cursor.progress)
        let bow = cursor.carrying && !reduceMotion ? -40 * sin(.pi * k) : 0
        let point = CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k + bow)
        ZStack(alignment: .topLeading) {
            if cursor.carrying {
                DeskFileIcon(selected: true)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 20)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .opacity(cursor.progress > 0.75 ? 1 : 0)
                            .offset(x: -26, y: -6)
                    }
                    .opacity(0.9)
                    .scaleEffect(0.6)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    .position(x: point.x, y: point.y + 6)
            }
            ArrowCursor()
                .scaleEffect(cursor.pressed ? 0.88 : 1, anchor: .topLeading)
                .offset(x: point.x, y: point.y)
        }
        .opacity(cursor.opacity)
        .allowsHitTesting(false)
    }
}

/// A Safari window: traffic lights, sidebar and arrows, the address field with a lock, then the page.
private struct SafariWindow<Content: View>: View {
    let url: String
    let bar: CGFloat
    let radius: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: bar * 0.3) {
                HStack(spacing: bar * 0.22) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)],
                            id: \.self) {
                        Circle().fill($0).frame(width: bar * 0.3, height: bar * 0.3)
                    }
                }
                Image(systemName: "sidebar.left")
                Image(systemName: "chevron.left")
                Image(systemName: "chevron.right").opacity(0.4)
                HStack(spacing: bar * 0.15) {
                    Image(systemName: "lock.fill").font(.system(size: bar * 0.26))
                    Text(url).lineLimit(1)
                }
                .font(.system(size: bar * 0.36))
                .padding(.vertical, bar * 0.12)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: bar * 0.24, style: .continuous).fill(Color.primary.opacity(0.07)))
                Image(systemName: "square.and.arrow.up")
                Image(systemName: "plus")
            }
            .font(.system(size: bar * 0.38, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, bar * 0.4)
            .frame(height: bar)
            .background(.bar)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: radius * 0.3, y: radius * 0.1)
        .shadow(color: .black.opacity(0.22), radius: radius * 2.2, y: radius * 0.9)
    }
}

/// Jay's FaceTime call, as a macOS notification.
private struct CallBanner: View {
    static let width: CGFloat = 250

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.86, blue: 0.45), Color(red: 0.16, green: 0.66, blue: 0.27)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Image(systemName: "video.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Jay").font(.system(size: 11, weight: .semibold))
                Text("FaceTime Video · Accept or Decline").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

/// A macOS-style abstract wallpaper: soft colour fields over a base, drawn with radial gradients, which cost nothing to
/// redraw each frame.
private struct Wallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let width = SketchDesk.size.width
        ZStack {
            LinearGradient(colors: dark ? [Color(red: 0.1, green: 0.11, blue: 0.22), Color(red: 0.16, green: 0.09, blue: 0.2)]
                                        : [Color(red: 0.78, green: 0.85, blue: 0.97), Color(red: 0.93, green: 0.86, blue: 0.93)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [(dark ? Color(red: 0.36, green: 0.22, blue: 0.62) : Color(red: 0.62, green: 0.72, blue: 1)).opacity(0.85), .clear],
                           center: UnitPoint(x: 0.18, y: 0.82), startRadius: 0, endRadius: width * 0.55)
            RadialGradient(colors: [(dark ? Color(red: 0.7, green: 0.3, blue: 0.45) : Color(red: 1, green: 0.78, blue: 0.7)).opacity(0.7), .clear],
                           center: UnitPoint(x: 0.85, y: 0.9), startRadius: 0, endRadius: width * 0.5)
            RadialGradient(colors: [(dark ? Color(red: 0.15, green: 0.35, blue: 0.6) : Color(red: 0.7, green: 0.9, blue: 1)).opacity(0.7), .clear],
                           center: UnitPoint(x: 0.75, y: 0.1), startRadius: 0, endRadius: width * 0.45)
        }
    }
}
