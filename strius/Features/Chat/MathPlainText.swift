import Foundation

/// 数式(LaTeX)を、WebView を使わずに読める文字に直す。
/// - 一覧のプレビュー・会話の題名(D7: `\(D>0\)` を `D>0` に)
/// - 数式の吹き出しが描き終わるまでの仮の文字と、VoiceOver の読み上げ(K1)
/// 書式をすべて再現するものではない。区切り記号と命令を外し、上付き・下付き・分数・根号を普通の文字で表す。
nonisolated enum MathPlainText {
    /// 本文中の数式区切り(`$…$`、`$$…$$`、`\(…\)`、`\[…\]`)の中だけを文字に直し、強調の `**` を外す。
    static func readable(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            if let (body, end) = delimited(text, at: index) {
                output += convert(body)
                index = end
                continue
            }
            output.append(text[index])
            index = text.index(after: index)
        }
        return output
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
    }

    /// 1 行で見せる所(一覧のプレビュー)のための形。改行と連続する空白を 1 つの空白にする。
    static func preview(_ text: String) -> String {
        readable(text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - 区切り

    private static let fences: [(open: String, close: String)] = [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]

    private static func delimited(_ text: String, at index: String.Index) -> (String, String.Index)? {
        for fence in fences where text[index...].hasPrefix(fence.open) {
            if fence.open == "$", isEscaped(text, index) { return nil }
            let bodyStart = text.index(index, offsetBy: fence.open.count)
            guard bodyStart <= text.endIndex,
                  let close = text.range(of: fence.close, range: bodyStart..<text.endIndex),
                  close.lowerBound > bodyStart
            else { continue }
            return (String(text[bodyStart..<close.lowerBound]), close.upperBound)
        }
        return nil
    }

    private static func isEscaped(_ text: String, _ index: String.Index) -> Bool {
        var count = 0
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            guard text[cursor] == "\\" else { break }
            count += 1
        }
        return count % 2 == 1
    }

    // MARK: - 数式の中

    /// LaTeX の式を読める文字にする(区切り記号は含まない)。
    static func convert(_ latex: String) -> String {
        var parser = Parser(Array(latex))
        let raw = parser.parseSequence(until: nil)
        return raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*([=<>≤≥≠±×÷·→⇒⇔])\s*"#, with: " $1 ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static let symbols: [String: String] = [
        "times": "×", "div": "÷", "cdot": "·", "pm": "±", "mp": "∓", "le": "≤", "leq": "≤", "leqq": "≤", "ge": "≥", "geq": "≥",
        "geqq": "≥", "ne": "≠", "neq": "≠", "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "Leftrightarrow": "⇔", "iff": "⇔", "infty": "∞", "pi": "π", "theta": "θ", "alpha": "α", "beta": "β", "gamma": "γ",
        "delta": "δ", "Delta": "Δ", "lambda": "λ", "mu": "μ", "sigma": "σ", "omega": "ω", "phi": "φ", "varphi": "φ",
        "epsilon": "ε", "varepsilon": "ε", "approx": "≈", "sim": "∼", "equiv": "≡", "in": "∈", "notin": "∉", "subset": "⊂",
        "cup": "∪", "cap": "∩", "angle": "∠", "triangle": "△", "perp": "⊥", "parallel": "∥", "therefore": "∴", "because": "∵",
        "circ": "°", "degree": "°", "ldots": "…", "cdots": "⋯", "dots": "…", "prime": "′", "sum": "Σ", "int": "∫",
        "quad": " ", "qquad": " ", ",": " ", ";": " ", ":": " ", "!": "", " ": " ", "%": "%", "{": "{", "}": "}", "$": "$",
        "&": "&", "#": "#", "_": "_", "\\": "、",
        "sin": "sin", "cos": "cos", "tan": "tan", "log": "log", "ln": "ln", "exp": "exp", "lim": "lim", "max": "max", "min": "min",
    ]

    /// 中身をそのまま出す命令(書体だけを変えるもの)。
    private static let passthrough: Set<String> = [
        "text", "mathrm", "mathbf", "mathit", "textbf", "textit", "operatorname", "mathbb", "boldsymbol", "displaystyle",
        "textstyle", "underline", "overline", "bar", "vec", "hat", "mbox",
    ]

    /// 何も出さない命令。
    private static let ignored: Set<String> = ["left", "right", "big", "Big", "bigg", "Bigg", "limits", "nolimits"]

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "n": "ⁿ", "i": "ⁱ", "(": "⁽", ")": "⁾", "=": "⁼",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "n": "ₙ", "(": "₍", ")": "₎", "=": "₌",
    ]

    private struct Parser {
        let chars: [Character]
        var position = 0

        init(_ chars: [Character]) { self.chars = chars }

        mutating func parseSequence(until terminator: Character?) -> String {
            var out = ""
            while position < chars.count {
                let char = chars[position]
                if let terminator, char == terminator {
                    position += 1
                    return out
                }
                switch char {
                case "{":
                    position += 1
                    out += parseSequence(until: "}")
                case "\\":
                    out += parseCommand()
                case "^":
                    position += 1
                    out += script(parseArgument(), map: MathPlainText.superscripts, fallback: "^")
                case "_":
                    position += 1
                    out += script(parseArgument(), map: MathPlainText.subscripts, fallback: "_")
                case "-":
                    position += 1
                    out += "−"
                case "&":
                    position += 1
                    out += " "
                case "~":
                    position += 1
                    out += " "
                default:
                    position += 1
                    out.append(char)
                }
            }
            return out
        }

        /// `{…}` か 1 文字(または 1 つの命令)を読む。
        mutating func parseArgument() -> String {
            while position < chars.count, chars[position] == " " { position += 1 }
            guard position < chars.count else { return "" }
            if chars[position] == "{" {
                position += 1
                return parseSequence(until: "}")
            }
            if chars[position] == "\\" { return parseCommand() }
            let char = chars[position]
            position += 1
            return char == "-" ? "−" : String(char)
        }

        mutating func parseOptional() -> String? {
            guard position < chars.count, chars[position] == "[" else { return nil }
            position += 1
            return parseSequence(until: "]")
        }

        mutating func parseCommand() -> String {
            position += 1  // "\"
            guard position < chars.count else { return "" }
            var name = ""
            if chars[position].isLetter {
                while position < chars.count, chars[position].isLetter {
                    name.append(chars[position])
                    position += 1
                }
            } else {
                name = String(chars[position])
                position += 1
            }
            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                let numerator = parseArgument()
                let denominator = parseArgument()
                return "\(grouped(numerator))/\(grouped(denominator))"
            case "sqrt":
                let index = parseOptional()
                let body = parseArgument()
                return (index.map { "\($0)" } ?? "") + "√" + grouped(body)
            case "begin", "end":
                _ = parseArgument()  // 環境の名前は出さない
                return " "
            default:
                if MathPlainText.ignored.contains(name) { return "" }
                if MathPlainText.passthrough.contains(name) { return parseArgument() }
                if let symbol = MathPlainText.symbols[name] { return symbol }
                return name
            }
        }

        private func grouped(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            let simple = trimmed.count <= 1 || trimmed.allSatisfy { $0.isNumber || $0 == "." }
            return simple ? trimmed : "(\(trimmed))"
        }

        private func script(_ value: String, map: [Character: Character], fallback: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            let mapped = trimmed.compactMap { map[$0] }
            if !trimmed.isEmpty, mapped.count == trimmed.count { return String(mapped) }
            return fallback + grouped(trimmed)
        }
    }
}
