import Foundation

/// 型の式(docs/offline-drill/format.md「式の書き方」)。変数どうしの四則演算・累乗・比較と、決まった関数だけを読む。
/// 型の中身をコードとして実行する仕組みは使わない。式は文字列をここで読み取り、許した演算だけを評価する。
nonisolated indirect enum DrillExpression: Hashable, Sendable {
    case number(DrillNumber)
    case string(String)
    case name(String)
    case member(DrillExpression, String)
    case negate(DrillExpression)
    case not(DrillExpression)
    case binary(String, DrillExpression, DrillExpression)
    case call(String, [DrillExpression])

    nonisolated struct SyntaxError: Error, Equatable, Sendable {
        let message: String
    }

    /// 評価できなかった理由。
    nonisolated enum EvaluationError: Error, Equatable, Sendable {
        /// 値が定まらない(0 で割る、負の数の平方根、定義域の外など)。
        case undefined(String)
        /// 次元が合わない。
        case dimension(String)
        /// 数を期待した所に文字列がある、など。
        case type(String)
        case unknownName(String)
        case unknownFunction(String)

        var message: String {
            switch self {
            case EvaluationError.undefined(let text): return text
            case EvaluationError.dimension(let text): return text
            case EvaluationError.type(let text): return text
            case EvaluationError.unknownName(let name): return "「\(name)」という名前がありません"
            case EvaluationError.unknownFunction(let name): return "「\(name)」という関数はありません"
            }
        }
    }

    // MARK: 読む

    private nonisolated enum Token: Equatable {
        case number(DrillNumber)
        case string(String)
        case identifier(String)
        case symbol(String)
    }

    private static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        let characters: [Character] = Array(source)
        var index: Int = 0
        func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
        while index < characters.count {
            let c: Character = characters[index]
            if c.isWhitespace { index += 1; continue }
            if isDigit(c) || (c == "." && index + 1 < characters.count && isDigit(characters[index + 1])) {
                var end: Int = index
                while end < characters.count, isDigit(characters[end]) { end += 1 }
                if end < characters.count, characters[end] == ".", end + 1 < characters.count, isDigit(characters[end + 1]) {
                    end += 1
                    while end < characters.count, isDigit(characters[end]) { end += 1 }
                }
                // 指数表記(6.02e23)。「e」の後に数字が続く時だけ。
                if end < characters.count, characters[end] == "e" || characters[end] == "E" {
                    var probe: Int = end + 1
                    if probe < characters.count, characters[probe] == "-" || characters[probe] == "+" { probe += 1 }
                    if probe < characters.count, isDigit(characters[probe]) {
                        while probe < characters.count, isDigit(characters[probe]) { probe += 1 }
                        end = probe
                    }
                }
                let literal: String = String(characters[index..<end])
                if let number: DrillNumber = DrillNumber(decimal: literal) {
                    tokens.append(Token.number(number))
                } else if let double: Double = Double(literal) {
                    tokens.append(Token.number(DrillNumber.real(double)))
                } else {
                    throw SyntaxError(message: "数「\(literal)」が読めません")
                }
                index = end
                continue
            }
            if c.isLetter && c.isASCII || c == "_" {
                var end: Int = index
                while end < characters.count, (characters[end].isASCII && (characters[end].isLetter || characters[end].isNumber)) || characters[end] == "_" { end += 1 }
                tokens.append(Token.identifier(String(characters[index..<end])))
                index = end
                continue
            }
            if c == "'" {
                guard let close: Int = characters[(index + 1)...].firstIndex(of: "'") else { throw SyntaxError(message: "文字列の「'」が閉じていません") }
                tokens.append(Token.string(String(characters[(index + 1)..<close])))
                index = close + 1
                continue
            }
            let pair: String = index + 1 < characters.count ? String(characters[index...(index + 1)]) : ""
            if ["==", "!=", "<=", ">="].contains(pair) {
                tokens.append(Token.symbol(pair))
                index += 2
                continue
            }
            if "+-*/^(),.<>".contains(c) {
                tokens.append(Token.symbol(String(c)))
                index += 1
                continue
            }
            throw SyntaxError(message: "式「\(source)」の「\(c)」が読めません")
        }
        return tokens
    }

    private nonisolated struct Parser {
        let tokens: [Token]
        let source: String
        var index: Int = 0
        /// かっこ・関数の引数・符号の入れ子の深さ。
        var depth: Int = 0

        var peek: Token? { index < tokens.count ? tokens[index] : nil }

        /// 入れ子を 1 段深くする。深すぎる式は断る(読む時の再帰でスタックを使い切らないように)。
        mutating func descend() throws {
            depth += 1
            guard depth <= DrillExpression.maximumDepth else { throw SyntaxError(message: "式のかっこの入れ子が深すぎます(「\(source.prefix(40))…」)。lets に分けて書いてください") }
        }

        mutating func accept(_ symbol: String) -> Bool {
            if peek == Token.symbol(symbol) {
                index += 1
                return true
            }
            return false
        }

        mutating func acceptWord(_ word: String) -> Bool {
            if peek == Token.identifier(word) {
                index += 1
                return true
            }
            return false
        }

        mutating func expression() throws -> DrillExpression {
            var value: DrillExpression = try conjunction()
            while acceptWord("or") {
                value = DrillExpression.binary("or", value, try conjunction())
            }
            return value
        }

        mutating func conjunction() throws -> DrillExpression {
            var value: DrillExpression = try negation()
            while acceptWord("and") {
                value = DrillExpression.binary("and", value, try negation())
            }
            return value
        }

        mutating func negation() throws -> DrillExpression {
            if acceptWord("not") { return DrillExpression.not(try negation()) }
            return try comparison()
        }

        mutating func comparison() throws -> DrillExpression {
            let left: DrillExpression = try sum()
            for symbol: String in ["==", "!=", "<=", ">=", "<", ">"] where accept(symbol) {
                return DrillExpression.binary(symbol, left, try sum())
            }
            return left
        }

        mutating func sum() throws -> DrillExpression {
            var value: DrillExpression = try product()
            while true {
                if accept("+") {
                    value = DrillExpression.binary("+", value, try product())
                } else if accept("-") {
                    value = DrillExpression.binary("-", value, try product())
                } else {
                    return value
                }
            }
        }

        mutating func product() throws -> DrillExpression {
            var value: DrillExpression = try unary()
            while true {
                if accept("*") {
                    value = DrillExpression.binary("*", value, try unary())
                } else if accept("/") {
                    value = DrillExpression.binary("/", value, try unary())
                } else {
                    return value
                }
            }
        }

        mutating func unary() throws -> DrillExpression {
            if accept("-") {
                try descend()
                defer { depth -= 1 }
                return DrillExpression.negate(try unary())
            }
            if accept("+") {
                try descend()
                defer { depth -= 1 }
                return try unary()
            }
            return try power()
        }

        mutating func power() throws -> DrillExpression {
            let base: DrillExpression = try postfix()
            if accept("^") {
                try descend()
                defer { depth -= 1 }
                return DrillExpression.binary("^", base, try unary())
            }
            return base
        }

        mutating func postfix() throws -> DrillExpression {
            var value: DrillExpression = try primary()
            while accept(".") {
                guard case Token.identifier(let field)? = peek else { throw SyntaxError(message: "式「\(source)」の「.」の後に名前がありません") }
                index += 1
                value = DrillExpression.member(value, field)
            }
            return value
        }

        mutating func primary() throws -> DrillExpression {
            guard let token: Token = peek else { throw SyntaxError(message: "式「\(source)」が途中で終わっています") }
            index += 1
            switch token {
            case Token.number(let number):
                return DrillExpression.number(number)
            case Token.string(let text):
                return DrillExpression.string(text)
            case Token.identifier(let name):
                if accept("(") {
                    try descend()
                    defer { depth -= 1 }
                    var arguments: [DrillExpression] = []
                    if !accept(")") {
                        arguments.append(try expression())
                        while accept(",") { arguments.append(try expression()) }
                        guard accept(")") else { throw SyntaxError(message: "式「\(source)」の「\(name)(」が閉じていません") }
                    }
                    return DrillExpression.call(name, arguments)
                }
                return DrillExpression.name(name)
            case Token.symbol("("):
                try descend()
                defer { depth -= 1 }
                let inner: DrillExpression = try expression()
                guard accept(")") else { throw SyntaxError(message: "式「\(source)」のかっこが閉じていません") }
                return inner
            case Token.symbol(let symbol):
                throw SyntaxError(message: "式「\(source)」の「\(symbol)」が読めません")
            }
        }
    }

    /// 1 つの式の長さの上限(語の数)。式の木の深さはこれを超えないので、読む時と計算する時の再帰が浅く収まる
    /// (AI が極端に長い式や深いかっこを書いても、スタックを使い切って落ちない)。
    static let maximumTokens: Int = 400
    /// かっこ・関数の引数・符号の入れ子の深さの上限(実際に書いた型の最大は 16)。
    static let maximumDepth: Int = 40

    static func parse(_ source: String) throws -> DrillExpression {
        let tokens: [Token] = try tokenize(source)
        guard tokens.count <= maximumTokens else { throw SyntaxError(message: "式が長すぎます(「\(source.prefix(40))…」)。lets に分けて書いてください") }
        var parser: Parser = Parser(tokens: tokens, source: source)
        guard parser.peek != nil else { throw SyntaxError(message: "式が空です") }
        let value: DrillExpression = try parser.expression()
        guard parser.peek == nil else { throw SyntaxError(message: "式「\(source)」に余分な文字があります(掛け算の「*」は省けません)") }
        return value
    }

    /// 式に出てくる名前(関数名と定数を除く)。
    var names: Set<String> {
        switch self {
        case DrillExpression.number, DrillExpression.string: return []
        case DrillExpression.name(let name): return [name]
        case DrillExpression.member(let inner, _), DrillExpression.negate(let inner), DrillExpression.not(let inner): return inner.names
        case DrillExpression.binary(_, let left, let right): return left.names.union(right.names)
        case DrillExpression.call(_, let arguments):
            return arguments.reduce(into: Set<String>()) { (set: inout Set<String>, argument: DrillExpression) -> Void in set.formUnion(argument.names) }
        }
    }

    /// 式に出てくる関数名。
    var functionNames: Set<String> {
        switch self {
        case DrillExpression.number, DrillExpression.string, DrillExpression.name: return []
        case DrillExpression.member(let inner, _), DrillExpression.negate(let inner), DrillExpression.not(let inner): return inner.functionNames
        case DrillExpression.binary(_, let left, let right): return left.functionNames.union(right.functionNames)
        case DrillExpression.call(let name, let arguments):
            return arguments.reduce(into: Set<String>([name])) { (set: inout Set<String>, argument: DrillExpression) -> Void in set.formUnion(argument.functionNames) }
        }
    }

    static let constants: Set<String> = ["pi", "e", "i", "true", "false"]

    // MARK: 評価する

    func evaluate(_ scope: [String: DrillValue]) throws -> DrillValue {
        switch self {
        case DrillExpression.number(let number):
            return DrillValue.number(number)
        case DrillExpression.string(let text):
            return DrillValue.text(text)
        case DrillExpression.name(let name):
            if let value: DrillValue = scope[name] { return value }
            switch name {
            case "pi": return DrillValue.number(DrillNumber.real(Double.pi))
            case "e": return DrillValue.number(DrillNumber.real(M_E))
            case "i": return DrillValue.number(DrillNumber.exact(DrillExact.imaginaryUnit))
            case "true": return DrillValue.bool(true)
            case "false": return DrillValue.bool(false)
            default: throw EvaluationError.unknownName(name)
            }
        case DrillExpression.member(let inner, let field):
            guard case DrillValue.record(let fields) = try inner.evaluate(scope) else { throw EvaluationError.type("「.\(field)」は選択肢の組にだけ使えます") }
            guard let value: DrillValue = fields[field] else { throw EvaluationError.unknownName(field) }
            return value
        case DrillExpression.negate(let inner):
            let value: DrillQuantity = try DrillExpression.quantity(try inner.evaluate(scope))
            return DrillValue.quantity(DrillQuantity(DrillArithmetic.negate(value.number), dimension: value.dimension))
        case DrillExpression.not(let inner):
            return DrillValue.bool(!(try DrillExpression.bool(try inner.evaluate(scope))))
        case DrillExpression.binary:
            return try DrillExpression.chain(self, scope)
        case DrillExpression.call(let name, let arguments):
            return try DrillFunctions.call(name, arguments, scope)
        }
    }

    static func quantity(_ value: DrillValue) throws -> DrillQuantity {
        guard case DrillValue.quantity(let quantity) = value else { throw EvaluationError.type("数ではない値を計算に使っています") }
        return quantity
    }

    static func bool(_ value: DrillValue) throws -> Bool {
        guard case DrillValue.bool(let flag) = value else { throw EvaluationError.type("条件ではない値を条件に使っています") }
        return flag
    }

    /// 値が有限の数であることを確かめる。
    static func finite(_ number: DrillNumber, _ what: String) throws -> DrillNumber {
        if case DrillNumber.real(let double) = number, !double.isFinite { throw EvaluationError.undefined("\(what)の値が定まりません") }
        return number
    }

    /// 足し算・引き算・比較の次元。0 はどの次元とも合う。
    private static func commonDimension(_ left: DrillQuantity, _ right: DrillQuantity, _ op: String) throws -> DrillDimension {
        if left.dimension == right.dimension { return left.dimension }
        if left.dimension.isNone, left.number.isZero { return right.dimension }
        if right.dimension.isNone, right.number.isZero { return left.dimension }
        throw EvaluationError.dimension("「\(op)」の両側の次元が合いません(\(left.dimension.text) と \(right.dimension.text))")
    }

    /// 2 項の演算を計算する。左に伸びる連なり(a + b + c + …)は、再帰せずに左から順に計算する。
    /// 再帰で下りると 1 段ごとにスタックを使い、長い式(実際の型で 300 語ほど)を、スタックの小さいスレッドで計算できなかった。
    private static func chain(_ top: DrillExpression, _ scope: [String: DrillValue]) throws -> DrillValue {
        var pending: [(op: String, right: DrillExpression)] = []
        var node: DrillExpression = top
        while case DrillExpression.binary(let op, let left, let right) = node {
            pending.append((op, right))
            node = left
        }
        var value: DrillValue = try node.evaluate(scope)
        for step: (op: String, right: DrillExpression) in pending.reversed() {
            if step.op == "and" {
                // 左が偽なら、右は計算しない。
                value = DrillValue.bool(try bool(value) ? try bool(try step.right.evaluate(scope)) : false)
            } else if step.op == "or" {
                value = DrillValue.bool(try bool(value) ? true : try bool(try step.right.evaluate(scope)))
            } else {
                value = try combine(step.op, value, try step.right.evaluate(scope))
            }
        }
        return value
    }

    private static func combine(_ op: String, _ leftValue: DrillValue, _ rightValue: DrillValue) throws -> DrillValue {
        if op == "==" || op == "!=" {
            let same: Bool
            switch (leftValue, rightValue) {
            case (DrillValue.text(let a), DrillValue.text(let b)): same = a == b
            case (DrillValue.bool(let a), DrillValue.bool(let b)): same = a == b
            case (DrillValue.quantity(let a), DrillValue.quantity(let b)):
                _ = try commonDimension(a, b, op)
                same = DrillArithmetic.equal(a.number, b.number)
            default: throw EvaluationError.type("「\(op)」で種類の違う値を比べています")
            }
            return DrillValue.bool(op == "==" ? same : !same)
        }
        let left: DrillQuantity = try quantity(leftValue)
        let right: DrillQuantity = try quantity(rightValue)
        switch op {
        case "+":
            return DrillValue.quantity(DrillQuantity(try finite(DrillArithmetic.add(left.number, right.number), "足し算"), dimension: try commonDimension(left, right, op)))
        case "-":
            return DrillValue.quantity(DrillQuantity(try finite(DrillArithmetic.subtract(left.number, right.number), "引き算"), dimension: try commonDimension(left, right, op)))
        case "*":
            return DrillValue.quantity(DrillQuantity(try finite(DrillArithmetic.multiply(left.number, right.number), "掛け算"), dimension: left.dimension.multiplied(by: right.dimension)))
        case "/":
            guard let quotient: DrillNumber = DrillArithmetic.divide(left.number, right.number) else { throw EvaluationError.undefined("0 で割っています") }
            return DrillValue.quantity(DrillQuantity(try finite(quotient, "割り算"), dimension: left.dimension.divided(by: right.dimension)))
        case "^":
            guard right.dimension.isNone else { throw EvaluationError.dimension("指数に次元があります") }
            var dimension: DrillDimension = DrillDimension.none
            if !left.dimension.isNone {
                guard let exponent: DrillRational = right.number.rational else { throw EvaluationError.dimension("次元のある量の指数は有理数にしてください") }
                dimension = left.dimension.power(exponent)
            }
            guard let result: DrillNumber = DrillArithmetic.power(left.number, right.number) else { throw EvaluationError.undefined("累乗の値が定まりません") }
            return DrillValue.quantity(DrillQuantity(try finite(result, "累乗"), dimension: dimension))
        case "<", "<=", ">", ">=":
            _ = try commonDimension(left, right, op)
            guard let order: ComparisonResult = DrillArithmetic.compare(left.number, right.number) else { throw EvaluationError.undefined("大小を比べられない数です") }
            switch op {
            case "<": return DrillValue.bool(order == ComparisonResult.orderedAscending)
            case "<=": return DrillValue.bool(order != ComparisonResult.orderedDescending)
            case ">": return DrillValue.bool(order == ComparisonResult.orderedDescending)
            default: return DrillValue.bool(order != ComparisonResult.orderedAscending)
            }
        default:
            throw EvaluationError.type("演算「\(op)」は使えません")
        }
    }
}
