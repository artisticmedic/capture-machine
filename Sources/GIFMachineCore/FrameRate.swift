/// The frame rate a recording asks ScreenCaptureKit for (plan question 10, settled 2026-11-14).
///
/// The M4 Pro's hardware H.264 encoder handles about 500 megapixels a second (Milestone 0 bench), so 120 fps holds up to
/// about 4 megapixels. Above 3.5 megapixels a recording asks for 60 fps, which leaves headroom.
public enum FrameRate {
    public static let largeRecordingPixels = 3_500_000
    public static let smallRecordingMaximum = 120
    public static let largeRecordingMaximum = 60

    public static func forRecording(displayMaximum: Int, pixelWidth: Int, pixelHeight: Int) -> Int {
        let display = max(1, displayMaximum)
        let cap = pixelWidth * pixelHeight > largeRecordingPixels ? largeRecordingMaximum : smallRecordingMaximum
        return min(display, cap)
    }
}
