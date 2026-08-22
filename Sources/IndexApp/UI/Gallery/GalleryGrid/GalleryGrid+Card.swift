import AppKit
import SwiftUI

// MARK: - 鼠标修饰键缓存
//
// SwiftUI 的 TapGesture 回调不带修饰键，旧实现从 `NSApp.currentEvent` 反查。
// 但 tap 回调执行时 `currentEvent` 可能已被后续 keyDown / scrollWheel 覆盖
//（GalleryKeyboard 的 keyDown local monitor 加剧了这个窗口），导致普通点击
// 被误判为 ⌘ 点击走 toggle，把刚选中的那张又取消——表现为"✅ 有时不显示"。
//
// 修法：在 mouseDown 时刻（点击手势的起点）用 NSEvent local monitor 缓存
// 修饰键，tap 回调直接读缓存。与 GalleryKeyboard 用 monitor 而非 SwiftUI
// 手势的理由一致（GalleryKeyboard.swift:9-11）。

@MainActor
final class MouseModifierCache {
    static let shared = MouseModifierCache()
    private var flags: NSEvent.ModifierFlags?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return event
        }
    }

    var cachedFlags: NSEvent.ModifierFlags? { flags }
}

// MARK: - 卡片装配 / 右键菜单 / 单张动作
//
// 从 `GalleryGrid.swift` 拆出：这一组方法围绕「一张卡片」展开 ——
// 装配（card/cardBody）、点击与修饰键、右键菜单（单张/批量/专题集）、
// 以及单张动作（导出/上传/拖拽/钉图/复制/重命名/出处）。
// 视图属性（store/selection/…）的写访问为这个扩展放开。

extension GalleryGrid {

    @ViewBuilder
    func card(for shot: Shot, height: CGFloat) -> some View {
        if GalleryVisualBudget.allowsScrollDepth(
            isEnabled: settings.galleryScrollDepth,
            cardCount: visibleShots.count
        ) {
            cardBody(for: shot, height: height).scrollDepth()
        } else {
            cardBody(for: shot, height: height)
        }
    }

    func cardBody(for shot: Shot, height: CGFloat) -> some View {
        ShotCard(
            shot: shot,
            height: height,
            isSelected: selection.isSelected(shot.id),
            isFavorite: shot.id.map(store.isFavorite) ?? false,
            category: shot.id.flatMap { categoriesByShot[$0] },
            isAnnotated: shot.id.map(annotatedIDs.contains) ?? false,
            isRecording: recordingAsset(for: shot).isRecording,
            onToggleFavorite: { store.toggleFavorite(shot) }
        )
        .id(shot.id)
        .onTapGesture { handleTap(shot) }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                // 带修饰键的双击只是两次修饰点击（toggle / 范围），不进编辑器。
                guard currentModifiers().isEmpty else { return }
                // 双击动作由 ContentMode 描述（= Emacs major mode），从 PluginRegistry 取。
                let mode = PluginRegistry.shared.mode(for: ContentKind(rawValue: shot.contentKind) ?? .image)
                if mode.doubleClick == .openMarkdownEditor {
                    openMarkdownEditor(shot)
                    return
                }
                RecordingAssetActions.performPrimary(
                    recordingAsset(for: shot), shotID: shot.id,
                    presenter: GalleryWindowController.shared
                )
            }
        )
        // 用 `onDrag` 而不是 `.draggable(_:)`，理由是**接收方兼容性**：
        //
        // `.draggable` 配 `FileRepresentation` 交出去的是「文件承诺」（promise）。
        // 访达、邮件认它，但**浏览器的上传控件和多数 Office 应用只收磁盘上
        // 真实存在的文件 URL**，拿到承诺就当没有，表现为「拖过去没反应」。
        // 暂存卡片一直能拖进这些地方，正是因为它走 AppKit 的
        // `NSDraggingItem(pasteboardWriter: url as NSURL)`，天生就是真 URL。
        //
        // `onDrag` 的闭包在**拖拽真正开始时**才执行（不是 body 求值时），
        // 所以「载荷必须廉价」那条红线依然守得住 —— 渲染整张 PNG 一次拖拽只跑一次，
        // 而不是每张可见卡片每帧跑一次（那是当年拖垮图库滚动的事故）。
        .onDrag {
            NSItemProvider(contentsOf: dragFileURL(for: shot)) ?? NSItemProvider()
        }
        .contextMenu {
            // ⚠️ 这个 ViewBuilder 会在**普通渲染时**被 SwiftUI 求值，不是右键才跑 ——
            // 在这里写任何状态（哪怕 async）都会形成「渲染→改选中→重渲染」的自激振荡
            // （曾经的尾部卡片 20Hz 闪烁事故，选中乒乓 4 万次/分钟）。只准纯读。
            // 右键未选中的卡不再抢选中（Finder 的预选行为放弃）：菜单项本就绑定该 shot。
            if selection.isMultiple && selection.isSelected(shot.id) {
                batchContextMenu()
            } else {
                contextMenu(for: shot)
            }
        } preview: {
            CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
                .frame(maxWidth: 480, maxHeight: 360)
        }
    }

    /// 点击 = 单选；⌘点击 = toggle；⇧点击 = 锚点到落点的全局顺序区间。
    /// 选中后显式让搜索框等文本输入失焦，使后续 ⌘C 走图片路径而非空文本路径。
    func handleTap(_ shot: Shot) {
        guard let id = shot.id else {
            NSLog("[Index] handleTap: shot.id 为 nil，点击被忽略（windowTitle=\(shot.windowTitle ?? "nil")）")
            return
        }
        let flags = currentModifiers()
        if flags.contains(.command) {
            selection.toggle(id)
        } else if flags.contains(.shift) {
            selection.selectRange(to: id, in: visibleShots.compactMap(\.id))
        } else {
            selection.select(only: id)
        }
        // SwiftUI TapGesture 不会自动移走 field editor 的 firstResponder，
        // 若搜索框仍是 firstResponder，后续 ⌘C 会被本应让位的文本路径误判。
        if GalleryWindowController.shared.window?.firstResponder is NSTextView {
            GalleryWindowController.shared.window?.makeFirstResponder(nil)
        }
    }

    /// 从 mouseDown 时刻的缓存取修饰键（MouseModifierCache），
    /// 不再反查 NSApp.currentEvent（tap 回调时它可能已被后续事件覆盖）。
    func currentModifiers() -> NSEvent.ModifierFlags {
        MouseModifierCache.shared.cachedFlags ?? []
    }

    /// 双击 Markdown 卡片：打开 Typora 风格编辑器。
    private func openMarkdownEditor(_ shot: Shot) {
        guard let shotID = shot.id else { return }
        let store = ShotStore.shared
        // 收口读取：三步查询由 store 内部完成，没有存储的 Markdown 就现场生成。
        let source = store.markdownSource(for: shot) ?? MarkdownGenerator.generate(for: shot)
        let title = shot.windowTitle ?? "Markdown"
        MarkdownEditorWindowController.shared.show(title: title, source: source) { newSource in
            try? store.saveContent(for: shotID, kind: .markdown, payload: .markdown(newSource), updateKind: false)
            store.reload(query: "", filter: .all)
        }
    }

    // MARK: 右键菜单

    /// 多选右键的批量菜单：标题带张数，动作与多选详情栏共用一套实现。
    @ViewBuilder
    func batchContextMenu() -> some View {
        let ids = selection.orderedSelectedIDs
        let count = ids.count
        Button(GalleryBatch.allFavorited(ids: ids) ? "取消收藏 \(count) 张" : "收藏 \(count) 张") {
            GalleryBatch.toggleFavorites(ids: ids)
        }
        .disabled(batchActivity.isBusy)
        collectionMenu(for: ids)
        Button("复制 \(count) 张图片") {
            Task { _ = await GalleryBatch.copyImages(ids: ids) }
        }
        .disabled(batchActivity.isBusy)
        Button("导出 \(count) 张…") {
            Task { _ = await GalleryBatch.exportAll(ids: ids) }
        }
        .disabled(batchActivity.isBusy)
        Divider()
        Button("删除 \(count) 张截图…", role: .destructive) {
            selection.pendingDeleteIDs = ids
        }
        .disabled(batchActivity.isBusy)
    }

    @ViewBuilder
    func contextMenu(for shot: Shot) -> some View {
        let recording = recordingAsset(for: shot)
        if recording.isRecording {
            Button(recording.availableURL == nil ? "播放录屏（文件缺失）" : "播放录屏") {
                RecordingAssetActions.play(recording)
            }
            Button(recording.availableURL == nil ? "显示录屏位置（文件缺失）" : "在访达中显示录屏") {
                RecordingAssetActions.reveal(recording)
            }
            Divider()
        }
        Button(shot.id.map(store.isFavorite) ?? false ? "取消收藏" : "收藏") {
            store.toggleFavorite(shot)
        }
        .disabled(batchActivity.isBusy)
        Button("重命名…") { beginRename(shot) }
        if let id = shot.id {
            collectionMenu(for: [id])
        }
        Button("编辑标注") { GalleryWindowController.shared.mode.openEditor(shotID: shot.id) }
        Button("钉在桌面") { pin(shot) }
        Button("复制图片") { copy(shot) }
            .disabled(batchActivity.isBusy)
        Divider()
        Button("相似截图") { similarShot = shot }
        Button("时间线") { timelineShot = shot }
        Divider()
        Button("出处") { openSource(of: shot) }
            .disabled(shot.sourceURL == nil && shot.appBundleID == nil)
        Button(recording.isRecording ? "在访达中显示封面" : "在访达中显示") {
            SystemNavigator.revealInFinder(store.originalURL(for: shot))
        }
        Divider()
        Button(recording.isRecording ? "导出封面…" : "导出…") { export(shot) }
            .disabled(batchActivity.isBusy)
        if !settings.uploadEndpoint.isEmpty {
            Button("上传并复制链接") { upload(shot) }
        }
        Button("复制 Bug 报告") {
            Clipboard.copy(text: BugReport.markdown(
                shot: shot,
                pixelWidth: shot.pixelWidth,
                pixelHeight: shot.pixelHeight
            ))
        }
        Divider()
        Button("删除…", role: .destructive) {
            selection.pendingDeleteIDs = shot.id.map { [$0] }
        }
        .disabled(batchActivity.isBusy)
    }

    @ViewBuilder
    func collectionMenu(for shotIDs: [Int64]) -> some View {
        let isCurrentSelection = shotIDs.count == selection.selectedIDs.count
            && shotIDs.allSatisfy(selection.selectedIDs.contains)
        Menu {
            if collectionSummaries.isEmpty {
                // 与 ShotDetailPane / MultiSelectionPane 同一文案（空专题集引导）。
                Text("尚无专题集，请先到“收藏”页创建")
            } else {
                ForEach(collectionSummaries) { collection in
                    let membershipKnown = !isCurrentSelection
                        || selectedCollectionSnapshotGeneration == selection.generation
                    let isInAll = !shotIDs.isEmpty && (
                        isCurrentSelection
                            ? membershipKnown
                                && selectedCollectionMembershipCounts[collection.id] == shotIDs.count
                            : shotIDs.allSatisfy {
                                collectionIDsByShot[$0]?.contains(collection.id) == true
                            }
                    )
                    Button {
                        setMembership(
                            shotIDs: shotIDs,
                            collectionID: collection.id,
                            remove: isInAll
                        )
                    } label: {
                        Label(
                            collection.name,
                            systemImage: isInAll ? "checkmark" : "rectangle.stack.badge.plus"
                        )
                    }
                    .disabled(!membershipKnown)
                }
            }
        } label: {
            Label("加入专题收藏集", systemImage: "rectangle.stack.badge.plus")
        }
        .disabled(collectionSummaries.isEmpty || shotIDs.isEmpty || batchActivity.isBusy)
    }

    func setMembership(shotIDs: [Int64], collectionID: Int64, remove: Bool) {
        if remove {
            store.removeFromCollection(shotIDs: shotIDs, collectionID: collectionID)
        } else {
            do {
                try store.addToCollection(shotIDs: shotIDs, collectionID: collectionID)
            } catch {
                NSLog("[Index] 加入收藏集失败: \(error)")
            }
        }
        Task { await refreshSelectedCollectionMemberships() }
    }

    // MARK: 重命名

    func beginRename(_ shot: Shot) {
        renameName = shot.customTitle ?? ""
        renameTarget = shot
    }

    func commitRename(_ rawName: String?) {
        guard let target = renameTarget else { return }
        store.setCustomTitle(rawName, for: target)
        renameTarget = nil
    }

    // MARK: 单张动作

    /// 含最新标注的成品图。导出 / 上传 / 拖出共用一个口径 —— 和暂存栏、详情页一致。
    func renderedImage(for shot: Shot) -> CGImage? {
        guard let base = store.originalImage(for: shot) else { return nil }
        return LayerRenderer.render(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers()
        )
    }

    func export(_ shot: Shot) {
        guard let rendered = renderedImage(for: shot) else { return }
        _ = try? ImageExporter.exportWithPanel(
            rendered,
            suggestedName: ImageExporter.suggestedName(for: shot)
        )
    }

    /// 上传到自定义图床，链接进剪贴板。配置读「设置 → 上传」，和截图动作同一套。
    func upload(_ shot: Shot) {
        guard let rendered = renderedImage(for: shot),
              let png = ImageCodec.pngData(from: rendered) else { return }
        let settings = self.settings
        let config = UploadConfig(
            endpoint: settings.uploadEndpoint,
            fieldName: settings.uploadFieldName,
            headersText: settings.uploadHeaders,
            responsePath: settings.uploadResponsePath
        )
        let filename = ImageExporter.suggestedName(for: shot)
        Task {
            do {
                let link = try await ImageUploader.upload(png: png, filename: filename, config: config)
                Clipboard.copy(text: settings.uploadLinkFormat.format(link))
                NSLog("[Index] 图库上传成功，链接已复制: \(link)")
            } catch {
                NSLog("[Index] 图库上传失败: \(error)")
            }
        }
    }

    /// 拖出卡片的载荷。**必须是廉价构造**：`.draggable` 的载荷在 body 里
    /// 逐卡片急切求值，任何重活（读原图/渲染/写盘）放在这里都会把主线程打满 ——
    /// 表现就是「图库滚不动、点击丢失」。渲染推迟到真正拖放时的传输闭包里做。
    /// 拖拽用的成品 PNG 落到磁盘，返回它的 URL。
    ///
    /// **只在拖拽真正开始时调一次**（`onDrag` 的闭包），不是每帧。
    /// 重活集中在这：读原图 → 合成最新修订 → 编码 → 写临时文件；
    /// 目录复用暂存栏的拖拽临时目录，下次启动统一清理；渲染失败退回原图路径
    /// （拖出去的至少还是这张截图，只是没有标注）。
    func dragFileURL(for shot: Shot) -> URL? {
        let recording = recordingAsset(for: shot)
        if recording.isRecording {
            // 录屏卡片的拖拽契约是原始 MP4。文件缺失时不能偷偷退化为封面 PNG。
            return recording.availableURL
        }
        let fallback = store.originalURL(for: shot)
        guard let base = store.originalImage(for: shot) else { return fallback }

        let rendered = LayerRenderer.render(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers()
        )
        guard let png = ImageCodec.pngData(from: rendered) else { return fallback }

        let dir = ShelfController.dragFileDirectory
            .appendingPathComponent(shot.sha256, isDirectory: true)
        let url = dir.appendingPathComponent(ImageExporter.suggestedName(for: shot))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return fallback
        }
    }

    func recordingPath(for shot: Shot) -> String? {
        shot.id.flatMap { recordingPathsByShot[$0] }
    }

    func recordingAsset(for shot: Shot) -> RecordingAsset {
        RecordingAsset(path: recordingPath(for: shot))
    }

    // 这里曾经有个 `draggedIDs`：拖拽时携带「全部选中项的 ID」，
    // 供侧边栏「拖到标签上打标签」接收。那批投放目标在简化侧边栏时删掉了，
    // 这条应用内通道随之没有了消费方（连同 `ShotDragFile` / `ShotIDPayload`
    // 与那个自定义 UTType 一起移除）。将来要恢复拖放打标签，
    // 从 git 历史里取回即可 —— 那套载荷的廉价纪律有完整注释。

    /// 钉在桌面：走注册表的 pin 动作（界面层不直接建窗口），材料从图库记录重建。
    func pin(_ shot: Shot) {
        guard let base = store.originalImage(for: shot) else { return }
        let context = CaptureContext(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers(),
            shot: shot,
            region: nil,
            host: nil
        )
        Task { try? await CaptureActionRegistry.shared.action(id: ActionID.pin)?.perform(context) }
    }

    /// 单张复制走与 ⌘C、批量菜单**同一份**实现（`GalleryBatch.copyImages`）——
    /// 复制的是成品（原图 + 最新修订的标注），三个入口不该有三种结果。
    func copy(_ shot: Shot) {
        GalleryBatch.copyImages([shot])
    }

    /// 回到出处：优先开网址（默认浏览器），否则激活来源 App。
    func openSource(of shot: Shot) {
        if let source = shot.sourceURL, let url = URL(string: source) {
            SystemNavigator.open(url: url)
        } else if let bundleID = shot.appBundleID {
            SystemNavigator.activateApp(bundleID: bundleID)
        }
    }
}
