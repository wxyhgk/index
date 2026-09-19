import Foundation
import SwiftUI

/// Option-Space 搜索浮窗的组件内尺寸与动效预算。
///
/// 这些值只服务搜索浮窗，不提升成全局设计 token；面板和三个子视图共享同一份度量，
/// 避免窗口、分栏、结果行和预览控件各自维护重复裸值。
///
/// 视觉语言统一走 DS 设计令牌（纯色面板、accent 选中、medium 字重、DS.Motion 动效）。
enum SearchPanelMetrics {
    static let panelSize = CGSize(width: 640, height: 420)
    static let previewWidth: CGFloat = 260

    static let resultRowHeight: CGFloat = 56
    static let resultSpacing: CGFloat = 2
    static let thumbnailSide: CGFloat = 40
    static let clearButtonSide: CGFloat = 18
    static let actionButtonSide: CGFloat = 24
    static let previewPlaceholderIconSize: CGFloat = 22
    static let subtitleBulletSide: CGFloat = 2.5
    static let textColumnSpacing: CGFloat = 2
    static let metadataSpacing: CGFloat = 3

    static let hairlineWidth: CGFloat = 1
    static let initialScale: CGFloat = 0.96

    static let destructiveTint = Color.red.opacity(0.6)
}
