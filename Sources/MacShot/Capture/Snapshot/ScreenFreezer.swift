import Foundation

struct ImmediateScreenSource: CaptureSource {
    let id = CaptureSourceID.immediate
    let title = "立即截图"
    let symbolName = "camera.viewfinder"
    private let capturer: ScreenCapturing
    init(capturer: ScreenCapturing? = nil) {
        if let capturer { self.capturer = capturer } else { self.capturer = MacScreenCapturer.shared }
    }
    func makeSnapshots() async throws -> [DisplaySnapshot] {
        try await capturer.captureDisplays()
    }
}
