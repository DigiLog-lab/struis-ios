import CoreGraphics
import Foundation
import UIKit
import OSLog
import Vision

private let regionLog = Logger(subsystem: "com.digiloglab.strius", category: "answer-regions")

/// 撮った答案の、問題ごとの領域(待ち時間の体験 要件 §5.1)。座標は写真に対する 0〜1(左上が原点)。
nonisolated struct WorkbookAnswerRegion: Hashable, Sendable {
    /// 領域の外枠。
    var rect: CGRect
    /// 領域の中の行(ペンがなぞる所)。上から順。
    var lines: [CGRect]
    /// 行頭の問題番号((1)・1.・①・問1 など)。読めなければ nil。
    var label: Int?

    /// 写真全体を 1 つの領域として扱う(領域が検出できない時、§5.1 の 3)。
    static let wholePhoto = WorkbookAnswerRegion(
        rect: CGRect(x: 0.04, y: 0.04, width: 0.92, height: 0.92),
        lines: [0.22, 0.46, 0.70].map { CGRect(x: 0.08, y: $0, width: 0.72, height: 0.06) },
        label: nil
    )
}

/// 端末の Vision で答案の行を見つけ、問題ごとの領域にまとめる。意味は読まない(W2): 使うのは行の位置と、
/// 行頭の問題番号の形だけ。どんな写真でも短く終わるよう画像を縮小し、時間を区切る(超えたら写真全体)。
nonisolated enum WorkbookAnswerRegions {
    /// 一度に扱う領域の上限。これを超える分け方は信用せず、写真全体を 1 つにする。
    static let maxRegions = 12
    /// 1 つの領域でペンがなぞる行の上限(1 行およそ 3 秒)。
    static let maxTracedLines = 4
    /// 検出にかける時間の上限。超えたら写真全体を 1 つの領域にする。
    static let timeout: Duration = .seconds(8)

    private static let cache = RegionCache()

    /// 答案の写真から領域を検出する。同じ答案は 2 回目から覚えた値を返す。
    static func detect(captureID: String, image: UIImage) async -> [WorkbookAnswerRegion] {
        if let cached = await cache.get(captureID) { return cached }
        let started = Date()
        let found = await withTaskGroup(of: [WorkbookAnswerRegion]?.self) { group in
            group.addTask { await recognize(image: image) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        regionLog.info("detected \(found?.count ?? -1, privacy: .public) regions in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")
        guard let found, !found.isEmpty else {
            // 写真全体で代える時は覚えない(次に開いた時にもう一度検出する)。
            return [WorkbookAnswerRegion.wholePhoto]
        }
        await cache.set(captureID, found)
        return found
    }

    private static func recognize(image: UIImage) async -> [WorkbookAnswerRegion] {
        guard let cgImage = downscaled(image, maxSide: 1400) else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                // 高速の認識は手書きの行を拾えないことがある(2026-09-27 確認)。縮小した画像の精密な認識で行と番号を読む。
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["ja-JP", "en-US"]
                request.usesLanguageCorrection = false
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                    return
                }
                let lines: [(rect: CGRect, text: String)] = (request.results ?? []).map { observation in
                    let box = observation.boundingBox
                    let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                    return (rect, observation.topCandidates(1).first?.string ?? "")
                }
                continuation.resume(returning: regions(from: lines))
            }
        }
    }

    /// 向きを正した縮小画像(Vision には上向きで渡す)。
    private static func downscaled(_ image: UIImage, maxSide: CGFloat) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }.cgImage
    }

    // MARK: - まとめ方(純粋な関数。単体テストの対象)

    /// 認識した行(0〜1、左上原点)を、問題ごとの領域にまとめる。
    /// 行頭に問題番号があれば、番号の行から次の番号の行の手前までを 1 つの領域にする。
    /// 番号が無ければ、行と行の間の大きな空きで区切る。行が無ければ空(呼び手が写真全体にする)。
    static func regions(from recognized: [(rect: CGRect, text: String)]) -> [WorkbookAnswerRegion] {
        let lines = mergeLines(recognized.filter { $0.rect.width > 0.01 && $0.rect.height > 0.004 })
        guard !lines.isEmpty else { return [] }
        var groups: [[(rect: CGRect, label: Int?)]] = []
        let labeled = lines.contains { $0.label != nil }
        if labeled {
            for line in lines {
                if line.label != nil || groups.isEmpty {
                    groups.append([line])
                } else {
                    groups[groups.count - 1].append(line)
                }
            }
            // 番号より上の行(名前・日付など)は最初の番号の領域に含めず捨てる。
            if groups.first?.first?.label == nil, groups.count > 1 { groups.removeFirst() }
        } else {
            let heights = lines.map(\.rect.height).sorted()
            let median = heights[heights.count / 2]
            for (index, line) in lines.enumerated() {
                if index == 0 {
                    groups.append([line])
                    continue
                }
                let previous = lines[index - 1].rect
                let gap = line.rect.minY - previous.maxY
                if gap > max(median * 1.4, 0.03) {
                    groups.append([line])
                } else {
                    groups[groups.count - 1].append(line)
                }
            }
        }
        guard groups.count <= maxRegions else { return [] }
        return groups.map { group in
            let union = group.map(\.rect).reduce(group[0].rect) { $0.union($1) }
            let padded = union.insetBy(dx: -0.02, dy: -0.012)
            let clamped = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return WorkbookAnswerRegion(
                rect: clamped, lines: Array(group.map(\.rect).prefix(maxTracedLines)), label: group.first?.label
            )
        }
    }

    /// 同じ高さに並ぶ認識結果を 1 行にまとめ、上から順に並べる。行頭の問題番号も読む。
    private static func mergeLines(_ recognized: [(rect: CGRect, text: String)]) -> [(rect: CGRect, label: Int?)] {
        let sorted = recognized.sorted { $0.rect.midY < $1.rect.midY }
        var lines: [(rect: CGRect, parts: [(rect: CGRect, text: String)])] = []
        for item in sorted {
            if let last = lines.last {
                let overlap = min(last.rect.maxY, item.rect.maxY) - max(last.rect.minY, item.rect.minY)
                if overlap > min(last.rect.height, item.rect.height) * 0.5 {
                    lines[lines.count - 1].rect = last.rect.union(item.rect)
                    lines[lines.count - 1].parts.append(item)
                    continue
                }
            }
            lines.append((item.rect, [item]))
        }
        return lines.map { line in
            let leading = line.parts.min { $0.rect.minX < $1.rect.minX }
            return (line.rect, leading.flatMap { labelNumber($0.text) })
        }
    }

    /// 行頭の問題番号。(1) / （1） / [1] / 1. / 1) / ① / 問1 / Q1。全角数字も読む。
    static func labelNumber(_ raw: String) -> Int? {
        let text = halfWidthDigits(raw).trimmingCharacters(in: .whitespaces)
        guard let first = text.unicodeScalars.first else { return nil }
        if (0x2460...0x2473).contains(first.value) { return Int(first.value - 0x2460) + 1 }
        let patterns = [
            #"^[\(\[（［【]\s*(\d{1,2})\s*[\)\]）］】]"#,
            #"^(?:問|Q|q|No\.?)\s*(\d{1,2})"#,
            #"^(\d{1,2})\s*[\.．\)）、:：]"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text)
            else { continue }
            return Int(text[range])
        }
        return nil
    }

    /// 判定の label から番号を読む(「(2)」「問3」「2」「②」など)。
    static func verdictNumber(_ label: String) -> Int? {
        let text = halfWidthDigits(label).trimmingCharacters(in: .whitespaces)
        if let number = labelNumber(text) { return number }
        if let scalar = text.unicodeScalars.first(where: { (0x2460...0x2473).contains($0.value) }) { return Int(scalar.value - 0x2460) + 1 }
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2})"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }

    private static func halfWidthDigits(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> Character in
            if (0xFF10...0xFF19).contains(scalar.value) { return Character(UnicodeScalar(scalar.value - 0xFF10 + 0x30)!) }
            return Character(scalar)
        })
    }

    /// 判定と領域の対応(判定の添字 → 領域の添字)。判定の label の番号と領域の番号が一致すればそこへ。
    /// 番号で結べない分は、判定の数と領域の数が同じ時だけ順に結ぶ。結べない判定は一覧だけに出す(§5.3 の 3)。
    static func assign(verdictLabels: [String], regions: [WorkbookAnswerRegion]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var used = Set<Int>()
        for (index, label) in verdictLabels.enumerated() {
            guard let number = verdictNumber(label),
                  let region = regions.indices.first(where: { !used.contains($0) && regions[$0].label == number })
            else { continue }
            result[index] = region
            used.insert(region)
        }
        if verdictLabels.count == regions.count {
            let freeRegions = regions.indices.filter { !used.contains($0) }
            let freeVerdicts = verdictLabels.indices.filter { result[$0] == nil }
            // 番号の付いた領域を別の番号の判定に結ばない(読み違いを丸にしない)。
            for (verdict, region) in zip(freeVerdicts, freeRegions) {
                if let label = regions[region].label, let number = verdictNumber(verdictLabels[verdict]), label != number { continue }
                result[verdict] = region
            }
        }
        return result
    }
}

private actor RegionCache {
    private var values: [String: [WorkbookAnswerRegion]] = [:]
    func get(_ key: String) -> [WorkbookAnswerRegion]? { values[key] }
    func set(_ key: String, _ value: [WorkbookAnswerRegion]) { values[key] = value }
}
