import Foundation

/// 文字で書かれた式(`pi^2/8+1`・`-cos(5x)/5`・`(1/2){sin 8x + sin(-2x)}`)を LaTeX に直す。
///
/// 答え(`answer_key`)と生徒の答え(`learner_answer`)は、モデルが計算機向けの書き方で返すことがある。そのまま数式として
/// 組むと `pi` が斜体の p・i になり(実機 2026-10-26)、文字のまま出すと `1/3` が分数に見えない。日本語を含む文や、
/// 読めない記号を含む文は直さない(`nil`)。
nonisolated enum TimelinePlainMath {
    /// 直した LaTeX(区切りなし)。直すところが無い(`0`・`x` だけ)か、読めなければ nil。
    static func latex(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\\"), !trimmed.contains("$") else { return nil }
        guard let tokens = tokenize(trimmed) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let piece = parser.parseList(), parser.atEnd else { return nil }
        let latex = piece.latex
        // 数字・文字・符号だけ(`0`・`-1`・`x`)は文字のままでよい。
        guard latex.contains("\\") || latex.contains("^") || latex.contains("{") else { return nil }
        return latex
    }

    // MARK: - 字句

    enum Token: Equatable {
        case number(String)
        case word(String)
        /// すでに LaTeX の命令になったもの(π → `\pi`)。
        case symbol(String)
        /// `+ - * / ^ = , < >` と `\le` などの関係。
        case op(String)
        case open(Character)
        case close(Character)
        /// 上付きの数字(`²`)。
        case superscript(String)
        case space
    }

    static let functions: [String] = [
        "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "sqrt", "sin", "cos", "tan", "cot", "sec", "csc", "log", "exp", "abs", "ln",
    ]

    private static let unicodeSymbols: [Character: Token] = [
        "π": .symbol("\\pi"), "∞": .symbol("\\infty"), "θ": .symbol("\\theta"), "α": .symbol("\\alpha"), "β": .symbol("\\beta"),
        "−": .op("-"), "–": .op("-"), "×": .op("*"), "·": .op("*"), "⋅": .op("*"), "÷": .op("/"),
        "≤": .op("\\le"), "≦": .op("\\le"), "≥": .op("\\ge"), "≧": .op("\\ge"), "≠": .op("\\ne"), "±": .op("\\pm"),
        "（": .open("("), "）": .close(")"), "，": .op(","), "、": .op(","), "　": .space,
    ]

    private static let superscripts: [Character: Character] = [
        "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "⁻": "-",
    ]

    static func tokenize(_ text: String) -> [Token]? {
        let chars = Array(text)
        var tokens: [Token] = []
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == " " || char == "\t" {
                if tokens.last != .space { tokens.append(.space) }
                index += 1
            } else if char.isASCII, char.isNumber || char == "." {
                var end = index
                while end < chars.count, chars[end].isASCII, chars[end].isNumber || chars[end] == "." { end += 1 }
                tokens.append(.number(String(chars[index..<end])))
                index = end
            } else if char.isASCII, char.isLetter {
                var end = index
                while end < chars.count, chars[end].isASCII, chars[end].isLetter { end += 1 }
                tokens.append(contentsOf: words(String(chars[index..<end])))
                index = end
            } else if superscripts[char] != nil {
                var end = index
                var value = ""
                while end < chars.count, let next = superscripts[chars[end]] { value.append(next); end += 1 }
                tokens.append(.superscript(value))
                index = end
            } else if let token = unicodeSymbols[char] {
                if token == .space { if tokens.last != .space { tokens.append(.space) } } else { tokens.append(token) }
                index += 1
            } else if "+-*/^=,<>".contains(char) {
                // `<=`・`>=`・`!=` は関係の記号。
                if index + 1 < chars.count, chars[index + 1] == "=", char == "<" || char == ">" {
                    tokens.append(.op(char == "<" ? "\\le" : "\\ge"))
                    index += 2
                } else {
                    tokens.append(.op(String(char)))
                    index += 1
                }
            } else if char == "!", index + 1 < chars.count, chars[index + 1] == "=" {
                tokens.append(.op("\\ne"))
                index += 2
            } else if "([{".contains(char) {
                tokens.append(.open(char))
                index += 1
            } else if ")]}".contains(char) {
                tokens.append(.close(char))
                index += 1
            } else {
                // 日本語・読めない記号: 直さない。
                return nil
            }
        }
        return tokens
    }

    /// 英字の並びを、関数名・`pi`・ただの文字に分ける(`sinx` → sin と x、`2pi` の pi → π)。
    private static func words(_ run: String) -> [Token] {
        var tokens: [Token] = []
        var rest = Substring(run)
        while !rest.isEmpty {
            if let name = functions.first(where: { rest.hasPrefix($0) }) {
                tokens.append(.word(name))
                rest = rest.dropFirst(name.count)
            } else if rest.hasPrefix("pi") {
                tokens.append(.symbol("\\pi"))
                rest = rest.dropFirst(2)
            } else if rest.hasPrefix("theta") {
                tokens.append(.symbol("\\theta"))
                rest = rest.dropFirst(5)
            } else if rest.hasPrefix("inf") && rest.count == 3 {
                tokens.append(.symbol("\\infty"))
                rest = rest.dropFirst(3)
            } else {
                tokens.append(.word(String(rest.first!)))
                rest = rest.dropFirst()
            }
        }
        return tokens
    }

    // MARK: - 組み立て

    struct Piece {
        var latex: String
        /// `( … )` で囲んだ式なら中身(分数の分子・分母、べきの指数では括弧を外す)。
        var inner: String? = nil
        var containsFraction: Bool { latex.contains("\\frac") }
    }

    struct Parser {
        let tokens: [Token]
        var index = 0

        init(tokens: [Token]) { self.tokens = tokens }

        var atEnd: Bool {
            var probe = index
            while probe < tokens.count, tokens[probe] == .space { probe += 1 }
            return probe >= tokens.count
        }

        private mutating func skipSpaces() {
            while index < tokens.count, tokens[index] == .space { index += 1 }
        }

        private func peek() -> Token? {
            var probe = index
            while probe < tokens.count, tokens[probe] == .space { probe += 1 }
            return probe < tokens.count ? tokens[probe] : nil
        }

        /// `a, b` の並び。
        mutating func parseList() -> Piece? {
            guard var result = parseRelation() else { return nil }
            while peek() == .op(",") {
                skipSpaces()
                index += 1
                guard let next = parseRelation() else { return nil }
                result = Piece(latex: result.latex + ",\\ " + next.latex)
            }
            return result
        }

        private mutating func parseRelation() -> Piece? {
            guard var result = parseSum() else { return nil }
            while case .op(let op)? = peek(), ["=", "<", ">", "\\le", "\\ge", "\\ne"].contains(op) {
                skipSpaces()
                index += 1
                guard let next = parseSum() else { return nil }
                result = Piece(latex: result.latex + " " + op + " " + next.latex)
            }
            return result
        }

        private mutating func parseSum() -> Piece? {
            var latex = ""
            if case .op(let sign)? = peek(), sign == "-" || sign == "+" || sign == "\\pm" {
                skipSpaces()
                index += 1
                latex = sign == "\\pm" ? "\\pm " : sign
            }
            guard let first = parseTerm() else { return nil }
            // 単項の符号が付かない 1 つだけの項は、括弧の中身を保つ(分数の分子などで外せるように)。
            if latex.isEmpty, !isSumOperator(peek()) { return first }
            latex += first.latex
            while case .op(let op)? = peek(), op == "+" || op == "-" || op == "\\pm" {
                skipSpaces()
                index += 1
                guard let next = parseTerm() else { return nil }
                latex += (op == "\\pm" ? " \\pm " : op) + next.latex
            }
            return Piece(latex: latex)
        }

        private func isSumOperator(_ token: Token?) -> Bool {
            guard case .op(let op)? = token else { return false }
            return op == "+" || op == "-" || op == "\\pm"
        }

        /// 掛け算・割り算(書かれていない掛け算を含む)。`a/b` は分数にする。
        private mutating func parseTerm() -> Piece? {
            guard var result = parsePower() else { return nil }
            while true {
                let token = peek()
                if token == .op("/") {
                    skipSpaces()
                    index += 1
                    guard let denominator = parsePower() else { return nil }
                    result = Piece(latex: "\\frac{" + (result.inner ?? result.latex) + "}{" + (denominator.inner ?? denominator.latex) + "}")
                } else if token == .op("*") {
                    skipSpaces()
                    index += 1
                    guard let next = parsePower() else { return nil }
                    result = Piece(latex: Self.multiply(result.latex, next.latex))
                } else if startsFactor(token) {
                    guard let next = parsePower() else { return nil }
                    // `(1/2)π` の括弧は分数だけなら外す。
                    let left = result.inner.flatMap { Self.isSingleFraction($0) ? $0 : nil } ?? result.latex
                    result = Piece(latex: Self.multiply(left, next.latex))
                } else {
                    return result
                }
            }
        }

        private func startsFactor(_ token: Token?) -> Bool {
            switch token {
            case .number?, .word?, .symbol?, .open?: true
            default: false
            }
        }

        static func multiply(_ left: String, _ right: String) -> String {
            let leftDigit = left.last?.isNumber ?? false
            let rightDigit = right.first?.isNumber ?? false
            if leftDigit && rightDigit { return left + " \\cdot " + right }
            return left + " " + right
        }

        static func isSingleFraction(_ latex: String) -> Bool {
            guard latex.hasPrefix("\\frac{") else { return false }
            // `\frac{…}{…}` だけで終わっているか(後ろに続きが無い)。
            var depth = 0
            var groups = 0
            var index = latex.index(latex.startIndex, offsetBy: 5)
            while index < latex.endIndex {
                let char = latex[index]
                if char == "{" { depth += 1 }
                if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        groups += 1
                        if groups == 2 { return latex.index(after: index) == latex.endIndex }
                    }
                }
                index = latex.index(after: index)
            }
            return false
        }

        /// べき(`x^2`・`π²`・`e^(2x)`)と単項の符号。
        private mutating func parsePower() -> Piece? {
            if case .op(let sign)? = peek(), sign == "-" {
                skipSpaces()
                index += 1
                guard let next = parsePower() else { return nil }
                return Piece(latex: "-" + next.latex)
            }
            guard var base = parsePrimary() else { return nil }
            while true {
                // 指数は空白を挟まずに続く時だけ(`x ^2` も読むが、空白の後の数字は掛け算)。
                if index < tokens.count, case .superscript(let value) = tokens[index] {
                    index += 1
                    base = Piece(latex: base.latex + "^{" + value + "}")
                } else if peek() == .op("^") {
                    skipSpaces()
                    index += 1
                    skipSpaces()
                    var sign = ""
                    if peek() == .op("-") { index += 1; sign = "-" }
                    guard let exponent = parsePrimary() else { return nil }
                    base = Piece(latex: base.latex + "^{" + sign + (exponent.inner ?? exponent.latex) + "}")
                } else {
                    return base
                }
            }
        }

        private mutating func parsePrimary() -> Piece? {
            skipSpaces()
            guard index < tokens.count else { return nil }
            let token = tokens[index]
            index += 1
            switch token {
            case .number(let value): return Piece(latex: value)
            case .symbol(let value): return Piece(latex: value)
            case .word(let name) where TimelinePlainMath.functions.contains(name): return parseFunction(name)
            case .word(let name): return Piece(latex: name)
            case .open(let char): return parseGroup(opening: char)
            default: return nil
            }
        }

        private mutating func parseGroup(opening: Character) -> Piece? {
            let closing: Character = opening == "(" ? ")" : opening == "[" ? "]" : "}"
            guard let inner = parseList() else { return nil }
            skipSpaces()
            guard index < tokens.count, tokens[index] == .close(closing) else { return nil }
            index += 1
            switch opening {
            case "(":
                let sized = inner.containsFraction
                return Piece(latex: (sized ? "\\left(" : "(") + inner.latex + (sized ? "\\right)" : ")"), inner: inner.latex)
            case "[":
                return Piece(latex: (inner.containsFraction ? "\\left[" : "[") + inner.latex + (inner.containsFraction ? "\\right]" : "]"))
            default:
                return Piece(latex: (inner.containsFraction ? "\\left\\{" : "\\{") + inner.latex + (inner.containsFraction ? "\\right\\}" : "\\}"))
            }
        }

        /// 関数(`sin 4x`・`cos(5x)`・`sin^2 x`・`sqrt(2)`・`abs(x)`)。括弧の無い引数は、次の演算子までの数字・文字・べき。
        private mutating func parseFunction(_ name: String) -> Piece? {
            var head = "\\" + name
            if peek() == .op("^"), name != "sqrt", name != "abs" {
                skipSpaces()
                index += 1
                guard let exponent = parsePrimary() else { return nil }
                head += "^{" + (exponent.inner ?? exponent.latex) + "}"
            }
            if case .open("(")? = peek() {
                skipSpaces()
                index += 1
                guard let group = parseGroup(opening: "("), let inner = group.inner else { return nil }
                switch name {
                case "sqrt": return Piece(latex: "\\sqrt{" + inner + "}")
                case "abs": return Piece(latex: "\\left|" + inner + "\\right|")
                default: return Piece(latex: head + group.latex)
                }
            }
            // 括弧の無い引数: `4x`・`x`・`2π`(掛け算でつながる数字・文字・べき)。
            guard var argument = parseArgumentFactor() else { return nil }
            while index < tokens.count, startsArgument(tokens[index]) {
                guard let next = parseArgumentFactor() else { return nil }
                argument = Piece(latex: Self.multiply(argument.latex, next.latex))
            }
            switch name {
            case "sqrt": return Piece(latex: "\\sqrt{" + argument.latex + "}")
            case "abs": return Piece(latex: "\\left|" + argument.latex + "\\right|")
            default: return Piece(latex: head + " " + argument.latex)
            }
        }

        /// 引数の続き: 空白を挟まない数字・文字・π(`4x`)。
        private func startsArgument(_ token: Token) -> Bool {
            switch token {
            case .number, .symbol: true
            case .word(let name): !TimelinePlainMath.functions.contains(name)
            default: false
            }
        }

        private mutating func parseArgumentFactor() -> Piece? {
            skipSpaces()
            guard index < tokens.count else { return nil }
            switch tokens[index] {
            case .number(let value):
                index += 1
                return withScripts(Piece(latex: value))
            case .symbol(let value):
                index += 1
                return withScripts(Piece(latex: value))
            case .word(let name) where !TimelinePlainMath.functions.contains(name):
                index += 1
                return withScripts(Piece(latex: name))
            case .op("-"):
                index += 1
                return parseArgumentFactor().map { Piece(latex: "-" + $0.latex) }
            default:
                return nil
            }
        }

        private mutating func withScripts(_ base: Piece) -> Piece? {
            var base = base
            while index < tokens.count {
                if case .superscript(let value) = tokens[index] {
                    index += 1
                    base = Piece(latex: base.latex + "^{" + value + "}")
                } else if tokens[index] == .op("^") {
                    index += 1
                    guard let exponent = parsePrimary() else { return nil }
                    base = Piece(latex: base.latex + "^{" + (exponent.inner ?? exponent.latex) + "}")
                } else {
                    break
                }
            }
            return base
        }
    }
}
