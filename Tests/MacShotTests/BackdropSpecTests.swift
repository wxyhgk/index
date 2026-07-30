import XCTest
@testable import MacShot

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

    /// 换预设**只动 preset 一个字段**：阴影参数必须留着。
    /// 旧实现是整条 text 覆盖成预设名，会把它们抹掉。
    @MainActor
    func testChangingPresetKeepsShadowParams() {
        let state = AnnotationState()
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
