import SwiftUI

/// 返事の本文の中の数式と強調(`**…**`)。§6: 要点の返事から先頭の最大 3 つを例題バーへ運ぶ。
/// 返事の書式(数式の区切り・強調の印)だけで機械的に切り出し、意味は読まない(W2)。
/// 数え方は `KaTeXMathText` の描画(`data-struis-mark`)と同じ: 数式 1 つで 1、強調の始まり 1 つで 1。
nonisolated enum StruisMarkedSpans {
    struct Span: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case math(display: Bool)
            case bold
        }

        let kind: Kind
        /// 区切りを外した中身。
        let body: String
        /// 区切りを含む元の範囲(文字数の位置)。
        let range: Range<Int>

        /// チップに出す文字(数式は `$…$` に戻して数式として描く)。
        var chipSource: String {
            switch kind {
            case .math: "$" + body + "$"
            case .bold: body
            }
        }
    }

    static func spans(_ source: String, limit: Int = .max) -> [Span] {
        let chars = Array(source)
        var index = 0
        var boldStart: Int?
        var boldOrder: Int?

        func startsWith(_ token: String, at position: Int) -> Bool {
            let needle = Array(token)
            guard position + needle.count <= chars.count else { return false }
            return Array(chars[position..<(position + needle.count)]) == needle
        }
        func isEscaped(_ position: Int) -> Bool {
            var slashes = 0
            var cursor = position - 1
            while cursor >= 0, chars[cursor] == "\\" { slashes += 1; cursor -= 1 }
            return slashes % 2 == 1
        }
        func findUnescaped(_ token: String, from: Int) -> Int? {
            var position = from
            while position < chars.count {
                if startsWith(token, at: position), !isEscaped(position) { return position }
                position += 1
            }
            return nil
        }
        func delimited(_ open: String, _ close: String, at position: Int) -> (body: String, end: Int)? {
            guard startsWith(open, at: position), let end = findUnescaped(close, from: position + open.count) else { return nil }
            let body = String(chars[(position + open.count)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (body, end + close.count)
        }
        func inlineDollar(at position: Int) -> (body: String, end: Int)? {
            guard chars[position] == "$", !startsWith("$$", at: position), !isEscaped(position),
                  let end = findUnescaped("$", from: position + 1), end > position else { return nil }
            return (String(chars[(position + 1)..<end]).trimmingCharacters(in: .whitespacesAndNewlines), end + 1)
        }
        func environment(at position: Int) -> (body: String, end: Int)? {
            guard startsWith("\\begin{", at: position) else { return nil }
            let rest = String(chars[(position + 7)...])
            guard let close = rest.firstIndex(of: "}") else { return nil }
            let name = String(rest[..<close])
            let closing = "\\end{\(name)}"
            let text = String(chars[position...])
            guard let range = text.range(of: closing) else { return nil }
            let length = text.distance(from: text.startIndex, to: range.upperBound)
            return (String(text[..<range.upperBound]), position + length)
        }
        func nextTokenStart(from: Int) -> Int {
            var position = from
            while position < chars.count {
                if !isEscaped(position), startsWith("$", at: position) || startsWith("\\[", at: position) || startsWith("\\(", at: position) || startsWith("\\begin{", at: position) {
                    return position
                }
                position += 1
            }
            return chars.count
        }

        var marks: [(order: Int, span: Span)] = []
        var order = 0
        while index < chars.count {
            if let display = delimited("$$", "$$", at: index) ?? delimited("\\[", "\\]", at: index) {
                marks.append((order, Span(kind: .math(display: true), body: display.body, range: index..<display.end)))
                order += 1
                index = display.end
                continue
            }
            if let inline = delimited("\\(", "\\)", at: index) ?? inlineDollar(at: index) {
                marks.append((order, Span(kind: .math(display: false), body: inline.body, range: index..<inline.end)))
                order += 1
                index = inline.end
                continue
            }
            if let env = environment(at: index) {
                marks.append((order, Span(kind: .math(display: true), body: env.body, range: index..<env.end)))
                order += 1
                index = env.end
                continue
            }
            let end = nextTokenStart(from: index + 1)
            var cursor = index
            while cursor < end {
                if startsWith("**", at: cursor) || startsWith("__", at: cursor) {
                    if let start = boldStart, let spanOrder = boldOrder {
                        let body = String(chars[(start + 2)..<cursor]).trimmingCharacters(in: .whitespacesAndNewlines)
                        marks.append((spanOrder, Span(kind: .bold, body: body, range: start..<(cursor + 2))))
                        boldStart = nil
                        boldOrder = nil
                    } else {
                        boldStart = cursor
                        boldOrder = order
                        order += 1
                    }
                    cursor += 2
                    continue
                }
                cursor += 1
            }
            index = end
        }
        let result = marks.sorted { $0.order < $1.order }.map(\.span).filter { !$0.body.isEmpty }
        return Array(result.prefix(limit))
    }

    /// 文字で描く本文(数式の無い返事)の、先頭から `count` 個の強調に淡い面の色をつける。
    @MainActor static func highlighted(_ text: String, count: Int) -> AttributedString {
        var attributed = AttributedString(text)
        let chars = Array(text)
        for span in spans(text, limit: count) {
            let lower = String(chars[..<span.range.lowerBound]).count
            let upper = String(chars[..<span.range.upperBound]).count
            let start = attributed.index(attributed.startIndex, offsetByCharacters: lower)
            let end = attributed.index(attributed.startIndex, offsetByCharacters: upper)
            attributed[start..<end].backgroundColor = Theme.accentColor.opacity(0.24)
        }
        return attributed
    }
}
