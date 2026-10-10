import CryptoKit
import PDFKit
import Foundation

/// 質問ターンの添付を、モデルへの画像の入力・作業ディレクトリへの写し・inbox の manifest にする
/// (信頼性計画 P3 の 2・3・6)。
/// - 縦長・横長の画像は、読める解像度で分割した画像を渡す(分割は保存した添付を変えず、実行時の写しで行う)。
/// - 1 ターンに渡す画像は `maxTurnImages` 枚・合計 `maxTurnImagePixels` 画素まで。今回の送信の添付を先に渡す。
///   入らなかった画像と、参照に回した添付(単元づくりの前の回答)は、原本を inbox に置き、`struis.document` で読ませる。
/// - PDF は最初のページの画像を渡し、総ページ数と「ほかのページは struis.document で読める」ことを書く。
nonisolated enum AttachmentStaging {
    static let maxTurnImages = 20
    static let maxTurnImagePixels = 50_000_000
    /// 分割した画像のうち、自動で渡す数(残りはモデルが `render` の `part` で見る)。
    static let maxPartsPerImage = 6

    struct Result {
        var images: [TurnPlan.ImageRef] = []
        var copies: [TurnPlan.CopySpec] = []
        var manifest: String?
        var manifestPath: String?
    }

    /// `messageID` は inbox のフォルダ名。重い処理(分割)を含むので主スレッドの外で呼ぶ。
    static func stage(_ attachments: [ChatTurns.Attachment], learnerID: String, threadID: String, messageID: String) throws -> Result {
        guard !attachments.isEmpty else { return Result() }
        let inbox = "tutor_desk/inbox/\(messageID)"
        let root = ChatTurns.attachmentsRoot
        var result = Result()
        var imageCount = 0
        var pixelCount = 0
        var sections: [String] = []

        /// 枠に入れば画像の入力にする。入らなければ false。
        func addImage(_ attachment: ChatTurns.Attachment, staged: String, pixels: Int) -> Bool {
            guard imageCount < maxTurnImages, pixelCount + pixels <= maxTurnImagePixels else { return false }
            imageCount += 1
            pixelCount += pixels
            result.images.append(TurnPlan.ImageRef(path: staged, hostPath: root.appendingPathComponent(attachment.relativePath).path))
            return true
        }
        func copy(_ attachment: ChatTurns.Attachment, as name: String) -> String {
            let staged = "\(inbox)/\(name)"
            result.copies.append(TurnPlan.CopySpec(hostPath: root.appendingPathComponent(attachment.relativePath).path, path: staged))
            return staged
        }
        func ext(_ attachment: ChatTurns.Attachment, fallback: String) -> String {
            let value = (attachment.filename as NSString).pathExtension.lowercased()
            return value.isEmpty ? fallback : value
        }

        // PDF のページの画像は、同じ束の PDF の下にまとめて書く(`<batch>/<n>-<name>.pdf` と `<batch>/<n>-<stem>-pN.jpg`)。
        let pageImages = attachments.filter { $0.kind == ChatTurns.Attachment.pageImageKind }
        func pages(of document: ChatTurns.Attachment) -> [ChatTurns.Attachment] {
            let stem = (document.relativePath as NSString).deletingPathExtension
            return pageImages.filter { $0.relativePath.hasPrefix(stem + "-p") }
        }
        let ownedPages = Set(attachments.filter { $0.kind != ChatTurns.Attachment.pageImageKind }.flatMap { pages(of: $0) }.map(\.relativePath))

        var sourceIndex = 0, documentIndex = 0, referenceIndex = 0
        for attachment in attachments {
            var lines = ["### \(attachment.filename)", "", "- content_type: `\(attachment.contentType)`", "- bytes: `\(attachment.bytes)`", "- sha256: `\(attachment.sha256)`"]
            switch attachment.kind {
            case "image":
                sourceIndex += 1
                let original = copy(attachment, as: "original-\(sourceIndex).\(ext(attachment, fallback: "jpg"))")
                lines.append("- original_path: `\(original)` (full resolution; open with struis.document)")
                let url = root.appendingPathComponent(attachment.relativePath)
                let info = DocumentReader.imageInfo(url)
                if let info { lines.append("- pixel_size: `\(info.width)x\(info.height)`") }
                let parts = info.map { DocumentReader.imagePartCount(width: $0.width, height: $0.height) } ?? 1
                if parts > 1 {
                    // 縦長(横長)の画像: 縮めると読めないので、分割した画像を渡す。
                    let pieces = try imageParts(attachment, limit: maxPartsPerImage)
                    var attached: [String] = []
                    for (index, piece) in pieces.enumerated() {
                        let staged = "\(inbox)/source-\(sourceIndex)-part\(index + 1).jpg"
                        if addImage(piece.attachment, staged: staged, pixels: piece.pixels) { attached.append(staged) } else { break }
                    }
                    if attached.isEmpty {
                        lines.append("- image_input: not attached (turn image limit). Look at it with struis.document render on original_path.")
                    } else {
                        lines.append("- image_input: split into \(parts) parts along its long side; parts 1-\(attached.count) are attached as \(attached.map { "`\($0)`" }.joined(separator: ", "))"
                            + (attached.count < parts ? "; see parts \(attached.count + 1)-\(parts) with struis.document render (path=original_path, part=N)." : "."))
                    }
                } else {
                    let staged = "\(inbox)/source-\(sourceIndex).\(ext(attachment, fallback: "jpg"))"
                    let pixels = info.map { let (w, h) = DocumentReader.fittedSize(width: CGFloat($0.width), height: CGFloat($0.height)); return w * h } ?? 2_600_000
                    if addImage(attachment, staged: staged, pixels: pixels) {
                        lines.append("- image_input: `\(staged)`")
                    } else {
                        lines.append("- image_input: not attached (turn image limit). Look at it with struis.document render on original_path.")
                    }
                }
            case ChatTurns.Attachment.pageImageKind:
                // 持ち主の PDF の節で書く。持ち主の無いページ(古い台帳)は、ただの画像として渡す。
                guard !ownedPages.contains(attachment.relativePath) else { continue }
                sourceIndex += 1
                let staged = "\(inbox)/source-\(sourceIndex).jpg"
                lines.append(addImage(try ChatStore.runtimePageImageAttachment(attachment), staged: staged, pixels: 2_600_000) ? "- image_input: `\(staged)`" : "- image_input: not attached (turn image limit).")
            case ChatTurns.Attachment.referenceKind:
                referenceIndex += 1
                let staged = copy(attachment, as: "reference-\(referenceIndex).\(ext(attachment, fallback: "bin"))")
                lines.append("- reference_path: `\(staged)`")
                lines.append("- reference_policy: The learner attached this to an earlier answer in this conversation. It is not attached as an image this turn; open it with struis.document (info, text, render) when it matters.")
            default:
                documentIndex += 1
                let staged = copy(attachment, as: "document-\(documentIndex).\(ext(attachment, fallback: "bin"))")
                lines.append("- document_path: `\(staged)`")
                if attachment.contentType == "application/pdf" || attachment.filename.lowercased().hasSuffix(".pdf") {
                    let url = root.appendingPathComponent(attachment.relativePath)
                    let pageCount = DocumentReader.pdfPageCount(url)
                    lines.append("- pages: `\(pageCount.map(String.init) ?? "unknown")`")
                    var attached: [String] = []
                    for page in pages(of: attachment) {
                        sourceIndex += 1
                        let staged = "\(inbox)/source-\(sourceIndex)-\(page.filename)"
                        if addImage(try ChatStore.runtimePageImageAttachment(page), staged: staged, pixels: 2_600_000) { attached.append("`\(staged)` (\(pageLabel(page.filename)))") }
                    }
                    if !attached.isEmpty { lines.append("- page_images: " + attached.joined(separator: ", ")) }
                    lines.append("- other_pages: Only the pages listed in page_images are attached as images. Read any page (text, OCR, images, search) with struis.document on document_path; do not guess about pages you have not read.")
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }
        let header = [
            "# Tutor desk inbox manifest", "",
            "- learner_id: `\(learnerID)`", "- thread_id: `\(threadID)`", "- message_id: `\(messageID)`",
            "- evidence_policy: Attached images are primary visual evidence. Attached documents are files in this folder; read PDFs and images with the struis.document tool (PDF command-line tools and Python PDF libraries are not installed).",
            "- manifest_policy: This file is metadata only. It must not contain OCR, transcription, or source-of-truth image interpretation.",
            "- image_input_policy: An image larger than the model image budget, or not stored as JPEG/PNG data, is staged as a converted copy at `image_input` (PNG for PNG sources or images with an alpha channel, otherwise JPEG); a tall or wide image is split into readable parts; `content_type`, `bytes` and `sha256` describe the saved original.",
            "- turn_image_limit: at most \(maxTurnImages) images are attached to one turn; the rest are listed as not attached.",
            "- lookup_policy: A lookup that names this manifest in its sources receives this whole folder, so it can open the files with struis.document. A short question about one page is faster to read directly with struis.document.",
            "", "## Attachments", "",
        ]
        result.manifestPath = "\(inbox)/manifest.md"
        result.manifest = (header + sections.flatMap { [$0, ""] }).joined(separator: "\n") + "\n"
        return result
    }

    private static func pageLabel(_ filename: String) -> String {
        // `<stem>-p3.jpg` → page 3、`<stem>-p1-2.jpg` → page 1 part 2
        let name = (filename as NSString).deletingPathExtension
        guard let range = name.range(of: "-p", options: .backwards) else { return filename }
        let parts = name[range.upperBound...].split(separator: "-")
        return parts.count == 2 ? "page \(parts[0]) part \(parts[1])" : "page \(parts.first ?? "")"
    }

    /// 縦長・横長の画像を分割した JPEG(実行時の写し。原本の sha256 ごとに `runtime-image-parts-v1/` に置いて使い回す)。
    static func imageParts(_ attachment: ChatTurns.Attachment, limit: Int) throws -> [(attachment: ChatTurns.Attachment, pixels: Int)] {
        let root = ChatTurns.attachmentsRoot
        let source = root.appendingPathComponent(attachment.relativePath)
        let key = attachment.sha256.isEmpty ? try ChatStore.fileSHA256(source) : attachment.sha256
        let directory = "runtime-image-parts-v1/\(key)"
        let folder = root.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var pieces: [(ChatTurns.Attachment, Int)] = []
        var missing: Set<Int> = []
        for index in 0..<limit where !FileManager.default.fileExists(atPath: folder.appendingPathComponent("part\(index + 1).jpg").path) {
            missing.insert(index)
        }
        if !missing.isEmpty, let rendered = DocumentReader.imageParts(source, parts: missing) {
            for (index, image) in rendered.images {
                guard let jpeg = autoreleasepool(invoking: { DocumentReader.jpeg(image) }) else { continue }
                try jpeg.write(to: folder.appendingPathComponent("part\(index + 1).jpg"), options: .atomic)
            }
        }
        for index in 0..<limit {
            let url = folder.appendingPathComponent("part\(index + 1).jpg")
            guard FileManager.default.fileExists(atPath: url.path), let info = DocumentReader.imageInfo(url) else { continue }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            pieces.append((ChatTurns.Attachment(
                filename: "\((attachment.filename as NSString).deletingPathExtension)-part\(index + 1).jpg", contentType: "image/jpeg",
                bytes: bytes, relativePath: "\(directory)/part\(index + 1).jpg", sha256: "", kind: ChatTurns.Attachment.pageImageKind
            ), Int(Double(info.width) * Double(info.height))))
        }
        return pieces
    }
}

extension ChatTurns.Attachment {
    /// 単元づくりの最後のターンで、前の回答に添えたものを画像の入力にせず参照に回す(C10)。
    nonisolated static let referenceKind = "reference"

    /// 参照に回した添付。PDF のページの画像は落とす(PDF そのものを struis.document で読める)。
    nonisolated var asReference: ChatTurns.Attachment? {
        guard kind != Self.pageImageKind else { return nil }
        var copy = self
        copy.kind = Self.referenceKind
        return copy
    }
}

nonisolated extension DocumentReader {
    static func pdfPageCount(_ url: URL) -> Int? {
        guard let document = PDFDocument(url: url) else { return nil }
        return document.pageCount
    }
}
