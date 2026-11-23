import Foundation
import Testing
import UIKit
@testable import strius

/// 数式の描画(Issue #28): SwiftMath で描ける数式の一覧(`Fixtures/math/formulas.json`)、KaTeX 向けの書き方の置き換え、
/// 本文の切り分け、画像の大きさと基線、描けない数式の退避と記録。
private struct MathFixture: Decodable, Sendable {
    let latex: String
    let display: Bool
    let source: String
    let expect: String
}

private struct MathFixtureFile: Decodable, Sendable {
    let items: [MathFixture]
}

@Suite(.serialized) @MainActor
struct MathRenderingTests {
    private func fixtures() throws -> [MathFixture] {
        let url = try #require(Bundle(for: EngineVectorBundleMarker.self).url(forResource: "formulas", withExtension: "json", subdirectory: "math"))
        return try JSONDecoder().decode(MathFixtureFile.self, from: Data(contentsOf: url)).items
    }

    // MARK: - 一覧の数式

    @Test func everyFixtureFormulaParsesWithSwiftMathUnlessMarkedFallback() throws {
        let items = try fixtures()
        #expect(items.count >= 260)
        var unexpected: [String] = []
        for item in items {
            let parses: Bool
            if case .success = NativeMathRenderer.shared.parse(item.latex) { parses = true } else { parses = false }
            if parses != (item.expect == "native") {
                unexpected.append("\(item.expect) [\(item.source)] \(item.latex)")
            }
        }
        #expect(unexpected.isEmpty, Comment(rawValue: "期待と違う: " + unexpected.joined(separator: "\n")))
    }

    @Test func everyNativeFixtureFormulaRendersToANonEmptyImage() throws {
        let style = NativeMathStyle(color: .black, fontSize: 15, fontWeight: 500, scale: 2)
        var empty: [String] = []
        for item in try fixtures() where item.expect == "native" {
            guard let glyph = NativeMathRenderer.shared.glyph(latex: item.latex, display: item.display, style: style, highlighted: false) else {
                empty.append("nil: " + item.latex)
                continue
            }
            // 空白だけの数式(`\,`、`\quad`)は 1pt の空白になる。それ以外は何か描かれている。
            let spacer = glyph.size == CGSize(width: 1, height: 1)
            let onlySpacing = item.latex.allSatisfy { "\\,;! ".contains($0) } || ["\\quad", "\\qquad", "\\ "].contains(item.latex)
            if onlySpacing { continue }
            if spacer || !KaTeXSnapshotStore.hasInk(glyph.image) {
                empty.append((spacer ? "spacer: " : "empty: ") + item.latex)
            }
        }
        #expect(empty.isEmpty, Comment(rawValue: empty.joined(separator: "\n")))
    }

    // MARK: - 置き換え

    @Test func kaTeXOnlyNotationIsRewrittenForSwiftMath() {
        #expect(MathSourceNormalizer.prepare("\\dots") == "\\ldots")
        #expect(MathSourceNormalizer.prepare("\\begin{align}x&=1\\\\y&=2\\end{align}") == "\\begin{aligned}x&=1\\\\y&=2\\end{aligned}")
        #expect(MathSourceNormalizer.prepare("x\\\\[4pt]y") == "x\\\\y")
        #expect(MathSourceNormalizer.prepare("\\begin{equation}E=mc^2\\end{equation}") == "E=mc^2")
        #expect(MathSourceNormalizer.prepare("\\tag{1}x=1") == "x=1")
        #expect(MathSourceNormalizer.prepare("\\therefore x=1") == "\\text{∴} x=1")
        #expect(MathSourceNormalizer.prepare("\\log_{10}2\\fallingdotseq 0.3010") == "\\log_{10}\\,2\\text{≒} 0.3010")
        #expect(MathSourceNormalizer.prepare("\\not\\in") == "\\notin ")
        #expect(MathSourceNormalizer.prepare("a\\ ") == "a\\ ")
    }

    /// SwiftMath は関数名と文字の間を詰める(実機で「sin3x」「3xcosx」)。TeX と同じ所にだけ細い空きを入れる。
    @Test func operatorNamesGetTeXSpacing() {
        #expect(MathSourceNormalizer.prepare("\\sin 3x") == "\\sin\\, 3x")
        #expect(MathSourceNormalizer.prepare("\\sin 3x\\cos x") == "\\sin\\, 3x\\,\\cos\\, x")
        #expect(MathSourceNormalizer.prepare("\\int_0^{\\pi/2} \\sin 3x\\,dx") == "\\int_0^{\\pi/2}\\, \\sin\\, 3x\\,dx")
        #expect(MathSourceNormalizer.prepare("\\frac{d}{dx}\\cos x") == "\\frac{d}{dx}\\,\\cos\\, x")
        #expect(MathSourceNormalizer.prepare("\\sin^2 x+\\cos^2 x=1") == "\\sin^2\\, x+\\cos^2\\, x=1")
        #expect(MathSourceNormalizer.prepare("2\\sin x") == "2\\,\\sin\\, x")
        // 括弧・演算子・関係の記号の隣と、すでに空きがある所には入れない。
        #expect(MathSourceNormalizer.prepare("\\sin(x)") == "\\sin(x)")
        #expect(MathSourceNormalizer.prepare("-\\sin x") == "-\\sin\\, x")
        #expect(MathSourceNormalizer.prepare("(\\sin x)") == "(\\sin\\, x)")
        #expect(MathSourceNormalizer.prepare("a\\cdot\\sin x") == "a\\cdot\\sin\\, x")
        #expect(MathSourceNormalizer.prepare("\\sin\\left(x\\right)") == "\\sin\\left(x\\right)")
        #expect(MathSourceNormalizer.prepare("\\max\\{a,b\\}") == "\\max\\{a,b\\}")
        #expect(MathSourceNormalizer.prepare("\\text{sin x}") == "\\text{sin x}")
        #expect(MathSourceNormalizer.prepare("\\begin{aligned}\\sin x&=1\\end{aligned}") == "\\begin{aligned}\\sin\\, x&=1\\end{aligned}")
        // 何度通しても同じ。
        let once = MathSourceNormalizer.prepare("\\int \\cos 2x\\,dx,\\quad \\int \\sin 2x\\,dx")
        #expect(once == "\\int\\, \\cos\\, 2x\\,dx,\\quad \\int\\, \\sin\\, 2x\\,dx")
        #expect(MathSourceNormalizer.prepare(once) == once)
    }

    @Test func charactersOutsideASCIIBecomeCommandsOrText() {
        #expect(MathSourceNormalizer.prepare("x=3 のとき y=5") == "x=3 \\text{のとき} y=5")
        #expect(MathSourceNormalizer.prepare("\\mathrm{日本語}x") == "\\text{日本語}x")
        #expect(MathSourceNormalizer.prepare("\\text{面積}=\\frac{1}{2}") == "\\text{面積}=\\frac{1}{2}")
        #expect(MathSourceNormalizer.prepare("α+β=-\\frac{b}{a}") == "\\alpha +\\beta =-\\frac{b}{a}")
        #expect(MathSourceNormalizer.prepare("∠A=60°") == "\\angle A=60^\\circ ")
        #expect(MathSourceNormalizer.prepare("x²+y₁") == "x^{2}+y_{1}")
        #expect(MathSourceNormalizer.prepare("a ≠ b") == "a \\ne  b")
        #expect(MathSourceNormalizer.prepare("x≒3.14") == "x\\text{≒}3.14")
    }

    @Test func factorialAndNegativeComparisonAreNotTurnedIntoArrows() {
        #expect(MathSourceNormalizer.prepare("n!=n(n-1)!") == "n!=n(n-1)!")
        #expect(MathSourceNormalizer.prepare("a != b") == "a \\ne  b")
        #expect(MathSourceNormalizer.prepare("x<-1") == "x<-1")
        #expect(MathSourceNormalizer.prepare("a <- b") == "a \\leftarrow  b")
        #expect(MathSourceNormalizer.prepare("\\\\frac{1}{2}") == "\\frac{1}{2}")
    }

    // MARK: - 切り分け

    @Test func textIsSplitIntoParagraphsInlineMathAndDisplayRows() {
        let blocks = MathTextLayout.blocks("式 $x^2$ と **強調 $a$ 太字**\n$$\\int_0^1 x\\,dx$$\n次の行", display: false)
        #expect(blocks == [
            .paragraph([
                .text("式 ", bold: false, mark: nil),
                .math("x^2", strongMark: nil, mark: 0),
                .text(" と ", bold: false, mark: nil),
                .text("強調 ", bold: true, mark: 1),
                .math("a", strongMark: 1, mark: 2),
                .text(" 太字", bold: true, mark: 1),
            ]),
            .display("\\int_0^1 x\\,dx", mark: 3),
            .paragraph([.text("次の行", bold: false, mark: nil)]),
        ])
    }

    @Test func markNumberingMatchesStruisMarkedSpans() {
        let source = "要点: $a+b$ は **和**、\\(a-b\\) は **差** で $$c$$ が積"
        let spans = StruisMarkedSpans.spans(source)
        var marks: [Int] = []
        for block in MathTextLayout.blocks(source, display: false) {
            switch block {
            case .display(_, let mark): marks.append(mark)
            case .paragraph(let runs):
                for run in runs {
                    switch run {
                    case .math(_, _, let mark): marks.append(mark)
                    case .text(_, true, let mark?): if !marks.contains(mark) { marks.append(mark) }
                    default: break
                    }
                }
            }
        }
        #expect(marks == Array(0..<spans.count))
    }

    @Test func pureMathDisplayBodyIsOneDisplayRow() {
        #expect(MathTextLayout.blocks("\\frac{1}{2}x^2", display: true) == [.display("\\frac{1}{2}x^2", mark: 0)])
        #expect(MathTextLayout.blocks("面積は $S$", display: true).count == 1)
        #expect(MathTextLayout.blocks("", display: false).isEmpty)
        #expect(MathTextLayout.blocks("$ $ だけ", display: false) == [.paragraph([.text(" だけ", bold: false, mark: nil)])])
    }

    /// 実 AI の続きのカードで `y=-\colorbox{#E9C8A6}{}^2-2` が文字のまま出た式。
    @Test func chainHighlightIsOneFormulaForKaTeX() {
        let cases: [(latex: String, changed: String)] = [("y=-(x+4)^2-2", "(x+4)"), ("y=x^2+6x+5", "x^2+6x+5"), ("y=\\frac{1}{2}x+1", "\\frac{1}{2}x")]
        for item: (latex: String, changed: String) in cases {
            let marked: String = item.latex.replacingOccurrences(of: item.changed, with: "\\colorbox{#E9C8A6}{$\\color{#1F1A17}{" + item.changed + "}$}")
            let highlighted: String = TimelineMath.highlighting(item.latex, changed: item.changed)
            #expect(highlighted == "$$" + marked + "$$")
            #expect(MathTextLayout.blocks(highlighted, display: true) == [.display(marked, mark: 0)])
            #expect(NativeMathDocument.make(highlighted, display: true) == nil)
            // WebView を待つ間の式(元の式)は SwiftMath で描ける。読み上げの文字に色の命令が混ざらない。
            #expect(NativeMathDocument.make(item.latex, display: true) != nil)
            #expect(MathPlainText.readable(highlighted) == MathPlainText.readable("$$" + item.latex + "$$"))
        }
    }

    /// SwiftMath は色の命令を中身ごと捨てる。式の一部が黙って消えないように KaTeX に回す。
    @Test func colorCommandsAreLeftToKaTeX() {
        for latex: String in ["a+\\color{red}{b}", "a+\\textcolor{red}{b}", "a+\\colorbox{#E9C8A6}{b}"] {
            #expect(NativeMathDocument.make("$" + latex + "$", display: false) == nil)
        }
        #expect(NativeMathDocument.make("$a+b$", display: false) != nil)
    }

    @Test func chainHighlightLeavesFormulaUnchangedWhenItCannotApply() {
        #expect(TimelineMath.highlighting("y=x^2", changed: nil) == "y=x^2")
        #expect(TimelineMath.highlighting("y=x^2", changed: "z") == "y=x^2")
        // `\pi` の途中を変えた所にすると、命令が壊れて SwiftMath で組めない。
        #expect(TimelineMath.highlighting("y=\\pi", changed: "i") == "y=\\pi")
    }

    // MARK: - 画像

    @Test func inlineGlyphCarriesABaselineAndDisplayGlyphIsTaller() throws {
        let style = NativeMathStyle(color: .black, fontSize: 15, fontWeight: 500, scale: 2)
        let inline = try #require(NativeMathRenderer.shared.glyph(latex: "\\frac{1}{2}", display: false, style: style, highlighted: false))
        let display = try #require(NativeMathRenderer.shared.glyph(latex: "\\frac{1}{2}", display: true, style: style, highlighted: false))
        #expect(inline.baseline > 0)
        #expect(inline.baseline < inline.size.height)
        #expect(display.size.height > inline.size.height)
        let highlighted = try #require(NativeMathRenderer.shared.glyph(latex: "x", display: false, style: style, highlighted: true))
        let plain = try #require(NativeMathRenderer.shared.glyph(latex: "x", display: false, style: style, highlighted: false))
        #expect(highlighted.size == plain.size)
    }

    /// 長い行中の式も、折り返さずに測った基線で文字に揃える。測る枠を式の幅ちょうどにしていた時は、SwiftMath が積分の式を
    /// 2 行に折り返して測り、基線が約 19pt 下にずれて後ろの「、」が式の上に浮いた(2026-11-19)。式の一番下は積分の下端の
    /// `-\pi` なので、積分だけの式と基線が同じになる。
    @Test func longInlineFormulaKeepsTheBaselineOfItsLowestPart() throws {
        let style = NativeMathStyle(color: .black, fontSize: 20, fontWeight: 700, scale: 2)
        let long = try #require(NativeMathRenderer.shared.glyph(
            latex: "\\int_{-\\pi}^{\\pi}\\sin mx\\sin nx\\,dx=\\pi\\ (m=n)", display: false, style: style, highlighted: false))
        let integral = try #require(NativeMathRenderer.shared.glyph(latex: "\\int_{-\\pi}^{\\pi}", display: false, style: style, highlighted: false))
        #expect(abs(long.baseline - integral.baseline) < 0.5, "長い式 \(long.baseline) / 積分だけ \(integral.baseline)")
        #expect(abs(long.size.height - integral.size.height) < 0.5)
    }

    @Test func sameFormulaIsRenderedOnceAndReused() throws {
        let style = NativeMathStyle(color: .black, fontSize: 15, fontWeight: 500, scale: 2)
        let first = try #require(NativeMathRenderer.shared.glyph(latex: "\\sqrt{2}", display: false, style: style, highlighted: false))
        let second = try #require(NativeMathRenderer.shared.glyph(latex: "\\sqrt{2}", display: false, style: style, highlighted: false))
        #expect(first.image === second.image)
    }

    // MARK: - 退避

    @Test func unsupportedCommandFallsBackToWebViewAndIsRecorded() throws {
        let before = MathRenderDiagnostics.shared.count
        let token = UUID().uuidString.prefix(6)
        #expect(NativeMathDocument.make("答えは $\\boxed{\(token)}$ です", display: false) == nil)
        #expect(MathRenderDiagnostics.shared.count == before + 1)
        // 同じ数式は 1 度だけ。
        #expect(NativeMathDocument.make("答えは $\\boxed{\(token)}$ です", display: false) == nil)
        #expect(MathRenderDiagnostics.shared.count == before + 1)
        #expect(NativeMathDocument.make("答えは $x=\(token)$ です", display: false) != nil)
        #expect(NativeMathDocument.make("$\\frac{1}{$", display: false) == nil)
    }

    @Test func diagnosticsAreExportedWithTheLedger() {
        #expect(LedgerArchive.fileRoots.contains("diagnostics"))
        #expect(MathRenderDiagnostics.file.lastPathComponent == "math_fallback.jsonl")
        #expect(MathRenderDiagnostics.directory.path.hasPrefix(StruisPaths.root.path))
    }

    /// オンボーディングの計画の説明文(日本語の文の中に `$…$` の式。2026-11-11 に実際の応答で出た形)は、数式として組める。
    @Test func aPlanLeadWithInlineDollarMathIsDrawnAsMath() {
        let lead: String = "お試しの1問で、$x+1=5$ から $x$ を求める最後の計算につまずいていたので、底を $2$ にそろえる練習から始めます。"
        let source: String = TimelineRichText.source(lead)
        #expect(source == lead)
        #expect(NativeMathDocument.make(source, display: false) != nil)
    }

    /// 答えの欄は、画面に出すほかの文と同じく `$…$` で囲んだ文で来る(2026-11-23 から)。区切りを足したり切ったりせず、そのまま組む。
    @Test func anAnswerWrittenLikeAWorkbookIsDrawnAsWritten() {
        let key: String = "$3.8\\times10^{4}\\,\\mathrm{N/C}$、x 軸の正の向き"
        #expect(TimelineRichText.answerSource(key) == key)
        #expect(NativeMathDocument.make(key, display: false) != nil)
    }

    /// 区切り無しで書かせていた頃の答え(実機 2026-11-23 の物理の答え)。日本語が混じると、どこまでが式かを推測して区切らず、
    /// 読める文字で出す(前は `\mathrm{N` で切れて閉じない `{` を囲み、LaTeX がそのまま出ていた)。
    @Test func anOldUndelimitedAnswerMixedWithJapaneseIsShownAsReadableText() {
        let key: String = TimelineRichText.answerSource("3.825\\times10^{4}\\,\\mathrm{N/C}\\ (+x\\text{向き})")
        let learner: String = TimelineRichText.answerSource("-4.5\\times10^{-2}\\,\\mathrm{N/C}\\ (x\\text{の負の方向})")
        #expect(key == "3.825 × 10⁴ N/C (+x向き)")
        #expect(learner == "−4.5 × 10⁻² N/C (xの負の方向)")
        #expect(!key.containsCatalogLaTeX && !learner.containsCatalogLaTeX)
    }

    /// 日本語を含まない区切り無しの式は、今までどおり全体を数式として組む。
    @Test func anOldUndelimitedFormulaIsStillDrawnAsMath() {
        #expect(TimelineRichText.answerSource("\\frac{\\pi^2}{8}+1") == "$\\frac{\\pi^2}{8}+1$")
    }
}
