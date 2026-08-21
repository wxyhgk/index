import XCTest
@testable import IndexApp

/// 工具契约的安全网。
///
/// 这些行为原先是 `AnnotationState`、`ResizeHandle`、`AnnotationTool` 里的
/// 若干个 switch，**一条测试都没有**——搬进描述符的时候没有任何东西拦得住走样。
/// 所以这个文件锁的不是「新设计好不好」，而是「搬过来之后行为一模一样」。
final class ToolDescriptorTests: XCTestCase {

    private func descriptor(_ tool: AnnotationTool) -> any AnnotationToolDescriptor {
        ToolRegistry.descriptor(for: tool)
    }

    private func layer(_ kind: Layer.Kind, _ rect: CGRect, lineWidth: Double = 4) -> Layer {
        Layer(kind: kind, rect: LRect(rect), color: .red, lineWidth: lineWidth)
    }

    // MARK: - 登记完整性

    /// 每个工具都登记了 —— 漏登记会掉进 `FallbackTool`（矩形语义），
    /// 界面还能用，但线段类会当场退化成拖矩形，很难当场发现。
    func testEveryToolIsRegistered() {
        for tool in AnnotationTool.allCases {
            XCTAssertTrue(
                ToolRegistry.descriptors.contains { $0.tool == tool },
                "\(tool) 没在 BuiltinTools.all 里登记"
            )
        }
        XCTAssertEqual(ToolRegistry.descriptors.count, AnnotationTool.allCases.count)
    }

    /// 快捷键与搬迁前那张手写表逐字相同（含指针的 V）。
    func testShortcutsMatchTheTableTheyReplaced() {
        let expected: [(UInt16, AnnotationTool?)] = [
            (KeyCode.v, nil),
            (KeyCode.r, .rect),
            (KeyCode.o, .ellipse),
            (KeyCode.a, .arrow),
            (KeyCode.l, .line),
            (KeyCode.t, .text),
            (KeyCode.h, .highlight),
            (KeyCode.p, .pixelate),
            (KeyCode.x, .crop),
            (KeyCode.n, .counter),
            (KeyCode.s, .spotlight),
            (KeyCode.m, .dimension)
        ]
        let actual = AnnotationTool.shortcuts.map { ($0.keyCode, $0.tool) }
        XCTAssertEqual(actual.count, expected.count)
        for (lhs, rhs) in zip(actual, expected) {
            XCTAssertEqual(lhs.0, rhs.0)
            XCTAssertEqual(lhs.1, rhs.1)
        }
    }

    /// 一个键只能绑一个工具。手写表时代这条全靠肉眼。
    func testShortcutKeysAreUnique() {
        let keys = AnnotationTool.shortcuts.map(\.keyCode)
        XCTAssertEqual(Set(keys).count, keys.count, "有重复的快捷键：\(keys)")
    }

    /// 常驻工具条的仍然是那四个主力。
    func testPinnedToolsUnchanged() {
        XCTAssertEqual(ToolRegistry.pinnedTools, [.rect, .arrow, .text, .pixelate])
    }

    // MARK: - 命中测试

    /// 线段按点到线段的距离判定：矩形外接框里、但离线段很远的点不该命中。
    func testSegmentHitTestUsesDistanceNotBoundingBox() {
        // 从 (0,0) 到 (100,100) 的对角线。
        let line = layer(.line, CGRect(x: 0, y: 0, width: 100, height: 100))
        let arrow = descriptor(.arrow)

        // 外接框的左上角 —— 在框内，但离线段 ~70。
        XCTAssertFalse(arrow.hitTest(line, at: CGPoint(x: 5, y: 95), tolerance: 8))
        // 线段中点附近。
        XCTAssertTrue(arrow.hitTest(line, at: CGPoint(x: 50, y: 52), tolerance: 8))
    }

    /// 容差随线宽放宽（粗线更好点中）—— 搬迁前是 `tolerance + lineWidth / 2`。
    func testSegmentToleranceGrowsWithLineWidth() {
        let thin = layer(.line, CGRect(x: 0, y: 0, width: 100, height: 0), lineWidth: 2)
        let thick = layer(.line, CGRect(x: 0, y: 0, width: 100, height: 0), lineWidth: 40)
        let point = CGPoint(x: 50, y: 20)

        XCTAssertFalse(descriptor(.line).hitTest(thin, at: point, tolerance: 8))
        XCTAssertTrue(descriptor(.line).hitTest(thick, at: point, tolerance: 8))
    }

    /// 序号徽章按圆形命中：四个角不该算命中。
    func testCounterHitTestIsCircular() {
        let badge = layer(.counter, CGRect(x: 0, y: 0, width: 100, height: 100))
        let counter = descriptor(.counter)

        XCTAssertTrue(counter.hitTest(badge, at: CGPoint(x: 50, y: 50), tolerance: 0))
        // 角落：到圆心距离 ~70.7 > 半径 50。
        XCTAssertFalse(counter.hitTest(badge, at: CGPoint(x: 0, y: 0), tolerance: 0))
    }

    /// 其余工具按外接矩形 + 一圈容差。
    func testDefaultHitTestUsesBoundsWithTolerance() {
        let box = layer(.rect, CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertTrue(descriptor(.rect).hitTest(box, at: CGPoint(x: -5, y: 25), tolerance: 8))
        XCTAssertFalse(descriptor(.rect).hitTest(box, at: CGPoint(x: -20, y: 25), tolerance: 8))
    }

    // MARK: - 控制点与缩放

    /// 线段类只有两端，其余八个全上；效果层一个都没有。
    func testHandleSets() {
        XCTAssertEqual(ResizeHandle.handles(for: .line), [.topLeft, .bottomRight])
        XCTAssertEqual(ResizeHandle.handles(for: .arrow), [.topLeft, .bottomRight])
        XCTAssertEqual(ResizeHandle.handles(for: .rect).count, 8)
        XCTAssertTrue(ResizeHandle.handles(for: .watermark).isEmpty)
        XCTAssertTrue(ResizeHandle.handles(for: .captureInfo).isEmpty)
    }

    /// 线段拖 `topLeft` 移动起点、长度相应缩短；负宽高合法（方向不能丢）。
    func testSegmentResizeMovesEndpoints() {
        let original = layer(.arrow, CGRect(x: 0, y: 0, width: 100, height: 100))
        let moved = descriptor(.arrow).resize(
            original, handle: .topLeft, delta: CGPoint(x: 10, y: 20), pixelScale: 1
        )
        XCTAssertEqual(moved.rect.x, 10, accuracy: 0.001)
        XCTAssertEqual(moved.rect.y, 20, accuracy: 0.001)
        XCTAssertEqual(moved.rect.w, 90, accuracy: 0.001)
        XCTAssertEqual(moved.rect.h, 80, accuracy: 0.001)
    }

    /// 序号缩放保持正圆，且被拖点的对侧不动（这里拖右下，左上角应钉住）。
    func testCounterResizeStaysSquare() {
        let original = layer(.counter, CGRect(x: 0, y: 0, width: 100, height: 100))
        let resized = descriptor(.counter).resize(
            original, handle: .bottomRight, delta: CGPoint(x: 40, y: -10), pixelScale: 1
        )
        let rect = resized.rect.cg
        XCTAssertEqual(rect.width, rect.height, accuracy: 0.001, "徽章必须保持正圆")
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
    }

    /// 文字缩放改的是字号而不是矩形。
    func testTextResizeScalesFontSize() {
        var text = layer(.text, CGRect(x: 0, y: 0, width: 0, height: 0))
        text.text = "测量"
        text.fontSize = 20

        let bounds = text.handleBounds
        XCTAssertGreaterThan(bounds.height, 0, "文字范围应由字号量出来")

        let grown = descriptor(.text).resize(
            text, handle: .top, delta: CGPoint(x: 0, y: bounds.height), pixelScale: 1
        )
        XCTAssertGreaterThan(grown.fontSize, text.fontSize)
    }

    // MARK: - 最小尺寸

    func testMinimumSizeRules() {
        // 线段：只看长度，单维为 0 也算数。
        let shortLine = layer(.line, CGRect(x: 0, y: 0, width: 2, height: 0))
        let longLine = layer(.line, CGRect(x: 0, y: 0, width: 50, height: 0))
        XCTAssertFalse(descriptor(.line).meetsMinimumSize(shortLine))
        XCTAssertTrue(descriptor(.line).meetsMinimumSize(longLine))

        // 测量允许单维为 0（吸附形态）。
        XCTAssertTrue(descriptor(.dimension).meetsMinimumSize(longLine))

        // 矩形要求两维都够。
        let sliver = layer(.rect, CGRect(x: 0, y: 0, width: 50, height: 1))
        XCTAssertFalse(descriptor(.rect).meetsMinimumSize(sliver))

        // 文字看字号。
        var tiny = layer(.text, .zero)
        tiny.fontSize = 2
        XCTAssertFalse(descriptor(.text).meetsMinimumSize(tiny))
    }

    // MARK: - 造层

    private func context(
        from: CGPoint, to: CGPoint, existing: [Layer] = [], pixelScale: Double = 1
    ) -> ToolLayerContext {
        ToolLayerContext(
            from: from, to: to,
            style: ToolStyle(),
            color: AnnotationState.palette[0],
            strokeScale: 1,
            pixelScale: pixelScale,
            existing: existing
        )
    }

    /// 只有声明了对应轴的工具才烤参数，其余保持 nil ——
    /// 渲染器遇到 nil 走旧的硬编码默认，旧图层因此行为不变。
    func testOnlyDeclaredAxesAreBaked() {
        let ctx = context(from: .zero, to: CGPoint(x: 40, y: 40))

        let pixelate = descriptor(.pixelate).makeLayer(ctx)
        XCTAssertNotNil(pixelate.blockScale)
        XCTAssertNil(pixelate.dim)

        let spotlight = descriptor(.spotlight).makeLayer(ctx)
        XCTAssertNotNil(spotlight.dim)
        XCTAssertNil(spotlight.blockScale)

        let rect = descriptor(.rect).makeLayer(ctx)
        XCTAssertNil(rect.blockScale)
        XCTAssertNil(rect.dim)
    }

    /// 高亮把 `.opacity` 轴压进颜色的 alpha；矩形不动 alpha。
    func testHighlightBakesOpacityIntoColor() {
        let ctx = context(from: .zero, to: CGPoint(x: 40, y: 40))
        XCTAssertLessThan(descriptor(.highlight).makeLayer(ctx).color.a, 1)
        XCTAssertEqual(descriptor(.rect).makeLayer(ctx).color.a, 1, accuracy: 0.001)
    }

    /// 序号：点击处是圆心，编号取现有序号的最大值 +1（删掉中间的不重排）。
    func testCounterNumbering() {
        var one = layer(.counter, CGRect(x: 0, y: 0, width: 10, height: 10))
        one.text = "1"
        var five = layer(.counter, CGRect(x: 0, y: 0, width: 10, height: 10))
        five.text = "5"

        let next = descriptor(.counter).makeLayer(
            context(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100),
                    existing: [one, five])
        )
        XCTAssertEqual(next.text, "6")
        let rect = next.rect.cg
        XCTAssertEqual(rect.midX, 100, accuracy: 0.001, "点击处应是圆心")
        XCTAssertEqual(rect.midY, 100, accuracy: 0.001)
        XCTAssertEqual(rect.width, rect.height, accuracy: 0.001)
    }

    /// 测量：薄轴被吸附成 0，数值按 pixelScale 换算成图像像素后烤进 text。
    func testDimensionSnapsAndBakesPixelValue() {
        // 近似横向：高只有 3 点，×1 倍率不足 8 → 吸附。
        let thin = descriptor(.dimension).makeLayer(
            context(from: .zero, to: CGPoint(x: 200, y: 3))
        )
        XCTAssertEqual(thin.rect.h, 0, accuracy: 0.001, "薄轴应被吸附为 0")
        XCTAssertEqual(thin.text, "200 px")

        // Retina 覆盖层：画布 100 点 = 200 图像像素。
        let retina = descriptor(.dimension).makeLayer(
            context(from: .zero, to: CGPoint(x: 100, y: 2), pixelScale: 2)
        )
        XCTAssertEqual(retina.text, "200 px", "标签应是图像像素而不是画布点")

        // 两维都够：矩形形态，标 W × H。
        let box = descriptor(.dimension).makeLayer(
            context(from: .zero, to: CGPoint(x: 60, y: 40))
        )
        XCTAssertEqual(box.text, "60 × 40 px")
    }

    /// 落笔方式：文字和序号是点一下就落，其余是拖。
    func testInputModes() {
        XCTAssertEqual(descriptor(.text).input, .click)
        XCTAssertEqual(descriptor(.counter).input, .click)
        for tool in AnnotationTool.allCases where tool != .text && tool != .counter {
            XCTAssertEqual(descriptor(tool).input, .drag, "\(tool) 应该是拖拽落笔")
        }
    }
}
