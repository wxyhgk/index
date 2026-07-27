import SwiftUI

/// 编辑器底部的胶片条（Snagit 式）：全库截图缩略图横排，不出编辑器直接换图。
///
/// 数据源是 `ShotStore.allShots()` —— 全库时间倒序，**刻意不跟图库的搜索 / 筛选联动**：
/// 编辑器换图的心智是「库里最近截了什么」，不该被另一个窗口的筛选状态牵着走。
/// 订阅 store 的变更通知刷新，新截图 / 删除都会即时体现。
///
/// 自带顶部 Divider，宿主（EditorView）只需在主 VStack 底部插一行。
struct EditorFilmstrip: View {

    /// 当前编辑中的 shot ID：高亮 accent 描边 + 自动滚动到可见。
    let currentShotID: Int64?
    /// 点击其它缩略图 → 请求换图。未保存守卫在宿主侧，这里只管转发。
    let onSelect: (Shot) -> Void

    /// 收起状态跨窗口、跨启动记住 —— 胶片条是屏幕空间的取舍，偏好因人而异。
    @AppStorage("editorFilmstripCollapsed") private var collapsed = false

    @State private var shots: [Shot] = []

    private let store = ShotStore.shared

    /// 缩略图行高；整条胶片条约 72pt。
    private static let thumbHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                if collapsed {
                    Text("胶片条（\(shots.count)）")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 14)
                    Spacer()
                } else {
                    strip
                }
                toggleButton
            }
            .frame(height: collapsed ? 24 : 72)
        }
        .onAppear(perform: refresh)
        .onReceive(store.objectWillChange) { _ in
            // objectWillChange 在变更**之前**发布；转一拍再查库，拿到变更后的内容。
            DispatchQueue.main.async { refresh() }
        }
    }

    // MARK: - 胶片

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(shots) { shot in
                        thumbnail(shot)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onAppear { scrollToCurrent(proxy, animated: false) }
            .onChange(of: currentShotID) { scrollToCurrent(proxy, animated: true) }
            .onChange(of: shots) { scrollToCurrent(proxy, animated: false) }
        }
    }

    private func thumbnail(_ shot: Shot) -> some View {
        let isCurrent = shot.id == currentShotID
        return Button {
            if !isCurrent { onSelect(shot) }
        } label: {
            CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
                .frame(height: Self.thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            isCurrent ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: isCurrent ? 2 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        // ScrollViewReader 的滚动锚点。Int64? 类型与 scrollToCurrent 传入的一致。
        .id(shot.id)
        .help(shot.sourceSummary)
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard currentShotID != nil else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(currentShotID, anchor: .center)
            }
        } else {
            proxy.scrollTo(currentShotID, anchor: .center)
        }
    }

    // MARK: - 折叠

    private var toggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
        } label: {
            Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                .font(.caption)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.trailing, 6)
        .help(collapsed ? "展开胶片条" : "收起胶片条")
    }

    private func refresh() {
        shots = store.allShots()
    }
}
