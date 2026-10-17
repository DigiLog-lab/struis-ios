import Foundation

/// 本文を「文字・行中の数式・表示用の数式」に切り分ける(`struis-math.js` の `tokenize`・`renderMixed` の移植)。
/// 数式と強調(`**…**`)の番号(§6 で色をつける数の数え方)は WebView の `data-struis-mark` と同じ:
/// 数式 1 つで 1、強調の始まり 1 つで 1(`StruisMarkedSpans.spans` とも同じ)。
nonisolated enum MathTextLayout {
    enum Token: Equatable, Sendable {
        case text(String)
        case inline(String)
        case display(String)
    }

    /// 段落の中の 1 つの部分。
    enum Run: Equatable, Sendable {
        /// 文字。`bold` なら強調の中(`mark` はその強調の番号)。
        case text(String, bold: Bool, mark: Int?)
        /// 行中の数式(区切りを外した中身)。`strongMark` は強調の中にある時のその強調の番号。
        case math(String, strongMark: Int?, mark: Int)
    }

    enum Block: Equatable, Sendable {
        case paragraph([Run])
        /// 表示用の数式(区切りを外した中身)。段落とは別の行に置く。
        case display(String, mark: Int)
    }

    /// 本文を描く単位に切り分ける。`display` は `.math(latex, display: true)` の本文(全体が 1 つの数式なら区切りなしで来る)。
    static func blocks(_ raw: String, display: Bool) -> [Block] {
        let normalized = MathSourceNormalizer.normalizeLatexEscapes(raw)
        if display, !normalized.contains("$"), isPureMath(normalized) {
            return [.display(normalized, mark: 0)]
        }
        var blocks: [Block] = []
        var runs: [Run] = []
        var mark = 0
        var strongOpen = false
        var strongMark: Int?
        var afterDisplay = false
        for token in tokenize(normalized) {
            switch token {
            case .display(let body):
                guard !body.isEmpty else { continue }
                // 表示用の数式は段落(ブロック)。直前の改行 1 つと直後の改行 1 つは空行にしない。
                if case .text(let text, let bold, let textMark)? = runs.last, text.hasSuffix("\n") {
                    runs[runs.count - 1] = .text(String(text.dropLast()), bold: bold, mark: textMark)
                }
                flushParagraph(&runs, into: &blocks)
                blocks.append(.display(body, mark: mark))
                mark += 1
                afterDisplay = true
                continue
            case .inline(let body):
                guard !body.isEmpty else { continue }
                runs.append(.math(body, strongMark: strongMark, mark: mark))
                mark += 1
            case .text(var text):
                if afterDisplay, text.hasPrefix("\n") { text.removeFirst() }
                var rest = Substring(text)
                while let marker = firstBoldMarker(in: rest) {
                    appendText(String(rest[..<marker.lowerBound]), bold: strongOpen, mark: strongMark, to: &runs)
                    if strongOpen {
                        strongOpen = false
                        strongMark = nil
                    } else {
                        strongOpen = true
                        strongMark = mark
                        mark += 1
                    }
                    rest = rest[marker.upperBound...]
                }
                appendText(String(rest), bold: strongOpen, mark: strongMark, to: &runs)
            }
            afterDisplay = false
        }
        flushParagraph(&runs, into: &blocks)
        return blocks
    }

    /// 強調の印(`**` か `__`)のうち、先に出る方。
    private static func firstBoldMarker(in text: Substring) -> Range<Substring.Index>? {
        [text.range(of: "**"), text.range(of: "__")].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
    }

    private static func appendText(_ text: String, bold: Bool, mark: Int?, to runs: inout [Run]) {
        guard !text.isEmpty else { return }
        if case .text(let previous, let previousBold, let previousMark)? = runs.last, previousBold == bold, previousMark == mark {
            runs[runs.count - 1] = .text(previous + text, bold: bold, mark: mark)
        } else {
            runs.append(.text(text, bold: bold, mark: mark))
        }
    }

    private static func flushParagraph(_ runs: inout [Run], into blocks: inout [Block]) {
        let kept = runs.filter {
            if case .text(let text, _, _) = $0 { return !text.isEmpty }
            return true
        }
        runs = []
        guard !kept.isEmpty else { return }
        blocks.append(.paragraph(kept))
    }

    // MARK: - 切り分け(`tokenize`)

    static func tokenize(_ source: String) -> [Token] {
        let chars = Array(source)
        var out: [Token] = []
        var index = 0
        while index < chars.count {
            if let fence = delimited(chars, at: index, open: "$$", close: "$$") ?? delimited(chars, at: index, open: "\\[", close: "\\]") {
                out.append(.display(fence.body))
                index = fence.end
                continue
            }
            if let fence = delimited(chars, at: index, open: "\\(", close: "\\)") ?? inlineDollar(chars, at: index) {
                out.append(.inline(fence.body))
                index = fence.end
                continue
            }
            if let environment = environment(chars, at: index) {
                out.append(.display(environment.body))
                index = environment.end
                continue
            }
            let next = nextTokenStart(chars, from: index + 1)
            out.append(.text(String(chars[index..<next])))
            index = next
        }
        return out
    }

    private static func startsWith(_ chars: [Character], _ token: [Character], at position: Int) -> Bool {
        guard position >= 0, position + token.count <= chars.count else { return false }
        for (offset, char) in token.enumerated() where chars[position + offset] != char { return false }
        return true
    }

    private static func isEscaped(_ chars: [Character], _ position: Int) -> Bool {
        var slashes = 0
        var cursor = position - 1
        while cursor >= 0, chars[cursor] == "\\" {
            slashes += 1
            cursor -= 1
        }
        return slashes % 2 == 1
    }

    private static func findUnescaped(_ chars: [Character], _ token: [Character], from: Int) -> Int? {
        var position = from
        while position + token.count <= chars.count {
            if startsWith(chars, token, at: position), !isEscaped(chars, position) { return position }
            position += 1
        }
        return nil
    }

    private static func delimited(_ chars: [Character], at position: Int, open: String, close: String) -> (body: String, end: Int)? {
        let openChars = Array(open)
        guard startsWith(chars, openChars, at: position),
              let end = findUnescaped(chars, Array(close), from: position + openChars.count) else { return nil }
        let body = String(chars[(position + openChars.count)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, end + close.count)
    }

    private static func inlineDollar(_ chars: [Character], at position: Int) -> (body: String, end: Int)? {
        guard chars[position] == "$", !startsWith(chars, ["$", "$"], at: position), !isEscaped(chars, position),
              let end = findUnescaped(chars, ["$"], from: position + 1), end > position else { return nil }
        return (String(chars[(position + 1)..<end]).trimmingCharacters(in: .whitespacesAndNewlines), end + 1)
    }

    private static func environment(_ chars: [Character], at position: Int) -> (body: String, end: Int)? {
        let begin = Array("\\begin{")
        guard startsWith(chars, begin, at: position) else { return nil }
        var cursor = position + begin.count
        var name = ""
        while cursor < chars.count, chars[cursor].isLetter || chars[cursor] == "*" {
            name.append(chars[cursor])
            cursor += 1
        }
        guard !name.isEmpty, cursor < chars.count, chars[cursor] == "}" else { return nil }
        let close = Array("\\end{\(name)}")
        var search = cursor + 1
        while search + close.count <= chars.count {
            if startsWith(chars, close, at: search) {
                let end = search + close.count
                return (String(chars[position..<end]).trimmingCharacters(in: .whitespacesAndNewlines), end)
            }
            search += 1
        }
        return nil
    }

    private static func nextTokenStart(_ chars: [Character], from: Int) -> Int {
        var position = from
        while position < chars.count {
            if !isEscaped(chars, position),
               chars[position] == "$" || startsWith(chars, ["\\", "["], at: position) || startsWith(chars, ["\\", "("], at: position)
                || startsWith(chars, Array("\\begin{"), at: position) {
                return position
            }
            position += 1
        }
        return chars.count
    }

    /// 区切りなしで全体が数式と見なせる本文(`isPureMath`)。
    static func isPureMath(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let allowed = Set("\\{}()[]+-−*/=^_,.<>!|:?'%&#≤≥≠×÷±∞√→←⇒⇔⁰¹²³⁴⁵⁶⁷⁸⁹ⁿ⁺⁻₀₁₂₃₄₅₆₇₈₉ₙ₊₋")
        return text.allSatisfy { char in
            char.isWhitespace || allowed.contains(char) || char.isASCII && (char.isLetter || char.isNumber)
                || ("Α"..."Ω").contains(char) || ("α"..."ω").contains(char)
        }
    }
}
