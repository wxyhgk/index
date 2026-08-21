import XCTest
@testable import IndexApp

@MainActor
final class SelectionAIToolbarTests: XCTestCase {
    private final class ModeState {
        var liveText = false
        var selectionAI = false
    }

    private func capabilities(_ state: ModeState) -> ToolbarHostCapabilities {
        ToolbarHostCapabilities(modes: [
            .liveText: ToolbarHostModeCapability(
                isActive: { state.liveText },
                activate: { state.liveText = true },
                deactivate: { state.liveText = false }
            ),
            .selectionAI: ToolbarHostModeCapability(
                isActive: { state.selectionAI },
                activate: { state.selectionAI = true },
                deactivate: { state.selectionAI = false }
            )
        ])
    }

    private func context(
        annotation: AnnotationState? = nil,
        capabilities: ToolbarHostCapabilities = .none
    ) -> ToolbarContext {
        ToolbarContext(
            annotation: annotation ?? AnnotationState(styleStore: FakeStyleStore()),
            scope: .capture,
            perform: { _ in },
            capabilities: capabilities
        )
    }

    func testSelectionAIControlOnlyAppearsWhenHostProvidesCapability() {
        let control = SelectionAIControl()
        XCTAssertFalse(control.isVisible(context()))

        let state = ModeState()
        XCTAssertTrue(control.isVisible(context(capabilities: capabilities(state))))
    }

    func testExclusiveToggleDeactivatesPreviousModeBeforeActivatingSelectionAI() {
        let state = ModeState()
        state.liveText = true
        let capabilities = capabilities(state)

        capabilities.toggleExclusive(.selectionAI)

        XCTAssertFalse(state.liveText)
        XCTAssertTrue(state.selectionAI)
        XCTAssertTrue(capabilities.hasActiveMode)
    }

    func testSelectionAIControlTogglesAndLeavesAnnotationInNeutralState() {
        let state = ModeState()
        let annotation = AnnotationState(styleStore: FakeStyleStore())
        annotation.tool = .rect
        annotation.pointerEngaged = true
        let context = context(annotation: annotation, capabilities: capabilities(state))
        let control = SelectionAIControl()

        control.activate(context)

        XCTAssertTrue(state.selectionAI)
        XCTAssertNil(annotation.tool)
        XCTAssertFalse(annotation.pointerEngaged)
        XCTAssertTrue(control.isSelected(context))
        XCTAssertEqual(control.accessibilityLabel(context), "退出 AI 选区")

        control.activate(context)
        XCTAssertFalse(state.selectionAI)
        XCTAssertFalse(control.isSelected(context))
    }

    func testSelectingAnnotationToolDeactivatesSelectionAI() {
        let state = ModeState()
        state.selectionAI = true
        let annotation = AnnotationState(styleStore: FakeStyleStore())
        let context = context(annotation: annotation, capabilities: capabilities(state))

        ToolControl(tool: .arrow, order: 0, isPinnedToBar: true).activate(context)

        XCTAssertFalse(state.selectionAI)
        XCTAssertEqual(annotation.tool, .arrow)
    }

    func testRegistryIncludesSelectionAIOnlyForCapableHost() {
        let registry = ToolbarRegistry()
        ToolbarRegistry.registerBuiltins(into: registry)
        let unavailable = registry.controls(for: .capture).filter { $0.isVisible(context()) }
        XCTAssertFalse(unavailable.contains { $0.id == SelectionAIControl.controlID })

        let state = ModeState()
        let capableContext = context(capabilities: capabilities(state))
        let available = registry.controls(for: .capture).filter { $0.isVisible(capableContext) }
        XCTAssertTrue(available.contains { $0.id == SelectionAIControl.controlID })
    }
}
