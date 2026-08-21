import XCTest
@testable import IndexApp

final class RecordingAssetTests: XCTestCase {
    func testMissingPathIsScreenshot() {
        let asset = RecordingAsset(path: nil, fileExists: { _ in false })

        XCTAssertEqual(asset, .screenshot)
        XCTAssertFalse(asset.isRecording)
        XCTAssertEqual(asset.playbackAction, .editCover)
    }

    func testExistingRecordingResolvesToPlayableAsset() {
        let path = "/tmp/example.mp4"
        let url = URL(fileURLWithPath: path)
        let asset = RecordingAsset(path: path, fileExists: { $0 == path })

        XCTAssertEqual(asset, .available(url))
        XCTAssertTrue(asset.isRecording)
        XCTAssertEqual(asset.availableURL, url)
        XCTAssertEqual(asset.playbackAction, .play(url))
    }

    func testMissingMP4PreservesRecordingIdentityAndReportsMissing() {
        let path = "/tmp/moved-recording.mp4"
        let url = URL(fileURLWithPath: path)
        let asset = RecordingAsset(path: path, fileExists: { _ in false })

        XCTAssertEqual(asset, .missing(url))
        XCTAssertTrue(asset.isRecording, "磁盘文件缺失不能让录屏索引退化为普通截图")
        XCTAssertNil(asset.availableURL)
        XCTAssertEqual(asset.playbackAction, .reportMissing(url))
    }
}
