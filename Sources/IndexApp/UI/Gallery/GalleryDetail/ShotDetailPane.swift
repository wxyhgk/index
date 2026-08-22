import SwiftUI

/// 空态提示：尚无专题集时的引导文案（ShotDetailPane / MultiSelectionPane / GalleryGrid+Card 三处共用）。
private let emptyCollectionHint = "尚无专题集，请先到“收藏”页创建"

// MARK: - 右侧详情（单选）
//
// 设计稿 §6 的那块浮动卡片，自上而下：
//   预览区（190 高）→ 动作行（编辑 + 收藏 / 钉图 / 分享 / 更多）
//   → 元信息列表（App / 来源页 / 时间 / 像素 / 识别字数）
//   → 标签胶囊行（TagSection）→ 「查看全部信息 ›」
//
// 三条结构上的取舍：
//
// 1. **旧的四张分组卡片（来源 / 识别 / 标签 / 修订历史）不再堆在首屏。**
//    首屏改成设计稿的「一行一条」元信息列表，完整属性（OCR 全文、场景标签、
//    文件路径、sha256、敏感明细、修订链）搬到下钻页 `ShotInfoPage`。
//    信息一件没少，只是分了两层 —— 常看的五行留在眼前，排查用的长尾按需展开。
//
// 2. **动作一件都不许丢。** 设计稿只给了 5 个位置（1 主按钮 + 4 圆形位），
//    所以「分享」和「更多」这两位是菜单：导出 / 复制图片 / 上传进分享，
//    出处 / 取字 / 访达 / 相似 / 时间线 / 历史版本 / 打开录像 / Bug 报告 / 删除
//    进更多。放不下 ≠ 砍掉。
//
// 3. **不加材质。** 外层 `floatingPanel` 已经是不透明的面板底色，
//    面板内再叠玻璃只会互相采样出浑浊；分块用半透明填充（`.quaternary`）
//    而不是 Material，且因为底是实色，`.quaternary` 的对比度也站得住
//    （规格 §7.2 禁止的是它落在 `.thin` / `.ultraThin` 材质上）。
//
// 关闭按钮由外层 `GalleryInspectorPanel` 画在面板右上角，这里不重复画，
// 但内容要给它让位 —— 见 `InspectorMetrics.closeButtonLane`。

struct ShotDetailPane: View {
    let shot: Shot

    // 订阅 store 是为了收藏态实时刷新；重查询都挂在 task(id:) 上，不受影响。
    @ObservedObject private var store: ShotStore
    @ObservedObject private var selection = GalleryWindowController.shared.selection
    @ObservedObject private var settings: AppSettings

    init(shot: Shot, store: ShotStore = .shared, settings: AppSettings = .shared) {
        self.shot = shot
        self._store = ObservedObject(wrappedValue: store)
        self._settings = ObservedObject(wrappedValue: settings)
    }
    /// 阴影要按外观分流：深色下 L1 的阴影是 `.none`（黑底上的黑阴影只是糊一层脏）。
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 目标是否已有特征指纹。没有就先禁用「相似」——刚截的图可能还在后台分析。
    @State private var hasFeaturePrint = false
    @State private var showingSimilar = false
    /// 同源截图数量（含自己）。切换截图时查一次，少于 2 张禁用时间线入口。
    @State private var relatedCount = 0
    @State private var showingTimeline = false
    /// 敏感内容检测结果（后台异步落库，和指纹一样随 store 刷新重查）。
    @State private var sensitiveRegions: [SensitiveRegion] = []
    /// 是否已打码。加载时按「最新修订的马赛克层是否盖住全部命中区域」判定，
    /// 一键打码完成后直接置真。
    @State private var sensitiveMasked = false
    /// 录屏锚点：这张截图是某段录屏的首帧时，recording 附件存着 mp4 路径。
    @State private var recordingPath: String?
    /// 是否处于「全部信息」下钻页。换截图时自动回到摘要页（见 task）。
    @State private var showingAllInfo = false
    @State private var collectionSummaries: [ShotCollectionSummary] = []
    @State private var collectionIDs: Set<Int64> = []
    @State private var customTitleDraft = ""
    @State private var isEditingName = false

    var body: some View {
        content
            .task(id: shot.id) {
                // 换了截图就回到摘要页：下钻页讲的是「这一张」的属性，
                // 让它跨截图保持展开会让人以为看的还是刚才那张。
                showingAllInfo = false
                refreshFeaturePrint()
                refreshSensitiveRegions()
                relatedCount = store.relatedShots(to: shot).count
                recordingPath = store.recordingPath(for: shot)
                refreshCollections()
            }
            // 指纹与敏感区域由后台分析异步补上：store 每次刷新（属性落库会触发
            // reload）都重查一次。属性写入不一定改变 shots 数组本身，所以订阅
            // objectWillChange 而不是 onChange。单行 LIMIT 1 查询，代价可忽略。
            .onReceive(store.objectWillChange) { _ in
                refreshFeaturePrint()
                refreshSensitiveRegions()
                refreshCollections()
            }
            .onChange(of: shot.customTitle, initial: true) { _, title in
                customTitleDraft = title ?? ""
            }
            .sheet(isPresented: $showingSimilar) {
                SimilarShotsSheet(shot: shot)
            }
            .sheet(isPresented: $showingTimeline) {
                TimelineSheet(shot: shot)
            }
            // 摘要页 ↔ 下钻页是同一块面板换面，走 standard（0.35 利落）；
            // ReduceMotion 下降级成短 easeOut，不是硬切 —— 突变会丢失
            // 「这是同一块面板」的连续性。
            .animation(DS.Motion.standard(reduced: reduceMotion), value: showingAllInfo)
    }

    @ViewBuilder
    private var content: some View {
        if showingAllInfo {
            ShotInfoPage(shot: shot) { showingAllInfo = false }
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            summary
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s2) {
                preview
                nameEditor
                actionRow
                if !sensitiveRegions.isEmpty {
                    sensitiveBanner
                }
                metaList
                TagSection(shot: shot)
                Divider()
                InspectorDrillRow(title: "查看全部信息") { showingAllInfo = true }
            }
            .padding(.horizontal, DS.s4)
            .padding(.top, InspectorMetrics.closeButtonLane)
            .padding(.bottom, DS.s4)
        }
    }

    /// 图库名称是独立元数据；这里编辑不会触碰内容寻址原图或来源标题。
    /// 紧凑化：平时显示名称 + 铅笔图标，点击才变输入框，去掉标签和说明文字。
    private var nameEditor: some View {
        HStack(spacing: DS.s2) {
            if isEditingName {
                TextField(
                    "自动：\(shot.windowTitle ?? shot.appName ?? "未知来源")",
                    text: $customTitleDraft
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: DS.font14, weight: .medium))
                .onSubmit { commitCustomTitle() }
                .onExitCommand { isEditingName = false }

                Button {
                    commitCustomTitle()
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.borderless)
                .help("保存图库名称")

                if shot.customTitle != nil {
                    Button {
                        customTitleDraft = ""
                        store.setCustomTitle(nil, for: shot)
                        isEditingName = false
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("恢复自动名称")
                }
            } else {
                Text(shot.primaryDisplayName)
                    .font(.system(size: DS.font14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        customTitleDraft = shot.customTitle ?? ""
                        isEditingName = true
                    }
                    .help("点击编辑图库名称")

                Button {
                    customTitleDraft = shot.customTitle ?? ""
                    isEditingName = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: DS.font11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("编辑图库名称")
            }
        }
    }

    private func commitCustomTitle() {
        let normalized = Shot.normalizedCustomTitle(customTitleDraft)
        customTitleDraft = normalized ?? ""
        store.setCustomTitle(normalized, for: shot)
        isEditingName = false
    }

    // MARK: - 预览

    /// 预览区（设计稿 §6.2：等比预览、约 190 高、圆角 12、四周留白）。
    ///
    /// 等比意味着宽图上下留边、长图左右留边，所以垫一层浅底把预览区的边界
    /// 交代清楚 —— 否则一张窄长图会读成「面板上飘着一条图片」。
    /// 预览图是 L1 内容层：单层阴影走 `DS.shadow(.content, scheme)`
    ///（浅色 black .07/r3/y1，深色 `.none`）。
    private var preview: some View {
        let sh = DS.shadow(.content, scheme)
        let shape = RoundedRectangle(
            cornerRadius: InspectorMetrics.previewRadius,
            style: .continuous
        )
        return CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
            .frame(maxWidth: .infinity)
            .frame(height: InspectorMetrics.previewHeight)
            .background(DS.insetSurface, in: shape)
            .clipShape(shape)
            .shadow(color: sh.color, radius: sh.radius, y: sh.y)
            .contentShape(Rectangle())
            .onTapGesture { GalleryWindowController.shared.quickLook.present() }
            .help("点击（或按空格）用 Quick Look 预览原图")
            .accessibilityLabel("预览：\(shot.primaryDisplayName)")
    }

    // MARK: - 动作行

    /// 设计稿 §6.3：主按钮「编辑」+ 四个圆形位（收藏 / 钉图 / 分享 / 更多）。
    /// 圆形位靠右对齐、主按钮贴左 —— 370 宽的面板上 100 + 4×34 + 缝还有余量，
    /// 把余量放在中间比全部堆在左边更像设计稿。
    private var actionRow: some View {
        HStack(spacing: DS.s2) {
            Button {
                GalleryWindowController.shared.mode.openEditor(shotID: shot.id)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            .buttonStyle(.inspectorPill)
            .help("编辑标注")

            Spacer(minLength: DS.s2)

            favoriteButton

            Button {
                pin()
            } label: {
                Image(systemName: "pin")
            }
            .buttonStyle(.inspectorCircle)
            .help("钉在桌面")
            .accessibilityLabel("钉在桌面")

            shareMenu
            moreMenu
        }
    }

    private var favoriteButton: some View {
        let favorited = shot.id.map(store.isFavorite) ?? false
        return Button {
            store.toggleFavorite(shot)
        } label: {
            Image(systemName: favorited ? "star.fill" : "star")
        }
        // 收藏用黄色而不是 accent：同屏只允许一个控件戴强调色，
        // 那一份归主按钮「编辑」（规格 §7.1）。
        .buttonStyle(.inspectorCircle(tint: favorited ? .yellow : nil))
        .help(favorited ? "取消收藏" : "收藏")
        .accessibilityLabel(favorited ? "取消收藏" : "收藏")
    }

    /// 分享位：出图的三条路（存盘 / 剪贴板 / 图床）。
    private var shareMenu: some View {
        InspectorCircleMenu(
            systemImage: "square.and.arrow.up",
            label: "分享：导出 / 复制图片 / 上传图床"
        ) {
            Button {
                export()
            } label: {
                Label("导出成品…", systemImage: "square.and.arrow.down")
            }

            Button {
                copyImage()
            } label: {
                Label("复制图片", systemImage: "doc.on.doc")
            }

            Button {
                upload()
            } label: {
                Label("上传图床", systemImage: "arrow.up.circle")
            }
            .disabled(
                settings.uploadEndpoint
                    .trimmingCharacters(in: .whitespaces).isEmpty
            )
        }
    }

    /// 更多位：设计稿放不下的动作全在这里，**一件都不许在改版里蒸发**。
    private var moreMenu: some View {
        InspectorCircleMenu(systemImage: "ellipsis", label: "更多动作") {
            Menu {
                if collectionSummaries.isEmpty {
                    Text(emptyCollectionHint)
                } else {
                    ForEach(collectionSummaries) { collection in
                        let isMember = collectionIDs.contains(collection.id)
                        Button {
                            toggleCollection(collection.id, remove: isMember)
                        } label: {
                            Label(
                                collection.name,
                                systemImage: isMember ? "checkmark" : "rectangle.stack.badge.plus"
                            )
                        }
                    }
                }
            } label: {
                Label("加入专题收藏集", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(collectionSummaries.isEmpty || shot.id == nil)

            Divider()

            Button {
                openSource()
            } label: {
                Label("回到出处", systemImage: "arrow.up.forward.app")
            }
            .disabled(shot.sourceURL == nil && shot.appBundleID == nil)

            Button {
                copyRecognizedText()
            } label: {
                Label("取字（复制识别文字）", systemImage: "text.viewfinder")
            }
            .disabled((shot.ocrText ?? "").isEmpty)

            Button {
                SystemNavigator.revealInFinder(store.originalURL(for: shot))
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }

            Divider()

            Button {
                showingSimilar = true
            } label: {
                Label("查找相似", systemImage: "sparkles.rectangle.stack")
            }
            .disabled(!hasFeaturePrint)

            Button {
                showingTimeline = true
            } label: {
                Label("同源时间线", systemImage: "clock.arrow.circlepath")
            }
            .disabled(relatedCount < 2)

            Button {
                showingAllInfo = true
            } label: {
                Label("历史版本与全部信息", systemImage: "clock.arrow.2.circlepath")
            }

            if let path = recordingPath {
                let recording = RecordingAsset(path: path)
                Button {
                    RecordingAssetActions.play(recording)
                } label: {
                    Label(
                        recording.availableURL == nil ? "录像文件缺失" : "打开录像",
                        systemImage: "play.rectangle"
                    )
                }
            }

            Divider()

            Button {
                Clipboard.copy(text: BugReport.markdown(
                    shot: shot,
                    pixelWidth: shot.pixelWidth,
                    pixelHeight: shot.pixelHeight
                ))
            } label: {
                Label("复制 Bug 报告", systemImage: "ladybug")
            }

            Divider()

            // 删除走和键盘 ⌘⌫ / 右键菜单同一条路：写 pendingDeleteIDs，
            // 由网格上那个唯一的确认对话框收口。删除不可撤销，必须过确认。
            Button(role: .destructive) {
                selection.pendingDeleteIDs = shot.id.map { [$0] }
            } label: {
                Label("删除…", systemImage: "trash")
            }
        }
    }

    private func refreshCollections() {
        collectionSummaries = store.collectionSummaries()
        guard let id = shot.id else {
            collectionIDs = []
            return
        }
        collectionIDs = store.collectionMemberships(shotIDs: [id])[id] ?? []
    }

    private func toggleCollection(_ collectionID: Int64, remove: Bool) {
        guard let id = shot.id else { return }
        if remove {
            store.removeFromCollection(shotIDs: [id], collectionID: collectionID)
        } else {
            do {
                try store.addToCollection(shotIDs: [id], collectionID: collectionID)
            } catch {
                NSLog("[Index] 加入收藏集失败: \(error)")
            }
        }
        refreshCollections()
    }

    // MARK: - 元信息列表

    /// 设计稿 §6.4：五行「18pt 图标 + 13pt 文字」，行高 38。
    /// **没有值的行不构造** —— 空行在列表里是一道读不出含义的缝。
    private var metaList: some View {
        VStack(spacing: 0) {
            if let appName = shot.appName, !appName.isEmpty {
                InspectorMetaRow(
                    icon: .appIcon(bundleID: shot.appBundleID),
                    text: appName,
                    help: shot.appBundleID ?? appName
                )
            }

            if let source = sourceRow {
                InspectorMetaRow(
                    icon: .symbol("globe"),
                    text: source.text,
                    help: source.help,
                    action: source.canOpen ? { openSource() } : nil
                )
            }

            InspectorMetaRow(icon: .symbol("calendar"), text: capturedText)

            InspectorMetaRow(
                icon: .symbol("photo"),
                text: "\(shot.pixelWidth) × \(shot.pixelHeight) px"
            )

            if let ocr = shot.ocrText, !ocr.isEmpty {
                InspectorMetaRow(
                    icon: .symbol("text.alignleft"),
                    text: "识别文字 \(ocr.count) 字",
                    help: "查看全部识别文字",
                    action: { showingAllInfo = true }
                )
            }
        }
    }

    /// 来源页那一行：优先窗口标题（浏览器截图里它就是页面标题），
    /// 没有标题时退到网址的主机名；两个都没有就不画这一行。
    private var sourceRow: (text: String, help: String?, canOpen: Bool)? {
        let title = shot.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = shot.sourceURL.flatMap { URL(string: $0)?.host }
        guard let text = [title, host].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            return nil
        }
        return (text, shot.sourceURL ?? text, shot.sourceURL != nil)
    }

    /// 设计稿的时间格式「2026年7月29日 · 20:17」。
    /// 用 `.long` + `.shortened` 让系统按用户区域给年月日与 24 小时制，
    /// 而不是写死一个中文模板 —— 中文环境下出来的就是上面那个样子。
    private var capturedText: String {
        let day = shot.capturedAt.formatted(date: .long, time: .omitted)
        let time = shot.capturedAt.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(time)"
    }

    // MARK: - 敏感内容

    /// 按种类汇总的提示文案，如「2 处邮箱、1 处 API 密钥」。
    private var sensitiveSummary: String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for region in sensitiveRegions {
            if counts[region.kind] == nil { order.append(region.kind) }
            counts[region.kind, default: 0] += 1
        }
        return order.map { "\(counts[$0] ?? 0) 处\($0)" }.joined(separator: "、")
    }

    /// 敏感横幅。设计稿没画它（那张设计图里没有命中），但它**只在有命中时出现**，
    /// 删掉等于让脱敏功能失去入口。命中内容的明细留在下钻页 ——
    /// 首屏只说「有几处什么」，具体的邮箱 / 密钥片段不铺在这里。
    private var sensitiveBanner: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack(alignment: .firstTextBaseline, spacing: DS.s2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("检测到敏感内容：\(sensitiveSummary)")
                    .font(.caption.weight(.semibold))
            }
            if sensitiveMasked {
                Label("已打码", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button {
                    maskSensitiveRegions()
                } label: {
                    Label("一键打码", systemImage: "squareshape.split.3x3")
                }
                .buttonStyle(InspectorSoftButtonStyle(tint: .orange))
            }
        }
        .padding(DS.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 警示色（黄）是状态语义，不是强调色也不参与深度表达。
        .background(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .fill(DS.statusWarningFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(DS.statusWarningStroke, lineWidth: 1)
        )
    }

    /// 一键打码：每个命中区域外扩 4px 生成一个马赛克层，
    /// 追加为**新修订**（非破坏，历史可回溯，随时能回到打码前）。
    private func maskSensitiveRegions() {
        let existing = store.latestRevision(for: shot)?.imageLayers ?? Layers()
        var layers = existing
        let bounds = CGRect(
            x: 0, y: 0,
            width: CGFloat(shot.pixelWidth), height: CGFloat(shot.pixelHeight)
        )
        for region in sensitiveRegions {
            let rect = region.rect.insetBy(dx: -4, dy: -4).intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { continue }
            layers.append(Layer(kind: .pixelate, rect: LRect(rect)))
        }
        guard store.appendRevision(shot: shot, layers: layers, note: "自动脱敏") != nil else { return }
        sensitiveMasked = true
    }

    // MARK: - 派生数据

    private func refreshFeaturePrint() {
        hasFeaturePrint = shot.id.map {
            store.attributePayload(shotID: $0, key: AttributeKey.featurePrint) != nil
        } ?? false
    }

    private func refreshSensitiveRegions() {
        guard let id = shot.id,
              let data = store.attributePayload(shotID: id, key: AttributeKey.sensitiveRegions),
              let regions = try? JSONDecoder().decode([SensitiveRegion].self, from: data),
              !regions.isEmpty
        else {
            sensitiveRegions = []
            sensitiveMasked = false
            return
        }
        sensitiveRegions = regions
        // 已打码 = 最新修订里每个命中区域都被某个马赛克层完整覆盖。
        let pixelates = (store.latestRevision(for: shot)?.layers ?? [])
            .filter { $0.kind == .pixelate }
        sensitiveMasked = regions.allSatisfy { region in
            pixelates.contains { $0.rect.cg.contains(region.rect) }
        }
    }

    // MARK: - 动作实现

    /// 图库记录 → 动作上下文。钉图 / 上传都从这里取材料（原图 + 最新标注）。
    private func actionContext() -> CaptureContext? {
        guard let base = store.originalImage(for: shot) else { return nil }
        return CaptureContext(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers(),
            shot: shot,
            region: nil,
            host: nil
        )
    }

    /// 钉在桌面：走注册表的 pin 动作（界面层不直接建窗口）。
    private func pin() {
        guard let context = actionContext() else { return }
        Task { try? await CaptureActionRegistry.shared.action(id: ActionID.pin)?.perform(context) }
    }

    /// 上传图床：走注册表的 upload 动作。
    ///
    /// 以前这里是 `UploadAction().perform(...)` —— 界面层直接实例化具体动作、
    /// 绕过注册表（ARCHITECTURE §1 违例表里记着的那一条）。后果不是理论上的：
    /// 谁替换或包装了注册表里的 upload（加一层限流、换成企业图床），
    /// 图库这条路径会悄悄用回旧实现。现在和 pin 走同一条路，界面层只认 `ActionID`。
    private func upload() {
        guard let context = actionContext(),
              let action = CaptureActionRegistry.shared.action(id: ActionID.upload) else { return }
        Task {
            do {
                try await action.perform(context)
            } catch {
                AppAlert.error(
                    "上传失败",
                    error: error,
                    host: GalleryWindowController.shared.window
                )
            }
        }
    }

    /// 回到出处：优先开网址（默认浏览器），否则激活来源 App。
    private func openSource() {
        if let source = shot.sourceURL, let url = URL(string: source) {
            SystemNavigator.open(url: url)
        } else if let bundleID = shot.appBundleID {
            SystemNavigator.activateApp(bundleID: bundleID)
        }
    }

    /// 取字：把已入库的 OCR 结果直接送进剪贴板。
    /// 不重跑一遍 Vision —— 后台早就识别过了，重跑只是让用户白等。
    private func copyRecognizedText() {
        guard let text = shot.ocrText, !text.isEmpty else { return }
        Clipboard.copy(text: text)
    }

    private func export() {
        guard let rendered = renderedImage() else { return }
        _ = try? ImageExporter.exportWithPanel(
            rendered,
            suggestedName: ImageExporter.suggestedName(for: shot)
        )
    }

    private func copyImage() {
        guard let rendered = renderedImage() else { return }
        Clipboard.copy(rendered)
    }

    /// 含最新标注的成品图。导出 / 复制共用一个口径 —— 和网格、暂存栏一致。
    private func renderedImage() -> CGImage? {
        guard let base = store.originalImage(for: shot) else { return nil }
        return LayerRenderer.render(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers()
        )
    }
}

#if DEBUG
#Preview {
    let store = FakeShotStore.preview
    if let shot = store.shots.first {
        Text("ShotDetailPane · \(shot.windowTitle ?? "Untitled") · FakeShotStore")
            .padding()
    } else {
        Text("No preview shots")
    }
}
#endif
