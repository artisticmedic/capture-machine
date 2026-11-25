import AppKit

/// The menu bar item, after the Sidewall icon: the key seen from above, a rounded square with a heavier front edge for
/// its skirt and the record dot. Template images, so the menu bar tints them, except the red recording capsule.
enum MenuBarGlyph {
    /// `fill` fills the key from the bottom while a GIF is made; `check` replaces the dot once a clip is copied.
    static func key(dot: Bool = true, check: Bool = false, fill: Double? = nil, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let scale = NSAffineTransform()
            scale.scale(by: size / 18)
            scale.concat()
            let outer = NSRect(x: 1.75, y: 1.75, width: 14.5, height: 14.5)
            let shape = NSBezierPath(roundedRect: outer, xRadius: 4.2, yRadius: 4.2)
            shape.lineWidth = 1.5
            NSColor.black.setStroke()
            NSColor.black.setFill()
            shape.stroke()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 3.6)).fill()
            NSGraphicsContext.restoreGraphicsState()
            if let fill {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: outer.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.8, yRadius: 3.8).addClip()
                NSColor.black.withAlphaComponent(0.55).setFill()
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 2 + 14 * min(1, max(0, fill)))).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if check {
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: 5.6, y: 9.6))
                tick.line(to: NSPoint(x: 8.0, y: 7.2))
                tick.line(to: NSPoint(x: 12.4, y: 12.0))
                tick.lineWidth = 1.7
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                tick.stroke()
            } else if dot {
                NSBezierPath(ovalIn: NSRect(x: 9 - 2.9, y: 9.9 - 2.9, width: 5.8, height: 5.8)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Capture Machine"
        return image
    }

    /// While recording: a red capsule holding a stop square and the elapsed time. The whole capsule is the stop button.
    static func recording(_ time: String, height: CGFloat = 18) -> NSImage {
        let unit = height / 18
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5 * unit, weight: .semibold)
        let text = NSAttributedString(string: time, attributes: [.font: font, .foregroundColor: NSColor.white])
        let width = ceil((8 + 9 + 5 + 9) * unit + text.size().width)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor(srgbRed: 0.86, green: 0.16, blue: 0.10, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 8 * unit, y: 4.5 * unit, width: 9 * unit, height: 9 * unit),
                         xRadius: 2 * unit, yRadius: 2 * unit).fill()
            text.draw(at: NSPoint(x: (8 + 9 + 5) * unit, y: (height - text.size().height) / 2 + 0.5 * unit))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Stop recording, \(time)"
        return image
    }
}
