import Foundation

/// 返事の数式(LaTeX)を SwiftMath で描ける形に直す(Issue #28)。
///
/// 返事は KaTeX 向けに書かれているので、KaTeX では通るが SwiftMath に無い書き方がある。意味が同じ別の書き方があるものは
/// ここで置き換える(`\dots` → `\ldots`、`align` → `aligned` など)。無いもの(`\boxed`、`array` 環境など)は SwiftMath の
/// 解析エラーとして呼び手(`NativeMathRenderer`)が検出し、その本文だけ従来の WebView(KaTeX)に落として台帳に記録する。
/// 判定を緩めて「出ないことにする」のではなく、退避と記録で済ませる。
///
/// SwiftMath は数式の中の ASCII 以外の文字(日本語・≒ など)を黙って捨てるので、記号は命令に直し、残りは `\text{…}` に包む。
/// (`struis-math.js` の `normalizeLatexEscapes`・`normalizeMathScalars` の移植を含む。)
nonisolated enum MathSourceNormalizer {
    // MARK: - 返事の escape

    /// JSON を二重に escape した返事(`\\frac`)を直す。`struis-math.js` と同じ一覧。
    static let doubleEscapedCommands: Set<String> = [
        "alpha", "angle", "bar", "begin", "beta", "binom", "cap", "cdot", "cdots", "cos", "cosh", "cup",
        "delta", "det", "div", "displaystyle", "ddots", "end", "epsilon", "exp", "exists", "forall",
        "frac", "gamma", "ge", "hat", "in", "infty", "int", "lambda", "land", "ldots", "le", "leftarrow",
        "Leftrightarrow", "left", "lim", "ln", "log", "lor", "lnot", "mathbb", "mathrm", "mathit",
        "mathbf", "mp", "mu", "nabla", "ne", "neq", "notin", "omega", "operatorname", "overline",
        "partial", "parallel", "perp", "phi", "pi", "pm", "prod", "qquad", "quad", "right", "Rightarrow",
        "rightarrow", "rho", "sigma", "sin", "sinh", "sqrt", "sum", "tan", "tanh", "text", "textstyle",
        "theta", "therefore", "times", "to", "triangle", "underline", "varepsilon", "varphi", "vec",
    ]

    static func normalizeLatexEscapes(_ source: String) -> String {
        var text = source.replacingOccurrences(of: #"\\([\[\]()])"#, with: #"\\$1"#, options: .regularExpression)
        text = replaceCommands(in: text, pattern: #"\\{2,}([A-Za-z]+)"#) { name, whole in
            doubleEscapedCommands.contains(name) ? "\\" + name : whole
        }
        return text
    }

    // MARK: - 文字の記号

    /// 上付き・下付きの文字(²、₁)を `^{2}`、`_{1}` に。NFKC より先にやる(NFKC は ² を 2 にしてしまう)。
    static func normalizeScriptCharacters(_ value: String) -> String {
        let superscripts: [Character: Character] = [
            "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "ⁿ": "n", "⁺": "+", "⁻": "-",
        ]
        let subscripts: [Character: Character] = [
            "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4", "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9", "ₙ": "n", "₊": "+", "₋": "-",
        ]
        var out = ""
        var run = ""
        var runIsSuper = false
        func flush() {
            guard !run.isEmpty else { return }
            out += (runIsSuper ? "^{" : "_{") + run + "}"
            run = ""
        }
        for char in value {
            if let plain = superscripts[char] {
                if !run.isEmpty, !runIsSuper { flush() }
                runIsSuper = true
                run.append(plain)
            } else if let plain = subscripts[char] {
                if !run.isEmpty, runIsSuper { flush() }
                runIsSuper = false
                run.append(plain)
            } else {
                flush()
                out.append(char)
            }
        }
        flush()
        return out
    }

    /// 記号の文字と ASCII の組み合わせ(`<=`、`->`)を命令に。`struis-math.js` の `normalizeMathScalars` と同じ。
    static func normalizeMathScalars(_ body: String) -> String {
        var text = normalizeScriptCharacters(body).precomposedStringWithCompatibilityMapping
        // `n!=…` は階乗(`!` の前が文字・数字・閉じ括弧)。`x<-1` は「x < -1」なので `<-` は空白で囲まれた時だけ矢印にする。
        text = text.replacingOccurrences(of: #"(?<![A-Za-z0-9)\]}])!="#, with: #"\\ne "#, options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<=\s)<-(?=\s)"#, with: #"\\leftarrow "#, options: .regularExpression)
        let replacements: [(String, String)] = [
            ("<=>", "\\Leftrightarrow "), ("⇔", "\\Leftrightarrow "),
            ("->", "\\to "), ("→", "\\to "), ("←", "\\leftarrow "),
            ("=>", "\\Rightarrow "), ("⇒", "\\Rightarrow "),
            ("<=", "\\le "), ("≤", "\\le "), ("≦", "\\le "),
            (">=", "\\ge "), ("≥", "\\ge "), ("≧", "\\ge "),
            ("≠", "\\ne "),
            ("−", "-"), ("×", "\\times "), ("÷", "\\div "), ("±", "\\pm "), ("∞", "\\infty "), ("√", "\\sqrt "),
        ]
        for (from, to) in replacements {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text
    }

    /// 数式の中に文字で書かれた記号・ギリシャ文字 → 命令。SwiftMath は ASCII 以外の文字を数式として扱えない(黙って捨てる)。
    static let unicodeSymbols: [Character: String] = [
        "α": "\\alpha ", "β": "\\beta ", "γ": "\\gamma ", "δ": "\\delta ", "ε": "\\varepsilon ", "ζ": "\\zeta ", "η": "\\eta ",
        "θ": "\\theta ", "ι": "\\iota ", "κ": "\\kappa ", "λ": "\\lambda ", "μ": "\\mu ", "ν": "\\nu ", "ξ": "\\xi ",
        "π": "\\pi ", "ρ": "\\rho ", "σ": "\\sigma ", "τ": "\\tau ", "υ": "\\upsilon ", "φ": "\\varphi ", "χ": "\\chi ",
        "ψ": "\\psi ", "ω": "\\omega ", "Γ": "\\Gamma ", "Δ": "\\Delta ", "Θ": "\\Theta ", "Λ": "\\Lambda ", "Ξ": "\\Xi ",
        "Π": "\\Pi ", "Σ": "\\Sigma ", "Φ": "\\Phi ", "Ψ": "\\Psi ", "Ω": "\\Omega ",
        "∑": "\\sum ", "∏": "\\prod ", "∫": "\\int ", "∬": "\\iint ", "∂": "\\partial ", "∇": "\\nabla ",
        "∈": "\\in ", "∉": "\\notin ", "∋": "\\ni ", "⊂": "\\subset ", "⊃": "\\supset ", "⊆": "\\subseteq ", "⊇": "\\supseteq ",
        "∪": "\\cup ", "∩": "\\cap ", "∅": "\\emptyset ", "∀": "\\forall ", "∃": "\\exists ", "¬": "\\neg ", "∧": "\\land ", "∨": "\\lor ",
        "∠": "\\angle ", "△": "\\triangle ", "⊥": "\\perp ", "∥": "\\parallel ", "°": "^\\circ ", "′": "'", "″": "''",
        "≈": "\\approx ", "≡": "\\equiv ", "∝": "\\propto ", "∼": "\\sim ", "≪": "\\ll ", "≫": "\\gg ",
        "…": "\\ldots ", "⋯": "\\cdots ", "⋮": "\\vdots ", "⋱": "\\ddots ", "·": "\\cdot ", "⋅": "\\cdot ", "∘": "\\circ ",
        "ℝ": "\\mathbb{R}", "ℕ": "\\mathbb{N}", "ℤ": "\\mathbb{Z}", "ℚ": "\\mathbb{Q}", "ℂ": "\\mathbb{C}",
        "↔": "\\leftrightarrow ", "⇐": "\\Leftarrow ", "↑": "\\uparrow ", "↓": "\\downarrow ", "↦": "\\mapsto ",
        "∴": "\\text{∴}", "∵": "\\text{∵}", "≒": "\\text{≒}",
        "ℓ": "\\ell ", "ℏ": "\\hbar ", "ℵ": "\\aleph ",
    ]

    // MARK: - SwiftMath に無い書き方

    /// 意味が同じ別の書き方に置き換える命令(引数は書き換えない)。
    static let commandRewrites: [String: String] = [
        "dots": "ldots", "dotsc": "ldots", "dotsb": "cdots", "dotsi": "cdots",
        "mbox": "text", "textnormal": "text",
        "lvert": "vert", "rvert": "vert", "lVert": "Vert", "rVert": "Vert",
        "dbinom": "binom", "tbinom": "binom",
        "mathscr": "mathcal", "pmb": "boldsymbol", "bm": "boldsymbol",
        "enspace": ",", "thinspace": ",", "negthinspace": "!",
        "newline": "\\",
        "therefore": "text{∴}", "because": "text{∵}", "fallingdotseq": "text{≒}", "risingdotseq": "text{≓}",
        "implies": "Rightarrow", "impliedby": "Leftarrow",
        "varnothing": "emptyset", "gets": "leftarrow", "neq": "ne", "leqq": "le", "geqq": "ge", "leqslant": "le", "geqslant": "ge",
    ]

    /// 引数ごと消す命令(見た目の微調整で、無くても読める)。
    static let commandsDroppedWithArgument: Set<String> = ["tag", "label", "phantom", "vphantom", "hphantom", "mathstrut", "strut", "nonumber", "notag", "smash", "hspace", "kern", "mkern"]

    /// 環境の置き換え。
    static let environmentRewrites: [String: String] = [
        "align": "aligned", "align*": "aligned", "alignat": "aligned", "flalign": "aligned",
        "equation": "", "equation*": "", "displaymath": "", "math": "",
    ]

    /// 中が普通の文字になる命令(`\text{日本語}`)。この中の ASCII 以外の文字はそのまま SwiftMath に渡せる。
    private static let textCommands: Set<String> = ["text", "textbf", "textit", "textrm", "textsf", "texttt", "mbox", "textnormal"]

    /// 本文の 1 つの数式(区切りは含まない)を SwiftMath 向けに直す。
    static func prepare(_ body: String) -> String {
        var text = normalizeMathScalars(normalizeLatexEscapes(trimmed(body)))
        text = text.replacingOccurrences(of: #"\\not\s*="#, with: #"\\ne "#, options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\not\s*\\in\b"#, with: #"\\notin "#, options: .regularExpression)
        text = replaceCommands(in: text, pattern: #"\\([A-Za-z]+)"#) { name, whole in
            if let replacement = commandRewrites[name] { return "\\" + replacement }
            return whole
        }
        text = text.replacingOccurrences(of: "\\:", with: "\\;")
        text = dropCommandsWithArgument(text)
        text = rewriteEnvironments(text)
        return spaceOperatorNames(wrapForeignCharacters(text))
    }

    // MARK: - 関数名の前後の空き

    /// 関数名・大きな演算子(`\sin`・`\log`・`\int` など)。
    static let operatorNames: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth",
        "log", "ln", "lg", "exp", "lim", "limsup", "liminf", "max", "min", "sup", "inf", "det", "deg", "dim",
        "gcd", "arg", "ker", "hom", "Pr", "int", "iint", "iiint", "oint", "sum", "prod",
    ]

    /// 文字と同じ扱いの命令(ギリシャ文字など)と、分数・根号・書体の命令(後ろに `{…}` が続く)。
    static let ordinaryCommands: Set<String> = [
        "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta", "vartheta", "iota", "kappa", "lambda",
        "mu", "nu", "xi", "pi", "varpi", "rho", "varrho", "sigma", "varsigma", "tau", "upsilon", "phi", "varphi", "chi", "psi", "omega",
        "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi", "Omega",
        "infty", "partial", "ell", "hbar", "nabla", "aleph", "emptyset",
        "frac", "dfrac", "tfrac", "sqrt", "binom", "mathrm", "mathbf", "mathit", "mathbb", "mathcal", "boldsymbol",
        "text", "textbf", "textit", "textrm", "textsf", "texttt", "bar", "hat", "vec", "dot", "ddot", "tilde", "overline",
    ]

    /// 関数名と前後の文字の間に細い空き(`\,`)を入れる。TeX は `\sin 3x` を「sin 3x」と組むが、SwiftMath(固定の版の
    /// 改行用の組み方)は種類の違う要素の間の空きを入れず「sin3x」「3xcosx」と詰めてしまう。TeX と同じ所(関数名と文字・数字・
    /// 分数の間)にだけ入れる。括弧・演算子・関係の記号の隣、すでに空きを入れた所には入れない。
    static func spaceOperatorNames(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        var index = 0
        while index < chars.count {
            guard chars[index] == "\\", index + 1 < chars.count, chars[index + 1].isLetter else {
                out.append(chars[index])
                index += 1
                continue
            }
            var end = index + 1
            while end < chars.count, chars[end].isLetter { end += 1 }
            let name = String(chars[(index + 1)..<end])
            if textCommands.contains(name) || name == "mathrm" || name == "begin" || name == "end" {
                // 中身(文字・環境の名前)はそのまま写す。
                var next = end
                while next < chars.count, chars[next] == " " { next += 1 }
                if next < chars.count, chars[next] == "{", let close = matchingBrace(chars, open: next) {
                    out.append(contentsOf: chars[index...close])
                    index = close + 1
                } else {
                    out.append(contentsOf: chars[index..<end])
                    index = end
                }
                continue
            }
            let isOperator = operatorNames.contains(name) || name == "operatorname"
            guard isOperator else {
                out.append(contentsOf: chars[index..<end])
                index = end
                continue
            }
            if endsWithOrdinary(out) { out.append(contentsOf: "\\,") }
            out.append(contentsOf: chars[index..<end])
            index = end
            // `\operatorname{…}` の名前、上下の添字(`_{0}^{\pi}`・`^2`)、`\limits` はそのまま写す。
            if name == "operatorname" {
                var next = index
                while next < chars.count, chars[next] == " " { next += 1 }
                if next < chars.count, chars[next] == "{", let close = matchingBrace(chars, open: next) {
                    out.append(contentsOf: chars[index...close])
                    index = close + 1
                }
            }
            index = copyScripts(chars, from: index, into: &out)
            var next = index
            while next < chars.count, chars[next] == " " { next += 1 }
            if startsOrdinary(chars, at: next) { out.append(contentsOf: "\\,") }
        }
        return String(out)
    }

    /// 添字(`_x`・`^{…}`・`^\pi`)と `\limits`・`\nolimits` を写し、その後ろの位置を返す。
    private static func copyScripts(_ chars: [Character], from start: Int, into out: inout [Character]) -> Int {
        var index = start
        while true {
            var next = index
            while next < chars.count, chars[next] == " " { next += 1 }
            guard next < chars.count else { return index }
            if chars[next] == "\\" {
                var end = next + 1
                while end < chars.count, chars[end].isLetter { end += 1 }
                let name = String(chars[(next + 1)..<end])
                guard name == "limits" || name == "nolimits" else { return index }
                out.append(contentsOf: chars[index..<end])
                index = end
                continue
            }
            guard chars[next] == "_" || chars[next] == "^" else { return index }
            var argument = next + 1
            while argument < chars.count, chars[argument] == " " { argument += 1 }
            guard argument < chars.count else {
                out.append(contentsOf: chars[index..<chars.count])
                return chars.count
            }
            var end: Int
            if chars[argument] == "{", let close = matchingBrace(chars, open: argument) {
                end = close + 1
            } else if chars[argument] == "\\" {
                end = argument + 1
                if end < chars.count, chars[end].isLetter {
                    while end < chars.count, chars[end].isLetter { end += 1 }
                } else {
                    end = min(chars.count, end + 1)
                }
            } else {
                end = argument + 1
            }
            out.append(contentsOf: chars[index..<end])
            index = end
        }
    }

    /// ここまでに書いたものが、文字と同じ扱いのもの(文字・数字・閉じ括弧・`}`・ギリシャ文字など)で終わるか。
    private static func endsWithOrdinary(_ out: [Character]) -> Bool {
        var index = out.count - 1
        while index >= 0, out[index] == " " { index -= 1 }
        guard index >= 0 else { return false }
        let last = out[index]
        if last.isNumber || last == ")" || last == "]" || last == "|" || last == "!" || last == "'" { return true }
        if last == "}" {
            // `\begin{aligned}` の後ろ(行の始まり)は空けない。`\}`(閉じ波括弧)は閉じ括弧。
            if index > 0, out[index - 1] == "\\" { return true }
            guard let open = matchingOpenBrace(out, close: index) else { return true }
            let before = String(out[..<open])
            return !(before.hasSuffix("\\begin") || before.hasSuffix("\\end"))
        }
        if last.isLetter {
            var start = index
            while start > 0, out[start - 1].isLetter { start -= 1 }
            guard start > 0, out[start - 1] == "\\" else { return true }
            let name = String(out[start...index])
            return ordinaryCommands.contains(name) || operatorNames.contains(name)
        }
        return false
    }

    /// `chars[index]` から、文字と同じ扱いのもの(文字・数字・`{…}`・ギリシャ文字・分数・別の関数名)が始まるか。
    private static func startsOrdinary(_ chars: [Character], at index: Int) -> Bool {
        guard index < chars.count else { return false }
        let char = chars[index]
        if char.isLetter || char.isNumber || char == "{" { return true }
        guard char == "\\", index + 1 < chars.count, chars[index + 1].isLetter else { return false }
        var end = index + 1
        while end < chars.count, chars[end].isLetter { end += 1 }
        let name = String(chars[(index + 1)..<end])
        return ordinaryCommands.contains(name) || operatorNames.contains(name) || name == "operatorname"
    }

    /// `chars[close]` が `}` の時、対応する `{` の位置。
    private static func matchingOpenBrace(_ chars: [Character], close: Int) -> Int? {
        var depth = 0
        var index = close
        while index >= 0 {
            let escaped = index > 0 && chars[index - 1] == "\\"
            if !escaped {
                if chars[index] == "}" { depth += 1 }
                if chars[index] == "{" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index -= 1
        }
        return nil
    }

    /// 前後の空白を落とす。末尾の `\ `(命令の空白)は残す。
    private static func trimmed(_ body: String) -> String {
        var text = Substring(body)
        while let first = text.first, first.isWhitespace { text = text.dropFirst() }
        while let last = text.last, last.isWhitespace {
            let before = text.dropLast()
            let slashes = before.reversed().prefix { $0 == "\\" }.count
            if last == " ", slashes % 2 == 1 { break }
            text = before
        }
        return String(text)
    }

    /// 式の中の命令の名前(重複あり、出た順)。
    static func commandNames(in text: String) -> [String] {
        var names: [String] = []
        let regex = try! NSRegularExpression(pattern: #"\\([A-Za-z]+)"#)
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            names.append(ns.substring(with: match.range(at: 1)))
        }
        return names
    }

    static func environmentNames(in text: String) -> [String] {
        var names: [String] = []
        let regex = try! NSRegularExpression(pattern: #"\\begin\{([A-Za-z*]+)\}"#)
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            names.append(ns.substring(with: match.range(at: 1)))
        }
        return names
    }

    // MARK: - 中身

    private static func replaceCommands(in text: String, pattern: String, _ transform: (String, String) -> String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += transform(ns.substring(with: match.range(at: 1)), ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// `\tag{1}`、`\phantom{x}` などを引数ごと消す(引数は `{…}` 1 つ、または無し)。
    private static func dropCommandsWithArgument(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var index = 0
        while index < chars.count {
            guard chars[index] == "\\", index + 1 < chars.count, chars[index + 1].isLetter else {
                out.append(chars[index])
                index += 1
                continue
            }
            var end = index + 1
            while end < chars.count, chars[end].isLetter { end += 1 }
            let name = String(chars[(index + 1)..<end])
            guard commandsDroppedWithArgument.contains(name) else {
                out += String(chars[index..<end])
                index = end
                continue
            }
            index = end
            while index < chars.count, chars[index] == " " { index += 1 }
            if index < chars.count, chars[index] == "{", let close = matchingBrace(chars, open: index) {
                index = close + 1
            } else if name == "kern" || name == "mkern" {
                // `\kern 1pt`: 長さの引数を飛ばす。
                while index < chars.count, chars[index] != " ", chars[index] != "\\" { index += 1 }
            }
        }
        return out
    }

    private static func rewriteEnvironments(_ text: String) -> String {
        var text = text
        for (from, to) in environmentRewrites {
            let escaped = NSRegularExpression.escapedPattern(for: from)
            for keyword in ["begin", "end"] {
                let pattern = #"\\"# + keyword + #"\{"# + escaped + #"\}"#
                let replacement = to.isEmpty ? "" : "\\\\" + keyword + "{" + to + "}"
                text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
            }
        }
        // `\begin{aligned}` の行の区切りは `\\`。`align` の `\\[4pt]` は SwiftMath に無いので間隔を落とす。
        return text.replacingOccurrences(of: #"\\\\\[[0-9.]+(pt|em|ex|mm)\]"#, with: "\\\\\\\\", options: .regularExpression)
    }

    /// 数式の中の ASCII 以外の文字: 記号は命令に、それ以外(日本語など)は `\text{…}` に包む。
    /// `\text{…}` の中はそのまま(SwiftMath はこの中だけ ASCII 以外を受け付ける)。
    static func wrapForeignCharacters(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var index = 0
        var foreign = ""
        func flushForeign() {
            guard !foreign.isEmpty else { return }
            out += "\\text{" + foreign + "}"
            foreign = ""
        }
        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count, chars[index + 1].isLetter {
                flushForeign()
                var end = index + 1
                while end < chars.count, chars[end].isLetter { end += 1 }
                let name = String(chars[(index + 1)..<end])
                var next = end
                while next < chars.count, chars[next] == " " { next += 1 }
                if textCommands.contains(name), next < chars.count, chars[next] == "{", let close = matchingBrace(chars, open: next) {
                    // `\mathrm{日本語}` は捨てられるので `\text` に。
                    let group = chars[(next + 1)..<close]
                    out += "\\" + name + "{" + String(group) + "}"
                    index = close + 1
                } else if name == "mathrm", next < chars.count, chars[next] == "{", let close = matchingBrace(chars, open: next),
                          chars[(next + 1)..<close].contains(where: { !$0.isASCII }) {
                    out += "\\text{" + String(chars[(next + 1)..<close]) + "}"
                    index = close + 1
                } else {
                    out += String(chars[index..<end])
                    index = end
                }
                continue
            }
            if char.isASCII {
                flushForeign()
                out.append(char)
            } else if let symbol = unicodeSymbols[char] {
                flushForeign()
                out += symbol
            } else if char == "　" {
                flushForeign()
                out += "\\ "
            } else {
                foreign.append(char)
            }
            index += 1
        }
        flushForeign()
        return out
    }

    /// `chars[open]` が `{` の時、対応する `}` の位置。無ければ nil。
    private static func matchingBrace(_ chars: [Character], open: Int) -> Int? {
        var depth = 0
        var index = open
        while index < chars.count {
            if chars[index] == "\\" { index += 2; continue }
            if chars[index] == "{" { depth += 1 }
            if chars[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }
}
