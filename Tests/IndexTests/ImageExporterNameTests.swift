import Foundation
import XCTest
@testable import IndexApp

@MainActor
final class ImageExporterNameTests: XCTestCase {

    func testDefaultTemplateProducesCompactSortableName() throws {
        let date = try makeDate(year: 2026, month: 8, day: 13, hour: 14, minute: 32, second: 8)

        let name = ImageExporter.renderName(
            template: ExportPrefs.defaults.exportNameTemplate,
            date: date,
            appName: "Microsoft Edge",
            windowTitle: "A very long page title"
        )

        XCTAssertEqual(name, "20260813-143208")
    }

    func testReadableAndSourceVariablesRemainCompatible() throws {
        let date = try makeDate(year: 2026, month: 8, day: 13, hour: 14, minute: 32, second: 8)

        let name = ImageExporter.renderName(
            template: "截图 {date} {time}{app}-{title}",
            date: date,
            appName: "预览",
            windowTitle: "分子结构"
        )

        XCTAssertEqual(name, "截图 2026-08-13 14.32.08-预览-分子结构")
    }

    func testOptionalNameVariableUsesCustomGalleryTitle() throws {
        let date = try makeDate(year: 2026, month: 8, day: 13, hour: 14, minute: 32, second: 8)

        let name = ImageExporter.renderName(
            template: "{dateCompact}-{name}",
            date: date,
            appName: "Microsoft Edge",
            windowTitle: "网页标题",
            customName: "MR-TADF/分子"
        )

        XCTAssertEqual(name, "20260813-MR-TADF-分子")
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )))
    }
}
