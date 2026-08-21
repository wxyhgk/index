import XCTest
@testable import IndexApp

/// 单工具样式的安全网。
///
/// 最要紧的两条是**旧数据兼容**：
///   · `Layer` 新增的 blockScale / dim 必须是可选的 —— 合成的 Codable 不会用默认值，
///     加非可选字段会让所有旧修订的 JSON 直接解不出来；
///   · `ToolStyle` 手写了 decodeIfPresent，用户存下的旧偏好缺哪根轴都不能整条失效。
final class ToolStyleTests: XCTestCase {

    // MARK: - 旧数据兼容

    /// 没有 blockScale / dim 字段的旧图层 JSON 必须能解出来，且两个字段为 nil
    /// （渲染器据此退回硬编码默认值，行为与从前一致）。
    func testLegacyLayerJSONDecodesWithoutNewFields() throws {
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "kind": "pixelate",
          "rect": {"x": 10, "y": 20, "w": 100, "h": 50},
          "color": {"r": 1, "g": 0, "b": 0, "a": 1},
          "lineWidth": 4,
          "text": "",
          "fontSize": 28
        }
        """
        let layer = try JSONDecoder().decode(Layer.self, from: Data(legacy.utf8))

        XCTAssertEqual(layer.kind, .pixelate)
        XCTAssertNil(layer.blockScale, "旧图层不该凭空长出颗粒倍率")
        XCTAssertNil(layer.dim)
        XCTAssertEqual(layer.lineWidth, 4)
    }

    /// 新字段能正常往返。
    func testLayerRoundTripsNewFields() throws {
        var layer = Layer(kind: .spotlight, rect: LRect(CGRect(x: 0, y: 0, width: 10, height: 10)))
        layer.dim = 0.75
        layer.blockScale = 1.8

        let data = try JSONEncoder().encode(layer)
        let back = try JSONDecoder().decode(Layer.self, from: data)

        XCTAssertEqual(back.dim, 0.75)
        XCTAssertEqual(back.blockScale, 1.8)
    }

    /// 用户存下来的旧偏好只有颜色和粗细两根轴，新增的轴要各自回到默认档，
    /// 而不是让整条偏好解码失败。
    func testToolStyleDecodesPartialJSON() throws {
        let partial = #"{"colorIndex": 2, "widthIndex": 0}"#
        let style = try JSONDecoder().decode(ToolStyle.self, from: Data(partial.utf8))

        XCTAssertEqual(style.colorIndex, 2)
        XCTAssertEqual(style.widthIndex, 0)
        XCTAssertEqual(style.fontSizeIndex, 1, "缺失的轴应回中档")
        XCTAssertEqual(style.opacityIndex, 1)
        XCTAssertEqual(style.blockSizeIndex, 1)
        XCTAssertEqual(style.dimIndex, 1)
    }

    /// 越界的档位下标（改坏的偏好 / 将来减少档位）不能崩，取值退回中档。
    func testOutOfRangeIndexFallsBackToMiddleStep() {
        var style = ToolStyle()
        style.widthIndex = 99
        XCTAssertEqual(style.value(for: .width), ToolStyleAxis.width.steps[1])
    }

    // MARK: - 档位值与旧行为对齐

    /// 中档必须等于改造前的硬编码值，否则老用户升级后观感会变。
    func testMiddleStepsMatchLegacyHardcodedValues() {
        XCTAssertEqual(ToolStyleAxis.opacity.steps[1], 0.40, accuracy: 0.001, "旧高亮透明度")
        XCTAssertEqual(ToolStyleAxis.dim.steps[1], 0.55, accuracy: 0.001, "旧聚光灯压暗")
        XCTAssertEqual(ToolStyleAxis.blockSize.steps[1], 1.0, accuracy: 0.001, "旧马赛克颗粒公式")
        // 旧字号公式是 线宽 × 4 + 8，线宽三档 [2,4,8] → [16,24,40]
        XCTAssertEqual(ToolStyleAxis.fontSize.steps, [16, 24, 40])
    }

    // MARK: - 描述符

    /// 渲染器不读这三个工具的 color，工具条就不该给它们摆色块。
    @MainActor
    func testToolsWithoutColorAxis() {
        for tool in [AnnotationTool.pixelate, .spotlight, .crop] {
            XCTAssertFalse(
                ToolRegistry.descriptor(for: tool).axes.contains(.color),
                "\(tool.title) 的渲染不读颜色，不该声明颜色轴"
            )
        }
    }

    /// 文字/序号吃字号不吃线宽；矩形一类反过来。两者从前共用一个下标。
    @MainActor
    func testFontSizeAndWidthAreSeparateAxes() {
        let text = ToolRegistry.descriptor(for: .text).axes
        XCTAssertTrue(text.contains(.fontSize))
        XCTAssertFalse(text.contains(.width))

        let rect = ToolRegistry.descriptor(for: .rect).axes
        XCTAssertTrue(rect.contains(.width))
        XCTAssertFalse(rect.contains(.fontSize))
    }

    /// 每个工具都要登记，否则会静默落到兜底描述符上。
    @MainActor
    func testEveryToolHasDescriptor() {
        for tool in AnnotationTool.allCases {
            XCTAssertTrue(
                ToolRegistry.descriptors.contains { $0.tool == tool },
                "\(tool.title) 没有登记描述符"
            )
        }
    }

    /// 图层种类 → 工具的反查要覆盖所有画笔类（指针模式下选中图层要靠它定样式轴）；
    /// 效果层没有对应工具，必须返回 nil。
    func testToolFromLayerKind() {
        for tool in AnnotationTool.allCases {
            XCTAssertEqual(AnnotationTool(kind: tool.layerKind), tool)
        }
        for kind in Layer.Kind.allCases where kind.isEffect {
            XCTAssertNil(AnnotationTool(kind: kind), "\(kind.displayName) 是效果层，不该反查出画笔")
        }
    }

    // MARK: - 每个工具各记各的

    @MainActor
    func testEachToolRemembersItsOwnStyle() {
        let state = AnnotationState(styleStore: FakeStyleStore())

        state.tool = .arrow
        state.setStyleIndex(2, for: .color)
        state.setStyleIndex(2, for: .width)

        state.tool = .text
        XCTAssertNotEqual(state.styleIndex(for: .color), 2, "文字不该继承箭头的颜色")
        state.setStyleIndex(0, for: .color)

        state.tool = .arrow
        XCTAssertEqual(state.styleIndex(for: .color), 2, "切回箭头应恢复它自己的颜色")
        XCTAssertEqual(state.styleIndex(for: .width), 2)
    }

    /// 改文字的字号不该动到矩形的线宽 —— 这正是旧公式绑在一起的那两件事。
    @MainActor
    func testFontSizeChangeDoesNotAffectLineWidth() {
        let state = AnnotationState(styleStore: FakeStyleStore())

        state.tool = .rect
        state.setStyleIndex(0, for: .width)
        let rectWidth = state.lineWidth

        state.tool = .text
        state.setStyleIndex(2, for: .fontSize)

        state.tool = .rect
        XCTAssertEqual(state.lineWidth, rectWidth, "调字号把矩形线宽改了")
    }

    /// 裁剪一根轴都没有：工具条上不该出现任何样式控件。
    @MainActor
    func testCropExposesNoStyleAxes() {
        let state = AnnotationState(styleStore: FakeStyleStore())
        state.tool = .crop
        XCTAssertTrue(state.styleAxes.isEmpty)
    }
}
