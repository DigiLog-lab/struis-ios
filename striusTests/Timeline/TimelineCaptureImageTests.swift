import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import strius

/// 2026-10-27 の依頼: 答案の写真を縮めて送り、読みきれない時だけ元の解像度で見る(`TimelineCaptureImage`)。
final class TimelineCaptureImageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 単色の画像を書く(`orientation` は EXIF の向き)。
    private func writeImage(width: Int, height: Int, type: UTType = .jpeg, orientation: Int? = nil, name: String) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func size(_ url: URL) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let size = try XCTUnwrap(TimelineCaptureImage.orientedSize(source))
        return size
    }

    private func size(jpeg: Data) throws -> (width: Int, height: Int, type: String?) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let size = try XCTUnwrap(TimelineCaptureImage.orientedSize(source))
        return (size.width, size.height, CGImageSourceGetType(source) as String?)
    }

    func testFittedSizeKeepsTheAspectAndLeavesSmallImages() {
        XCTAssertTrue(TimelineCaptureImage.fitted(width: 3024, height: 3470, limit: 1_092) == (952, 1_092))
        XCTAssertTrue(TimelineCaptureImage.fitted(width: 3470, height: 3024, limit: 1_092) == (1_092, 952))
        XCTAssertTrue(TimelineCaptureImage.fitted(width: 750, height: 880, limit: 1_092) == (750, 880))
        XCTAssertTrue(TimelineCaptureImage.fitted(width: 1_092, height: 500, limit: 1_092) == (1_092, 500))
        XCTAssertTrue(TimelineCaptureImage.fitted(width: 3000, height: 4000, limit: 2_576) == (1_932, 2_576))
    }

    func testCameraPhotoIsStagedAsAReducedJPEGAndInkIsCopiedUnchanged() throws {
        let photo = try writeImage(width: 3024, height: 3470, name: "photo.jpg")
        let staged = directory.appendingPathComponent("staged.jpg")
        try TimelineCaptureImage.stageReduced(from: photo, to: staged, limit: TimelineCaptureImage.requestMaxDimension)
        let reduced = try size(jpeg: Data(contentsOf: staged))
        XCTAssertEqual(reduced.width, 952)
        XCTAssertEqual(reduced.height, 1_092)
        XCTAssertEqual(reduced.type, UTType.jpeg.identifier)
        // 元の写真はそのまま。
        XCTAssertTrue(try size(photo) == (3024, 3470))

        // 指で書いた答案(長い辺が 1,092 以下)は、今までどおりそのまま置く。
        let ink = try writeImage(width: 750, height: 880, type: .png, name: "ink.png")
        let stagedInk = directory.appendingPathComponent("ink-staged.png")
        try TimelineCaptureImage.stageReduced(from: ink, to: stagedInk, limit: TimelineCaptureImage.requestMaxDimension)
        XCTAssertEqual(try Data(contentsOf: stagedInk), try Data(contentsOf: ink))
    }

    func testStagingAppliesTheExifOrientation() throws {
        // 横長で保存し、向き 6(90 度回す)を付けた写真は、縦長として縮める(道具の座標と揃える)。
        let photo = try writeImage(width: 3470, height: 3024, orientation: 6, name: "rotated.jpg")
        XCTAssertTrue(try size(photo) == (3024, 3470))
        let staged = directory.appendingPathComponent("rotated-staged.jpg")
        try TimelineCaptureImage.stageReduced(from: photo, to: staged, limit: TimelineCaptureImage.requestMaxDimension)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(staged as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 952)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 1_092)
    }

    func testRegionOnTheAttachedPhotoMapsToTheOriginalPhoto() throws {
        // 3024×3470 を 952×1092 で付けた。倍率は 横 3024/952、縦 3470/1092。
        let rect = try XCTUnwrap(TimelineCaptureImage.originalRect(region: CGRect(x: 100, y: 200, width: 300, height: 100), width: 3024, height: 3470))
        XCTAssertEqual(rect.minX, (100.0 * 3024 / 952).rounded(.down), accuracy: 1)
        XCTAssertEqual(rect.minY, (200.0 * 3470 / 1092).rounded(.down), accuracy: 1)
        XCTAssertEqual(rect.width, 300.0 * 3024 / 952, accuracy: 2)
        XCTAssertEqual(rect.height, 100.0 * 3470 / 1092, accuracy: 2)

        // 端をはみ出す範囲は、写真の中だけに切る。
        let edge = try XCTUnwrap(TimelineCaptureImage.originalRect(region: CGRect(x: 900, y: 1000, width: 200, height: 200), width: 3024, height: 3470))
        XCTAssertEqual(edge.maxX, 3024)
        XCTAssertEqual(edge.maxY, 3470)
        let negative = try XCTUnwrap(TimelineCaptureImage.originalRect(region: CGRect(x: -50, y: -50, width: 100, height: 100), width: 3024, height: 3470))
        XCTAssertEqual(negative.minX, 0)
        XCTAssertEqual(negative.minY, 0)
        // 写真と重ならない範囲は受け取らない。
        XCTAssertNil(TimelineCaptureImage.originalRect(region: CGRect(x: 2000, y: 2000, width: 10, height: 10), width: 3024, height: 3470))

        // 元から小さい画像(付けた写真と同じ大きさ)は、座標をそのまま使う。
        let ink = try XCTUnwrap(TimelineCaptureImage.originalRect(region: CGRect(x: 10, y: 20, width: 30, height: 40), width: 750, height: 880))
        XCTAssertEqual(ink, CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    func testViewReturnsTheWholePhotoWithinTheLimitAndARegionAtTheOriginalResolution() throws {
        let photo = try writeImage(width: 3000, height: 4000, name: "large.jpg")
        // 全体: 長い辺が 2,576 を超えるので 2,576 に縮める。
        let whole = try TimelineCaptureImage.view(url: photo, region: nil)
        XCTAssertEqual(whole.width, 1_932)
        XCTAssertEqual(whole.height, 2_576)
        XCTAssertEqual(whole.rect, CGRect(x: 0, y: 0, width: 3000, height: 4000))
        XCTAssertTrue(try size(jpeg: whole.jpeg) == (1_932, 2_576, UTType.jpeg.identifier))

        // 一部: 付けた写真(819×1092)の上の 100×100 は、元の写真の約 366×366 を元の解像度のまま返す。
        let part = try TimelineCaptureImage.view(url: photo, region: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(part.width, Int(part.rect.width))
        XCTAssertEqual(part.height, Int(part.rect.height))
        XCTAssertEqual(Double(part.width), 100.0 * 4000 / 1092, accuracy: 2)

        // 一部でも大きければ 2,576 に縮める。
        let big = try TimelineCaptureImage.view(url: photo, region: CGRect(x: 0, y: 0, width: 819, height: 1092))
        XCTAssertEqual(max(big.width, big.height), 2_576)

        // 小さい画像の全体はそのままの大きさ。
        let ink = try writeImage(width: 750, height: 880, type: .png, name: "ink.png")
        let small = try TimelineCaptureImage.view(url: ink, region: nil)
        XCTAssertEqual(small.width, 750)
        XCTAssertEqual(small.height, 880)

        XCTAssertThrowsError(try TimelineCaptureImage.view(url: photo, region: CGRect(x: 5000, y: 5000, width: 10, height: 10)))
    }

    func testToolReadsTheAttemptPhotoFromTheLedgerAndKeepsTheShownImage() async throws {
        let name = "timeline-test-\(UUID().uuidString).jpg"
        let stored = StruisPaths.captures.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: StruisPaths.captures, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try writeImage(width: 3024, height: 3470, name: "photo.jpg"), to: stored)
        defer { try? FileManager.default.removeItem(at: stored) }
        let ledger = try Ledger.inMemory()
        let attemptID = try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", TimelineFixture.card("c1"))
            let id = timeline.recordCapture(cardID: "c1", capturePath: name, seconds: 3, assisted: false)
            return (timeline.events, id)
        }
        TimelineQueryHost.install(ledger)

        let reply = await TimelineQueryHost.viewCapture(["attempt_id": attemptID, "region": ["x": 100, "y": 100, "width": 200, "height": 100]])
        XCTAssertTrue(reply.success)
        let image = try XCTUnwrap(reply.items.first { $0["type"] as? String == "inputImage" }?["imageUrl"] as? String)
        XCTAssertTrue(image.hasPrefix("data:image/jpeg;base64,"))
        let record = try XCTUnwrap(reply.record)
        XCTAssertEqual(record["attempt_id"] as? String, attemptID)
        XCTAssertEqual(Double(record["width"] as? Int ?? 0), 200.0 * 3024 / 952, accuracy: 2)
        let saved = try XCTUnwrap(record["saved_path"] as? String)
        XCTAssertTrue(saved.hasPrefix("timeline_views/"))
        let savedURL = StruisPaths.captures.appendingPathComponent(saved)
        defer { try? FileManager.default.removeItem(at: savedURL) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))

        // 範囲なしは全体(2,576 以下なのでそのまま)。写真の無い答案と、はみ出した範囲は失敗として返す。
        let whole = await TimelineQueryHost.viewCapture(["attempt_id": attemptID])
        XCTAssertTrue(whole.success)
        XCTAssertEqual(Double(whole.record?["height"] as? Int ?? 0), 2_576, accuracy: 1)
        if let path = whole.record?["saved_path"] as? String { try? FileManager.default.removeItem(at: StruisPaths.captures.appendingPathComponent(path)) }
        let missing = await TimelineQueryHost.viewCapture(["attempt_id": "nope"])
        XCTAssertFalse(missing.success)
        let outside = await TimelineQueryHost.viewCapture(["attempt_id": attemptID, "region": ["x": 5000, "y": 5000, "width": 10, "height": 10]])
        XCTAssertFalse(outside.success)
    }
}
