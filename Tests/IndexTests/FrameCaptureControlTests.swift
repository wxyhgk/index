import XCTest
@testable import IndexApp

@MainActor
final class FrameCaptureControlTests: XCTestCase {

    private func context(_ annotation: AnnotationState) -> ToolbarContext {
        ToolbarContext(annotation: annotation, scope: .capture, perform: { _ in })
    }

    func testCaptureControlTogglesFrameEffect() {
        let annotation = AnnotationState(styleStore: FakeStyleStore())
        let control = FrameCaptureControl()
        let ctx = context(annotation)

        XCTAssertTrue(control.isVisible(ctx))
        XCTAssertFalse(control.isSelected(ctx))
        XCTAssertFalse(annotation.hasEffect(.frame))

        control.activate(ctx)
        XCTAssertTrue(annotation.hasEffect(.frame))
        XCTAssertTrue(control.isSelected(ctx))

        control.activate(ctx)
        XCTAssertFalse(annotation.hasEffect(.frame))
    }

    func testOnlyRegisteredForCaptureScope() {
        let control = FrameCaptureControl()
        XCTAssertTrue(control.scopes.contains(.capture))
        XCTAssertFalse(control.scopes.contains(.pinned), "钉图已经有 EffectToggleControl，不能重复")
    }
}

@MainActor
final class FrameStyleCycleControlTests: XCTestCase {

    private func context(_ annotation: AnnotationState) -> ToolbarContext {
        ToolbarContext(annotation: annotation, scope: .capture, perform: { _ in })
    }

    func testStyleControlOnlyVisibleWhenShellOn() {
        let annotation = AnnotationState(styleStore: FakeStyleStore())
        let control = FrameStyleCycleControl()
        let ctx = context(annotation)

        XCTAssertFalse(control.isVisible(ctx))
        annotation.toggleEffect(.frame)
        XCTAssertTrue(control.isVisible(ctx))
    }

    func testStyleControlCyclesMacOSAndBrowser() {
        let annotation = AnnotationState(styleStore: FakeStyleStore())
        let control = FrameStyleCycleControl()
        let ctx = context(annotation)
        annotation.toggleEffect(.frame)

        XCTAssertEqual(annotation.frameStyle, .macos)
        control.activate(ctx)
        XCTAssertEqual(annotation.frameStyle, .browser)
        control.activate(ctx)
        XCTAssertEqual(annotation.frameStyle, .macos)
    }

    func testStyleControlIsNoOpWithoutShell() {
        let annotation = AnnotationState(styleStore: FakeStyleStore())
        FrameStyleCycleControl().activate(context(annotation))
        XCTAssertNil(annotation.frameStyle)
    }
}
