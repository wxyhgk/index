import XCTest
import CoreGraphics
@testable import IndexApp

final class MoleculeXYZTests: XCTestCase {
    func testParsesStandardXYZAndNormalizesElements() throws {
        let molecule = try MoleculeXYZ.parse("""
        3
        water
        o 0.0 0.0 0.0
        h 0.7586 0.0 0.5043
        H -0.7586 0.0 0.5043
        """)

        XCTAssertEqual(molecule.atomCount, 3)
        XCTAssertEqual(molecule.comment, "water")
        XCTAssertEqual(molecule.atoms.map(\.element), ["O", "H", "H"])
        XCTAssertTrue(molecule.canonicalText.hasPrefix("3\nwater\nO 0 0 0\n"))
    }

    func testParsesBareCoordinateBlock() throws {
        let molecule = try MoleculeXYZ.parse("""
        C 0 0 0
        H 1.09 0 0 optional-extra-column
        """)

        XCTAssertEqual(molecule.atomCount, 2)
        XCTAssertEqual(molecule.comment, "Index clipboard molecule")
        XCTAssertEqual(molecule.atoms[1].x, 1.09, accuracy: 0.000_001)
        XCTAssertEqual(molecule.canonicalText.components(separatedBy: "\n").count, 5)
    }

    func testStandardXYZMayOmitCommentLine() throws {
        let molecule = try MoleculeXYZ.parse("""
        2
        H 0 0 0
        Cl 0 0 1.27
        """)

        XCTAssertEqual(molecule.atoms.map(\.element), ["H", "Cl"])
    }

    func testRejectsDeclaredAtomCountMismatch() {
        XCTAssertThrowsError(try MoleculeXYZ.parse("""
        3
        incomplete
        H 0 0 0
        H 0 0 1
        """))
    }

    func testRejectsUnknownElementAndNonFiniteCoordinate() {
        XCTAssertThrowsError(try MoleculeXYZ.parse("Xx 0 0 0"))
        XCTAssertThrowsError(try MoleculeXYZ.parse("H nan 0 0"))
    }

    func testRejectsEmptyAndOversizedDocuments() {
        XCTAssertThrowsError(try MoleculeXYZ.parse(" \n\n"))
        let tooMany = String(MoleculeXYZ.maximumAtomCount + 1) + "\ncomment"
        XCTAssertThrowsError(try MoleculeXYZ.parse(tooMany)) { error in
            XCTAssertEqual(
                error as? MoleculeXYZ.ParseError,
                .tooManyAtoms(maximum: MoleculeXYZ.maximumAtomCount)
            )
        }
    }

    func testMoleculeSourceAttachmentRoundTripsAsVersionedJSON() throws {
        let source = MoleculeSourceAttachment(
            canonicalXYZ: "2\nH2\nH 0 0 0\nH 0 0 0.74\n",
            atomCount: 2,
            createdAt: Date(timeIntervalSince1970: 123)
        )

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(MoleculeSourceAttachment.self, from: data)

        XCTAssertEqual(decoded, source)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.format, "xyz")
    }

    @MainActor
    func testFakeStorePersistsMoleculeSourceSeparatelyFromImage() throws {
        let store = FakeShotStore()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = context.makeImage()!
        let shot = try store.save(image: image, metadata: CaptureMetadata())
        let source = MoleculeSourceAttachment(
            canonicalXYZ: "1\nHe\nHe 0 0 0\n",
            atomCount: 1
        )

        XCTAssertNil(store.moleculeSource(for: shot))
        try store.attachMoleculeSource(source, to: shot)
        XCTAssertEqual(store.moleculeSource(for: shot), source)
        XCTAssertNotNil(store.originalImage(for: shot))
    }

    @MainActor
    func testMoleculeToolbarControlOnlyAppearsWithSourceActions() {
        let state = AnnotationState(styleStore: FakeStyleStore())
        let control = MoleculeSourceControl()
        let ordinary = ToolbarContext(
            annotation: state,
            scope: .pinned,
            perform: { _ in }
        )
        let molecule = ToolbarContext(
            annotation: state,
            scope: .pinned,
            perform: { _ in },
            moleculeSourceActions: MoleculeSourceActions(
                copyXYZ: {},
                openInDefaultApp: {},
                reopen3D: {}
            )
        )

        XCTAssertFalse(control.isVisible(ordinary))
        XCTAssertTrue(control.isVisible(molecule))
    }
}
