import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// 学習者が添えた PDF と画像を、標準 SDK だけで読む(信頼性計画 P3、決定 2)。
/// PDFKit でページ・暗号化・テキスト層・目次、ImageIO/CoreGraphics で原寸をデコードしない縮小と分割、
/// Vision でテキスト層の無いページや写真の文字認識を行う。UIKit を使わず、どのスレッドからでも呼べる。
/// 画素を持つのは 1 ページ(1 枚)分だけにする(`maxDecodePixels`)。
nonisolated enum DocumentReader {
    // MARK: - Model image budget

    /// 分割するときの短い辺の上限(px)。Codex の高精細の枠(長辺 2048px・32px のパッチ 2,500 個)に収まる。
    static let tileShortSide = 1280
    /// 分割した画像どうしの重なり(行が切れても、どちらかの画像で読めるように)。
    static let tileOverlap = 64
    /// 縦長(横長)とみなす縦横比。これを超える画像・ページは、縮めずに分割する。
    static let splitAspect: CGFloat = 2.2
    /// 一度にデコードする画素数の上限(RGBA で約 96MB)。これを超える画像は、ここまで縮めてから分割する。
    static let maxDecodePixels = 24_000_000
    /// PDF を描く解像度(1pt あたりの px)の上限。390pt 幅の Safari のフルページで 1170px。
    static let pdfMaxScale: CGFloat = 3
    /// 切り抜き(`crop`)を拡大して描く時の上限(1pt あたりの px)。
    static let pdfMaxZoomScale: CGFloat = 8

    /// モデルの枠に収まるか(`WorkspaceStager.modelImageFits` と同じ式)。
    static func fitsModelBudget(width: Int, height: Int) -> Bool {
        max(width, height) <= 2048 && ((width + 31) / 32) * ((height + 31) / 32) <= 2500
    }

    /// 縦横比を保って枠に収まる最大の大きさ。`upscale` が偽なら元より大きくしない。
    static func fittedSize(width: CGFloat, height: CGFloat, upscale: Bool = false) -> (Int, Int) {
        guard width > 0, height > 0 else { return (1, 1) }
        var edge = upscale ? 2048 : min(Int(max(width, height).rounded(.down)), 2048)
        while edge > 1 {
            let scale = CGFloat(edge) / max(width, height)
            let w = max(1, Int((width * scale).rounded(.down))), h = max(1, Int((height * scale).rounded(.down)))
            if fitsModelBudget(width: w, height: h) { return (w, h) }
            edge -= 8
        }
        return (1, 1)
    }

    /// 分割の割り付け。`short` は分割後の短い辺(px)、`long` は長い辺の全長(px)。
    /// 返すのは長い辺に沿った各部分の開始位置と長さ。分割しない時は 1 つ。
    static func tileSpans(short: Int, long: Int) -> [(start: Int, length: Int)] {
        let columns = (short + 31) / 32
        let rows = max(1, 2500 / max(1, columns))
        let tile = min(2048, rows * 32)
        guard long > tile else { return [(0, long)] }
        var spans: [(Int, Int)] = []
        var start = 0
        while true {
            let length = min(tile, long - start)
            spans.append((start, length))
            if start + length >= long { break }
            start += tile - tileOverlap
        }
        return spans
    }

    /// 描く大きさと分割。`size` は描く範囲の大きさ(PDF は pt、画像は px)。
    struct Plan {
        /// `size` の単位あたりの px。
        var scale: CGFloat
        var width: Int
        var height: Int
        var vertical: Bool
        var spans: [(start: Int, length: Int)]
        var isSplit: Bool { spans.count > 1 }
    }

    /// 縦横比が `splitAspect` 以下なら 1 枚(枠に収める)。超えるなら短い辺を `tileShortSide`(と `maxScale`)まで保って分割する。
    static func plan(width: CGFloat, height: CGFloat, maxScale: CGFloat, upscale: Bool, capPixels: Bool = false) -> Plan {
        guard width > 0, height > 0 else { return Plan(scale: 1, width: 1, height: 1, vertical: true, spans: [(0, 1)]) }
        let vertical = height >= width
        let longSide = max(width, height), shortSide = min(width, height)
        if longSide / shortSide <= splitAspect {
            var (w, h) = fittedSize(width: width, height: height, upscale: upscale)
            var scale = CGFloat(w) / width
            if scale > maxScale {
                scale = maxScale
                w = max(1, Int((width * scale).rounded(.down)))
                h = max(1, Int((height * scale).rounded(.down)))
            }
            return Plan(scale: scale, width: w, height: h, vertical: vertical, spans: [(0, vertical ? h : w)])
        }
        var scale = min(maxScale, CGFloat(tileShortSide) / shortSide)
        if !upscale { scale = min(scale, 1) }
        // 画像は全体を一度にデコードするので、画素数に上限を付ける(PDF は部分ごとに描くので要らない)。
        if capPixels, width * scale * height * scale > CGFloat(maxDecodePixels) {
            scale = sqrt(CGFloat(maxDecodePixels) / (width * height))
        }
        let w = max(1, Int((width * scale).rounded(.down))), h = max(1, Int((height * scale).rounded(.down)))
        return Plan(scale: scale, width: w, height: h, vertical: vertical, spans: tileSpans(short: min(w, h), long: max(w, h)))
    }

    /// 長い辺に沿った部分 `span` の、画像の中の長方形(左上が原点)。
    static func partRect(_ plan: Plan, _ span: (start: Int, length: Int)) -> CGRect {
        plan.vertical
            ? CGRect(x: 0, y: span.start, width: plan.width, height: span.length)
            : CGRect(x: span.start, y: 0, width: span.length, height: plan.height)
    }

    /// 0〜1 の切り抜き(左上が原点)を、範囲内に収めて返す。小さすぎる・不正なものは nil。
    static func normalizedCrop(_ crop: [Double]?) -> CGRect? {
        guard let crop, crop.count == 4 else { return nil }
        let x0 = max(0, min(1, crop[0])), y0 = max(0, min(1, crop[1])), x1 = max(0, min(1, crop[2])), y1 = max(0, min(1, crop[3]))
        guard x1 - x0 >= 0.02, y1 - y0 >= 0.02 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // MARK: - Kinds

    enum Kind: Equatable {
        case pdf
        case image(UTType)
    }

    /// 中身から形式を決める(拡張子は見ない。拡張子の無い JPEG や、名前だけ .pdf のテキストを正しく扱う)。
    static func sniff(_ url: URL) -> Kind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        if head.range(of: Data("%PDF-".utf8)) != nil { return .pdf }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, let uti = UTType(type),
              uti.conforms(to: .image), CGImageSourceGetCount(source) > 0 else { return nil }
        return .image(uti)
    }

    // MARK: - Images

    struct ImageInfo {
        /// 向き(EXIF)を反映した大きさ。
        let width: Int
        let height: Int
        let type: UTType
        let frames: Int
    }

    static func imageInfo(_ url: URL) -> ImageInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        return ImageInfo(width: rotated ? height : width, height: rotated ? width : height, type: type, frames: CGImageSourceGetCount(source))
    }

    /// 画像が実際にデコードできるか(ヘッダだけの JPEG などを入口で見分ける)。
    static func imageDecodes(_ url: URL) -> Bool {
        autoreleasepool {
            guard let thumbnail = thumbnail(url, maxPixelSize: 64) else { return false }
            return thumbnail.width > 0 && thumbnail.height > 0
        }
    }

    /// 長い辺を `maxPixelSize` に縮めた画像(向きは反映済み)。原寸はデコードしない(ImageIO のサブサンプリング)。
    static func thumbnail(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// 画像を分割する数(デコードせずに大きさだけで決める)。
    static func imagePartCount(width: Int, height: Int, crop: CGRect? = nil) -> Int {
        let region = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return plan(width: CGFloat(width) * region.width, height: CGFloat(height) * region.height, maxScale: 1, upscale: false, capPixels: true).spans.count
    }

    /// 画像を、モデルが読める大きさの画像(縦長・横長は長い辺に沿って分割)にする。
    /// `parts` は 0 始まりの番号(nil なら全部)。`crop` は 0〜1 の切り抜き(左上が原点)。
    static func imageParts(_ url: URL, parts: Set<Int>? = nil, crop: CGRect? = nil) -> (count: Int, images: [(index: Int, image: CGImage)])? {
        guard let info = imageInfo(url) else { return nil }
        let region = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let regionWidth = CGFloat(info.width) * region.width, regionHeight = CGFloat(info.height) * region.height
        let layout = plan(width: regionWidth, height: regionHeight, maxScale: 1, upscale: false, capPixels: true)
        // 画像全体を、切り抜いた範囲が `layout.scale` になる倍率でデコードする(上限 `maxDecodePixels`)。
        var decodeScale = layout.scale
        let full = CGFloat(info.width) * CGFloat(info.height)
        if full * decodeScale * decodeScale > CGFloat(maxDecodePixels) { decodeScale = sqrt(CGFloat(maxDecodePixels) / full) }
        let decodeLong = max(1, Int((CGFloat(max(info.width, info.height)) * decodeScale).rounded(.down)))
        return autoreleasepool {
            guard let decoded = thumbnail(url, maxPixelSize: decodeLong) else { return nil }
            var source = decoded
            if crop != nil {
                let rect = CGRect(
                    x: region.minX * CGFloat(decoded.width), y: region.minY * CGFloat(decoded.height),
                    width: region.width * CGFloat(decoded.width), height: region.height * CGFloat(decoded.height)
                ).integral
                guard let cropped = decoded.cropping(to: rect) else { return nil }
                source = cropped
            }
            // デコードの丸めで大きさがずれるので、実際の画素で割り付け直す。
            let actual = plan(width: CGFloat(source.width), height: CGFloat(source.height), maxScale: 1, upscale: false, capPixels: true)
            var images: [(Int, CGImage)] = []
            for (index, span) in actual.spans.enumerated() where parts?.contains(index) ?? true {
                if !actual.isSplit {
                    if fitsModelBudget(width: source.width, height: source.height) {
                        images.append((index, source))
                    } else if let fitted = scaled(source, to: (actual.width, actual.height)) {
                        images.append((index, fitted))
                    }
                } else if let piece = source.cropping(to: partRect(actual, span)) {
                    images.append((index, piece))
                }
            }
            return (actual.spans.count, images)
        }
    }

    static func scaled(_ image: CGImage, to size: (Int, Int)) -> CGImage? {
        guard let context = bitmapContext(width: size.0, height: size.1) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.0, height: size.1))
        return context.makeImage()
    }

    // MARK: - PDF

    /// ページの見た目の大きさ(pt)。cropBox と回転を反映する。
    static func displaySize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        let quarter = ((page.rotation % 360) + 360) % 360
        return quarter == 90 || quarter == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    private static func pagePlan(_ page: PDFPage, crop: CGRect?) -> (Plan, CGRect) {
        let size = displaySize(page)
        let region = crop.map { CGRect(x: $0.minX * size.width, y: $0.minY * size.height, width: $0.width * size.width, height: $0.height * size.height) }
            ?? CGRect(origin: .zero, size: size)
        return (plan(width: region.width, height: region.height, maxScale: crop == nil ? pdfMaxScale : pdfMaxZoomScale, upscale: true), region)
    }

    /// ページを分割する数(描かずに大きさだけで決める)。
    static func pagePartCount(_ page: PDFPage, crop: CGRect? = nil) -> Int {
        pagePlan(page, crop: crop).0.spans.count
    }

    /// ページを画像にする。縦長・横長のページは、読める解像度のまま長い辺に沿って分割する。
    /// 一度に持つ画素は 1 枚分だけ(各部分を別々に描く)。`parts` は 0 始まりの番号(nil なら全部)。
    /// `crop` は 0〜1 の切り抜き(左上が原点)。細かい文字を拡大して読む時に使う。
    static func renderPage(_ page: PDFPage, parts: Set<Int>? = nil, crop: CGRect? = nil) -> (count: Int, images: [(index: Int, image: CGImage)]) {
        let (layout, region) = pagePlan(page, crop: crop)
        let pageHeight = displaySize(page).height
        var images: [(Int, CGImage)] = []
        for (index, span) in layout.spans.enumerated() where parts?.contains(index) ?? true {
            let image: CGImage? = autoreleasepool {
                let part = layout.isSplit ? partRect(layout, span) : CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
                let width = Int(part.width), height = Int(part.height)
                guard let context = bitmapContext(width: width, height: height) else { return nil }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                // CoreGraphics は左下が原点。ページの (region の左上 + part の左上) を、この画像の左上に合わせる。
                let left = region.minX * layout.scale + part.minX
                let bottom = (pageHeight - region.maxY) * layout.scale + (CGFloat(layout.height) - part.maxY)
                context.translateBy(x: -left, y: -bottom)
                context.scaleBy(x: layout.scale, y: layout.scale)
                context.interpolationQuality = .high
                page.draw(with: .cropBox, to: context)
                return context.makeImage()
            }
            if let image { images.append((index, image)) }
        }
        return (layout.spans.count, images)
    }

    /// 文字の層が無く、描いても一色のページ(白紙)か。
    static func isBlank(_ page: PDFPage) -> Bool {
        if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return autoreleasepool {
            let size = displaySize(page)
            guard size.width > 0, size.height > 0 else { return true }
            let scale = 96 / max(size.width, size.height)
            let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
            guard let context = bitmapContext(width: width, height: height) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
            guard let data = context.data else { return false }
            let pixels = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
            var low: UInt8 = 255, high: UInt8 = 0
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * context.bytesPerRow + x * 4
                    for c in 0..<3 {
                        low = min(low, pixels[offset + c])
                        high = max(high, pixels[offset + c])
                    }
                }
            }
            return Int(high) - Int(low) < 8
        }
    }

    /// ページの文字の層(無ければ nil)。
    static func textLayer(_ page: PDFPage) -> String? {
        guard let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// 目次(しおり)。深さ 3 まで、最大 `limit` 項目。
    static func outline(_ document: PDFDocument, limit: Int = 120) -> [(title: String, page: Int, depth: Int)] {
        guard let root = document.outlineRoot else { return [] }
        var entries: [(String, Int, Int)] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for index in 0..<node.numberOfChildren {
                guard entries.count < limit, let child = node.child(at: index) else { return }
                let page = child.destination?.page.map { document.index(for: $0) + 1 } ?? 0
                entries.append((child.label ?? "", page, depth))
                if depth < 3 { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 1)
        return entries
    }

    // MARK: - Encoding

    static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    }

    static func jpeg(_ image: CGImage, quality: CGFloat = 0.82) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - Text recognition (Vision)

    /// 画像の文字を読む(日本語・英語)。段落・表の構造は `RecognizeDocumentsRequest` で取り、
    /// 何も取れない時は `RecognizeTextRequest` の行にする。
    static func recognizeText(_ image: CGImage) async -> String {
        let languages = [Locale.Language(identifier: "ja-JP"), Locale.Language(identifier: "en-US")]
        var documents = RecognizeDocumentsRequest()
        documents.textRecognitionOptions.recognitionLanguages = languages
        documents.textRecognitionOptions.useLanguageCorrection = true
        if let observations = try? await documents.perform(on: image), let document = observations.first?.document {
            let text = documentText(document)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return collapseBlankLines(text) }
        }
        var request = RecognizeTextRequest()
        request.recognitionLanguages = languages
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let lines = try? await request.perform(on: image) else { return "" }
        return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func documentText(_ document: DocumentObservation.Container) -> String {
        var parts = [document.text.transcript]
        for table in document.tables {
            let rows = table.rows.map { row in "| " + row.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |" }
            if !rows.isEmpty { parts.append("[table]\n" + rows.joined(separator: "\n")) }
        }
        return parts.joined(separator: "\n\n")
    }

    static func collapseBlankLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 書類を撮った写真なら、四隅を検出して書類の部分だけを切り出す(外接する長方形で切る)。
    /// 書類が見つからない・画像のほぼ全体が書類(スクショなど)なら nil。
    static func documentRegion(_ image: CGImage) async -> CGRect? {
        guard let observation = try? await DetectDocumentSegmentationRequest().perform(on: image), observation.confidence > 0.6 else { return nil }
        let points = [observation.topLeft, observation.topRight, observation.bottomLeft, observation.bottomRight]
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              maxX - minX > 0.2, maxY - minY > 0.2, (maxX - minX) * (maxY - minY) < 0.92 else { return nil }
        // Vision の正規化座標は左下が原点。返すのは左上が原点の 0〜1。
        return CGRect(x: minX, y: 1 - maxY, width: maxX - minX, height: maxY - minY)
    }
}
