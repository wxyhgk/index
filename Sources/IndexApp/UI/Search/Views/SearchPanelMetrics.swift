import Foundation
import SwiftUI

/// Option-Space 搜索浮窗的组件内尺寸与动效预算。
///
/// 这些值只服务搜索浮窗，不提升成全局设计 token；面板和三个子视图共享同一份度量，
/// 避免窗口、分栏、结果行和预览控件各自维护重复裸值。
enum SearchPanelMetrics {
    static let panelSize = CGSize(width: 640, height: 420)
    static let previewWidth: CGFloat = 240
    static let dividerHeight: CGFloat = 360

    static let resultRowHeight: CGFloat = 52
    static let resultSpacing: CGFloat = 1
    static let thumbnailSide: CGFloat = 36
    static let clearButtonSide: CGFloat = 18
    static let actionButtonSide: CGFloat = 24
    static let previewPlaceholderIconSize: CGFloat = 22
    static let subtitleBulletSide: CGFloat = 2.5
    static let textColumnSpacing: CGFloat = 2
    static let metadataSpacing: CGFloat = 3

    static let hairlineWidth: CGFloat = 0.5
    static let initialScale: CGFloat = 0.96
    static let appearanceResponse = 0.22
    static let appearanceDamping = 0.88
    static let hoverDuration = 0.1
    static let copyFeedbackDelay: Duration = .milliseconds(800)

    static let panelBorder = DS.whiteOpacity(0.06)
    static let controlHoverFill = DS.primaryOpacity(0.06)
    static let selectedRowFill = DS.primaryOpacity(0.08)
    static let hoveredRowFill = DS.primaryOpacity(0.04)
    static let thumbnailPlaceholderFill = DS.primaryOpacity(0.05)
    static let destructiveTint = Color.red.opacity(0.6)
}
