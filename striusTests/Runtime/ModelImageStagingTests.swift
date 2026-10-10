import ImageIO
import UIKit
import XCTest
@testable import strius

/// Images staged for Codex stay within Codex's high-detail budget, so the runtime
/// extension no longer decodes full-resolution camera photos. JPEG/PNG images already
/// within the budget, including PDF page images, are passed through unchanged; Codex
/// still decodes those itself.
final class ModelImageStagingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-image-staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(width: Int, height: Int, type: String, orientation: Int? = nil, name: String) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true // the renderer defaults to an alpha channel
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: width / 4, height: height / 8))
        }
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixels(_ url: URL) throws -> (width: Int, height: Int, type: String?) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return ((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
                (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0,
                CGImageSourceGetType(source) as String?)
    }

    private func assertWithinCodexBudget(_ staged: (width: Int, height: Int, type: String?), file: StaticString = #filePath, line: UInt = #line) {
        // Codex's high-detail budget: 2048 px per side, 2,500 patches of 32 px.
        XCTAssertLessThanOrEqual(max(staged.width, staged.height), 2048, file: file, line: line)
        XCTAssertLessThanOrEqual(((staged.width + 31) / 32) * ((staged.height + 31) / 32), 2_500, file: file, line: line)
        XCTAssertTrue(WorkspaceStager.modelImageFits(width: staged.width, height: staged.height), file: file, line: line)
    }

    func testCameraSizedPhotoIsDownsampledToCodexBudget() throws {
        let source = try write(width: 3024, height: 4032, type: "public.jpeg", name: "paper.jpg")
        let target = directory.appendingPathComponent("staged.jpg")
        try WorkspaceStager.stageModelImage(from: source, to: target)
        let staged = try pixels(target)
        assertWithinCodexBudget(staged)
        XCTAssertEqual(staged.type, "public.jpeg")
        // Close to the largest size Codex itself would send for 3:4 (about 1376x1835).
        XCTAssertGreaterThanOrEqual(staged.height, 1800)
        XCTAssertEqual(Double(staged.width) / Double(staged.height), 0.75, accuracy: 0.01)
    }

    func testPDFPageWithinBudgetIsCopiedByteForByte() throws {
        // PDF pages are stored at 1600 px (1131x1600 for A4): 1,800 patches, already within budget.
        let source = try write(width: 1131, height: 1600, type: "public.jpeg", name: "doc-p1.jpg")
        let target = directory.appendingPathComponent("doc-p1-staged.jpg")
        try WorkspaceStager.stageModelImage(from: source, to: target)
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: source))
    }

    func testBoundedJPEGIsCopiedByteForByte() throws {
        let source = try write(width: 1200, height: 900, type: "public.jpeg", name: "small.jpg")
        let target = directory.appendingPathComponent("small-staged.jpg")
        try WorkspaceStager.stageModelImage(from: source, to: target)
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: source))
    }

    func testRotatedPhotoAppliesOrientationWhenDownsampling() throws {
        // EXIF orientation 6 displays a 4032x3024 sensor image as portrait.
        let source = try write(width: 4032, height: 3024, type: "public.jpeg", orientation: 6, name: "rotated.jpg")
        let target = directory.appendingPathComponent("rotated-staged.jpg")
        try WorkspaceStager.stageModelImage(from: source, to: target)
        let staged = try pixels(target)
        assertWithinCodexBudget(staged)
        XCTAssertLessThan(staged.width, staged.height)
    }

    func testNonJPEGFormatIsConvertedToJPEG() throws {
        let source = try write(width: 800, height: 600, type: "public.tiff", name: "scan.tiff")
        let target = directory.appendingPathComponent("scan-staged.tiff")
        try WorkspaceStager.stageModelImage(from: source, to: target)
        let staged = try pixels(target)
        XCTAssertEqual(staged.type, "public.jpeg")
        XCTAssertEqual(staged.width, 800)
    }

    func testOversizedTransparentPNGStaysPNGWithAlpha() throws {
        let width = 3000, height = 3000
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: width / 2, height: 40))
        }
        let source = directory.appendingPathComponent("diagram.png")
        try XCTUnwrap(image.pngData()).write(to: source)
        let target = directory.appendingPathComponent("diagram-staged.png")
        try WorkspaceStager.stageModelImage(from: source, to: target)
        let staged = try pixels(target)
        assertWithinCodexBudget(staged)
        XCTAssertEqual(staged.type, "public.png")
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil)), 0, nil))
        XCTAssertFalse([.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo))
    }

    func testOversizedOpaquePNGStaysLosslessPNG() throws {
        let source = try write(width: 3000, height: 2000, type: "public.png", name: "screenshot.png")
        let target = directory.appendingPathComponent("screenshot-staged.png")
        try WorkspaceStager.stageModelImage(from: source, to: target)
        let staged = try pixels(target)
        assertWithinCodexBudget(staged)
        XCTAssertEqual(staged.type, "public.png")
    }

    func testNonImageIsCopiedUnchanged() throws {
        let source = directory.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: source)
        let target = directory.appendingPathComponent("notes-staged.txt")
        try WorkspaceStager.stageModelImage(from: source, to: target)
        XCTAssertEqual(try Data(contentsOf: target), Data("not an image".utf8))
    }
}
