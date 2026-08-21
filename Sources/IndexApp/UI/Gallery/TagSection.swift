import SwiftUI

// MARK: - 详情栏标签胶囊行

/// 详情面板单选视图里的标签行（设计稿 §6.5：一行小号胶囊，深色底、灰字）。
///
/// 已有标签显示为胶囊流式排列（hover 出 ✕ 移除），尾部「+ 标签」点击变
/// TextField，回车提交；输入时按前缀匹配给最多 5 条建议（按使用量降序），
/// 点击即选。数据挂 task(id: shot.id)，切换截图时查一次，不挂 body ——
/// 和详情面板里其它派生数据的惯例一致；增删之后就地刷新本地状态。
///
/// 改版说明：**外面那层「标签」组题卡片去掉了**。设计稿把标签画成紧接元信息
/// 列表的一行胶囊 —— 胶囊本身就说明了自己是什么，再套一张带标题的卡片是
/// 一层白付的层级（而且它会把这一行从「面板的一部分」变成「面板里的一个盒子」）。
/// 功能一件没动：增、删、建议、焦点态全在。
///
/// 材质纪律：胶囊一律用 `.quaternary` 半透明填充 + 一圈发丝描边，不用 Material。
/// 外层面板是不透明纯色底（`floatingPanel`），在实色上做模糊只是白付一次采样；
/// 而 `.quaternary` 落在实色上对比度是够的（规格 §7.2 禁的是它落在
/// `.thin` / `.ultraThin` 材质上）。
struct TagSection: View {
    let shot: Shot
    var store: ShotStore = .shared

    /// 当前截图的标签，按添加顺序。
    @State private var tags: [String] = []
    /// 全库标签名（按使用量降序），输入建议用。进入输入态时拉一次。
    @State private var allTagNames: [String] = []
    /// 是否处于「+ 标签」输入态。
    @State private var isAdding = false
    @State private var input = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            FlowLayout(spacing: DS.s1 + 2) {
                ForEach(tags, id: \.self) { tag in
                    TagChip(name: tag) { remove(tag) }
                }
                addControl
            }

            if isAdding, !suggestions.isEmpty {
                suggestionRow
            }
        }
        // 左右不再内缩：这一行现在和元信息列表、下钻行共用面板的内边距，
        // 缩进会让它看起来比上下两块窄一圈。
        .padding(.horizontal, DS.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 「+ 标签」按钮 ↔ 输入框的互换、以及建议行的出没，都是小件出没 → micro。
        .animation(DS.Motion.micro(reduced: reduceMotion), value: isAdding)
        .task(id: shot.id) {
            refresh()
            cancelInput()
        }
    }

    // MARK: 输入

    /// 尾部控件：常态是「+ 标签」胶囊按钮，点击变输入框。
    @ViewBuilder
    private var addControl: some View {
        if isAdding {
            TextField("标签名", text: $input)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 96)
                .padding(.horizontal, DS.s2)
                .padding(.vertical, 3)
                // 材质换成 quaternary 填充（详见类型注释）。胶囊圆角 = 高度/2，
                // 这一档不走圆角阶梯，Capsule 本身就是公式的答案。
                .background(DS.insetSurface, in: Capsule())
                // 这圈 accent 是**焦点指示**，是 accent 在本视图里唯一合法的归属；
                // 正因为它占着，下面的建议胶囊就不能再上强调色了。
                .overlay(
                    Capsule().strokeBorder(DS.accentStrokeInput, lineWidth: 1)
                )
                .focused($inputFocused)
                .onSubmit { commit() }
                .onExitCommand { cancelInput() }
        } else {
            Button {
                // 建议候选在进入输入态时拉一次，不跟着每个键击查库。
                allTagNames = store.allTags().map(\.name)
                input = ""
                isAdding = true
                inputFocused = true
            } label: {
                Label("标签", systemImage: "plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.s2)
                    .padding(.vertical, 3)
                    // 这里**不填底**：虚线空胶囊读起来是「还没有的一个位置」，
                    // 一旦填上底就和真标签长得一样了。原来的 .thinMaterial
                    // 既是第三层玻璃，也让它冒充成了一个已存在的标签。
                    .overlay(
                        Capsule().strokeBorder(
                            DS.borderSubtle,
                            style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                        )
                    )
            }
            .buttonStyle(.plain)
            .help("添加标签")
        }
    }

    /// 前缀匹配的建议（大小写不敏感），排除已打上的，最多 5 条。
    /// 输入为空时给出最常用的几个 —— 方便直接点选。
    private var suggestions: [String] {
        let prefix = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Array(
            allTagNames
                .filter { !tags.contains($0) }
                .filter { prefix.isEmpty || $0.lowercased().hasPrefix(prefix) }
                .prefix(5)
        )
    }

    private var suggestionRow: some View {
        FlowLayout(spacing: DS.s1 + 2) {
            ForEach(suggestions, id: \.self) { name in
                Button {
                    add(name)
                } label: {
                    // 建议胶囊卸掉强调色：accent 在这套设计里只归选中/焦点态，
                    // 而此刻焦点正戴在上面那个输入框上（同屏最多一个控件加色）。
                    // 「还没打上」的区别改用虚线边表达 —— 和「+ 标签」同一套语言。
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DS.s2)
                        .padding(.vertical, 3)
                        .background(DS.insetSurface, in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(
                                DS.borderSubtle,
                                style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                            )
                        )
                }
                .buttonStyle(.plain)
                .help("添加「\(name)」")
            }
        }
    }

    // MARK: 动作

    private func commit() {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            cancelInput()
            return
        }
        add(name)
    }

    private func add(_ name: String) {
        guard let id = shot.id else { return }
        store.addTag(shotID: id, name)
        // 胶囊的增删是小件出没 → micro（§6）。没有动画时新胶囊会「跳」进流式布局，
        // 用户会丢失「刚才那一下发生在哪」的线索。
        withAnimation(DS.Motion.micro(reduced: reduceMotion)) { refresh() }
        // 新名字立刻可被后续建议匹配；清空输入、保持焦点，方便连续打标签。
        allTagNames = store.allTags().map(\.name)
        input = ""
        inputFocused = true
    }

    private func remove(_ name: String) {
        guard let id = shot.id else { return }
        store.removeTag(shotID: id, name)
        withAnimation(DS.Motion.micro(reduced: reduceMotion)) { refresh() }
    }

    private func refresh() {
        tags = shot.id.map { store.tags(shotID: $0) } ?? []
    }

    private func cancelInput() {
        isAdding = false
        input = ""
    }
}

// MARK: - 胶囊

/// 单个标签胶囊。✕ 常驻布局、hover 才显形 —— 避免悬停时胶囊宽度跳动。
private struct TagChip: View {
    let name: String
    let onRemove: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            // 设计稿 §6.5：小号胶囊、灰字。标签是「这张图属于哪几堆」的补充信息，
            // 不该和元信息列表的正文抢同一档对比度。
            Text(name)
                .font(.system(size: DS.font12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: DS.font9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .help("移除标签")
        }
        .padding(.horizontal, DS.s2)
        .padding(.vertical, 3)
        // quaternary 填充 + 一圈发丝描边，不用 Material：面板底是不透明纯色，
        // 在实色上做模糊只是白付一次采样。
        // 「边缘比表面重要」—— 这圈线比任何背景模糊都更能把胶囊托起来。
        .background(DS.insetSurface, in: Capsule())
        .overlay(
            Capsule().strokeBorder(DS.borderFaint, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        // ✕ 的显形是最小的一档微交互 → micro。
        .animation(DS.Motion.micro(reduced: reduceMotion), value: isHovering)
    }
}

// MARK: - 流式布局

/// 简单的流式布局：从左到右排，放不下就换行。选 Layout 协议而不是
/// 固定列 LazyVGrid —— 标签宽度差异大，等宽网格会浪费大量横向空间。
/// 子视图是个位数到十几个胶囊，逐个 sizeThatFits 足够快，不做缓存。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return CGSize(width: proposal.width ?? usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
