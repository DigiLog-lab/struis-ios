import SwiftUI
import SwiftMath
import UIKit

/// 本文と数式を SwiftMath(CoreText)で描く(Issue #28)。数式は画像にして文字の行に埋め込む(行中)か、独立した行に置く(表示用)。
/// 画像はその場で作るので、行の高さはレイアウトの時に決まる。WebView のように「描き終えてから高さが変わる」ことが無く、
/// `ChatTimeline` が高さの変化を補正する必要が無くなる。
///
/// 描き方は `KaTeXMathText`(WebView)と同じに揃える: 文字は `Typography.sans`、数式は本文の 1.08 倍、表示用の数式は左寄せで
/// 横にはみ出したら横スクロール、強調(`**`)は太字、§6 の色は先頭から `highlightCount` 個の数式・強調につける。
struct NativeMathText: View {
    let document: NativeMathDocument
    let foregroundColor: UIColor
    let fontSize: CGFloat
    let fontWeight: Int
    let highlightCount: Int

    @Environment(\.displayScale) private var displayScale
    @State private var width: CGFloat = 0

    var body: some View {
        let style = NativeMathStyle(color: foregroundColor, fontSize: fontSize, fontWeight: fontWeight, scale: displayScale)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(layout(style).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let runs):
                    MathParagraph(runs: runs, style: style, highlightCount: highlightCount, readable: document.readable)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .display(let latex, let mark):
                    MathDisplayRow(latex: latex, style: style, highlighted: mark < highlightCount)
                        .padding(.top, fontSize * 0.42)
                        .padding(.bottom, fontSize * 0.54)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contextMenu {
            Button {
                UIPasteboard.general.string = document.readable
            } label: {
                Label("コピー", systemImage: "doc.on.doc")
            }
        }
        .transaction { $0.animation = nil }
    }

    /// 行中の数式が行の幅より広い時は、表示用の行に昇格させる(横スクロールで読めるように。WebView でも横スクロールだった)。
    /// 幅が分かる前(0)は昇格しない。
    private func layout(_ style: NativeMathStyle) -> [MathTextLayout.Block] {
        guard width > 0 else { return document.blocks }
        var out: [MathTextLayout.Block] = []
        for block in document.blocks {
            guard case .paragraph(let runs) = block else {
                out.append(block)
                continue
            }
            var current: [MathTextLayout.Run] = []
            for run in runs {
                if case .math(let latex, _, let mark) = run,
                   let glyph = NativeMathRenderer.shared.glyph(latex: latex, display: false, style: style, highlighted: false),
                   glyph.size.width > width - 2 {
                    if !current.isEmpty { out.append(.paragraph(current)) }
                    current = []
                    out.append(.display(latex, mark: mark))
                } else {
                    current.append(run)
                }
            }
            if !current.isEmpty { out.append(.paragraph(current)) }
        }
        return out
    }
}

/// 1 つの本文の切り分け結果と、数式の解析が全部通ったかどうか。解析できない数式が 1 つでもあれば `nil`(呼び手が WebView に落とす)。
struct NativeMathDocument: Equatable {
    let blocks: [MathTextLayout.Block]
    /// VoiceOver・コピー用の読める文字。
    let readable: String

    /// 本文の数式を全部 SwiftMath で解析できれば文書を返す。できなければ、落ちた命令を台帳向けの記録に残して `nil`。
    @MainActor
    static func make(_ raw: String, display: Bool) -> NativeMathDocument? {
        let blocks = MathTextLayout.blocks(raw, display: display)
        for block in blocks {
            switch block {
            case .display(let latex, _):
                guard check(latex, raw: raw) else { return nil }
            case .paragraph(let runs):
                for run in runs {
                    if case .math(let latex, _, _) = run, !check(latex, raw: raw) { return nil }
                }
            }
        }
        return NativeMathDocument(blocks: blocks, readable: MathPlainText.readable(raw.replacingOccurrences(of: "\\n", with: "\n")))
    }

    @MainActor
    private static func check(_ latex: String, raw: String) -> Bool {
        switch NativeMathRenderer.shared.parse(latex) {
        case .success:
            return true
        case .failure(let error):
            MathRenderDiagnostics.shared.recordFallback(latex: latex, reason: error.localizedDescription, source: raw)
            return false
        }
    }
}

/// 数式の描き方(色・大きさ・画面の倍率)。
struct NativeMathStyle: Hashable {
    let color: UIColor
    let fontSize: CGFloat
    let fontWeight: Int
    let scale: CGFloat

    /// 本文の書体(`Typography.sans` と同じ、Dynamic Type の倍率込み)。
    var textFont: UIFont { Typography.sansUIFont(size: fontSize, weight: fontWeight >= 500 ? .medium : .regular) }
    var boldFont: UIFont { Typography.sansUIFont(size: fontSize, weight: .bold) }
    /// 数式の大きさ。KaTeX は本文の 1.08 倍で描いていた。Dynamic Type の倍率は本文と同じにする。
    var mathSize: CGFloat { fontSize * 1.08 * textFont.pointSize / fontSize }
    var highlightColor: UIColor { UIColor(Theme.accentColor).withAlphaComponent(0.24) }

    func hash(into hasher: inout Hasher) {
        hasher.combine(color.hexString)
        hasher.combine(fontSize)
        hasher.combine(fontWeight)
        hasher.combine(scale)
    }

    static func == (lhs: NativeMathStyle, rhs: NativeMathStyle) -> Bool {
        lhs.color.hexString == rhs.color.hexString && lhs.fontSize == rhs.fontSize && lhs.fontWeight == rhs.fontWeight && lhs.scale == rhs.scale
    }
}

/// 描いた数式の画像。`baseline` は画像の下端から文字の基線までの距離(行中に置く時の下げ幅)。
struct NativeMathGlyph {
    let image: UIImage
    let size: CGSize
    let baseline: CGFloat
}

/// 数式の解析と描画。解析は SwiftMath、描画は `MTMathImage`(CoreText)。同じ数式・大きさ・色の画像は使い回す。
@MainActor
final class NativeMathRenderer {
    static let shared = NativeMathRenderer()

    struct ParseError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class Box {
        let glyph: NativeMathGlyph
        init(_ glyph: NativeMathGlyph) { self.glyph = glyph }
    }

    private let images: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private var parsed: [String: Result<Void, ParseError>] = [:]
    private var fonts: [CGFloat: MTFont] = [:]
    private let measurer = MTMathUILabel()

    private init() {
        measurer.displayErrorInline = false
    }

    /// SwiftMath で解析できるか。結果は本文ごとに覚える(解析は描く前に毎回呼ばれる)。
    func parse(_ latex: String) -> Result<Void, ParseError> {
        let prepared = MathSourceNormalizer.prepare(latex)
        if let known = parsed[prepared] { return known }
        var error: NSError?
        let list = MTMathListBuilder.build(fromString: prepared, error: &error)
        let result: Result<Void, ParseError>
        if let error {
            result = .failure(ParseError(message: error.localizedDescription))
        } else if list == nil {
            result = .failure(ParseError(message: "解析できない"))
        } else {
            result = .success(())
        }
        if parsed.count > 2_000 { parsed.removeAll() }
        parsed[prepared] = result
        return result
    }

    /// 数式の画像。解析できない数式は `nil`(呼び手は先に `parse` で確かめている)。
    func glyph(latex: String, display: Bool, style: NativeMathStyle, highlighted: Bool) -> NativeMathGlyph? {
        let prepared = MathSourceNormalizer.prepare(latex)
        let key = [prepared, String(display), String(describing: style.mathSize), style.color.hexString, String(describing: style.scale), String(highlighted)]
            .joined(separator: "\u{1F}") as NSString
        if let box = images.object(forKey: key) { return box.glyph }
        guard case .success = parse(latex), let font = font(size: style.mathSize) else { return nil }
        // 先に大きさを測る。空の数式(`\,` だけなど)は描かず、1pt の空白にする(0 の大きさの画像は作れない)。
        measurer.font = font
        measurer.labelMode = display ? .display : .text
        measurer.latex = prepared
        let fitted = measurer.sizeThatFits(.zero)
        measurer.frame = CGRect(origin: .zero, size: fitted)
        measurer.layoutSubviews()
        guard let list = measurer.displayList, list.width >= 0.5, list.ascent + list.descent >= 0.5 else {
            return NativeMathGlyph(image: UIImage(), size: CGSize(width: 1, height: 1), baseline: 0)
        }
        // `MTMathImage` は画像の高さを ascent + descent にし、基線を下端から descent の所に置く。ただし高さが fontSize/2 未満の
        // 数式(`-`、`\ldots` など)は fontSize/2 の中央に寄せるので、そのままだと下にはみ出して描かれない(CI で `\ldots` が空になった)。
        // 下の余白をその分だけ足して全部を画像の中に入れる。左右 1pt は斜体のはみ出し分。基線は常に下端から descent + 1。
        let height = list.ascent + list.descent
        let shift = max(0, (style.mathSize / 2 - height) / 2)
        let renderer = MTMathImage(latex: prepared, fontSize: style.mathSize, textColor: style.color, labelMode: display ? .display : .text, textAlignment: .left)
        renderer.font = font
        renderer.contentInsets = MTEdgeInsets(top: 1, left: 1, bottom: shift + 1, right: 1)
        let (error, rendered) = renderer.asImage()
        guard error == nil, let rendered, rendered.size.width >= 1, rendered.size.height >= 1 else { return nil }
        let baseline = list.descent + 1
        let image = highlighted ? Self.withHighlight(rendered, color: style.highlightColor, scale: rendered.scale) : rendered
        let glyph = NativeMathGlyph(image: image, size: image.size, baseline: baseline)
        images.setObject(Box(glyph), forKey: key, cost: Int(image.size.width * image.scale * image.size.height * image.scale * 4))
        return glyph
    }

    private func font(size: CGFloat) -> MTFont? {
        if let font = fonts[size] { return font }
        let font = MTFontManager.manager.latinModernFont(withSize: size)
        fonts[size] = font
        return font
    }

    /// §6 の色: 数式の後ろに角の丸い面を敷く(WebView の `.struis-hl` と同じ色・角)。
    private static func withHighlight(_ image: UIImage, color: UIColor, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: image.size).insetBy(dx: -1, dy: -1), cornerRadius: 5).fill()
            image.draw(at: .zero)
        }
    }

    /// サインアウトの時: 学習者の会話の中身(数式の画像)を捨てる。
    func removeAll() {
        images.removeAllObjects()
        parsed.removeAll()
    }
}

/// 段落(文字と行中の数式)。`UILabel` に `NSAttributedString` で入れる。数式は `NSTextAttachment` の画像で、基線を文字に合わせる。
/// 高さは `sizeThatFits` でレイアウトの時に決まる。
private struct MathParagraph: UIViewRepresentable {
    let runs: [MathTextLayout.Run]
    let style: NativeMathStyle
    let highlightCount: Int
    let readable: String

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.adjustsFontForContentSizeCategory = true
        label.backgroundColor = .clear
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = "math-text"
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.attributedText = attributed()
        label.accessibilityLabel = readable
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        var width = label.window?.screen.bounds.width ?? 390
        if let proposed = proposal.width, proposed.isFinite, proposed > 0 { width = proposed }
        label.preferredMaxLayoutWidth = width
        let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height))
    }

    private func attributed() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.fontSize * 0.25
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSMutableAttributedString()
        for run in runs {
            switch run {
            case .text(let string, let bold, let mark):
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: bold ? style.boldFont : style.textFont,
                    .foregroundColor: style.color,
                    .paragraphStyle: paragraph,
                ]
                if let mark, mark < highlightCount { attributes[.backgroundColor] = style.highlightColor }
                text.append(NSAttributedString(string: string, attributes: attributes))
            case .math(let latex, let strongMark, let mark):
                let highlighted = mark < highlightCount || (strongMark.map { $0 < highlightCount } ?? false)
                guard let glyph = NativeMathRenderer.shared.glyph(latex: latex, display: false, style: style, highlighted: highlighted) else {
                    // 解析は通っているはずなので来ない。来たら読める文字で出す(空にしない)。
                    text.append(NSAttributedString(string: MathPlainText.convert(latex), attributes: [.font: style.textFont, .foregroundColor: style.color, .paragraphStyle: paragraph]))
                    continue
                }
                let attachment = NSTextAttachment()
                attachment.image = glyph.image
                attachment.bounds = CGRect(x: 0, y: -glyph.baseline, width: glyph.size.width, height: glyph.size.height)
                let piece = NSMutableAttributedString(attachment: attachment)
                piece.addAttributes([.font: style.textFont, .paragraphStyle: paragraph], range: NSRange(location: 0, length: piece.length))
                text.append(piece)
            }
        }
        return text
    }
}

/// 表示用の数式の行。左寄せ。行の幅より広ければ横スクロールにし、右端を薄くして続きがあることを示す(D5)。
/// UIKit(`UIScrollView` + `UIImageView`)で描く: SwiftUI の `Image` は識別子を付けても UI テストの要素にならなかった(CI 2 回)。
/// 高さは画像の高さで、`sizeThatFits` でレイアウトの時に決まる。
private struct MathDisplayRow: View {
    let latex: String
    let style: NativeMathStyle
    let highlighted: Bool

    var body: some View {
        if let glyph = NativeMathRenderer.shared.glyph(latex: latex, display: true, style: style, highlighted: highlighted) {
            MathDisplayView(glyph: glyph, readable: MathPlainText.convert(latex))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("math-display")
        } else {
            Text(MathPlainText.convert(latex))
                .font(Typography.sans(size: style.fontSize, weight: .medium))
                .foregroundStyle(Color(style.color))
        }
    }
}

private struct MathDisplayView: UIViewRepresentable {
    let glyph: NativeMathGlyph
    let readable: String

    func makeUIView(context: Context) -> MathDisplayScrollView {
        let view = MathDisplayScrollView()
        // 1 つの要素として見せる。識別子は吹き出しの `assistant-message-…` に上書きされる(SwiftUI は親の identifier を子に広げる)ので、
        // UI テストは要素の型(scrollView)で見つける。staticText の trait は付けない(付けると型が staticText になる)。
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "math-display"
        return view
    }

    func updateUIView(_ view: MathDisplayScrollView, context: Context) {
        view.imageView.image = glyph.image
        view.imageSize = glyph.size
        view.accessibilityLabel = readable
        view.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: MathDisplayScrollView, context: Context) -> CGSize? {
        var width = glyph.size.width
        if let proposed = proposal.width, proposed.isFinite, proposed > 0 { width = min(width, proposed) }
        return CGSize(width: width, height: glyph.size.height)
    }
}

/// 横にはみ出した数式を横に動かす枠。はみ出している間は右端を薄くする(端まで送ったら薄くしない)。
final class MathDisplayScrollView: UIScrollView {
    let imageView = UIImageView()
    var imageSize: CGSize = .zero
    private let fade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.black.withAlphaComponent(0.15).cgColor]
        fade.locations = [0, 0.9, 1]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = CGRect(origin: .zero, size: imageSize)
        let overflowing = imageSize.width > bounds.width + 1
        contentSize = CGSize(width: overflowing ? imageSize.width + 24 : bounds.width, height: imageSize.height)
        isScrollEnabled = overflowing
        updateFade()
    }

    override var contentOffset: CGPoint {
        didSet { updateFade() }
    }

    private func updateFade() {
        let more = imageSize.width > bounds.width + 1 && contentOffset.x + bounds.width < imageSize.width - 1
        if more {
            fade.frame = bounds
            layer.mask = fade
        } else {
            layer.mask = nil
        }
    }
}

/// SwiftMath で描けなかった数式の記録。台帳の書き出し(zip)に `diagnostics/math_fallback.jsonl` として入る。
/// 1 行 = 1 回の退避(同じ数式は 1 度だけ)。どの命令で落ちたかを見て、置き換え(`MathSourceNormalizer`)か SwiftMath 側の対応を足す。
@MainActor
final class MathRenderDiagnostics {
    static let shared = MathRenderDiagnostics()
    static let directory = StruisPaths.root.appendingPathComponent("diagnostics", isDirectory: true)
    static let file = directory.appendingPathComponent("math_fallback.jsonl")

    private var seen: Set<String> = []
    private(set) var count = 0

    func recordFallback(latex: String, reason: String, source: String) {
        guard seen.insert(latex).inserted else { return }
        count += 1
        let commands = Array(Set(MathSourceNormalizer.commandNames(in: latex))).sorted()
        let environments = Array(Set(MathSourceNormalizer.environmentNames(in: latex))).sorted()
        let record: [String: Any] = [
            "at": LedgerClock.now(), "latex": String(latex.prefix(400)), "reason": reason,
            "commands": commands, "environments": environments, "source_head": String(source.prefix(120)),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        let line = data + Data("\n".utf8)
        let file = Self.file
        let directory = Self.directory
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: file, options: .atomic)
            }
        }
    }
}
