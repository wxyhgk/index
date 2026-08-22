import SwiftUI
import AppKit

// MARK: - 同源时间线
//
// 元数据自动聚合「同一页面 / 同一 App 窗口」的截图序列（同源规则见
// ShotStore.relatedShots），顶部时间条挑选任意一张看大图，或开启对比模式
// 选 A/B 两张做并排 / 滑块 / 逐像素差异对比。
//
// **语义决定**：大图和 diff 用的都是原图（不含标注）—— 对比回答的是
// 「画面本身变没变」，标注是用户后加的解读，不该混进画面差异里。
// sha256 内容寻址免费提供「完全相同」判定：相同哈希直接判一致，不跑 diff。

struct TimelineSheet: View {
    let shot: Shot
    @ObservedObject private var store: ShotStore

    init(shot: Shot, store: ShotStore = .shared) {
        self.shot = shot
        self._store = ObservedObject(wrappedValue: store)
    }

    @Environment(\.dismiss) private var dismiss

    /// nil = 还在查库；查完少于 2 张不会走到这里（入口已禁用），但仍兜底显示空态。
    @State private var related: [Shot]?
    @State private var selectedID: Int64?
    @State private var compareMode = false
    @State private var idA: Int64?
    @State private var idB: Int64?

    private var selectedShot: Shot? {
        related?.first { $0.id == selectedID }
    }

    private var shotA: Shot? { related?.first { $0.id == idA } }
    private var shotB: Shot? { related?.first { $0.id == idB } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let related {
                if related.count < 2 {
                    ContentUnavailableView(
                        "没有同源截图",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("同一网址或同一 App 窗口的截图不足两张")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    strip(related)
                    Divider()
                    mainArea
                }
            } else {
                ProgressView("正在聚合同源截图…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 900, height: 620)
        .task(id: shot.id) {
            related = store.relatedShots(to: shot)
            selectedID = shot.id
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: DS.s3) {
            Label("时间线", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            if let related {
                Text(sourceDescription + " · \(related.count) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("对比模式", isOn: $compareMode)
                .toggleStyle(.switch)
                .controlSize(.small)
            Button {
                locateInGallery()
            } label: {
                Label("在图库中定位", systemImage: "square.grid.2x2")
            }
            .disabled(selectedID == nil)
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DS.s4)
        .padding(.vertical, DS.s3)
    }

    /// 同源依据的一行描述，让用户知道这串图是按什么聚起来的。
    private var sourceDescription: String {
        if let url = shot.sourceURL {
            return ShotStore.normalizedSourceURL(url)
        }
        if let app = shot.appName ?? shot.appBundleID {
            if let title = shot.windowTitle, !title.isEmpty {
                return "\(app) — \(title)"
            }
            return app
        }
        return "未知来源"
    }

    /// 把当前选中张带回图库并关闭 sheet。定位类场景：清空多选后单选目标。
    private func locateInGallery() {
        guard let selectedID else { return }
        GalleryWindowController.shared.selection.select(only: selectedID)
        dismiss()
    }

    // MARK: 缩略图条

    private func strip(_ shots: [Shot]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.s2) {
                ForEach(Array(shots.enumerated()), id: \.element.id) { index, item in
                    TimelineThumb(
                        shot: item,
                        role: role(of: item),
                        onTap: { tap(item) },
                        store: store
                    )
                    // sha256 相同 = 画面完全一致，在相邻两张之间标出来。
                    if index + 1 < shots.count, shots[index + 1].sha256 == item.sha256 {
                        Text("=")
                            .font(.system(size: DS.font14, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .help("相邻两张画面完全一致（内容哈希相同）")
                    }
                }
            }
            .padding(.horizontal, DS.s4)
            .padding(.vertical, DS.s3)
        }
        .frame(height: 118)
    }

    private func role(of item: Shot) -> TimelineThumb.Role {
        if compareMode {
            if item.id == idA { return .compareA }
            if item.id == idB { return .compareB }
            return .none
        }
        return item.id == selectedID ? .selected : .none
    }

    private func tap(_ item: Shot) {
        guard let id = item.id else { return }
        if compareMode {
            // 点已选中的取消；否则先填 A 再填 B；都满了替换 B。
            if idA == id { idA = nil } else if idB == id {
                idB = nil
            } else if idA == nil {
                idA = id
            } else {
                idB = id
            }
        } else {
            selectedID = id
        }
    }

    // MARK: 主区域

    @ViewBuilder
    private var mainArea: some View {
        if compareMode {
            if let a = shotA, let b = shotB {
                DiffView(a: a, b: b, store: store)
            } else {
                ContentUnavailableView(
                    idA == nil ? "选择两张进行对比" : "再选一张作为 B",
                    systemImage: "square.on.square.dashed",
                    description: Text("在上方缩略图条里点选 A、B 两张截图")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let selected = selectedShot {
            VStack(spacing: DS.s2) {
                LargeShotImage(shot: selected, store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(caption(for: selected))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(DS.s4)
        } else {
            Color.clear
        }
    }

    private func caption(for item: Shot) -> String {
        let time = item.capturedAt.formatted(date: .abbreviated, time: .standard)
        return "\(time) · \(item.pixelWidth) × \(item.pixelHeight) px"
    }
}

// MARK: - 缩略图条的单张

private struct TimelineThumb: View {
    enum Role {
        case none
        case selected
        case compareA
        case compareB
    }

    let shot: Shot
    let role: Role
    let onTap: () -> Void
    private let store: ShotStore

    init(shot: Shot, role: Role, onTap: @escaping () -> Void, store: ShotStore = .shared) {
        self.shot = shot
        self.role = role
        self.onTap = onTap
        self.store = store
    }

    private var borderColor: Color {
        switch role {
        case .none: return DS.timelineIdle
        case .selected: return DS.accent
        case .compareA: return .blue
        case .compareB: return .orange
        }
    }

    private var badge: String? {
        switch role {
        case .compareA: return "A"
        case .compareB: return "B"
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: DS.s1) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                    .fill(DS.insetSurface)
                CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
                    .clipShape(RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
            }
            .frame(width: 108, height: 68)
            .overlay {
                RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: role == .none ? 1 : 2.5)
            }
            .overlay(alignment: .topLeading) {
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, DS.s1 + 1)
                        .padding(.vertical, 1)
                        .background(borderColor, in: RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous))
                        .padding(DS.s1)
                }
            }

            Text(shot.capturedAt, format: .dateTime.month().day().hour().minute())
                .font(.caption2)
                .foregroundStyle(role == .none ? .secondary : .primary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - 大图（原图，不含标注）

private struct LargeShotImage: View {
    let shot: Shot
    private let store: ShotStore

    init(shot: Shot, store: ShotStore = .shared) {
        self.shot = shot
        self.store = store
    }

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: shot.sha256) {
            // 路径在主 actor 上取，磁盘解码放后台。
            let url = store.originalURL(for: shot)
            let cg = await Task.detached(priority: .userInitiated) {
                ImageCodec.load(from: url)
            }.value
            guard let cg else { return }
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}

// MARK: - 对比视图

struct DiffView: View {
    let a: Shot
    let b: Shot
    @ObservedObject private var store: ShotStore

    init(a: Shot, b: Shot, store: ShotStore = .shared) {
        self.a = a
        self.b = b
        self._store = ObservedObject(wrappedValue: store)
    }

    enum Mode: String, CaseIterable, Identifiable {
        case sideBySide = "并排"
        case slider = "滑块"
        case highlight = "差异高亮"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .sideBySide
    @State private var imageA: NSImage?
    @State private var imageB: NSImage?
    /// 差异蒙版（红色半透明），懒计算：切到高亮模式才算，算一次缓存。
    @State private var diffMask: NSImage?
    /// 差异像素占比（0…1）。nil = 还没算。
    @State private var diffRatio: Double?
    @State private var diffFailed = false

    /// 滑块分割位置（0…1），左边露 A、右边露 B。
    @State private var split: CGFloat = 0.5

    /// 内容寻址白送的判定：哈希相同 = 画面逐字节一致，不需要跑 diff。
    private var identical: Bool { a.sha256 == b.sha256 }
    private var sameSize: Bool {
        a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight
    }

    var body: some View {
        VStack(spacing: DS.s3) {
            controls
            content
        }
        .padding(DS.s4)
        .task(id: a.sha256 + b.sha256) { await loadImages() }
        .task(id: "\(a.sha256)|\(b.sha256)|\(mode.rawValue)") {
            // 只有真正切到高亮模式才计算，且 identical / 尺寸不同都不跑。
            guard mode == .highlight, !identical, sameSize,
                  diffMask == nil, !diffFailed else { return }
            await computeDiff()
        }
    }

    // MARK: 控制条

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: DS.s3) {
            if identical {
                Label("两张画面完全一致 ✓", systemImage: "equal.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
            } else if !sameSize {
                Label(
                    "尺寸不同（\(a.pixelWidth)×\(a.pixelHeight) vs \(b.pixelWidth)×\(b.pixelHeight)），无法逐像素对比",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Picker("对比方式", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)

                if mode == .highlight, let diffRatio {
                    Text(String(format: "差异像素 %.2f%%", diffRatio * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if identical {
            // 一致时展示其中一张即可，diff 没有意义。
            pane(image: imageA, title: label(for: a, tag: "A = B"))
        } else if let imageA, let imageB {
            if !sameSize {
                sideBySide(imageA, imageB)
            } else {
                switch mode {
                case .sideBySide: sideBySide(imageA, imageB)
                case .slider: sliderCompare(imageA, imageB)
                case .highlight: highlightCompare(imageA)
                }
            }
        } else {
            ProgressView("正在加载原图…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func label(for shot: Shot, tag: String) -> String {
        "\(tag) · " + shot.capturedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func pane(image: NSImage?, title: String) -> some View {
        VStack(spacing: DS.s2) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sideBySide(_ left: NSImage, _ right: NSImage) -> some View {
        HStack(spacing: DS.s3) {
            pane(image: left, title: label(for: a, tag: "A"))
            pane(image: right, title: label(for: b, tag: "B"))
        }
    }

    /// 上下叠放 + 竖直分割线：A 盖在 B 上，用 leading 对齐的矩形 mask
    /// 只露出左边 `split` 比例，拖动分割线改比例。
    private func sliderCompare(_ top: NSImage, _ bottom: NSImage) -> some View {
        VStack(spacing: DS.s2) {
            GeometryReader { geo in
                let fitted = fittedSize(
                    content: CGSize(width: a.pixelWidth, height: a.pixelHeight),
                    in: geo.size
                )
                ZStack(alignment: .leading) {
                    Image(nsImage: bottom)
                        .resizable()
                        .interpolation(.medium)
                    Image(nsImage: top)
                        .resizable()
                        .interpolation(.medium)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: fitted.width * split)
                        }
                    // 分割线 + 抓手
                    ZStack {
                        Rectangle()
                            .fill(.white)
                            .frame(width: 2)
                            .shadow(color: DS.shadowOverlay, radius: 2)
                        Image(systemName: "arrow.left.and.right.circle.fill")
                            .font(.system(size: DS.font20))
                            .foregroundStyle(.white)
                            .shadow(color: DS.shadowOverlay, radius: 2)
                    }
                    .offset(x: fitted.width * split - 1)
                }
                .frame(width: fitted.width, height: fitted.height)
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            split = min(1, max(0, value.location.x / fitted.width))
                        }
                )
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            Text("左 A（\(label(for: a, tag: "A"))） ｜ 右 B（\(label(for: b, tag: "B"))）· 拖动分割线")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 差异高亮：红色半透明蒙版叠在 A 上。
    @ViewBuilder
    private func highlightCompare(_ base: NSImage) -> some View {
        if diffFailed {
            ContentUnavailableView(
                "差异计算失败",
                systemImage: "exclamationmark.triangle",
                description: Text("无法解码像素数据")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diffMask {
            VStack(spacing: DS.s2) {
                ZStack {
                    Image(nsImage: base)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                    Image(nsImage: diffMask)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("红色区域 = 与 B 不同的像素（容差 ±8/通道），底图为 A")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView("正在逐像素比较…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// aspect-fit 后的实际尺寸。
    private func fittedSize(content: CGSize, in container: CGSize) -> CGSize {
        guard content.width > 0, content.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        return CGSize(width: content.width * scale, height: content.height * scale)
    }

    // MARK: 加载与计算

    private func loadImages() async {
        diffMask = nil
        diffRatio = nil
        diffFailed = false
        let urlA = store.originalURL(for: a)
        let urlB = store.originalURL(for: b)
        let pair = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
            (ImageCodec.load(from: urlA), ImageCodec.load(from: urlB))
        }.value
        imageA = pair.0.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        imageB = pair.1.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    private func computeDiff() async {
        let urlA = store.originalURL(for: a)
        let urlB = store.originalURL(for: b)
        // 4K 逐像素约 800 万次比较，裸循环几十毫秒量级 —— 但绝不在主线程做。
        let result = await Task.detached(priority: .userInitiated) { () -> (CGImage, Double)? in
            guard let ia = ImageCodec.load(from: urlA),
                  let ib = ImageCodec.load(from: urlB) else { return nil }
            return PixelDiff.redMask(ia, ib)
        }.value
        guard let result else {
            diffFailed = true
            return
        }
        diffMask = NSImage(
            cgImage: result.0,
            size: NSSize(width: result.0.width, height: result.0.height)
        )
        diffRatio = result.1
    }
}

// MARK: - 逐像素差异

/// 与界面无关的纯计算，调用方负责放到后台线程。
enum PixelDiff {

    /// 逐像素比较两张同尺寸图（容差 ±8/通道），返回
    /// （差异区域的红色 55% 透明蒙版，差异像素占比）。尺寸不同或解码失败返回 nil。
    static func redMask(
        _ a: CGImage,
        _ b: CGImage,
        tolerance: Int = 8
    ) -> (mask: CGImage, ratio: Double)? {
        let width = a.width
        let height = a.height
        guard width > 0, height > 0, b.width == width, b.height == height else { return nil }

        guard let pa = rgbaBytes(of: a, width: width, height: height),
              let pb = rgbaBytes(of: b, width: width, height: height) else { return nil }

        let count = width * height * 4
        var mask = [UInt8](repeating: 0, count: count)
        var changed = 0
        var i = 0
        while i < count {
            let dr = abs(Int(pa[i]) - Int(pb[i]))
            let dg = abs(Int(pa[i + 1]) - Int(pb[i + 1]))
            let db = abs(Int(pa[i + 2]) - Int(pb[i + 2]))
            if dr > tolerance || dg > tolerance || db > tolerance {
                // premultipliedLast：红 55% 透明 → alpha 140，预乘后 r 同为 140。
                mask[i] = 140
                mask[i + 3] = 140
                changed += 1
            }
            i += 4
        }

        let image: CGImage? = mask.withUnsafeMutableBytes { ptr in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                    data: ptr.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }
            return ctx.makeImage()
        }
        guard let image else { return nil }
        return (image, Double(changed) / Double(width * height))
    }

    /// 把任意格式的 CGImage 统一画进 sRGB RGBA8 位图，逐字节可比。
    private static func rgbaBytes(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buffer.withUnsafeMutableBytes { ptr -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                    data: ptr.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        return ok ? buffer : nil
    }
}
