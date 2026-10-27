import Foundation

/// タイムラインの検算に使う式(Issue #46「保存する前に数式で検算する」)。AI が返した `checks` の両辺・答えの式・
/// 手書きを読み取った式を、いくつかの点で数値に直して同じかどうかを確かめる。端末の中だけで動き、AI を待たない。
///
/// 書き方: `+ - * / ^`、かっこ、1 文字の変数、`sqrt sin cos tan exp log abs`、`pi`・`e`。掛け算の省略(`2x`、`2(x-1)`、
/// `(x-1)(x+1)`)と、`−`・`×`・`÷`・`²`・`³` も読む。等式は `y = ...` の右辺、座標は `(2, -5)` の組として読む。
nonisolated indirect enum TimelineExpression: Equatable, Sendable {
    case number(Double)
    case variable(String)
    case unary(String, TimelineExpression)
    case binary(Character, TimelineExpression, TimelineExpression)
    case call(String, TimelineExpression)
    case tuple([TimelineExpression])

    nonisolated enum ParseError: Error, Equatable { case unexpected(String), empty }

    static let functions: Set<String> = ["sqrt", "sin", "cos", "tan", "exp", "log", "abs", "ln"]

    // MARK: 読む

    static func parse(_ source: String) throws -> TimelineExpression {
        var text = normalize(source)
        // `y = 2x + 1` は右辺。`f(x) = ...` も同じ。
        if let range = text.range(of: "="), !text[range.upperBound...].contains("=") {
            let left = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if left.count <= 4 { text = String(text[range.upperBound...]) }
        }
        var parser = Parser(tokens: try tokenize(text))
        let value = try parser.expression()
        guard parser.isAtEnd else { throw ParseError.unexpected(parser.peek.map { "\($0)" } ?? "") }
        return value
    }

    static func normalize(_ source: String) -> String {
        var text = source
        // \frac{a}{b} → ((a)/(b))(入れ子は内側から)
        let frac = try! NSRegularExpression(pattern: #"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#)
        while let match = frac.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let replacement = frac.replacementString(for: match, in: text, offset: 0, template: "(($1)/($2))")
            text = (text as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        for (from, to) in [("−", "-"), ("–", "-"), ("×", "*"), ("·", "*"), ("÷", "/"), ("²", "^2"), ("³", "^3"), ("，", ","), ("（", "("), ("）", ")"),
                           ("\\left", ""), ("\\right", ""), ("\\cdot", "*"), ("\\times", "*"), ("\\pi", "pi"), ("**", "^"), ("{", "("), ("}", ")")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        text = text.replacingOccurrences(of: "\\sqrt", with: "sqrt")
        return text.replacingOccurrences(of: "\\", with: "")
    }

    nonisolated enum Token: Equatable, CustomStringConvertible {
        case number(Double), name(String), symbol(Character)
        var description: String {
            switch self {
            case .number(let n): "\(n)"
            case .name(let n): n
            case .symbol(let c): String(c)
            }
        }
    }

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c.isWhitespace { index += 1; continue }
            if c.isNumber || c == "." {
                var end = index
                while end < chars.count, chars[end].isNumber || chars[end] == "." { end += 1 }
                guard let value = Double(String(chars[index..<end])) else { throw ParseError.unexpected(String(chars[index..<end])) }
                tokens.append(.number(value))
                index = end
                continue
            }
            if c.isLetter {
                var end = index
                while end < chars.count, chars[end].isLetter, chars[end].isASCII { end += 1 }
                guard end > index else { throw ParseError.unexpected(String(c)) }
                var word = Substring(String(chars[index..<end]).lowercased())
                // 関数名・定数はひとまとまり、それ以外は 1 文字ずつの変数の積(`ax` = a*x、`sinx` = sin x)。
                while !word.isEmpty {
                    if let name = (functions.sorted { $0.count > $1.count } + ["pi"]).first(where: { word.hasPrefix($0) }) {
                        tokens.append(.name(name))
                        word = word.dropFirst(name.count)
                    } else {
                        tokens.append(.name(String(word.removeFirst())))
                    }
                }
                index = end
                continue
            }
            if "+-*/^(),".contains(c) {
                tokens.append(.symbol(c))
                index += 1
                continue
            }
            throw ParseError.unexpected(String(c))
        }
        guard !tokens.isEmpty else { throw ParseError.empty }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0
        init(tokens: [Token]) { self.tokens = tokens }
        var isAtEnd: Bool { index >= tokens.count }
        var peek: Token? { isAtEnd ? nil : tokens[index] }
        mutating func next() -> Token? { defer { index += 1 }; return peek }

        mutating func expression() throws -> TimelineExpression {
            var value = try term()
            while case .symbol(let c)? = peek, c == "+" || c == "-" {
                index += 1
                value = .binary(c, value, try term())
            }
            return value
        }

        mutating func term() throws -> TimelineExpression {
            var value = try unary()
            while true {
                if case .symbol(let c)? = peek, c == "*" || c == "/" {
                    index += 1
                    value = .binary(c, value, try unary())
                } else if startsFactor {
                    // 掛け算の省略: 2x、2(x-1)、x sin x
                    value = .binary("*", value, try power())
                } else {
                    return value
                }
            }
        }

        var startsFactor: Bool {
            switch peek {
            case .number?, .name?: true
            case .symbol(let c)?: c == "("
            default: false
            }
        }

        mutating func unary() throws -> TimelineExpression {
            if case .symbol(let c)? = peek, c == "-" || c == "+" {
                index += 1
                let operand = try unary()
                return c == "-" ? .unary("-", operand) : operand
            }
            return try power()
        }

        mutating func power() throws -> TimelineExpression {
            let base = try primary()
            if case .symbol("^")? = peek {
                index += 1
                return .binary("^", base, try unary())
            }
            return base
        }

        mutating func primary() throws -> TimelineExpression {
            switch next() {
            case .number(let value)?:
                return .number(value)
            case .name(let name)?:
                if name == "pi" { return .number(Double.pi) }
                if TimelineExpression.functions.contains(name) {
                    if case .symbol("(")? = peek { return .call(name, try primary()) }
                    return .call(name, try power())
                }
                return .variable(name)
            case .symbol("(")?:
                var items = [try expression()]
                while case .symbol(",")? = peek {
                    index += 1
                    items.append(try expression())
                }
                guard case .symbol(")")? = next() else { throw ParseError.unexpected(")") }
                return items.count == 1 ? items[0] : .tuple(items)
            case let token?:
                throw ParseError.unexpected(token.description)
            case nil:
                throw ParseError.empty
            }
        }
    }

    // MARK: 値

    var variables: Set<String> {
        switch self {
        case .number: []
        case .variable(let name): name == "e" ? [] : [name]
        case .unary(_, let x), .call(_, let x): x.variables
        case .binary(_, let a, let b): a.variables.union(b.variables)
        case .tuple(let items): items.reduce(into: Set<String>()) { $0.formUnion($1.variables) }
        }
    }

    /// 値。組(座標)は使えない(`values` を使う)。
    func evaluate(_ bindings: [String: Double]) -> Double? {
        switch self {
        case .number(let value): return value
        case .variable(let name): return bindings[name] ?? (name == "e" ? M_E : nil)
        case .unary(_, let x): return x.evaluate(bindings).map { -$0 }
        case .call(let name, let x):
            guard let v = x.evaluate(bindings) else { return nil }
            switch name {
            case "sqrt": return v < 0 ? nil : v.squareRoot()
            case "sin": return sin(v)
            case "cos": return cos(v)
            case "tan": return tan(v)
            case "exp": return exp(v)
            case "log", "ln": return v <= 0 ? nil : log(v)
            case "abs": return abs(v)
            default: return nil
            }
        case .binary(let op, let a, let b):
            guard let l = a.evaluate(bindings), let r = b.evaluate(bindings) else { return nil }
            switch op {
            case "+": return l + r
            case "-": return l - r
            case "*": return l * r
            case "/": return r == 0 ? nil : l / r
            case "^":
                let value = pow(l, r)
                return value.isFinite ? value : nil
            default: return nil
            }
        case .tuple: return nil
        }
    }

    func values(_ bindings: [String: Double]) -> [Double]? {
        if case .tuple(let items) = self {
            let values = items.compactMap { $0.evaluate(bindings) }
            return values.count == items.count ? values : nil
        }
        return evaluate(bindings).map { [$0] }
    }

    // MARK: 比べる

    /// 2 つの式が同じか(どの変数にも、決まった数組の値を入れて比べる。組は要素ごと)。読めない式は nil。
    static func equivalent(_ left: String, _ right: String, tolerance: Double = 1e-6) -> Bool? {
        guard let a = try? parse(left), let b = try? parse(right) else { return nil }
        return equivalent(a, b, tolerance: tolerance)
    }

    static func equivalent(_ a: TimelineExpression, _ b: TimelineExpression, tolerance: Double = 1e-6) -> Bool {
        let names = Array(a.variables.union(b.variables)).sorted()
        var compared = 0
        for sample in samplePoints {
            var bindings: [String: Double] = [:]
            for (offset, name) in names.enumerated() { bindings[name] = sample[offset % sample.count] + Double(offset) * 0.37 }
            guard let l = a.values(bindings), let r = b.values(bindings) else { continue }
            guard l.count == r.count else { return false }
            for (x, y) in zip(l, r) where abs(x - y) > tolerance * max(1, abs(x), abs(y)) { return false }
            compared += 1
        }
        return compared >= 2
    }

    static let samplePoints: [[Double]] = [[0.5, 1.3, -0.7], [2.25, -1.5, 0.9], [-1.75, 3.1, 1.6], [3.4, 0.6, -2.2], [-2.6, -0.8, 2.7], [1.1, 2.9, -1.3]]

    /// `f` の頂点(二次関数のとき)。数値微分で軸を求める。二次でなければ nil。
    static func vertex(of source: String) -> (x: Double, y: Double)? {
        guard let f = try? parse(source), f.variables.count == 1, let name = f.variables.first else { return nil }
        func value(_ x: Double) -> Double? { f.evaluate([name: x]) }
        // 二次かどうか: 2 階の差分が一定で 0 でない。
        let h = 0.5
        var seconds: [Double] = []
        for x in stride(from: -3.0, through: 3.0, by: 1.5) {
            guard let a = value(x - h), let b = value(x), let c = value(x + h) else { return nil }
            seconds.append((a - 2 * b + c) / (h * h))
        }
        guard let first = seconds.first, abs(first) > 1e-9, seconds.allSatisfy({ abs($0 - first) < 1e-6 * max(1, abs(first)) }) else { return nil }
        guard let f0 = value(0), let f1 = value(1) else { return nil }
        // f(x) = a x^2 + b x + c
        let a = first / 2
        let b = f1 - f0 - a
        let x0 = -b / (2 * a)
        guard let y0 = value(x0) else { return nil }
        return (x0, y0)
    }
}
