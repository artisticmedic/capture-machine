import CoreGraphics

/// Where the recording outline runs: half a line plus a point outside the recorded area, so it never covers what's
/// in frame, and kept on the screen, so at a screen's edge it runs just inside.
public enum Outline {
    public static func path(around rect: CGRect, in bounds: CGRect, lineWidth: CGFloat) -> CGRect {
        let half = lineWidth / 2
        let outside = rect.insetBy(dx: -(half + 1), dy: -(half + 1))
        let limit = bounds.insetBy(dx: half, dy: half)
        let minX = max(outside.minX, limit.minX), minY = max(outside.minY, limit.minY)
        return CGRect(x: minX, y: minY, width: min(outside.maxX, limit.maxX) - minX, height: min(outside.maxY, limit.maxY) - minY)
    }
}
