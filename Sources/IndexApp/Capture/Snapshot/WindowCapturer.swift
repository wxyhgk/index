import CoreGraphics

enum WindowCapturer {
    @MainActor
    static func capture(windowID: CGWindowID, scale: CGFloat, includeShadow: Bool) async throws -> CGImage {
        try await MacScreenCapturer.shared.captureWindow(windowID: windowID, scale: scale, includeShadow: includeShadow)
    }
    @MainActor
    static func capture(windowID: CGWindowID, scale: CGFloat, includeShadow: Bool, using capturer: ScreenCapturing) async throws -> CGImage {
        try await capturer.captureWindow(windowID: windowID, scale: scale, includeShadow: includeShadow)
    }
}
