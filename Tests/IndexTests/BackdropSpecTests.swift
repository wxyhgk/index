import XCTest
@testable import IndexApp

/// 美化层参数的安全网。
///
/// 关键是**两种 `Layer.text` 格式共存**：早期版本只存一个裸预设名
/// （`"gradient-blue"`），加了阴影参数之后改存 JSON。旧修订必须照常渲染。
final class BackdropSpecTests: XCTestCase {

    /// 旧格式：text 里只有预设名，阴影字段应为 nil（渲染器据此退回旧的推导值）。
    func testParsesLegacyBarePresetName() {
        let spec = BackdropSpec.parse("gradient-sunset")

        XCTAssertEqual(spec.preset, "gradient-sunset")
        XCTAssertEqual(spec.backdropPreset, .gradientSunset)
        XCTAssertNil(spec.shadowRadius, "旧图层不该凭空长出阴影参数")
        XCTAssertNil(spec.shadowAlpha)
        XCTAssertNil(spec.shadowColor)
    }

    /// 空串（异常数据）落到默认预设，不崩。
    func testParsesEmptyTextAsDefault() {
        XCTAssertEqual(BackdropSpec.parse("").backdropPreset, BackdropPreset.default)
    }

    /// 无法识别的预设名落到默认，不崩。
    func testUnknownPresetFallsBackToDefault() {
        XCTAssertEqual(BackdropSpec.parse("no-such-preset").backdropPreset, BackdropPreset.default)
    }

    /// 新格式往返。
    func testJSONRoundTrip() {
        let spec = BackdropSpec(
            preset: BackdropPreset.transparent.rawValue,
            shadowRadius: 18,
            shadowAlpha: 0.3
        )
        let back = BackdropSpec.parse(spec.json)

        XCTAssertEqual(back.backdropPreset, .transparent)
        XCTAssertEqual(back.shadowRadius, 18)
        XCTAssertEqual(back.shadowAlpha, 0.3)
    }

    /// 只有透明档不填背景 —— 这正是「四周留白是透明的」那个效果的开关。
    func testOnlyTransparentSkipsBackgroundFill() {
        XCTAssertFalse(BackdropPreset.transparent.fillsBackground)
        for preset in BackdropPreset.allCases where preset != .transparent {
            XCTAssertTrue(preset.fillsBackground, "\(preset.displayName) 应该填背景")
        }
    }

    /// 透明与纯色都没有渐变色对（前者不画，后者用图层自身颜色）。
    func testGradientColorsAbsentForFlatPresets() {
        XCTAssertNil(BackdropPreset.transparent.gradientColors)
        XCTAssertNil(BackdropPreset.solid.gradientColors)
        XCTAssertNotNil(BackdropPreset.gradientBlue.gradientColors)
    }

    // MARK: - 参数按短边比例缩放

    /// 留白/圆角/阴影都是短边百分比：图大一倍，三项都跟着大一倍。
    /// 这同时也是 Retina 一致性的保证 —— 同一个窗口 2x 抓出来像素多一倍，
    /// 参数也大一倍，视觉尺寸才相同。
    @MainActor
    func testBackdropMetricsScaleWithImageSize() {
        guard let backdrop = EffectRegistry.descriptor(for: .backdrop) else {
            return XCTFail("美化描述符没登记")
        }

        func make(_ w: Double, _ h: Double) -> Layer {
            var context = EffectContext()
            context.imagePixelWidth = w
            context.imagePixelHeight = h
            return backdrop.makeLayer(context)
        }

        let small = make(800, 600)     // 短边 600
        let large = make(1600, 1200)   // 短边 1200，正好两倍

        XCTAssertEqual(large.lineWidth, small.lineWidth * 2, accuracy: 0.01, "留白没按比例缩放")
        XCTAssertEqual(large.fontSize, small.fontSize * 2, accuracy: 0.01, "圆角没按比例缩放")

        let smallShadow = BackdropSpec.parse(small.text).shadowRadius ?? 0
        let largeShadow = BackdropSpec.parse(large.text).shadowRadius ?? 0
        XCTAssertEqual(largeShadow, smallShadow * 2, accuracy: 0.01, "阴影没按比例缩放")
    }

    /// 按**短边**算，不是按宽 —— 超宽长条截图不该获得夸张的留白。
    @MainActor
    func testUsesShorterSideNotWidth() {
        guard let backdrop = EffectRegistry.descriptor(for: .backdrop) else { return }

        var wide = EffectContext()
        wide.imagePixelWidth = 4000
        wide.imagePixelHeight = 300

        var square = EffectContext()
        square.imagePixelWidth = 300
        square.imagePixelHeight = 300

        XCTAssertEqual(
            backdrop.makeLayer(wide).lineWidth,
            backdrop.makeLayer(square).lineWidth,
            accuracy: 0.01,
            "短边相同，留白就该相同"
        )
    }

    /// 极小图不该被留白淹掉（下限兜住），极大图也不该失控（上限兜住）。
    @MainActor
    func testMetricsAreClamped() {
        guard let backdrop = EffectRegistry.descriptor(for: .backdrop) else { return }

        var tiny = EffectContext()
        tiny.imagePixelWidth = 40
        tiny.imagePixelHeight = 30
        let tinyPadding = backdrop.makeLayer(tiny).lineWidth
        XCTAssertGreaterThanOrEqual(tinyPadding, 8, "小图留白被压到看不见")
        XCTAssertLessThan(tinyPadding, 30, "小图留白反而比内容还大")

        var huge = EffectContext()
        huge.imagePixelWidth = 20000
        huge.imagePixelHeight = 20000
        XCTAssertLessThanOrEqual(backdrop.makeLayer(huge).lineWidth, 240, "大图留白失控")
    }

    /// 尺寸未知（0）时退回下限，而不是算出 0 留白。
    @MainActor
    func testUnknownSizeFallsBackToMinimum() {
        guard let backdrop = EffectRegistry.descriptor(for: .backdrop) else { return }
        XCTAssertEqual(backdrop.makeLayer(EffectContext()).lineWidth, 8, accuracy: 0.01)
    }

    /// 换预设**只动 preset 一个字段**：阴影参数必须留着。
    /// 旧实现是整条 text 覆盖成预设名，会把它们抹掉。
    @MainActor
    func testChangingPresetKeepsShadowParams() {
        let state = AnnotationState(styleStore: FakeStyleStore())
        state.toggleEffect(.backdrop)

        // `effectText` 是私有的，从公开的图层数组读，不为测试放宽封装。
        func backdropText() -> String {
            state.layers.elements.first { $0.kind == .backdrop }?.text ?? ""
        }

        // 描述符造层时会按设置烤入阴影参数。
        let original = BackdropSpec.parse(backdropText())
        XCTAssertNotNil(original.shadowRadius, "新建的美化层应带上阴影参数")

        state.setBackdropPreset(BackdropPreset.transparent.rawValue)

        let after = BackdropSpec.parse(backdropText())
        XCTAssertEqual(after.backdropPreset, BackdropPreset.transparent, "预设没换成功")
        XCTAssertEqual(after.shadowRadius, original.shadowRadius, "换预设把阴影半径弄丢了")
        XCTAssertEqual(after.shadowAlpha, original.shadowAlpha, "换预设把阴影浓度弄丢了")
    }
}
