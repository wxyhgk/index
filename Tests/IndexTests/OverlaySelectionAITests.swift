import CoreGraphics
import XCTest
@testable import IndexApp

@MainActor
final class OverlaySelectionAITests: XCTestCase {
    func testRetinaOffsetDisplayDragStoresCropRelativePixelsAndMapsBackToView() {
        let view = makeConfirmedView(scale: 2)
        view.selectionAIHost.activate()

        XCTAssertTrue(view.beginSelectionAI(atViewLocal: CGPoint(x: 30, y: 70)))
        XCTAssertTrue(view.updateSelectionAI(atViewLocal: CGPoint(x: 80, y: 40)))
        XCTAssertEqual(
            view.endSelectionAI(atViewLocal: CGPoint(x: 80, y: 40)),
            CGRect(x: 20, y: 20, width: 100, height: 60)
        )
        XCTAssertEqual(
            view.selectionAIViewRect,
            CGRect(x: 30, y: 40, width: 50, height: 30)
        )
    }

    func testReverseDragUsesSamePixelRect() {
        let view = makeConfirmedView(scale: 2)
        view.selectionAIHost.activate()

        XCTAssertTrue(view.beginSelectionAI(atViewLocal: CGPoint(x: 80, y: 40)))
        view.updateSelectionAI(atViewLocal: CGPoint(x: 30, y: 70))

        XCTAssertEqual(
            view.endSelectionAI(atViewLocal: CGPoint(x: 30, y: 70)),
            CGRect(x: 20, y: 20, width: 100, height: 60)
        )
    }

    func testPointOutsideConfirmedImageDoesNotStartAISelection() {
        let view = makeConfirmedView(scale: 2)
        view.selectionAIHost.activate()

        XCTAssertFalse(view.beginSelectionAI(atViewLocal: CGPoint(x: 10, y: 10)))
        XCTAssertEqual(view.selectionAIHost.session.snapshot.phase, .armed)
    }

    func testCaptureToolbarProvidesSelectionAIButPlainModeDoesNot() {
        let capture = makeConfirmedView(scale: 1)
        XCTAssertTrue(capture.toolbarContext.capabilities.supports(.selectionAI))
        XCTAssertTrue(SelectionAIControl().isVisible(capture.toolbarContext))

        let plain = makeConfirmedView(scale: 1, mode: .plain)
        XCTAssertFalse(plain.toolbarContext.capabilities.supports(.selectionAI))
        XCTAssertFalse(SelectionAIControl().isVisible(plain.toolbarContext))
    }

    func testEscapeStepsFromSelectionToArmedToInactiveBeforeCancellingCapture() {
        let view = makeConfirmedView(scale: 1)
        SelectionAIControl().activate(view.toolbarContext)
        XCTAssertTrue(view.beginSelectionAI(atViewLocal: CGPoint(x: 30, y: 70)))
        view.updateSelectionAI(atViewLocal: CGPoint(x: 80, y: 40))
        XCTAssertNotNil(view.endSelectionAI(atViewLocal: CGPoint(x: 80, y: 40)))

        var finishCount = 0
        view.onFinish = { _ in finishCount += 1 }

        view.cancelFromEscape()
        XCTAssertEqual(view.selectionAIHost.session.snapshot.phase, .armed)
        XCTAssertEqual(finishCount, 0)

        view.cancelFromEscape()
        XCTAssertEqual(view.selectionAIHost.session.snapshot.phase, .inactive)
        XCTAssertEqual(finishCount, 0)

        view.cancelFromEscape()
        XCTAssertEqual(finishCount, 1)
    }

    func testSelectedRegionBuildsOnlyLocalPixels() {
        let view = makeConfirmedView(scale: 2, patterned: true)
        selectAIRegion(in: view)

        guard let rect = view.selectionAIHost.session.snapshot.selectionRect,
              let transform = view.selectionAITransform,
              let input = OverlaySelectionAIInputBuilder.makeInput(
                  model: view.model,
                  annotation: view.annotation,
                  geometry: view.geometry,
                  transform: transform,
                  selectionRect: rect
              )
        else { return XCTFail("应生成 AI 输入") }

        XCTAssertEqual(input.pixelSize, CGSize(width: 100, height: 60))
        guard let expected = view.model.snapshot.image.cropping(
            to: CGRect(x: 60, y: 100, width: 100, height: 60)
        ) else { return XCTFail("应裁出预期区域") }
        XCTAssertEqual(rgbaBytes(input.image), rgbaBytes(expected), "AI 输入发生坐标偏移")
    }

    func testPixelateIsBakedIntoSelectionAIInput() {
        let rawView = makeConfirmedView(scale: 2, patterned: true)
        selectAIRegion(in: rawView)
        let raw = makeAIInput(from: rawView)

        let redactedView = makeConfirmedView(scale: 2, patterned: true)
        selectAIRegion(in: redactedView)
        redactedView.annotation.tool = .pixelate
        XCTAssertTrue(redactedView.annotation.beginDraw(at: CGPoint(x: 30, y: 50)))
        XCTAssertTrue(redactedView.annotation.updateDraw(to: CGPoint(x: 80, y: 80)))
        XCTAssertTrue(redactedView.annotation.endDraw(pixelSource: { _ in nil }))
        let redacted = makeAIInput(from: redactedView)

        XCTAssertEqual(raw?.pixelSize, redacted?.pixelSize)
        XCTAssertNotEqual(raw.map { rgbaBytes($0.image) }, redacted.map { rgbaBytes($0.image) })
    }

    func testTaskPaletteOffersFourBoundedDistinctActions() {
        let bounds = CGRect(x: 0, y: 0, width: 260, height: 120)
        let slots = OverlaySelectionAITaskPalette.slots(
            near: CGRect(x: 70, y: 42, width: 100, height: 50),
            in: bounds
        )

        XCTAssertEqual(slots.map(\.kind), SelectionAITaskKind.allCases)
        XCTAssertEqual(slots.count, 4)
        XCTAssertTrue(slots.allSatisfy { bounds.contains($0.frame) })
        for (index, slot) in slots.enumerated() {
            XCTAssertFalse(slots.dropFirst(index + 1).contains { $0.frame.intersects(slot.frame) })
        }
        XCTAssertEqual(
            OverlaySelectionAITaskPalette.task(for: .translate),
            .translate(targetLanguage: "zh-Hans")
        )
    }

    func testDefaultExecutionFailsSafelyWithoutSendingPixels() async {
        let execution = OverlaySelectionAIExecution()
        let changed = expectation(description: "default provider reports unavailable")
        execution.onChange = {
            if execution.status == .failed("尚未配置 AI 服务") { changed.fulfill() }
        }

        execution.submit(
            task: .explain,
            input: SelectionAIInput(image: solidImage(width: 1, height: 1))
        )
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(execution.status, .failed("尚未配置 AI 服务"))
    }

    func testResultPanelStaysInsideBoundsAndExposesAllExports() {
        let document = SelectionAIResponse(
            requestID: UUID(),
            task: .extractTable,
            providerID: "test.selection-ai",
            result: .table(.init(markdown: "| A | B |", csv: "A,B"))
        ).document
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 180)

        guard let layout = OverlaySelectionAIResultPanel.layout(
            document: document,
            near: CGRect(x: 240, y: 140, width: 40, height: 30),
            in: bounds
        ) else { return XCTFail("应生成结果面板") }

        XCTAssertTrue(bounds.contains(layout.frame))
        XCTAssertEqual(layout.actionSlots.map(\.action), [
            .copy(.markdown),
            .copy(.csv),
            .close
        ])
        XCTAssertTrue(layout.actionSlots.allSatisfy { layout.frame.contains($0.frame) })
        XCTAssertEqual(
            OverlaySelectionAIResultPanel.export(for: .copy(.csv), in: document),
            .init(format: .csv, text: "A,B")
        )
        XCTAssertNil(OverlaySelectionAIResultPanel.export(for: .close, in: document))
    }

    private func selectAIRegion(in view: OverlayView) {
        view.selectionAIHost.activate()
        XCTAssertTrue(view.beginSelectionAI(atViewLocal: CGPoint(x: 30, y: 70)))
        XCTAssertTrue(view.updateSelectionAI(atViewLocal: CGPoint(x: 80, y: 40)))
        XCTAssertNotNil(view.endSelectionAI(atViewLocal: CGPoint(x: 80, y: 40)))
    }

    private func makeAIInput(from view: OverlayView) -> SelectionAIInput? {
        guard let rect = view.selectionAIHost.session.snapshot.selectionRect,
              let transform = view.selectionAITransform
        else { return nil }
        return OverlaySelectionAIInputBuilder.makeInput(
            model: view.model,
            annotation: view.annotation,
            geometry: view.geometry,
            transform: transform,
            selectionRect: rect
        )
    }

    private func makeConfirmedView(
        scale: CGFloat,
        mode: SelectionMode = .capture,
        patterned: Bool = false
    ) -> OverlayView {
        let frame = CGRect(x: 100, y: 50, width: 200, height: 120)
        let display = DisplayInfo(
            id: 1,
            name: "Offset Display",
            frame: frame,
            scale: scale
        )
        let image = patterned
            ? checkerboardImage(width: Int(frame.width * scale), height: Int(frame.height * scale))
            : solidImage(width: Int(frame.width * scale), height: Int(frame.height * scale))
        let snapshot = DisplaySnapshot(display: display, image: image)
        let model = SelectionModel(snapshot: snapshot, windows: [])
        model.beginDrag(at: CGPoint(x: 120, y: 70))
        model.updateDrag(to: CGPoint(x: 220, y: 130))
        XCTAssertTrue(model.endDrag())

        let view = OverlayView(model: model, isPrimaryScreen: true, mode: mode, capture: FakeStyleStore(), annotationStyle: FakeStyleStore())
        view.frame = CGRect(origin: .zero, size: frame.size)
        return view
    }

    private func solidImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func checkerboardImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for y in 0..<height {
            for x in 0..<width {
                context.setFillColor(CGColor(
                    red: CGFloat(x % 251) / 250,
                    green: CGFloat(y % 239) / 238,
                    blue: CGFloat((x + y) % 233) / 232,
                    alpha: 1
                ))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }

    private func rgbaBytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
