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
