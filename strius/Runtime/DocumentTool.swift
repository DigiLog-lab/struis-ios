import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// ホスト側の dynamic tool `struis.document`(信頼性計画 P3 の 2)。学習者が添えた PDF と画像を、
/// ゲストの中ではなくアプリで読む(ゲストには PDF を読む手段が無い。pypdf も入れない)。
/// 主スレッドの外で動き、一度に 1 つの呼び出しだけを処理する(画素を持つのは 1 ページ分だけ)。
nonisolated enum DocumentTool {
    static let name = "document"

    /// 1 回の呼び出しの上限。
    static let maxTextPages = 10
    static let maxRenderImages = 4
    static let maxTextCharacters = 40_000
    static let maxSearchHits = 40

    static var definition: JSONObject {
        ["type": "function", "name": name,
         "description": "Read a PDF or image the learner attached (the paths in the inbox manifest). PDF command-line tools and Python PDF libraries are not installed; use this tool for every page beyond the attached page images. "
            + "operation=info: page count, encryption, which pages have a text layer, outline and how many image parts each tall page splits into; for an image its pixel size and part count. "
            + "operation=text: the text of `pages` (e.g. \"150\", \"148-152\", \"1,4\"; at most 10 pages). A page without a text layer is read by on-device OCR (Japanese/English) and marked so; for an image the whole image is OCR'd. "
            + "operation=render: images of `pages` (at most 4 images per call) to look at figures, handwriting or layout. A tall or wide page/image is split into readable parts; `part` (1-based) picks one, `crop` [x0,y0,x1,y1] (0-1, top-left origin) zooms into a region to read small print. "
            + "operation=search: page numbers and snippets where `query` occurs in the text layer.",
         "inputSchema": ["type": "object", "properties": [
            "operation": ["type": "string", "enum": ["info", "text", "render", "search"]],
            "path": ["type": "string", "description": "File path relative to the workspace, as written in the manifest."],
            "pages": ["type": "string", "description": "1-based page numbers or ranges for text/render, e.g. \"150\" or \"3-5\". Ignored for images."],
            "part": ["type": "integer", "description": "1-based part of a split tall/wide page or image (render only)."],
            "crop": ["type": "array", "items": ["type": "number"], "description": "Region [x0,y0,x1,y1] in 0-1 page coordinates, top-left origin (render only)."],
            "query": ["type": "string", "description": "Text to find (search only)."],
         ], "required": ["operation", "path"], "additionalProperties": false]]
    }

    struct Reply {
        var success: Bool
        var items: [JSONObject]
    }

    private static let gate = DocumentToolGate()

    /// `root` はこのターンの作業ディレクトリ。そこから外のファイルは読まない。
    @concurrent
    static func handle(_ arguments: JSONObject, root: String) async -> Reply {
        await gate.acquire()
        let reply: Reply
        do {
            reply = try await run(arguments, root: root)
        } catch let error as DocumentToolError {
            reply = Reply(success: false, items: [text(error.message)])
        } catch {
            reply = Reply(success: false, items: [text("The document could not be read: \(error.localizedDescription)")])
        }
        await gate.release()
        return reply
    }

    private static func run(_ arguments: JSONObject, root: String) async throws -> Reply {
        guard let operation = arguments["operation"] as? String else { throw DocumentToolError("Missing `operation` (info, text, render or search).") }
        guard let path = arguments["path"] as? String, !path.isEmpty else { throw DocumentToolError("Missing `path`.") }
        let url = try resolve(path, root: root)
        guard let kind = DocumentReader.sniff(url) else {
            throw DocumentToolError("\(path) is neither a PDF nor an image this tool can read.")
        }
        switch kind {
        case .pdf:
            guard let document = PDFDocument(url: url) else { throw DocumentToolError("\(path) could not be opened as a PDF (it may be damaged).") }
            guard !document.isLocked else { throw DocumentToolError("\(path) is password-protected and was not unlocked by the learner.") }
            return try await pdf(operation, document: document, path: path, arguments: arguments)
        case .image:
            return try await image(operation, url: url, path: path, arguments: arguments)
        }
    }

    // MARK: - PDF

    private static func pdf(_ operation: String, document: PDFDocument, path: String, arguments: JSONObject) async throws -> Reply {
        let count = document.pageCount
        switch operation {
        case "info":
            var withText = 0
            var withoutText: [Int] = []
            var split: [String: Int] = [:]
            let started = Date()
            var checked = 0
            for index in 0..<count {
                // 2000 ページでも数秒で返す。それ以上かかる時は、調べたところまでを返す。
                if Date().timeIntervalSince(started) > 8 { break }
                autoreleasepool {
                    guard let page = document.page(at: index) else { return }
                    if DocumentReader.textLayer(page) != nil { withText += 1 } else { withoutText.append(index + 1) }
                    let parts = DocumentReader.pagePartCount(page)
                    if parts > 1 { split[String(index + 1)] = parts }
                }
                checked = index + 1
            }
            var info: JSONObject = [
                "path": path, "type": "pdf", "pages": count, "encrypted": document.isEncrypted,
                "pages_with_text_layer": withText, "pages_without_text_layer": ranges(withoutText),
            ]
            if checked < count { info["checked_pages"] = "1-\(checked)" }
            if let first = document.page(at: 0) {
                let size = DocumentReader.displaySize(first)
                info["first_page_size_pt"] = [Int(size.width.rounded()), Int(size.height.rounded())]
            }
            if !split.isEmpty { info["image_parts_per_page"] = split }
            let outline = DocumentReader.outline(document)
            if !outline.isEmpty { info["outline"] = outline.map { ["title": $0.title, "page": $0.page, "depth": $0.depth] } }
            return Reply(success: true, items: [text(json(info))])
        case "text":
            let pages = try pageList(arguments["pages"], count: count, limit: maxTextPages)
            var output = ""
            for number in pages {
                guard let page = document.page(at: number - 1) else { continue }
                if let layer = DocumentReader.textLayer(page) {
                    output += "--- page \(number) ---\n\(layer)\n"
                } else {
                    var recognized: [String] = []
                    let rendered = DocumentReader.renderPage(page)
                    for (_, image) in rendered.images { recognized.append(await DocumentReader.recognizeText(image)) }
                    let body = recognized.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    output += "--- page \(number) (no text layer; recognized by on-device OCR, may contain errors) ---\n"
                        + (body.isEmpty ? "(no text recognized; the page may be blank or only a figure — use render to look)" : body) + "\n"
                }
                if output.count > maxTextCharacters { break }
            }
            return Reply(success: true, items: [text(truncated(output))])
        case "render":
            let pages = try pageList(arguments["pages"], count: count, limit: maxRenderImages)
            let crop = DocumentReader.normalizedCrop(numbers(arguments["crop"]))
            let wanted = (arguments["part"] as? NSNumber)?.intValue
            var items: [JSONObject] = []
            var images = 0
            for number in pages where images < maxRenderImages {
                guard let page = document.page(at: number - 1) else { continue }
                let total = DocumentReader.pagePartCount(page, crop: crop)
                let parts: Set<Int>
                if let wanted {
                    guard (1...total).contains(wanted) else { throw DocumentToolError("Page \(number) has \(total) part(s); `part` must be 1-\(total).") }
                    parts = [wanted - 1]
                } else {
                    parts = Set(0..<min(total, maxRenderImages - images))
                }
                let rendered = DocumentReader.renderPage(page, parts: parts, crop: crop)
                for (index, image) in rendered.images {
                    guard let jpeg = DocumentReader.jpeg(image) else { continue }
                    items.append(text("page \(number) of \(count)" + (total > 1 ? ", part \(index + 1) of \(total) (top to bottom)" : "") + (crop == nil ? "" : ", cropped")))
                    items.append(["type": "inputImage", "imageUrl": "data:image/jpeg;base64," + jpeg.base64EncodedString()])
                    images += 1
                }
                if wanted == nil, total > parts.count {
                    items.append(text("page \(number) has \(total) parts; parts \(parts.count + 1)-\(total) were not returned. Call render with `part` to see them."))
                }
            }
            return Reply(success: true, items: items)
        case "search":
            guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                throw DocumentToolError("Missing `query`.")
            }
            var hits: [JSONObject] = []
            var withoutText = 0
            for index in 0..<count where hits.count < maxSearchHits {
                autoreleasepool {
                    guard let page = document.page(at: index) else { return }
                    guard let layer = DocumentReader.textLayer(page) else { withoutText += 1; return }
                    var searchRange = layer.startIndex..<layer.endIndex
                    while hits.count < maxSearchHits, let found = layer.range(of: query, options: [.caseInsensitive, .widthInsensitive], range: searchRange) {
                        let lower = layer.index(found.lowerBound, offsetBy: -60, limitedBy: layer.startIndex) ?? layer.startIndex
                        let upper = layer.index(found.upperBound, offsetBy: 60, limitedBy: layer.endIndex) ?? layer.endIndex
                        hits.append(["page": index + 1, "snippet": String(layer[lower..<upper]).replacingOccurrences(of: "\n", with: " ")])
                        searchRange = found.upperBound..<layer.endIndex
                    }
                }
            }
            var result: JSONObject = ["query": query, "hits": hits]
            if hits.count >= maxSearchHits { result["note"] = "Only the first \(maxSearchHits) hits are listed." }
            if withoutText > 0 { result["pages_without_text_layer"] = withoutText; result["note_ocr"] = "Pages without a text layer were not searched; read them with operation=text." }
            return Reply(success: true, items: [text(json(result))])
        default:
            throw DocumentToolError("Unknown operation \(operation). Use info, text, render or search.")
        }
    }

    // MARK: - Image

    private static func image(_ operation: String, url: URL, path: String, arguments: JSONObject) async throws -> Reply {
        guard let info = DocumentReader.imageInfo(url), DocumentReader.imageDecodes(url) else {
            throw DocumentToolError("\(path) could not be decoded as an image.")
        }
        switch operation {
        case "info":
            let parts = DocumentReader.imagePartCount(width: info.width, height: info.height)
            return Reply(success: true, items: [text(json([
                "path": path, "type": "image", "format": info.type.preferredFilenameExtension ?? info.type.identifier,
                "width_px": info.width, "height_px": info.height, "frames": info.frames, "image_parts": parts,
            ]))])
        case "text", "search":
            guard let rendered = DocumentReader.imageParts(url) else { throw DocumentToolError("\(path) could not be decoded as an image.") }
            var recognized: [String] = []
            for (_, image) in rendered.images { recognized.append(await DocumentReader.recognizeText(image)) }
            let body = recognized.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if operation == "search" {
                guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                    throw DocumentToolError("Missing `query`.")
                }
                let lines = body.split(separator: "\n").filter { $0.range(of: query, options: [.caseInsensitive, .widthInsensitive]) != nil }
                return Reply(success: true, items: [text(json(["query": query, "matching_ocr_lines": lines.prefix(maxSearchHits).map(String.init), "note": "Searched on-device OCR text of the image."]))])
            }
            return Reply(success: true, items: [text(truncated("--- \(path) (recognized by on-device OCR, may contain errors) ---\n"
                + (body.isEmpty ? "(no text recognized — use render to look)" : body)))])
        case "render":
            let crop = DocumentReader.normalizedCrop(numbers(arguments["crop"]))
            let total = DocumentReader.imagePartCount(width: info.width, height: info.height, crop: crop)
            let parts: Set<Int>
            if let wanted = (arguments["part"] as? NSNumber)?.intValue {
                guard (1...total).contains(wanted) else { throw DocumentToolError("This image has \(total) part(s); `part` must be 1-\(total).") }
                parts = [wanted - 1]
            } else {
                parts = Set(0..<min(total, maxRenderImages))
            }
            guard let rendered = DocumentReader.imageParts(url, parts: parts, crop: crop) else { throw DocumentToolError("\(path) could not be decoded as an image.") }
            var items: [JSONObject] = []
            for (index, image) in rendered.images {
                guard let jpeg = DocumentReader.jpeg(image) else { continue }
                items.append(text("\(path)" + (rendered.count > 1 ? ", part \(index + 1) of \(rendered.count)" : "") + (crop == nil ? "" : ", cropped")))
                items.append(["type": "inputImage", "imageUrl": "data:image/jpeg;base64," + jpeg.base64EncodedString()])
            }
            if rendered.count > parts.count, parts.count > 1 || (arguments["part"] == nil) {
                items.append(text("The image has \(rendered.count) parts; call render with `part` for the others."))
            }
            return Reply(success: true, items: items)
        default:
            throw DocumentToolError("Unknown operation \(operation). Use info, text, render or search.")
        }
    }

    // MARK: - Helpers

    /// 作業ディレクトリの中のファイルだけを読む(記号リンクを辿った先も確かめる)。
    static func resolve(_ path: String, root: String) throws -> URL {
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: base))
            .resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else {
            throw DocumentToolError("This operation is not permitted: the path is outside this turn's workspace. Use a path from the inbox manifest.")
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { throw DocumentToolError("\(path) does not exist in the workspace.") }
        return url
    }

    /// "150"・"3-5"・"1,4,7-8" をページ番号の並びにする。
    static func pageList(_ value: Any?, count: Int, limit: Int) throws -> [Int] {
        guard count > 0 else { throw DocumentToolError("The PDF has no pages.") }
        let spec = (value as? String) ?? (value as? NSNumber)?.stringValue ?? "1"
        var pages: [Int] = []
        for piece in spec.split(separator: ",") {
            let bounds = piece.split(separator: "-", maxSplits: 1).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let first = bounds.first ?? nil else { throw DocumentToolError("`pages` must look like \"150\" or \"3-5\".") }
            let last = bounds.count > 1 ? (bounds[1] ?? first) : first
            guard first >= 1, last >= first else { throw DocumentToolError("`pages` must look like \"150\" or \"3-5\".") }
            guard first <= count else { throw DocumentToolError("The PDF has \(count) pages; page \(first) does not exist.") }
            for page in first...min(last, count) where !pages.contains(page) {
                pages.append(page)
                if pages.count == limit { return pages }
            }
        }
        return pages
    }

    static func ranges(_ pages: [Int]) -> String {
        var parts: [String] = []
        var start: Int?, previous: Int?
        for page in pages + [Int.min] {
            if let p = previous, page == p + 1 { previous = page; continue }
            if let s = start, let p = previous { parts.append(s == p ? "\(s)" : "\(s)-\(p)") }
            start = page; previous = page
        }
        return parts.joined(separator: ",")
    }

    private static func numbers(_ value: Any?) -> [Double]? {
        (value as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
    }

    private static func truncated(_ output: String) -> String {
        guard output.count > maxTextCharacters else { return output }
        return String(output.prefix(maxTextCharacters)) + "\n[truncated: ask for fewer pages]"
    }

    private static func text(_ string: String) -> JSONObject { ["type": "inputText", "text": string] }

    private static func json(_ object: JSONObject) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }
}

nonisolated struct DocumentToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// 一度に 1 つの呼び出しだけを処理する(画素を持つのを 1 ページ分に抑える)。
actor DocumentToolGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// タイムラインの答案の写真(2026-10-27 の依頼)。採点・見直しには長い辺 1,092 ピクセルに縮めた写しを付け、
/// 読みきれない時はモデルが `struis.timeline_view_capture` で元の写真(またはその一部)を元の解像度で見る。
/// 元の写真は `captures` にそのまま残す。座標はどれも向き(EXIF)を直した後の画像の上のピクセル。
nonisolated enum TimelineCaptureImage {
    static let toolName = "timeline_view_capture"
    /// 依頼に付ける写真の長い辺。
    static let requestMaxDimension = 1_092
    /// 道具で返す画像の長い辺の上限(今のモデルが高解像度で受け取る大きさ)。
    static let viewMaxDimension = 2_576
    /// 道具で見た画像を残す場所(`captures` の下)。
    static let viewDirectory = "timeline_views"

    static var toolDefinition: JSONObject {
        ["type": "function", "name": toolName,
         "description": "Look at the learner's answer photo at its original resolution. Without region, returns the whole photo; with region, only that part. Region coordinates are pixels on the photo attached to the request.",
         "inputSchema": ["type": "object", "properties": [
            "attempt_id": ["type": "string"],
            "region": ["type": "object", "properties": [
                "x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"],
            ], "required": ["x", "y", "width", "height"], "additionalProperties": false],
         ], "required": ["attempt_id"], "additionalProperties": false]]
    }

    struct ViewError: Error, CustomStringConvertible { let description: String }

    /// 長い辺を `limit` 以下にした大きさ(もともと収まる時はそのまま)。
    static func fitted(width: Int, height: Int, limit: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > limit, longest > 0 else { return (width, height) }
        let scale = Double(limit) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// 依頼に付いた写真の上の範囲を、元の写真の上の範囲に直す。はみ出した分は切り、写真と重ならなければ nil。
    static func originalRect(region: CGRect, width: Int, height: Int) -> CGRect? {
        let shown = fitted(width: width, height: height, limit: requestMaxDimension)
        let sx = Double(width) / Double(shown.width), sy = Double(height) / Double(shown.height)
        let mapped = CGRect(x: region.minX * sx, y: region.minY * sy, width: region.width * sx, height: region.height * sy).standardized
        let rect = mapped.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        return rect
    }

    /// 向きを直した後の大きさ。
    static func orientedSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    /// 向きを直した画像を、長い辺 `maxPixel` で取り出す(元より大きくはしない)。
    static func decode(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// ちょうどその大きさに描き直す(白地。JPEG にするので透明は持たない)。
    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        if image.width == width, image.height == height { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 依頼に付ける写しを作る。長い辺が `limit` を超える時だけ縮めた JPEG にし、収まる時は今までどおり
    /// (`WorkspaceStager.stageModelImage`) にする。
    static func stageReduced(from source: URL, to target: URL, limit: Int) throws {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = orientedSize(image), max(size.width, size.height) > limit else {
            try WorkspaceStager.stageModelImage(from: source, to: target)
            return
        }
        let wanted = fitted(width: size.width, height: size.height, limit: limit)
        guard let decoded = decode(image, maxPixel: max(wanted.width, wanted.height)),
              let reduced = resized(decoded, width: wanted.width, height: wanted.height),
              let jpeg = DocumentReader.jpeg(reduced, quality: 0.85) else {
            try WorkspaceStager.stageModelImage(from: source, to: target)
            return
        }
        try jpeg.write(to: target, options: .atomic)
    }

    struct View {
        let jpeg: Data
        let width: Int
        let height: Int
        /// 元の写真の上で見せた範囲。
        let rect: CGRect
        let originalWidth: Int
        let originalHeight: Int
    }

    /// 元の写真(またはその一部)を元の解像度で取り出す。長い辺が `viewMaxDimension` を超える時だけ縮める。
    static func view(url: URL, region: CGRect?) throws -> View {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = orientedSize(image) else { throw ViewError(description: "The photo could not be decoded.") }
        let whole = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        var rect = whole
        if let region {
            guard let mapped = originalRect(region: region, width: size.width, height: size.height) else {
                throw ViewError(description: "The region is outside the photo. The attached photo is \(fitted(width: size.width, height: size.height, limit: requestMaxDimension).width)×\(fitted(width: size.width, height: size.height, limit: requestMaxDimension).height) px.")
            }
            rect = mapped
        }
        let picture: CGImage
        if rect == whole {
            // 全体なら、デコードの時に縮める(原寸を持たない)。
            guard let decoded = decode(image, maxPixel: min(max(size.width, size.height), viewMaxDimension)) else {
                throw ViewError(description: "The photo could not be decoded.")
            }
            picture = decoded
        } else {
            guard let full = decode(image, maxPixel: max(size.width, size.height)),
                  let cropped = full.cropping(to: rect.applying(CGAffineTransform(scaleX: Double(full.width) / Double(size.width), y: Double(full.height) / Double(size.height))).integral) else {
                throw ViewError(description: "The photo could not be decoded.")
            }
            picture = cropped
        }
        let out = fitted(width: picture.width, height: picture.height, limit: viewMaxDimension)
        guard let final = resized(picture, width: out.width, height: out.height) else { throw ViewError(description: "The photo could not be decoded.") }
        var jpeg = DocumentReader.jpeg(final, quality: 0.85)
        // Claude に渡せる画像は 5 MB まで(`ClaudeRequestTranslator.Options.maxImageBytes`)。
        if let data = jpeg, data.count > 3_500_000 { jpeg = DocumentReader.jpeg(final, quality: 0.6) }
        guard let jpeg else { throw ViewError(description: "The photo could not be encoded.") }
        return View(jpeg: jpeg, width: final.width, height: final.height, rect: rect, originalWidth: size.width, originalHeight: size.height)
    }
}
