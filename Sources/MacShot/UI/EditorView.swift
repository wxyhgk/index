import SwiftUI
import AppKit

/// 非破坏性标注编辑器。
/// 画布上的一切都是图层；保存时只是往 revision 表追加一条记录，原图字节永远不变。
///
/// 活在**图库窗口内**（Snagit 的 Editor/Library 单窗口双模式）：
/// `GalleryWindowMode.editingShotID` 非 nil 时 GalleryView 按 ID 现查 Shot
/// 并整窗切到本视图，返回图库 = `returnToGallery()`；换图 = 换成目标 ID
/// （宿主用 `.id(shot.id)` 保证重建，`shot` 因此得以保持 `let`，
/// 重新走一遍 onAppear → load）。
///
/// 状态机是和截图覆盖层 / 钉图窗口**同一个** `AnnotationState` ——
/// 工具、固定 4 色 3 档粗细、选中 / 拖动 / 删除、全量撤销重做因此完全一致。
/// 编辑器的画布空间就是图片像素（和钉图一样），`CanvasSpace ↔ ImageSpace` 是恒等变换。
struct EditorView: View {

    let shot: Shot

    // 不订阅 store：后台 OCR 回填会触发它发布变更，没必要为此重建整个编辑器。
    private let store = ShotStore.shared

    /// `AnnotationState` 不是 ObservableObject；它的每次变更都经由本视图的
    /// 处理函数发生，处理函数末尾自增这个计数器驱动 SwiftUI 重绘。
    @State private var annotation = AnnotationState()
    @State private var annotationTick = 0

    @State private var baseImage: CGImage?
    /// 底图 + 已应用的马赛克。拖拽过程中不重算，只在图层提交后刷新。
    @State private var canvasImage: CGImage?

    @State private var loadedRevisionIndex: Int?

    /// 未保存检测的基线：最近一次载入 / 保存时的图层数组。
    /// 当前图层与它不等 = 有未保存的标注（换图守卫用，Layer 是 Equatable）。
    @State private var baselineLayers: [Layer] = []

    /// 拖拽标注时 body 每帧都会重建 —— 修订列表绝不能挂在 body 上做数据库查询。
    @State private var revisions: [Revision] = []

    /// 一次画布拖拽在做什么。`idle` 表示这次按下不产生后续（点空处取消选中等）。
    private enum CanvasDrag { case draw, move, resize, idle }
    @State private var canvasDrag: CanvasDrag?

    /// 画布缩放倍率。`nil` = 适应窗口（自适应 fitted 分支）；
    /// 非 nil 时画布尺寸 = 图像点尺寸 × 倍率，包进滚动容器可平移。
    @State private var zoomLevel: Double?

    /// 缩放菜单的固定档位。⌃滚轮 / 捏合走连续缩放，范围见 `zoomRange`。
    private static let zoomSteps: [Double] = [0.25, 0.5, 1, 2, 4]

    /// 连续缩放的钳制范围。
    private static let zoomRange: ClosedRange<Double> = 0.1...8.0

    /// 画布模式：指针（画/选/移图层）或抓手（拖拽平移视口）。
    /// 抓手**不是**标注工具（不进 AnnotationTool）—— 覆盖层 / 钉图没有滚动概念。
    private enum CanvasMode { case pointer, hand }
    @State private var canvasMode: CanvasMode = .pointer

    /// 滚动容器的命令桥：抓手平移、锚点缩放都经它摸 NSClipView。
    @State private var panBox = CanvasPanBox()

    /// 抓手拖拽的上一次光标位置（窗口坐标 —— 平移时内容在光标下滑动，
    /// 本地坐标会跟着变，只有窗口坐标是稳定参照）。nil = 没在拖。
    @State private var panLastWindowLocation: CGPoint?

    /// 光标是否悬在画布上（空格临时抓手切换光标样式时用）。
    @State private var canvasHovered = false

    /// 按住空格临时抓手的按键监视器。
    @StateObject private var spaceMonitor = EditorSpaceHandMonitor()

    /// 右侧面板的两个 tab：图层（列表 + 文字编辑 + 历史版本）/ 效果（美化、水印、外壳）。
    private enum InspectorTab: String, CaseIterable { case layers = "图层", effects = "效果" }
    @State private var inspectorTab: InspectorTab = .layers

    /// 右侧文字框获得焦点时，裸键工具快捷键（R / A / …）必须让位给打字。
    @FocusState private var textFieldFocused: Bool

    /// 编辑器工具栏的展示顺序。`nil` 是指针模式。
    private static let toolOrder: [AnnotationTool?] =
        [nil, .rect, .ellipse, .arrow, .line, .text, .counter, .highlight, .spotlight,
         .dimension, .pixelate, .crop]

    var body: some View {
        // 读一下计数器，让所有标注变更都能触发 body 重算。
        let _ = annotationTick

        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                inspector
                    .frame(width: 260)
            }
            Divider()
            bottomBar
            EditorFilmstrip(currentShotID: shot.id, onSelect: requestSwitch)
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(hiddenShortcuts)
        .onAppear {
            load()
            spaceMonitor.install()
        }
        .onDisappear { spaceMonitor.remove() }
        .onChange(of: zoomLevel) { _, newValue in
            // 适应窗口态没有可平移空间，抓手模式随之退场（按钮也已置灰）。
            if newValue == nil { canvasMode = .pointer }
        }
        .onChange(of: spaceMonitor.spaceHeld) { _, held in
            // 空格切手势会让进行中的标注拖拽收不到 onEnded，主动收尾避免状态卡住。
            if held, canvasDrag != nil { handleDragEnded() }
            if !held { panLastWindowLocation = nil }
            if canvasHovered {
                (handModeActive ? NSCursor.openHand : NSCursor.arrow).set()
            }
        }
    }

    // MARK: - 加载

    private func load() {
        guard let base = store.originalImage(for: shot) else { return }
        baseImage = base
        // 效果层的注入上下文（编辑器这一处，与覆盖层/钉图同一契约）：
        // 画布就是图像像素 —— 水印按原图宽烤字号、壳/信息栏按 shot.scale 缩放；
        // 元数据来自采集时落库的真实归因 —— 竞品的壳是空的，这里是真的。
        annotation.effectContext = { [shot] in
            var context = EffectContext()
            context.imagePixelWidth = Double(base.width)
            context.imagePixelHeight = Double(base.height)
            context.chromeScale = max(1, shot.scale)
            context.windowTitle = shot.windowTitle
            context.sourceURL = shot.sourceURL
            context.appDescription = CaptureInfoSpec.appDescription(
                name: shot.appName, version: shot.appVersion
            )
            context.capturedAt = shot.capturedAt
            return context
        }
        revisions = store.revisions(for: shot)
        loadRevision(layers: revisions.last?.layers ?? [], index: max(0, revisions.count - 1))
    }

    private func loadRevision(layers: [Layer], index: Int) {
        annotation.load(Layers(persisted: layers), pixelSource: cropPixels)
        baselineLayers = layers
        loadedRevisionIndex = index
        refreshCanvasImage()
        annotationTick += 1
    }

    /// 马赛克贴片的像素来源：编辑器画布就是图片像素，直接从原图裁。
    private func cropPixels(_ rect: CGRect) -> CGImage? {
        baseImage?.cropping(to: rect.integral)
    }

    /// 只有马赛克需要走像素管线，这里单独重算一次。
    private func refreshCanvasImage() {
        guard let base = baseImage else { return }
        let pixelates = exportedLayers.filter { $0.kind == .pixelate }
        canvasImage = pixelates.isEmpty
            ? base
            : LayerRenderer.render(base: base, layers: pixelates)
    }

    /// 恒等投影到图像像素空间 —— 入库、导出、烤底图都用这一份。
    private var exportedLayers: Layers<ImageSpace> {
        annotation.layers.projected(onto: .zero, scale: 1)
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Snagit 的 Editor/Library 位：左上角返回图库（同一窗口整体切回）。
            Button {
                requestReturnToGallery()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("图库")
                }
                .frame(height: 44)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回图库（⎋）")

            Divider().frame(height: 24)

            // Snagit 式大按钮：图标上、标签下，工具一目了然。
            // 指针旁是抓手（画布模式，不是标注工具），其后才是标注工具。
            HStack(spacing: 2) {
                toolButton(nil)
                handButton
                ForEach(Array(Self.toolOrder.dropFirst().enumerated()), id: \.offset) { _, tool in
                    toolButton(tool)
                }
            }

            Spacer(minLength: DS.s2)

            // 样式控件靠右紧凑放，**只显示当前工具声明的轴**
            // （见 ToolStyle：马赛克没有颜色轴，裁剪一根轴都没有）。
            if annotation.styleAxes.contains(.color) {
                HStack(spacing: 4) {
                    ForEach(AnnotationState.palette.indices, id: \.self) { index in
                        colorButton(index)
                    }
                }
                Divider().frame(height: 18)
            }

            ForEach(annotation.styleAxes.filter { $0 != .color }, id: \.self) { axis in
                HStack(spacing: 4) {
                    ForEach(axis.steps.indices, id: \.self) { index in
                        paramButton(axis, index)
                    }
                }
                Divider().frame(height: 18)
            }

            Button {
                performUndo()
            } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 26, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!annotation.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("撤销（⌘Z）")

            Button {
                performRedo()
            } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 26, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!annotation.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("重做（⇧⌘Z）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func toolButton(_ tool: AnnotationTool?) -> some View {
        // 抓手激活时指针按钮不再高亮（两者都对应 annotation.tool == nil）。
        let selected = annotation.tool == tool && canvasMode == .pointer
        let shortcut = AnnotationTool.shortcuts.first { $0.tool == tool }

        return Button {
            selectTool(tool)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tool?.symbolName ?? "cursorarrow")
                    .font(.system(size: 15))
                    .frame(height: 18)
                Text(tool?.title ?? "指针")
                    .font(.caption2)
            }
            .frame(width: 48, height: 44)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusSmall)
                .fill(selected ? Color.accentColor.opacity(0.22) : .clear)
        )
        .foregroundStyle(selected ? Color.accentColor : .primary)
        .keyboardShortcut(bareKeyShortcut(shortcut?.label))
        .help(shortcut.map { "\($0.toolName)（\($0.label)）" } ?? tool?.title ?? "指针")
    }

    /// 抓手按钮（Snagit 式大按钮同款样式）。适应窗口态没有可平移空间，置灰。
    /// 快捷键刻意不占字母（H 已是高亮）：按住空格即临时抓手，点按钮是常驻抓手。
    private var handButton: some View {
        let selected = canvasMode == .hand
        let disabled = zoomLevel == nil
        return Button {
            toggleHandMode()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 15))
                    .frame(height: 18)
                Text("抓手")
                    .font(.caption2)
            }
            .frame(width: 48, height: 44)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusSmall)
                .fill(selected ? Color.accentColor.opacity(0.22) : .clear)
        )
        .foregroundStyle(selected ? Color.accentColor : .primary)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .help(disabled
              ? "抓手：放大后可拖拽平移画布（按住空格临时抓手）"
              : "抓手：拖拽平移画布（按住空格临时抓手）")
    }

    private func toggleHandMode() {
        annotation.endTextEditing()
        if canvasMode == .hand {
            canvasMode = .pointer
        } else {
            canvasMode = .hand
            annotation.tool = nil
        }
        annotationTick += 1
    }

    /// 裸键快捷键（无修饰）。文字框在打字时返回 nil，把按键让给输入。
    /// 显式限定 `SwiftUI.`：项目里有个同名的全局热键类型（Settings/KeyboardShortcut.swift）。
    private func bareKeyShortcut(_ label: String?) -> SwiftUI.KeyboardShortcut? {
        guard !textFieldFocused,
              let ch = label?.lowercased().first else { return nil }
        return SwiftUI.KeyboardShortcut(KeyEquivalent(ch), modifiers: [])
    }

    private func colorButton(_ index: Int) -> some View {
        let c = AnnotationState.palette[index]
        let selected = annotation.styleIndex(for: .color) == index
        return Button {
            annotation.setStyleIndex(index, for: .color)
            annotation.applyColorToSelection()
            annotationTick += 1
        } label: {
            Circle()
                .fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b))
                .overlay(Circle().strokeBorder(.black.opacity(0.25)))
                .frame(width: 14, height: 14)
                .padding(3)
                .overlay(
                    Circle().strokeBorder(
                        selected ? Color.accentColor : .clear,
                        lineWidth: 1.5
                    )
                )
        }
        .buttonStyle(.plain)
        .help("颜色 \(index + 1)")
    }

    /// 数值型样式轴的档位按钮（粗细 / 字号 / 透明度 / 颗粒 / 压暗）。
    /// 圆点直径按档位递增，够表达「三档由小到大」；具体语义靠 help 文案区分。
    private func paramButton(_ axis: ToolStyleAxis, _ index: Int) -> some View {
        let diameter = 5 + CGFloat(index) * 4
        let selected = annotation.styleIndex(for: axis) == index
        return Button {
            annotation.setStyleIndex(index, for: axis)
            annotation.applyStyleToSelection(axis)
            annotationTick += 1
        } label: {
            Circle()
                .fill(selected ? Color.accentColor : Color.primary.opacity(0.75))
                .frame(width: diameter, height: diameter)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help("\(axis.title) \(index + 1)")
    }

    // MARK: - 效果面板（右侧「效果」tab）

    /// 效果 tab：每个效果一行分组卡片（开关 + 展开的样式子选项）。
    /// 行样式对齐图库 inspector：quaternary 底 + DS.radiusCard + caption.semibold 组题。
    private var effectsPanel: some View {
        ScrollView {
            VStack(spacing: DS.s3) {
                backdropCard
                watermarkCard
                frameCard
                EditorCaptureInfoRow(annotation: annotation) {
                    annotationTick += 1
                }
            }
            .padding(DS.s3)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 分组卡片骨架：组题 + 右侧开关，开着时展开子选项。
    private func effectCard(
        _ title: String,
        isOn: Bool,
        toggle: @escaping () -> Void,
        @ViewBuilder options: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(title, isOn: Binding(get: { isOn }, set: { _ in toggle() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            if isOn {
                options()
            }
        }
        .padding(DS.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.radiusCard))
    }

    /// 美化行。backdrop 只影响导出/复制/保存的成品 ——
    /// 画布预览刻意不变（见 `AnnotationRenderer` 的说明），开关表达状态。
    /// 预设色块点选即换（`setBackdropPreset`），作为一条可撤销的 style 记录。
    private var backdropCard: some View {
        effectCard("美化", isOn: annotation.hasEffect(.backdrop), toggle: {
            annotation.toggleEffect(.backdrop)
            annotationTick += 1
        }) {
            HStack(spacing: DS.s2) {
                ForEach(BackdropPreset.allCases, id: \.rawValue) { preset in
                    backdropSwatch(preset)
                }
            }
        }
    }

    /// 背景预设小色块：渐变预设画渐变、纯色预设画灰块，选中态描 accent 边。
    private func backdropSwatch(_ preset: BackdropPreset) -> some View {
        let selected = annotation.backdropPresetID == preset.rawValue
        return Button {
            annotation.setBackdropPreset(preset.rawValue)
            annotationTick += 1
        } label: {
            RoundedRectangle(cornerRadius: DS.radiusSmall)
                .fill(swatchGradient(preset))
                .frame(width: 40, height: 26)
                // 透明档画一条斜杠示意「这里什么都没有」——
                // 光靠一块浅灰跟 solid 预设分不出来。
                .overlay {
                    if preset == .transparent {
                        Path { path in
                            path.move(to: CGPoint(x: 6, y: 20))
                            path.addLine(to: CGPoint(x: 34, y: 6))
                        }
                        .stroke(Color.primary.opacity(0.45), lineWidth: 1.5)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusSmall)
                        .strokeBorder(
                            selected ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: selected ? 2 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help(preset.displayName)
    }

    private func swatchGradient(_ preset: BackdropPreset) -> LinearGradient {
        guard let (a, b) = preset.gradientColors else {
            // 透明档示意为很淡的底（配一条斜杠）；solid 导出时用图层自身颜色，示意为中性灰。
            let white = preset == .transparent ? 0.85 : 0.4
            return LinearGradient(
                colors: [Color(.sRGB, white: white, opacity: preset == .transparent ? 0.25 : 1)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color(cgColor: a), Color(cgColor: b)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// 水印行。参数（设置里的文案/模式/透明度，没配文案时的 "MacShot" 兜底）
    /// 都在描述符 `EffectRegistry.watermark` 里 —— 工具条开关、自动水印共用同一份。
    /// 和美化不同，水印会画进画布预览 —— 它影响构图判断。
    /// 位置三选走 `setWatermarkMode`，作为一条可撤销的 style 记录。
    private var watermarkCard: some View {
        effectCard("水印", isOn: annotation.hasEffect(.watermark), toggle: {
            annotation.toggleEffect(.watermark)
            annotationTick += 1
        }) {
            Picker("水印位置", selection: Binding(
                get: { annotation.watermarkMode ?? .corner },
                set: { mode in
                    annotation.setWatermarkMode(mode)
                    annotationTick += 1
                }
            )) {
                ForEach(WatermarkMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// 外壳行。frame 只影响导出/复制/保存的成品，画布预览刻意不变（同美化的取舍）。
    /// 开壳时把 shot 的真实窗口标题 / 网址烤进壳的参数 JSON（见 `load` 的注入上下文）；
    /// 样式二选走 `setFrameStyle`，作为一条可撤销的 style 记录。
    private var frameCard: some View {
        effectCard("外壳", isOn: annotation.hasEffect(.frame), toggle: {
            annotation.toggleEffect(.frame)
            annotationTick += 1
        }) {
            Picker("壳样式", selection: Binding(
                get: { annotation.frameStyle ?? .macos },
                set: { style in
                    annotation.setFrameStyle(style)
                    annotationTick += 1
                }
            )) {
                ForEach(FrameSpec.Style.allCases, id: \.rawValue) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func selectTool(_ tool: AnnotationTool?) {
        annotation.endTextEditing()
        annotation.tool = tool
        canvasMode = .pointer
        annotationTick += 1
    }

    /// 不可见按钮承载的快捷键：⌫ 删除选中图层（打字时禁用，退格让给文字框）、
    /// ⌘0 适应窗口、⌘+ 放大（⌘= 挂在底栏的加号按钮上，这里补真正的 "+" 键）。
    private var hiddenShortcuts: some View {
        Group {
            Button("删除选中图层") { performDelete() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(textFieldFocused || annotation.selectedID == nil)
            Button("适应窗口") { zoomLevel = nil }
                .keyboardShortcut("0", modifiers: .command)
            Button("放大") { zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - 操作

    private func performUndo() {
        guard annotation.undo() else { return }
        refreshCanvasImage()
        annotationTick += 1
    }

    private func performRedo() {
        guard annotation.redo() else { return }
        refreshCanvasImage()
        annotationTick += 1
    }

    private func performDelete() {
        guard annotation.deleteSelected() else { return }
        refreshCanvasImage()
        annotationTick += 1
    }

    // MARK: - 画布

    /// 两种布局态共用一条 `canvasBody` 修饰链，只是 fitted 矩形来源不同：
    /// 适应窗口时内容 = 视口（无滚动，fitted 居中带 16pt 留白）；
    /// 缩放时画布尺寸 = 图像点尺寸 × 倍率，小于视口时通过 fitted 的 origin 居中。
    /// 两态都包在 `EditorCanvasScrollView`（NSScrollView）里 ——
    /// ⌃滚轮 / 捏合缩放、抓手平移、锚点定位都要程序化摸滚动原点，
    /// SwiftUI 的 ScrollView 给不了（见 EditorCanvasScrollView 的说明）。
    private var canvas: some View {
        GeometryReader { geo in
            let viewport = geo.size
            let layout = canvasLayout(viewport: viewport)
            EditorCanvasScrollView(
                contentSize: layout.content,
                panBox: panBox,
                onZoom: { factor, docPoint, clipPoint in
                    handleContinuousZoom(
                        factor: factor, docPoint: docPoint,
                        clipPoint: clipPoint, viewport: viewport
                    )
                }
            ) {
                canvasBody(fitted: layout.fitted)
                    .frame(
                        width: layout.content.width,
                        height: layout.content.height,
                        alignment: .topLeading
                    )
            }
        }
    }

    /// 两态统一的画布布局。返回的 `fitted` 同构（origin = 画布在滚动内容里的
    /// 位置），`imagePoint` / 手势因此不区分分支。
    private func canvasLayout(viewport: CGSize) -> (fitted: CGRect, content: CGSize) {
        if let zoom = zoomLevel {
            return zoomedRects(zoom: zoom, viewport: viewport)
        }
        // 适应窗口：四周 16pt 留白里适配居中，内容恰好一个视口大（无滚动）。
        let inner = CGSize(
            width: max(1, viewport.width - 32),
            height: max(1, viewport.height - 32)
        )
        let fitted = fittedRect(in: inner).offsetBy(dx: 16, dy: 16)
        return (fitted, viewport)
    }

    /// 抓手是否生效：常驻抓手或按住空格，且处于缩放态（适应态无可平移空间）。
    private var handModeActive: Bool {
        zoomLevel != nil && (canvasMode == .hand || spaceMonitor.spaceHeld)
    }

    /// 画布本体 + 手势。`fitted` 是画布在其父容器坐标里的摆放矩形 ——
    /// 视图以 topLeading 参与布局（origin 在父容器 (0,0)），再 offset 到 fitted 的
    /// origin。offset 只挪渲染和命中位置、不动布局 frame，所以手势的 .local 坐标
    /// 落在父容器空间里，`imagePoint` 统一减掉 fitted.origin 再除显示倍率。
    private func canvasBody(fitted: CGRect) -> some View {
        let handActive = handModeActive
        return LayerCanvas(
            image: canvasImage ?? blankImage,
            layers: annotation.displayLayers.projected(onto: .zero, scale: 1),
            pixelatePreviews: annotation.pixelatePreviews,
            selectedLayerID: annotation.selectedID
        )
        .frame(width: fitted.width, height: fitted.height)
        .offset(x: fitted.minX, y: fitted.minY)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            // 指针模式下悬停到选中图层的缩放控制点 → resize 光标。
            // 坐标映射和下面的 DragGesture 完全一致（同一条修饰链）。
            switch phase {
            case .active(let location):
                canvasHovered = true
                if handModeActive {
                    (panLastWindowLocation == nil
                        ? NSCursor.openHand : NSCursor.closedHand).set()
                    return
                }
                annotation.strokeScale = Double(
                    CGFloat(max(1, shot.pixelWidth)) / max(1, fitted.width)
                )
                if annotation.tool == nil,
                   let handle = annotation.resizeHandle(
                       at: imagePoint(location, fitted: fitted)
                   ) {
                    handle.cursor.set()
                } else {
                    NSCursor.arrow.set()
                }
            case .ended:
                canvasHovered = false
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    handleDragChanged(value, fitted: fitted)
                }
                .onEnded { _ in
                    handleDragEnded()
                }
        )
        // 抓手激活时外层平移手势独占（.gesture 掩码屏蔽内层标注手势），
        // 掩码切换不改视图 identity，空格按住 / 松开的瞬间切换不重建画布。
        .gesture(panGesture, including: handActive ? .gesture : .subviews)
    }

    /// 抓手平移：拖多少滚多少（内容跟着光标走）。用窗口坐标算增量 ——
    /// 平移时文档在光标下滑动，本地 / 内容坐标会跟着变，会形成反馈回环。
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if let last = panLastWindowLocation {
                    panBox.scrollBy(
                        dx: last.x - value.location.x,
                        dy: last.y - value.location.y
                    )
                }
                panLastWindowLocation = value.location
                NSCursor.closedHand.set()
            }
            .onEnded { _ in
                panLastWindowLocation = nil
                NSCursor.openHand.set()
            }
    }

    private func handleDragChanged(_ value: DragGesture.Value, fitted: CGRect) {
        let point = imagePoint(value.location, fitted: fitted)

        if canvasDrag == nil {
            let start = imagePoint(value.startLocation, fitted: fitted)
            // 笔宽按显示倍率反算：不论画布被缩到多小，画出来的线在屏幕上都一样粗。
            annotation.strokeScale = Double(
                CGFloat(max(1, shot.pixelWidth)) / max(1, fitted.width)
            )

            if annotation.tool == .text {
                placeTextLayer(at: start)
                canvasDrag = .idle
            } else if annotation.tool != nil {
                annotation.beginDraw(at: start)
                canvasDrag = .draw
            } else if let handle = annotation.resizeHandle(at: start) {
                // 选中图层的缩放控制点优先于图层本体的命中。
                annotation.endTextEditing()
                annotation.beginResize(handle: handle, at: start)
                canvasDrag = .resize
            } else if let id = annotation.layer(at: start) {
                annotation.endTextEditing()
                annotation.beginMove(id: id, at: start)
                canvasDrag = .move
            } else {
                annotation.select(nil)
                canvasDrag = .idle
            }
        }

        switch canvasDrag {
        case .draw: annotation.updateDraw(to: point)
        case .move: annotation.updateMove(to: point)
        case .resize: annotation.updateResize(to: point)
        default: break
        }
        annotationTick += 1
    }

    private func handleDragEnded() {
        switch canvasDrag {
        case .draw:
            annotation.endDraw(pixelSource: cropPixels)
            refreshCanvasImage()
        case .move:
            annotation.endMove(pixelSource: cropPixels)
            refreshCanvasImage()
        case .resize:
            annotation.endResize(pixelSource: cropPixels)
            refreshCanvasImage()
        default:
            break
        }
        canvasDrag = nil
        annotationTick += 1
    }

    /// 文字工具：落点即建层，给一段占位文字，随即选中并把焦点交给右侧文本框。
    private func placeTextLayer(at point: CGPoint) {
        annotation.beginDraw(at: point)
        guard let id = annotation.editingTextID else { return }
        annotation.insertText("文字")
        annotation.endTextEditing()
        annotation.select(id)
        textFieldFocused = true
    }

    /// 底图还没加载完时的占位，避免把画布做成可选类型污染整个视图树。
    private var blankImage: CGImage {
        CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!.makeImage()!
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let iw = CGFloat(max(1, shot.pixelWidth))
        let ih = CGFloat(max(1, shot.pixelHeight))
        let scale = min(size.width / iw, size.height / ih)
        let w = iw * scale
        let h = ih * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// 固定倍率下的布局：画布尺寸 = 图像点尺寸（像素 ÷ shot.scale）× 倍率，
    /// 四周留 16pt 空白；ScrollView 内容至少撑满视口，画布小于视口时居中。
    /// 返回的 `fitted` 与自适应分支同构（origin = 画布在滚动内容里的位置），
    /// `imagePoint` / 手势因此不区分分支。
    private func zoomedRects(
        zoom: Double, viewport: CGSize
    ) -> (fitted: CGRect, content: CGSize) {
        let pointScale = CGFloat(max(1, shot.scale))
        let w = CGFloat(max(1, shot.pixelWidth)) / pointScale * CGFloat(zoom)
        let h = CGFloat(max(1, shot.pixelHeight)) / pointScale * CGFloat(zoom)
        let cw = max(w + 32, viewport.width)
        let ch = max(h + 32, viewport.height)
        return (
            fitted: CGRect(x: (cw - w) / 2, y: (ch - h) / 2, width: w, height: h),
            content: CGSize(width: cw, height: ch)
        )
    }

    /// 视图坐标 → 图像像素坐标（左上原点）。
    private func imagePoint(_ point: CGPoint, fitted: CGRect) -> CGPoint {
        let scale = CGFloat(max(1, shot.pixelWidth)) / max(1, fitted.width)
        return CGPoint(
            x: (point.x - fitted.minX) * scale,
            y: (point.y - fitted.minY) * scale
        )
    }

    // MARK: - 缩放控制

    /// 图像的点尺寸（像素 ÷ 显示倍率），zoomLevel 的换算基准。
    private var imagePointWidth: CGFloat {
        CGFloat(max(1, shot.pixelWidth)) / CGFloat(max(1, shot.scale))
    }

    /// 当前实际倍率：缩放态就是 zoomLevel；适应窗口态用 fitted 宽反推 ——
    /// 从适应态开始连续缩放 / 归档时以它为起点，体验上无跳变。
    private func effectiveZoom(viewport: CGSize) -> Double {
        if let zoom = zoomLevel { return zoom }
        guard viewport.width > 1 else { return 1 }
        return Double(canvasLayout(viewport: viewport).fitted.width / imagePointWidth)
    }

    /// ⌃滚轮 / 捏合的连续缩放：锚定光标处的图像点不动。
    private func handleContinuousZoom(
        factor: Double, docPoint: CGPoint, clipPoint: CGPoint, viewport: CGSize
    ) {
        guard viewport.width > 1 else { return }
        let oldZoom = effectiveZoom(viewport: viewport)
        let newZoom = min(Self.zoomRange.upperBound,
                          max(Self.zoomRange.lowerBound, oldZoom * factor))
        applyZoom(newZoom, docPoint: docPoint, clipPoint: clipPoint, viewport: viewport)
    }

    /// 设定新倍率并把 `docPoint`（旧内容坐标系）锚在视口 `clipPoint` 处：
    /// 旧 fitted 反解出图像像素 → 新 fitted 下的内容坐标 → 期望滚动原点，
    /// 写进 pendingOrigin 由滚动容器在内容尺寸更新后的 update 应用（自动钳制）。
    /// 全程只走 fittedRect/imagePoint 那一条公式，坐标不变量不破。
    private func applyZoom(
        _ newZoom: Double, docPoint: CGPoint, clipPoint: CGPoint, viewport: CGSize
    ) {
        let oldFitted = canvasLayout(viewport: viewport).fitted
        let pixel = imagePoint(docPoint, fitted: oldFitted)
        zoomLevel = newZoom
        let newFitted = zoomedRects(zoom: newZoom, viewport: viewport).fitted
        let scale = newFitted.width / CGFloat(max(1, shot.pixelWidth))
        panBox.pendingOrigin = CGPoint(
            x: newFitted.minX + pixel.x * scale - clipPoint.x,
            y: newFitted.minY + pixel.y * scale - clipPoint.y
        )
    }

    /// 档位直设（缩放菜单 / ⌘± 归档共用）：视口中心为锚。
    private func setZoom(_ zoom: Double) {
        let viewport = panBox.viewportSize
        guard viewport.width > 1 else {
            zoomLevel = zoom
            return
        }
        let clipPoint = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let origin = panBox.scrollOrigin
        applyZoom(
            zoom,
            docPoint: CGPoint(x: origin.x + clipPoint.x, y: origin.y + clipPoint.y),
            clipPoint: clipPoint,
            viewport: viewport
        )
    }

    /// 升到下一档。基准是当前**实际**倍率（连续缩放后的散值就近归档，
    /// 适应窗口态用 fitted 反推的倍率），与连续缩放自然共存。
    private func zoomIn() {
        let current = effectiveZoom(viewport: panBox.viewportSize)
        setZoom(Self.zoomSteps.first { $0 > current + 0.001 } ?? Self.zoomSteps.last!)
    }

    private func zoomOut() {
        let current = effectiveZoom(viewport: panBox.viewportSize)
        setZoom(Self.zoomSteps.last { $0 < current - 0.001 } ?? Self.zoomSteps.first!)
    }

    private var zoomLabel: String {
        zoomLevel.map { "\(Int(($0 * 100).rounded()))%" } ?? "适应"
    }

    // MARK: - 右侧面板（图层 / 效果双 tab）

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("面板", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DS.s3)
            .padding(.vertical, DS.s2)

            Divider()

            switch inspectorTab {
            case .layers: layersPanel
            case .effects: effectsPanel
            }
        }
    }

    /// 图层列表只列画布上有形体的标注层。效果层（`kind.isEffect`）不在这里 ——
    /// 它们没有可选中/可拖拽的形体，开关和样式都在「效果」tab。
    private var listedLayers: [Layer] {
        annotation.layers.elements.filter { !$0.kind.isEffect }
    }

    private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("图层（\(listedLayers.count)）")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()

            List(selection: selectionBinding) {
                ForEach(listedLayers) { layer in
                    HStack(spacing: 8) {
                        Image(systemName: layer.kind.symbolName)
                            .foregroundStyle(Color(
                                .sRGB, red: layer.color.r, green: layer.color.g,
                                blue: layer.color.b, opacity: 1
                            ))
                        Text(layer.kind.displayName)
                            .font(.caption)
                        Spacer()
                        Button {
                            annotation.select(layer.id)
                            performDelete()
                        } label: {
                            Image(systemName: "trash").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .tag(layer.id)
                }
            }
            .listStyle(.inset)

            if let selectedID = annotation.selectedID,
               let index = annotation.layers.firstIndex(id: selectedID),
               annotation.layers[index].kind == .text {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("文字内容").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: textBinding(for: selectedID))
                        .font(.system(size: 12))
                        .frame(height: 60)
                        .border(Color.primary.opacity(0.12))
                        .focused($textFieldFocused)
                }
                .padding(12)
            }

            Divider()
            historyPicker
        }
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { annotation.selectedID },
            set: { id in
                annotation.select(id)
                annotationTick += 1
            }
        )
    }

    /// 文字改动走 `setText` 入撤销栈（连续输入合并成一条记录），
    /// 绝不直接改图层数组 —— 那是旧路径，绕开撤销。
    private func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                annotation.layers.firstIndex(id: id).map { annotation.layers[$0].text } ?? ""
            },
            set: { text in
                annotation.setText(id: id, text)
                annotationTick += 1
            }
        )
    }

    private var historyPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("历史版本").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(revisions.enumerated()), id: \.element.id) { index, rev in
                        Button {
                            loadRevision(layers: rev.layers, index: index)
                        } label: {
                            HStack {
                                Text("v\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                Text(rev.note ?? "编辑")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(rev.layers.count) 层")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(loadedRevisionIndex == index
                                          ? Color.accentColor.opacity(0.18) : .clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
        .padding(12)
    }

    // MARK: - 底部状态栏

    private var bottomBar: some View {
        HStack(spacing: 10) {
            zoomControls

            Divider().frame(height: 14)

            // 尺寸读数：像素尺寸 @ 显示倍率。原图字节从不被修改（见文件头注释）。
            Text("\(shot.pixelWidth) × \(shot.pixelHeight) @\(scaleReadout)x")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text(shot.sourceSummary)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()
            Button("复制") { copyRendered() }
            Button("导出 PNG") { exportRendered() }
            Button("保存为新版本") { saveRevision() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
            Button("返回图库") { requestReturnToGallery() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 缩放控制：`-` / 百分比菜单 / `+`。⌘- 缩小、⌘=（和 ⌘+，见 hiddenShortcuts）
    /// 放大、⌘0 适应窗口。
    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button {
                zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("-", modifiers: .command)
            .help("缩小（⌘-）")

            Menu {
                ForEach(Self.zoomSteps, id: \.self) { step in
                    Button {
                        setZoom(step)
                    } label: {
                        if zoomLevel == step {
                            Label("\(Int((step * 100).rounded()))%", systemImage: "checkmark")
                        } else {
                            Text("\(Int((step * 100).rounded()))%")
                        }
                    }
                }
                Divider()
                Button {
                    zoomLevel = nil
                } label: {
                    if zoomLevel == nil {
                        Label("适应窗口", systemImage: "checkmark")
                    } else {
                        Text("适应窗口")
                    }
                }
            } label: {
                Text(zoomLabel)
                    .font(.caption.monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("缩放（⌘0 适应窗口）")

            Button {
                zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("=", modifiers: .command)
            .help("放大（⌘+）")
        }
    }

    /// 显示倍率读数：整数倍去掉小数点（"2" 而不是 "2.0"）。
    private var scaleReadout: String {
        String(format: "%g", max(1, shot.scale))
    }

    private func rendered() -> CGImage? {
        guard let base = baseImage else { return nil }
        return LayerRenderer.render(base: base, layers: exportedLayers)
    }

    private func saveRevision() {
        annotation.endTextEditing()
        guard confirmSaveOverNewerRevision() else { return }
        store.appendRevision(
            shot: shot,
            layers: exportedLayers,
            note: "编辑 \(annotation.layers.count) 层"
        )
        revisions = store.revisions(for: shot)
        loadedRevisionIndex = revisions.count - 1
        baselineLayers = exportedLayers.persisted
        annotationTick += 1
    }

    /// 胶片条点击换图。未保存守卫通过后直接换 `editingShotID` ——
    /// 宿主（GalleryView）挂了 `.id(shot.id)`，identity 变化即重建本视图完成切换。
    private func requestSwitch(to target: Shot) {
        guard target.id != shot.id, resolveUnsavedChanges() else { return }
        GalleryWindowMode.shared.openEditor(shotID: target.id)
    }

    /// 左上「‹ 图库」/ 底部「返回图库」/ Esc：守卫通过后整窗切回图库模式。
    private func requestReturnToGallery() {
        guard resolveUnsavedChanges() else { return }
        GalleryWindowMode.shared.returnToGallery()
    }

    /// 未保存守卫（返回图库和换图共用）。有未保存的标注时先问一声
    /// （保存并继续 / 不保存继续 / 取消）；返回 true = 可以离开当前画布。
    private func resolveUnsavedChanges() -> Bool {
        annotation.endTextEditing()
        guard exportedLayers.persisted != baselineLayers else { return true }

        switch AppAlert.confirm(
            "有未保存的标注，仍要离开吗？",
            message: "当前画布上的改动还没有保存为新版本，离开后会丢失。",
            buttons: ["保存并继续", "不保存继续", "取消"]
        ) {
        case 0:
            saveRevision()
            // 保存可能被并发修订确认（confirmSaveOverNewerRevision）取消 ——
            // 那样基线不会更新，改动仍未保存，不能走。
            return exportedLayers.persisted == baselineLayers
        case 1:
            return true
        default:
            return false
        }
    }

    /// 并发保存检测：修订链本身由 appendRevision 的单事务保证线性
    /// （不会坏链），但后保存的一方是基于打开时的旧图层覆盖式追加 ——
    /// 图库里已经出现更新的修订（钉图 / 自动脱敏落的）时，
    /// 先问一声再追加。`revisions` 在打开和每次保存后都会与库同步，
    /// 它的尾项就是本编辑器所认知的「最新」。
    private func confirmSaveOverNewerRevision() -> Bool {
        guard store.latestRevision(for: shot)?.id != revisions.last?.id else { return true }

        return AppAlert.confirm(
            "图库中已有更新的修订，仍要保存吗？",
            message: "这张截图在别处（钉图或自动脱敏）"
                + "已保存了更新的版本。继续保存会把当前画布内容追加为最新修订，"
                + "历史版本都还在，不会丢失。",
            buttons: ["仍要保存", "取消"]
        ) == 0
    }

    private func copyRendered() {
        guard let image = rendered() else { return }
        Clipboard.copy(image)
    }

    private func exportRendered() {
        guard let image = rendered() else { return }
        _ = try? ImageExporter.exportWithPanel(
            image,
            suggestedName: ImageExporter.suggestedName(for: shot)
        )
    }
}
