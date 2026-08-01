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
        // 只订「库存内容变了」，**不订 objectWillChange**。
        //
        // 后者任何写入都会发，包括编辑器自己每隔一秒多的一次修订保存 ——
        // 而保存修订并不改变胶片条的内容（还是同一批截图、同样的顺序），
        // 却会害这里在主线程上重查一次全库。那正是「编辑时点按钮有延迟」的来源。
        //
        // `libraryDidChange` 发在 `reload()` 之后（即库存真的重查过），
        // 所以这里不需要再 `DispatchQueue.main.async` 转一拍去等变更落地。
        .onReceive(store.libraryDidChange) { _ in refresh() }
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

    /// 重查全库。
    ///
    /// ⚠️ **这是主线程上的一次 500 行取回 + 全量解码**，不便宜。
    /// 它订阅的是 store 的**全部**变更，而编辑器每保存一次修订就会发一次通知 ——
    /// 于是编辑时每隔一秒多就在主线程上重查一次全库，表现为「点按钮有延迟」。
    ///
    /// 但保存修订并**不改变胶片条的内容**：还是同一批截图、同样的顺序，
    /// 变的只是某一张的缩略图像素（那由 `ThumbnailCache` 的作废机制负责刷新，
    /// 与这里的列表无关）。所以先做一次廉价的对比，**内容没变就不动**——
    /// 不动 `shots` 就不会触发 ForEach 重建，也不会连锁 scrollToCurrent。
    private func refresh() {
        let latest = store.allShots()
        // Shot 是 Equatable，但逐个比对 500 个结构体也不必要：
        // 胶片条只关心「有哪些图、什么顺序」，比 ID 序列就够了。
        guard latest.map(\.id) != shots.map(\.id) else { return }
        shots = latest
    }
}
