import Foundation

/// 複素数(数値の点検用)。
nonisolated struct DrillComplex: Equatable, Sendable {
    var real: Double
    var imaginary: Double

    init(_ real: Double, _ imaginary: Double = 0) {
        self.real = real
        self.imaginary = imaginary
    }

    static let zero: DrillComplex = DrillComplex(0)
    static let one: DrillComplex = DrillComplex(1)
    static let i: DrillComplex = DrillComplex(0, 1)

    var isFinite: Bool { real.isFinite && imaginary.isFinite }
    var modulus: Double { (real * real + imaginary * imaginary).squareRoot() }
    var isReal: Bool { abs(imaginary) <= 1e-12 * Swift.max(1, abs(real)) }

    static func + (a: DrillComplex, b: DrillComplex) -> DrillComplex { DrillComplex(a.real + b.real, a.imaginary + b.imaginary) }
    static func - (a: DrillComplex, b: DrillComplex) -> DrillComplex { DrillComplex(a.real - b.real, a.imaginary - b.imaginary) }
    static func * (a: DrillComplex, b: DrillComplex) -> DrillComplex {
        DrillComplex(a.real * b.real - a.imaginary * b.imaginary, a.real * b.imaginary + a.imaginary * b.real)
    }
    static func / (a: DrillComplex, b: DrillComplex) -> DrillComplex {
        let size: Double = b.real * b.real + b.imaginary * b.imaginary
        return DrillComplex((a.real * b.real + a.imaginary * b.imaginary) / size, (a.imaginary * b.real - a.real * b.imaginary) / size)
    }
    static prefix func - (a: DrillComplex) -> DrillComplex { DrillComplex(-a.real, -a.imaginary) }

    var exponential: DrillComplex {
        let size: Double = exp(real)
        return DrillComplex(size * cos(imaginary), size * sin(imaginary))
    }

    /// 対数の主値。
    var logarithm: DrillComplex { DrillComplex(log(modulus), atan2(imaginary, real)) }

    /// 平方根の主値。
    var squareRoot: DrillComplex {
        if imaginary == 0 { return real >= 0 ? DrillComplex(real.squareRoot()) : DrillComplex(0, (-real).squareRoot()) }
        let size: Double = modulus
        let re: Double = ((size + real) / 2).squareRoot()
        let im: Double = ((size - real) / 2).squareRoot()
        return DrillComplex(re, imaginary < 0 ? -im : im)
    }

    var sine: DrillComplex { DrillComplex(sin(real) * cosh(imaginary), cos(real) * sinh(imaginary)) }
    var cosine: DrillComplex { DrillComplex(cos(real) * cosh(imaginary), -sin(real) * sinh(imaginary)) }

    func power(_ exponent: DrillComplex) -> DrillComplex {
        if exponent.imaginary == 0, exponent.real == exponent.real.rounded(), abs(exponent.real) <= 512 {
            var result: DrillComplex = DrillComplex.one
            for _ in 0..<Int(abs(exponent.real)) { result = result * self }
            return exponent.real < 0 ? DrillComplex.one / result : result
        }
        if real == 0, imaginary == 0 {
            return exponent.real > 0 ? DrillComplex.zero : DrillComplex(Double.nan)
        }
        return (exponent * logarithm).exponential
    }

    /// 相対誤差で近いか。
    func isClose(to other: DrillComplex, tolerance: Double) -> Bool {
        (self - other).modulus <= tolerance * Swift.max(1, modulus, other.modulus)
    }
}

/// 画面に出す LaTeX の式を、数値にするために読んだもの(docs/offline-drill/format.md「数値の点検」)。
/// 点検器が「画面に出ている式」と「答え」が合っているかを数値で確かめるのに使う。式の変形はしない。
nonisolated indirect enum DrillTeX: Equatable, Sendable {
    case number(Double)
    case symbol(String)
    case pi
    case negate(DrillTeX)
    case binary(Character, DrillTeX, DrillTeX)
    /// a ± b(`left` が無ければ ±b)。`flipped` は ∓。
    case plusMinus(left: DrillTeX?, right: DrillTeX, flipped: Bool)
    case call(String, DrillTeX)
    case logarithm(base: DrillTeX, DrillTeX)
    case root(degree: DrillTeX, DrillTeX)
    case factorial(DrillTeX)
    /// 度(30^\circ)。
    case degrees(DrillTeX)

    nonisolated struct ParseError: Error, Equatable, Sendable {
        let message: String
    }

    static let functions: Set<String> = ["sin", "cos", "tan", "log", "ln", "exp", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh"]
    static let greek: Set<String> = ["alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "theta", "lambda", "mu", "nu", "rho", "sigma", "tau", "phi", "varphi", "omega"]
    private static let skipped: Set<String> = ["left", "right", "displaystyle", "quad", "qquad", "limits", "bigl", "bigr", "Bigl", "Bigr", "big", "Big"]

    // MARK: 読む

    private nonisolated enum Token: Equatable {
        case number(String)
        case letter(Character)
        case command(String)
        case symbol(Character)
    }

    private static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        let characters: [Character] = Array(source)
        var index: Int = 0
        while index < characters.count {
            let c: Character = characters[index]
            if c.isWhitespace { index += 1; continue }
            if c == "\\" {
                var end: Int = index + 1
                while end < characters.count, characters[end].isASCII, characters[end].isLetter { end += 1 }
                if end == index + 1 {
                    // \, \; \! \  は空き。\{ \} はかっこ。\% は読めない。
                    guard end < characters.count else { throw ParseError(message: "「\\」で終わっています") }
                    let next: Character = characters[end]
                    if next == "{" { tokens.append(Token.symbol("(")) } else if next == "}" { tokens.append(Token.symbol(")")) } else if !",;! :".contains(next) {
                        throw ParseError(message: "「\\\(next)」は数値にできません")
                    }
                    index = end + 1
                    continue
                }
                let name: String = String(characters[(index + 1)..<end])
                index = end
                if skipped.contains(name) { continue }
                switch name {
                case "cdot", "times": tokens.append(Token.symbol("*"))
                case "div": tokens.append(Token.symbol("/"))
                case "lvert", "rvert", "vert": tokens.append(Token.symbol("|"))
                case "lbrace": tokens.append(Token.symbol("("))
                case "rbrace": tokens.append(Token.symbol(")"))
                case "dfrac", "tfrac": tokens.append(Token.command("frac"))
                default: tokens.append(Token.command(name))
                }
                continue
            }
            if c.isASCII, c.isNumber {
                var end: Int = index
                while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }
                if end + 1 < characters.count, characters[end] == ".", characters[end + 1].isASCII, characters[end + 1].isNumber {
                    end += 1
                    while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }
                }
                tokens.append(Token.number(String(characters[index..<end])))
                index = end
                continue
            }
            if c.isASCII, c.isLetter { tokens.append(Token.letter(c)); index += 1; continue }
            switch c {
            case "−", "–": tokens.append(Token.symbol("-"))
            case "×", "·": tokens.append(Token.symbol("*"))
            case "÷": tokens.append(Token.symbol("/"))
            case "π": tokens.append(Token.command("pi"))
            case "±": tokens.append(Token.command("pm"))
            case "+", "-", "*", "/", "^", "_", "(", ")", "[", "]", "{", "}", "|", ",", "!", "'":
                tokens.append(Token.symbol(c))
            default:
                throw ParseError(message: "「\(c)」は数値にできません")
            }
            index += 1
        }
        return tokens
    }

    private nonisolated struct Parser {
        let tokens: [Token]
        let source: String
        var index: Int = 0
        /// 絶対値の「|」の中にいる深さ(閉じる「|」を見分ける)。
        var bars: Int = 0

        var peek: Token? { index < tokens.count ? tokens[index] : nil }

        mutating func accept(_ symbol: Character) -> Bool {
            if peek == Token.symbol(symbol) {
                index += 1
                return true
            }
            return false
        }

        func fail(_ message: String) -> ParseError {
            ParseError(message: "式「\(source)」: \(message)")
        }

        mutating func list() throws -> [DrillTeX] {
            var items: [DrillTeX] = [try sum()]
            while accept(",") { items.append(try sum()) }
            return items
        }

        mutating func sum() throws -> DrillTeX {
            var value: DrillTeX
            if accept("-") {
                value = DrillTeX.negate(try product())
            } else if peek == Token.command("pm") || peek == Token.command("mp") {
                let flipped: Bool = peek == Token.command("mp")
                index += 1
                value = DrillTeX.plusMinus(left: nil, right: try product(), flipped: flipped)
            } else {
                _ = accept("+")
                value = try product()
            }
            while true {
                if accept("+") {
                    value = DrillTeX.binary("+", value, try product())
                } else if accept("-") {
                    value = DrillTeX.binary("-", value, try product())
                } else if peek == Token.command("pm") || peek == Token.command("mp") {
                    let flipped: Bool = peek == Token.command("mp")
                    index += 1
                    value = DrillTeX.plusMinus(left: value, right: try product(), flipped: flipped)
                } else {
                    return value
                }
            }
        }

        /// 次の字句から、掛け算を省いた因数が始まるか。
        func startsFactor(allowFunction: Bool) -> Bool {
            switch peek {
            case Token.number?, Token.letter?: return true
            case Token.symbol(let c)?:
                if c == "|" { return bars == 0 }
                return c == "(" || c == "{" || c == "["
            case Token.command(let name)?:
                if DrillTeX.functions.contains(name) { return allowFunction }
                return name == "frac" || name == "sqrt" || name == "pi" || DrillTeX.greek.contains(name)
            case nil: return false
            }
        }

        mutating func product() throws -> DrillTeX {
            var value: DrillTeX = try signedFactor()
            while true {
                if accept("*") {
                    value = DrillTeX.binary("*", value, try signedFactor())
                } else if accept("/") {
                    value = DrillTeX.binary("/", value, try signedFactor())
                } else if startsFactor(allowFunction: true) {
                    value = DrillTeX.binary("*", value, try postfix())
                } else {
                    return value
                }
            }
        }

        mutating func signedFactor() throws -> DrillTeX {
            if accept("-") { return DrillTeX.negate(try signedFactor()) }
            if accept("+") { return try signedFactor() }
            return try postfix()
        }

        mutating func postfix() throws -> DrillTeX {
            var value: DrillTeX = try atom()
            while true {
                if accept("^") {
                    if peek == Token.command("circ") {
                        index += 1
                        value = DrillTeX.degrees(value)
                    } else if peek == Token.symbol("{"), index + 2 < tokens.count, tokens[index + 1] == Token.command("circ"), tokens[index + 2] == Token.symbol("}") {
                        index += 3
                        value = DrillTeX.degrees(value)
                    } else {
                        value = DrillTeX.binary("^", value, try argument())
                    }
                } else if accept("!") {
                    value = DrillTeX.factorial(value)
                } else {
                    return value
                }
            }
        }

        /// 命令や上付き・下付きの引数: `{…}` か、字句 1 つ。
        mutating func argument() throws -> DrillTeX {
            if accept("{") {
                if accept("}") { throw fail("空の波かっこがあります") }
                let inner: DrillTeX = try sum()
                guard accept("}") else { throw fail("波かっこが閉じていません") }
                return inner
            }
            guard let token: Token = peek else { throw fail("途中で終わっています") }
            index += 1
            switch token {
            case Token.number(let digits):
                guard digits.count == 1, let value: Double = Double(digits) else { throw fail("2 桁以上の指数や添字は波かっこで囲んでください(「\(digits)」)") }
                return DrillTeX.number(value)
            case Token.letter(let letter):
                return DrillTeX.symbol(String(letter))
            case Token.command("pi"):
                return DrillTeX.pi
            case Token.command(let name) where DrillTeX.greek.contains(name):
                return DrillTeX.symbol(name)
            case Token.command("frac"):
                index -= 1
                return try atom()
            case Token.symbol("-"):
                return DrillTeX.negate(try argument())
            default:
                throw fail("引数が読めません")
            }
        }

        /// 添字を名前の一部として読む(x_1、a_{n})。
        mutating func subscriptName() throws -> String {
            if accept("{") {
                var name: String = ""
                while let token: Token = peek, token != Token.symbol("}") {
                    index += 1
                    switch token {
                    case Token.number(let digits): name += digits
                    case Token.letter(let letter): name.append(letter)
                    case Token.command(let command): name += command
                    default: throw fail("添字が読めません")
                    }
                }
                guard accept("}") else { throw fail("添字の波かっこが閉じていません") }
                return name
            }
            guard let token: Token = peek else { throw fail("添字がありません") }
            index += 1
            switch token {
            case Token.number(let digits): return digits
            case Token.letter(let letter): return String(letter)
            default: throw fail("添字が読めません")
            }
        }

        mutating func symbol(_ base: String) throws -> DrillTeX {
            var name: String = base
            if accept("_") { name += "_" + (try subscriptName()) }
            while accept("'") { name += "'" }
            return DrillTeX.symbol(name)
        }

        mutating func atom() throws -> DrillTeX {
            guard let token: Token = peek else { throw fail("途中で終わっています") }
            index += 1
            switch token {
            case Token.number(let digits):
                guard let value: Double = Double(digits) else { throw fail("数「\(digits)」が読めません") }
                return DrillTeX.number(value)
            case Token.letter(let letter):
                return try symbol(String(letter))
            case Token.symbol("("), Token.symbol("["):
                let outerBars: Int = bars
                bars = 0
                let inner: DrillTeX = try sum()
                guard accept(")") || accept("]") else { throw fail("かっこが閉じていません") }
                bars = outerBars
                return inner
            case Token.symbol("{"):
                if accept("}") { throw fail("空の波かっこがあります") }
                let outerBars: Int = bars
                bars = 0
                let inner: DrillTeX = try sum()
                guard accept("}") else { throw fail("波かっこが閉じていません") }
                bars = outerBars
                return inner
            case Token.symbol("|"):
                bars += 1
                let inner: DrillTeX = try sum()
                guard accept("|") else { throw fail("絶対値の「|」が閉じていません") }
                bars -= 1
                return DrillTeX.call("abs", inner)
            case Token.command("frac"):
                let top: DrillTeX = try argument()
                let bottom: DrillTeX = try argument()
                return DrillTeX.binary("/", top, bottom)
            case Token.command("sqrt"):
                if accept("[") {
                    let degree: DrillTeX = try sum()
                    guard accept("]") else { throw fail("\\sqrt の [ ] が閉じていません") }
                    return DrillTeX.root(degree: degree, try argument())
                }
                return DrillTeX.call("sqrt", try argument())
            case Token.command("pi"):
                return DrillTeX.pi
            case Token.command(let name) where DrillTeX.greek.contains(name):
                return try symbol(name)
            case Token.command(let name) where DrillTeX.functions.contains(name):
                return try function(name)
            case Token.command(let name):
                throw fail("「\\\(name)」は数値にできません")
            case Token.symbol(let c):
                throw fail("「\(c)」の位置が読めません")
            }
        }

        mutating func function(_ name: String) throws -> DrillTeX {
            var base: DrillTeX? = nil
            var exponent: DrillTeX? = nil
            // \log_{2}、\sin^{2} はどちらの順でもよい。
            for _ in 0..<2 {
                if name == "log", base == nil, accept("_") {
                    base = try argument()
                } else if exponent == nil, accept("^") {
                    exponent = try argument()
                }
            }
            let inner: DrillTeX
            if peek == Token.symbol("(") {
                index += 1
                let outerBars: Int = bars
                bars = 0
                inner = try sum()
                guard accept(")") else { throw fail("\\\(name)( が閉じていません") }
                bars = outerBars
            } else {
                // かっこの無い引数: 掛け算を省いた因数の並び(\sin 2x、\sin \frac{\pi}{3})。次の関数や + - の手前まで。
                var value: DrillTeX = accept("-") ? DrillTeX.negate(try postfix()) : try postfix()
                while startsFactor(allowFunction: false) {
                    value = DrillTeX.binary("*", value, try postfix())
                }
                inner = value
            }
            var result: DrillTeX
            if name == "log", let base: DrillTeX = base {
                result = DrillTeX.logarithm(base: base, inner)
            } else if exponent == DrillTeX.negate(DrillTeX.number(1)), ["sin", "cos", "tan"].contains(name) {
                return DrillTeX.call("arc" + name, inner)
            } else {
                result = DrillTeX.call(name == "log" ? "ln" : name, inner)
            }
            if let exponent: DrillTeX = exponent { result = DrillTeX.binary("^", result, exponent) }
            return result
        }
    }

    /// LaTeX の式を読む。コンマで区切られていれば、その数だけ返す。
    /// 数値にする LaTeX の大きさの上限: 語の数、かっこ(波かっこ・丸かっこ・角かっこ)の入れ子の深さ、続けて書ける符号の数。
    /// 読む時と計算する時の再帰が浅く収まるようにする(AI が極端な式を書いても、スタックを使い切って落ちない)。
    /// 実際に書いた型の点検の式は、入れ子が 5 段まで。
    static let maximumTokens: Int = 200
    static let maximumDepth: Int = 24
    static let maximumSigns: Int = 6

    static func parse(_ source: String) throws -> [DrillTeX] {
        let tokens: [Token] = try tokenize(source)
        guard tokens.count <= maximumTokens else { throw ParseError(message: "式が長すぎて数値にできません(「\(source.prefix(40))…」)") }
        var depth: Int = 0
        var signs: Int = 0
        for token: Token in tokens {
            if case Token.symbol(let c) = token {
                if c == "{" || c == "(" || c == "[" || c == "|" { depth += 1 }
                if c == "}" || c == ")" || c == "]" { depth = max(0, depth - 1) }
                signs = (c == "-" || c == "+") ? signs + 1 : 0
            } else if token == Token.command("frac") || token == Token.command("sqrt") {
                signs = 0
            } else {
                signs = 0
            }
            guard depth <= maximumDepth, signs <= maximumSigns else { throw ParseError(message: "式の入れ子が深すぎて数値にできません(「\(source.prefix(40))…」)") }
        }
        var parser: Parser = Parser(tokens: tokens, source: source)
        guard parser.peek != nil else { throw ParseError(message: "式が空です") }
        let items: [DrillTeX] = try parser.list()
        guard parser.peek == nil else { throw ParseError(message: "式「\(source)」に読めない所があります") }
        return items
    }

    // MARK: 値

    /// 式に出てくる文字(e と i は定数として扱うので含めない)。
    var symbols: Set<String> {
        switch self {
        case DrillTeX.number, DrillTeX.pi: return []
        case DrillTeX.symbol(let name): return name == "e" || name == "i" ? [] : [name]
        case DrillTeX.negate(let inner), DrillTeX.call(_, let inner), DrillTeX.factorial(let inner), DrillTeX.degrees(let inner): return inner.symbols
        case DrillTeX.binary(_, let left, let right): return left.symbols.union(right.symbols)
        case DrillTeX.plusMinus(let left, let right, _): return (left?.symbols ?? []).union(right.symbols)
        case DrillTeX.logarithm(let base, let inner): return base.symbols.union(inner.symbols)
        case DrillTeX.root(let degree, let inner): return degree.symbols.union(inner.symbols)
        }
    }

    var hasPlusMinus: Bool {
        switch self {
        case DrillTeX.number, DrillTeX.pi, DrillTeX.symbol: return false
        case DrillTeX.negate(let inner), DrillTeX.call(_, let inner), DrillTeX.factorial(let inner), DrillTeX.degrees(let inner): return inner.hasPlusMinus
        case DrillTeX.binary(_, let left, let right): return left.hasPlusMinus || right.hasPlusMinus
        case DrillTeX.plusMinus: return true
        case DrillTeX.logarithm(let base, let inner): return base.hasPlusMinus || inner.hasPlusMinus
        case DrillTeX.root(let degree, let inner): return degree.hasPlusMinus || inner.hasPlusMinus
        }
    }

    /// 値。定まらない時は nil。`sign` は ± のどちらを取るか(+1 か -1)。
    func evaluate(_ bindings: [String: DrillComplex], sign: Double = 1) -> DrillComplex? {
        func finite(_ value: DrillComplex) -> DrillComplex? { value.isFinite ? value : nil }
        switch self {
        case DrillTeX.number(let value):
            return DrillComplex(value)
        case DrillTeX.pi:
            return DrillComplex(Double.pi)
        case DrillTeX.symbol(let name):
            if let bound: DrillComplex = bindings[name] { return bound }
            if name == "e" { return DrillComplex(M_E) }
            if name == "i" { return DrillComplex.i }
            return nil
        case DrillTeX.negate(let inner):
            return inner.evaluate(bindings, sign: sign).map { (value: DrillComplex) -> DrillComplex in -value }
        case DrillTeX.degrees(let inner):
            return inner.evaluate(bindings, sign: sign).map { (value: DrillComplex) -> DrillComplex in value * DrillComplex(Double.pi / 180) }
        case DrillTeX.plusMinus(let left, let right, let flipped):
            guard let r: DrillComplex = right.evaluate(bindings, sign: sign) else { return nil }
            let l: DrillComplex
            if let left: DrillTeX = left {
                guard let value: DrillComplex = left.evaluate(bindings, sign: sign) else { return nil }
                l = value
            } else {
                l = DrillComplex.zero
            }
            return l + DrillComplex(flipped ? -sign : sign) * r
        case DrillTeX.binary:
            // 左に伸びる連なり(a + b + c + …)は、再帰せずに左から順に計算する(長い式でスタックを使い切らないように)。
            var pending: [(op: Character, right: DrillTeX)] = []
            var node: DrillTeX = self
            while case DrillTeX.binary(let op, let left, let right) = node {
                pending.append((op, right))
                node = left
            }
            guard var value: DrillComplex = node.evaluate(bindings, sign: sign) else { return nil }
            for step: (op: Character, right: DrillTeX) in pending.reversed() {
                guard let r: DrillComplex = step.right.evaluate(bindings, sign: sign) else { return nil }
                let next: DrillComplex?
                switch step.op {
                case "+": next = finite(value + r)
                case "-": next = finite(value - r)
                case "*": next = finite(value * r)
                case "/": next = r.modulus == 0 ? nil : finite(value / r)
                case "^": next = finite(value.power(r))
                default: next = nil
                }
                guard let result: DrillComplex = next else { return nil }
                value = result
            }
            return value
        case DrillTeX.factorial(let inner):
            guard let value: DrillComplex = inner.evaluate(bindings, sign: sign), value.isReal, value.real >= 0, value.real <= 170, value.real == value.real.rounded() else { return nil }
            return DrillComplex((1...max(1, Int(value.real))).reduce(1.0) { (product: Double, k: Int) -> Double in product * Double(k) })
        case DrillTeX.logarithm(let base, let inner):
            guard let b: DrillComplex = base.evaluate(bindings, sign: sign), let x: DrillComplex = inner.evaluate(bindings, sign: sign), b.modulus != 0, x.modulus != 0 else { return nil }
            let bottom: DrillComplex = b.logarithm
            return bottom.modulus == 0 ? nil : finite(x.logarithm / bottom)
        case DrillTeX.root(let degree, let inner):
            guard let n: DrillComplex = degree.evaluate(bindings, sign: sign), let x: DrillComplex = inner.evaluate(bindings, sign: sign), n.modulus != 0 else { return nil }
            // 負の実数の奇数乗根は、負の実数にする(∛(-8) = -2)。
            if x.isReal, x.real < 0, n.isReal, n.real == n.real.rounded(), Int(n.real) % 2 != 0 {
                return DrillComplex(-pow(-x.real, 1 / n.real))
            }
            return finite(x.power(DrillComplex.one / n))
        case DrillTeX.call(let name, let inner):
            guard let x: DrillComplex = inner.evaluate(bindings, sign: sign) else { return nil }
            switch name {
            case "sqrt": return finite(x.squareRoot)
            case "abs": return DrillComplex(x.modulus)
            case "sin": return finite(x.sine)
            case "cos": return finite(x.cosine)
            case "tan":
                let bottom: DrillComplex = x.cosine
                return bottom.modulus < 1e-12 ? nil : finite(x.sine / bottom)
            case "exp": return finite(x.exponential)
            case "ln": return x.modulus == 0 ? nil : finite(x.logarithm)
            case "sinh": return finite((x.exponential - (-x).exponential) / DrillComplex(2))
            case "cosh": return finite((x.exponential + (-x).exponential) / DrillComplex(2))
            case "tanh":
                let bottom: DrillComplex = x.exponential + (-x).exponential
                return bottom.modulus == 0 ? nil : finite((x.exponential - (-x).exponential) / bottom)
            case "arcsin": return x.isReal && abs(x.real) <= 1 ? DrillComplex(asin(x.real)) : nil
            case "arccos": return x.isReal && abs(x.real) <= 1 ? DrillComplex(acos(x.real)) : nil
            case "arctan": return x.isReal ? DrillComplex(atan(x.real)) : nil
            default: return nil
            }
        }
    }

    /// 式の値をすべて返す(コンマ区切りと ± を展開する)。どれかが定まらなければ nil。
    static func values(of items: [DrillTeX], bindings: [String: DrillComplex]) -> [DrillComplex]? {
        var out: [DrillComplex] = []
        for item: DrillTeX in items {
            let signs: [Double] = item.hasPlusMinus ? [1, -1] : [1]
            for sign: Double in signs {
                guard let value: DrillComplex = item.evaluate(bindings, sign: sign) else { return nil }
                out.append(value)
            }
        }
        return out
    }
}
