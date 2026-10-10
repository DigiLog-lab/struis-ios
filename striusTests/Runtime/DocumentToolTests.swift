import PDFKit
import UIKit
import XCTest
@testable import strius

/// 添付の入口・struis.document・ターンへの渡し方(信頼性計画 P3)。教材はテストの中で作る。
final class DocumentToolTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("document-tool-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 各ページに「PAGE n」と書いた PDF。`size` はページの大きさ(pt)。
    private func makePDF(_ name: String, pages: Int, size: CGSize = CGSize(width: 595, height: 842), blank: Set<Int> = []) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            for page in 1...pages {
                context.beginPage()
                guard !blank.contains(page) else { continue }
                let text = "PAGE \(page) keyword\(page)" as NSString
                text.draw(at: CGPoint(x: 40, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 28)])
                if size.height > 4000 {
                    ("BOTTOM LINE" as NSString).draw(at: CGPoint(x: 20, y: size.height - 80), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                }
            }
        }
        try data.write(to: url)
        return url
    }

    private func makeImage(_ name: String, size: CGSize, type: String = "public.png") throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("TOP" as NSString).draw(at: CGPoint(x: 10, y: 10), withAttributes: [.font: UIFont.systemFont(ofSize: 40)])
        }
        let data = type == "public.png" ? image.pngData()! : image.jpegData(compressionQuality: 0.9)!
        try data.write(to: url)
        return url
    }

    private func text(_ reply: DocumentTool.Reply) -> String {
        reply.items.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func images(_ reply: DocumentTool.Reply) -> [CGImage] {
        reply.items.compactMap { item -> CGImage? in
            guard let url = item["imageUrl"] as? String, let comma = url.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
            return UIImage(data: data)?.cgImage
        }
    }

    // MARK: - struis.document

    func testInfoTextSearchReachPagesBeyondTheAttachedImages() async throws {
        _ = try makePDF("book.pdf", pages: 200)
        let info = await DocumentTool.handle(["operation": "info", "path": "book.pdf"], root: directory.path)
        XCTAssertTrue(info.success, text(info))
        XCTAssertTrue(text(info).contains("\"pages\":200"), text(info))
        let page = await DocumentTool.handle(["operation": "text", "path": "book.pdf", "pages": "150"], root: directory.path)
        XCTAssertTrue(page.success)
        XCTAssertTrue(text(page).contains("--- page 150 ---"))
        XCTAssertTrue(text(page).contains("PAGE 150"), text(page))
        let search = await DocumentTool.handle(["operation": "search", "path": "book.pdf", "query": "keyword150"], root: directory.path)
        XCTAssertTrue(text(search).contains("\"page\":150"), text(search))
        let range = await DocumentTool.handle(["operation": "text", "path": "book.pdf", "pages": "1-50"], root: directory.path)
        XCTAssertTrue(text(range).contains("--- page \(DocumentTool.maxTextPages) ---"))
        XCTAssertFalse(text(range).contains("--- page \(DocumentTool.maxTextPages + 1) ---"))
        let missing = await DocumentTool.handle(["operation": "text", "path": "book.pdf", "pages": "201"], root: directory.path)
        XCTAssertFalse(missing.success)
    }

    func testRenderFitsTheModelBudgetAndSplitsTallPages() async throws {
        _ = try makePDF("a4.pdf", pages: 1)
        let a4 = await DocumentTool.handle(["operation": "render", "path": "a4.pdf", "pages": "1"], root: directory.path)
        let a4Images = images(a4)
        XCTAssertEqual(a4Images.count, 1)
        let a4Image = try XCTUnwrap(a4Images.first)
        XCTAssertTrue(DocumentReader.fitsModelBudget(width: a4Image.width, height: a4Image.height))
        XCTAssertGreaterThan(a4Image.height, 1500, "A4 は枠いっぱいまで拡大して描く")

        // Safari のフルページ(390×20000pt): 縮めずに、幅 1170px で分割する。
        _ = try makePDF("full.pdf", pages: 1, size: CGSize(width: 390, height: 20000))
        let page = try XCTUnwrap(PDFDocument(url: directory.appendingPathComponent("full.pdf"))?.page(at: 0))
        let parts = DocumentReader.pagePartCount(page)
        XCTAssertGreaterThan(parts, 20)
        let first = await DocumentTool.handle(["operation": "render", "path": "full.pdf", "pages": "1"], root: directory.path)
        XCTAssertEqual(images(first).count, DocumentTool.maxRenderImages)
        for image in images(first) {
            XCTAssertEqual(image.width, 1170)
            XCTAssertTrue(DocumentReader.fitsModelBudget(width: image.width, height: image.height))
        }
        let last = await DocumentTool.handle(["operation": "render", "path": "full.pdf", "pages": "1", "part": parts], root: directory.path)
        XCTAssertEqual(images(last).count, 1)
        XCTAssertTrue(text(last).contains("part \(parts) of \(parts)"))
        let crop = await DocumentTool.handle(["operation": "render", "path": "full.pdf", "pages": "1", "crop": [0, 0.98, 1, 1]], root: directory.path)
        XCTAssertEqual(images(crop).count, 1)
    }

    func testTallImageIsSplitAndPathsStayInsideTheWorkspace() async throws {
        _ = try makeImage("tall.png", size: CGSize(width: 1170, height: 20000))
        let info = await DocumentTool.handle(["operation": "info", "path": "tall.png"], root: directory.path)
        XCTAssertTrue(text(info).contains("\"image_parts\":11"), text(info))
        let render = await DocumentTool.handle(["operation": "render", "path": "tall.png", "part": 1], root: directory.path)
        let image = try XCTUnwrap(images(render).first)
        XCTAssertEqual(image.width, 1170)
        XCTAssertTrue(DocumentReader.fitsModelBudget(width: image.width, height: image.height))

        let outside = await DocumentTool.handle(["operation": "info", "path": "../../etc/hosts"], root: directory.path)
        XCTAssertFalse(outside.success)
        XCTAssertTrue(text(outside).contains("not permitted"))
    }

    // MARK: - Intake

    func testIntakeAcceptsReadableFilesAndGivesReasonsForTheRest() async throws {
        let pdf = try makePDF("textbook.pdf", pages: 3)
        let blank = try makePDF("blank.pdf", pages: 1, blank: [1])
        let partly = try makePDF("partly.pdf", pages: 3, blank: [2])
        let image = try makeImage("noext", size: CGSize(width: 300, height: 200), type: "public.jpeg")
        let docx = directory.appendingPathComponent("doc.docx")
        try Data("PK\u{3}\u{4}not really".utf8).write(to: docx)
        let movie = directory.appendingPathComponent("clip.mp4")
        try Data(repeating: 7, count: 2048).write(to: movie)
        let broken = directory.appendingPathComponent("broken.jpg")
        try Data(try Data(contentsOf: image).prefix(300)).write(to: broken)
        let notPDF = directory.appendingPathComponent("fake.pdf")
        try Data("hello".utf8).write(to: notPDF)
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let outcomes = await AttachmentIntake.importFiles(
            [pdf, blank, partly, image, docx, movie, broken, notPDF, folder], budget: AttachmentIntake.Budget(existing: [])
        )
        var accepted: [String: ComposerAttachment] = [:]
        var rejected: [String: String] = [:]
        var notices: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .accepted(let attachment, let notice):
                accepted[attachment.filename] = attachment
                if let notice { notices.append(notice) }
                XCTAssertTrue(attachment.fileURL.path.hasPrefix(AttachmentIntake.stagingRoot.path))
            case .rejected(let rejection): rejected[rejection.filename] = rejection.reason
            case .needsPassword: XCTFail("no password expected")
            }
        }
        XCTAssertEqual(accepted["textbook.pdf"]?.detail, "PDF・3ページ")
        XCTAssertNotNil(accepted["partly.pdf"])
        XCTAssertTrue(notices.contains { $0.contains("partly.pdf") && $0.contains("2ページ目が白紙") }, "\(notices)")
        XCTAssertEqual(accepted["noext.jpeg"]?.contentType, "image/jpeg", "拡張子の無い JPEG は中身で名前と形式を決める")
        XCTAssertEqual(rejected.count, 6, "\(rejected)")
        XCTAssertTrue(rejected["blank.pdf"]?.contains("白紙") == true)
        XCTAssertTrue(rejected["doc.docx"]?.contains(".docx") == true)
        XCTAssertTrue(rejected["clip.mp4"]?.contains("動画") == true)
        XCTAssertTrue(rejected["broken.jpg"]?.contains("画像を読み込めませんでした") == true)
        XCTAssertTrue(rejected["fake.pdf"]?.contains("壊れて") == true)
        XCTAssertTrue(rejected["folder"]?.contains("フォルダ") == true)
    }

    func testBlankLeadingPagesDoNotRejectAPDFWithLaterContent() async throws {
        let leading = try makePDF("cover.pdf", pages: 10, blank: Set(1...8))
        let allBlank = try makePDF("empty.pdf", pages: 10, blank: Set(1...10))
        let outcomes = await AttachmentIntake.importFiles([leading, allBlank], budget: AttachmentIntake.Budget(existing: []))
        guard case .accepted(let attachment, let notice) = outcomes.first else { return XCTFail("先頭 8 ページが白紙でも、後ろに内容があれば受け付ける") }
        XCTAssertEqual(attachment.detail, "PDF・10ページ")
        XCTAssertTrue(notice?.contains("1-8ページ目が白紙") == true, String(describing: notice))
        guard case .rejected(let rejection) = outcomes.last else { return XCTFail("全体が白紙なら断る") }
        XCTAssertTrue(rejection.reason.contains("白紙"))
    }

    /// 細工した PNG のヘッダ(幅・高さが 2^31-1)でも落ちず、理由を付けて断る。
    func testCraftedHugeImageHeaderIsRejectedWithoutCrashing() async throws {
        func crc32(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            return ~crc
        }
        func be(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            return be(UInt32(body.count)) + typed + be(crc32(typed))
        }
        let ihdr = be(0x7FFF_FFFF) + be(0x7FFF_FFFF) + [8, 2, 0, 0, 0]
        let idat: [UInt8] = [0x78, 0x9C, 0x63, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01]
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IDAT", idat) + chunk("IEND", [])
        let url = directory.appendingPathComponent("huge.png")
        try Data(png).write(to: url)
        let outcomes = await AttachmentIntake.importFiles([url], budget: AttachmentIntake.Budget(existing: []))
        guard case .rejected(let rejection) = outcomes.first else { return XCTFail("expected a rejection") }
        XCTAssertFalse(rejection.reason.isEmpty)
    }

    func testIntakeChecksTheSizeBeforeCopying() async throws {
        let big = directory.appendingPathComponent("big.pdf")
        FileManager.default.createFile(atPath: big.path, contents: Data("%PDF-1.7\n".utf8))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(AttachmentIntake.maxTotalBytes + 1))
        try handle.close()
        let outcomes = await AttachmentIntake.importFiles([big], budget: AttachmentIntake.Budget(existing: []))
        guard case .rejected(let rejection) = outcomes.first else { return XCTFail("expected a rejection") }
        XCTAssertTrue(rejection.reason.contains("大きすぎます"), rejection.reason)

        let small = try makePDF("small.pdf", pages: 1)
        let full = await AttachmentIntake.importFiles([small], budget: AttachmentIntake.Budget(count: 0, bytes: AttachmentIntake.maxTotalBytes))
        guard case .rejected(let countRejection) = full.first else { return XCTFail("expected a rejection") }
        XCTAssertTrue(countRejection.reason.contains("\(AttachmentIntake.maxCount)件"))
    }

    func testEncryptedPDFIsUnlockedWithThePassword() async throws {
        let plain = try makePDF("plain.pdf", pages: 2)
        let document = try XCTUnwrap(PDFDocument(url: plain))
        let locked = directory.appendingPathComponent("locked.pdf")
        XCTAssertTrue(document.write(to: locked, withOptions: [.userPasswordOption: "test", .ownerPasswordOption: "owner"]))
        let outcomes = await AttachmentIntake.importFiles([locked], budget: AttachmentIntake.Budget(existing: []))
        guard case .needsPassword(let pending) = outcomes.first else { return XCTFail("expected a password prompt") }
        let wrong = await AttachmentIntake.unlock(pending, password: "nope")
        XCTAssertNil(wrong)
        let unlocked = await AttachmentIntake.unlock(pending, password: "test")
        guard case .accepted(let attachment, _) = unlocked else { return XCTFail("expected acceptance") }
        let reopened = try XCTUnwrap(PDFDocument(url: attachment.fileURL))
        XCTAssertFalse(reopened.isLocked, "モデルの道具が読めるよう、解錠した写しを渡す")
        XCTAssertEqual(reopened.pageCount, 2)
    }

    // MARK: - Turn staging

    func testStagingCapsImagesSplitsTallImagesAndListsPDFPages() throws {
        let batch = "staging-test-" + UUID().uuidString.lowercased()
        let root = ChatTurns.attachmentsRoot.appendingPathComponent(batch, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func store(_ source: URL, as name: String, kind: String, type: String) throws -> ChatTurns.Attachment {
            let target = root.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: target)
            return ChatTurns.Attachment(filename: name, contentType: type, bytes: 1, relativePath: "\(batch)/\(name)", sha256: try ChatStore.fileSHA256(target), kind: kind)
        }
        let pdf = try store(try makePDF("book.pdf", pages: 30), as: "1-book.pdf", kind: "document", type: "application/pdf")
        var attachments = [pdf]
        for page in ChatStore.pdfPageImages(at: root.appendingPathComponent("1-book.pdf")) {
            let url = root.appendingPathComponent("1-book-\(page.name).jpg")
            try page.jpeg.write(to: url)
            attachments.append(ChatTurns.Attachment(filename: "book-\(page.name).jpg", contentType: "image/jpeg", bytes: page.jpeg.count, relativePath: "\(batch)/1-book-\(page.name).jpg", sha256: "", kind: ChatTurns.Attachment.pageImageKind))
        }
        XCTAssertEqual(attachments.count, 1 + ChatStore.pdfPageImageLimit)
        attachments.append(try store(try makeImage("tall.png", size: CGSize(width: 1170, height: 20000)), as: "2-tall.png", kind: "image", type: "image/png"))
        for index in 0..<20 {
            attachments.append(try store(try makeImage("p\(index).jpg", size: CGSize(width: 800, height: 600), type: "public.jpeg"), as: "3-\(index).jpg", kind: "image", type: "image/jpeg"))
        }
        attachments.append(try XCTUnwrap(try store(try makeImage("old.jpg", size: CGSize(width: 800, height: 600), type: "public.jpeg"), as: "4-old.jpg", kind: "image", type: "image/jpeg").asReference))

        let result = try AttachmentStaging.stage(attachments, learnerID: "l", threadID: "t", messageID: "m")
        let manifest = try XCTUnwrap(result.manifest)
        XCTAssertEqual(result.images.count, AttachmentStaging.maxTurnImages)
        XCTAssertTrue(manifest.contains("- pages: `30`"))
        XCTAssertTrue(manifest.contains("(page 8)"))
        XCTAssertTrue(manifest.contains("struis.document"))
        XCTAssertTrue(manifest.contains("split into 11 parts"), manifest)
        XCTAssertTrue(manifest.contains("not attached (turn image limit)"))
        XCTAssertTrue(manifest.contains("- reference_path: `tutor_desk/inbox/m/reference-1.jpg`"))
        XCTAssertTrue(result.copies.contains { $0.path == "tutor_desk/inbox/m/document-1.pdf" })
        for image in result.images {
            let info = try XCTUnwrap(DocumentReader.imageInfo(URL(fileURLWithPath: image.hostPath)))
            XCTAssertTrue(DocumentReader.fitsModelBudget(width: info.width, height: info.height) || image.hostPath.hasSuffix(".jpg"))
        }
    }
}
