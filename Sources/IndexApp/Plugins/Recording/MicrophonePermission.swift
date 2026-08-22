import AppKit
import AVFoundation

/// 麦克风权限。首次请求会触发系统授权弹窗
/// （文案在 Info.plist 的 `NSMicrophoneUsageDescription`）。
///
/// 设置里勾选「录制麦克风」时就请求 —— 让弹窗出现在用户做决定的当下，
/// 而不是按下录制键的紧要关头。
@MainActor
enum MicrophonePermission {

    /// 用户明确拒绝过（或被系统策略限制）。此时再请求不会出弹窗，
    /// 只能引导去系统设置。
    static var isDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    /// 未决定时弹系统授权框，其余状态直接回报结果。回调回到主线程。
    static func request(_ completion: @escaping @MainActor (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in completion(granted) }
            }
        case .authorized:
            completion(true)
        default:
            completion(false)
        }
    }

    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
