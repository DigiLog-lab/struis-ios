import Foundation

/// 単位(docs/offline-drill/format.md「単位と有効数字」)。`m/s^2`、`kg*m/s^2`、`J/(mol*K)` のような文字列を読み、
/// SI の組立単位への倍率と次元にする。型の式は SI の値で計算するので、単位の換算は書かなくてよい。
nonisolated struct DrillUnit: Hashable, Sendable {
    /// 書かれたままの文字列。
    let source: String
    /// SI の組立単位への倍率(km なら 1000)。
    let scale: DrillNumber
    let dimension: DrillDimension

    nonisolated struct ParseError: Error, Equatable, Sendable {
        let message: String
    }

    private nonisolated struct Entry {
        let scale: DrillNumber
        let dimension: DrillDimension
    }

    private static func dimension(_ m: Int, _ kg: Int, _ s: Int, _ a: Int = 0, _ k: Int = 0, _ mol: Int = 0) -> DrillDimension {
        DrillDimension(exponents: [m, kg, s, a, k, mol].map { (value: Int) -> DrillRational in DrillRational(integer: value) })
    }

    private static func entry(_ numerator: Int, _ denominator: Int, _ dimension: DrillDimension) -> Entry {
        Entry(scale: DrillNumber(rational: DrillRational(numerator, denominator) ?? DrillRational.one), dimension: dimension)
    }

    /// 接頭語を付けられる単位。
    private static let prefixable: [String: Entry] = [
        "m": entry(1, 1, dimension(1, 0, 0)),
        "g": entry(1, 1000, dimension(0, 1, 0)),
        "s": entry(1, 1, dimension(0, 0, 1)),
        "A": entry(1, 1, dimension(0, 0, 0, 1)),
        "K": entry(1, 1, dimension(0, 0, 0, 0, 1)),
        "mol": entry(1, 1, dimension(0, 0, 0, 0, 0, 1)),
        "N": entry(1, 1, dimension(1, 1, -2)),
        "J": entry(1, 1, dimension(2, 1, -2)),
        "W": entry(1, 1, dimension(2, 1, -3)),
        "Pa": entry(1, 1, dimension(-1, 1, -2)),
        "Hz": entry(1, 1, dimension(0, 0, -1)),
        "C": entry(1, 1, dimension(0, 0, 1, 1)),
        "V": entry(1, 1, dimension(2, 1, -3, -1)),
        "ohm": entry(1, 1, dimension(2, 1, -3, -2)),
        "Ω": entry(1, 1, dimension(2, 1, -3, -2)),
        "F": entry(1, 1, dimension(-2, -1, 4, 2)),
        "T": entry(1, 1, dimension(0, 1, -2, -1)),
        "Wb": entry(1, 1, dimension(2, 1, -2, -1)),
        "H": entry(1, 1, dimension(2, 1, -2, -2)),
        "L": entry(1, 1000, dimension(3, 0, 0)),
    ]

    /// 接頭語を付けない単位。
    private static let plain: [String: Entry] = [
        "1": entry(1, 1, DrillDimension.none),
        "min": entry(60, 1, dimension(0, 0, 1)),
        "h": entry(3600, 1, dimension(0, 0, 1)),
        "t": entry(1000, 1, dimension(0, 1, 0)),
        "atm": entry(101_325, 1, dimension(-1, 1, -2)),
        "degC": entry(1, 1, dimension(0, 0, 0, 0, 1)),
        "℃": entry(1, 1, dimension(0, 0, 0, 0, 1)),
        "deg": entry(1, 1, DrillDimension.none),
        "°": entry(1, 1, DrillDimension.none),
        "rad": entry(1, 1, DrillDimension.none),
        "%": entry(1, 100, DrillDimension.none),
        "個": entry(1, 1, DrillDimension.none),
        "回": entry(1, 1, DrillDimension.none),
    ]

    private static let prefixes: [(symbol: String, numerator: Int, denominator: Int)] = [
        ("k", 1000, 1), ("h", 100, 1), ("d", 1, 10), ("c", 1, 100), ("m", 1, 1000),
        ("u", 1, 1_000_000), ("μ", 1, 1_000_000), ("n", 1, 1_000_000_000), ("p", 1, 1_000_000_000_000),
        ("M", 1_000_000, 1), ("G", 1_000_000_000, 1),
    ]

    private static func lookup(_ symbol: String) -> Entry? {
        if let found: Entry = plain[symbol] ?? prefixable[symbol] { return found }
        for prefix: (symbol: String, numerator: Int, denominator: Int) in prefixes where symbol.hasPrefix(prefix.symbol) {
            let rest: String = String(symbol.dropFirst(prefix.symbol.count))
            guard let base: Entry = prefixable[rest], let factor: DrillRational = DrillRational(prefix.numerator, prefix.denominator),
                  let baseScale: DrillRational = base.scale.rational, let scale: DrillRational = baseScale.multiplied(by: factor) else { continue }
            return Entry(scale: DrillNumber(rational: scale), dimension: base.dimension)
        }
        return nil
    }

    private nonisolated enum Token: Equatable {
        case symbol(String)
        case integer(Int)
        case multiply, divide, power, open, close
    }

    private static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let characters: [Character] = Array(text)
        var index: Int = 0
        while index < characters.count {
            let c: Character = characters[index]
            if c == " " { index += 1; continue }
            if c == "*" || c == "·" || c == "⋅" { tokens.append(Token.multiply); index += 1; continue }
            if c == "/" { tokens.append(Token.divide); index += 1; continue }
            if c == "^" { tokens.append(Token.power); index += 1; continue }
            if c == "(" { tokens.append(Token.open); index += 1; continue }
            if c == ")" { tokens.append(Token.close); index += 1; continue }
            if c == "-" || (c.isASCII && c.isNumber) {
                var end: Int = index + 1
                while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }
                let literal: String = String(characters[index..<end])
                // 先頭の「1」は無次元("1/mol")。指数は「^」の後だけ。
                if tokens.last == Token.power, let value: Int = Int(literal) {
                    tokens.append(Token.integer(value))
                } else if literal == "1" {
                    tokens.append(Token.symbol("1"))
                } else {
                    throw ParseError(message: "単位「\(text)」の「\(literal)」が読めません")
                }
                index = end
                continue
            }
            var end: Int = index
            while end < characters.count, !" */^()·⋅".contains(characters[end]) { end += 1 }
            tokens.append(Token.symbol(String(characters[index..<end])))
            index = end
        }
        return tokens
    }

    /// 単位の文字列を読む。知らない単位は投げる。
    static func parse(_ text: String) throws -> DrillUnit {
        guard text.count <= 40 else { throw ParseError(message: "単位が長すぎます(「\(text.prefix(20))…」)") }
        let tokens: [Token] = try tokenize(text)
        guard !tokens.isEmpty else { throw ParseError(message: "単位が空です") }
        var position: Int = 0

        func factor() throws -> (scale: DrillNumber, dimension: DrillDimension) {
            guard position < tokens.count else { throw ParseError(message: "単位「\(text)」が途中で終わっています") }
            var base: (scale: DrillNumber, dimension: DrillDimension)
            switch tokens[position] {
            case Token.symbol(let symbol):
                guard let found: Entry = lookup(symbol) else { throw ParseError(message: "単位「\(symbol)」を知りません") }
                base = (found.scale, found.dimension)
                position += 1
            case Token.open:
                position += 1
                base = try product()
                guard position < tokens.count, tokens[position] == Token.close else { throw ParseError(message: "単位「\(text)」のかっこが閉じていません") }
                position += 1
            default:
                throw ParseError(message: "単位「\(text)」が読めません")
            }
            if position + 1 < tokens.count, tokens[position] == Token.power, case Token.integer(let exponent) = tokens[position + 1] {
                position += 2
                guard let scale: DrillNumber = DrillArithmetic.power(base.scale, DrillNumber(integer: exponent)) else {
                    throw ParseError(message: "単位「\(text)」の指数が大きすぎます")
                }
                base = (scale, base.dimension.power(DrillRational(integer: exponent)))
            }
            return base
        }

        func product() throws -> (scale: DrillNumber, dimension: DrillDimension) {
            var result: (scale: DrillNumber, dimension: DrillDimension) = try factor()
            while position < tokens.count, tokens[position] == Token.multiply || tokens[position] == Token.divide {
                let divide: Bool = tokens[position] == Token.divide
                position += 1
                let next: (scale: DrillNumber, dimension: DrillDimension) = try factor()
                if divide {
                    guard let scale: DrillNumber = DrillArithmetic.divide(result.scale, next.scale) else { throw ParseError(message: "単位「\(text)」が読めません") }
                    result = (scale, result.dimension.divided(by: next.dimension))
                } else {
                    result = (DrillArithmetic.multiply(result.scale, next.scale), result.dimension.multiplied(by: next.dimension))
                }
            }
            return result
        }

        let result: (scale: DrillNumber, dimension: DrillDimension) = try product()
        guard position == tokens.count else { throw ParseError(message: "単位「\(text)」が読めません") }
        return DrillUnit(source: text, scale: result.scale, dimension: result.dimension)
    }

    /// 画面に出す LaTeX。書かれた順のまま、`*` は中点、`^2` は上付きにする。
    var tex: String {
        if source == "deg" || source == "°" { return "^{\\circ}" }
        if source == "degC" || source == "℃" { return "^{\\circ}\\mathrm{C}" }
        if source == "%" { return "\\%" }
        var out: String = ""
        let characters: [Character] = Array(source)
        var index: Int = 0
        while index < characters.count {
            let c: Character = characters[index]
            if c == " " { index += 1; continue }
            if c == "*" || c == "·" || c == "⋅" { out += " \\cdot "; index += 1; continue }
            if c == "^" {
                var end: Int = index + 1
                while end < characters.count, characters[end] == "-" || (characters[end].isASCII && characters[end].isNumber) { end += 1 }
                out += "^{\(String(characters[(index + 1)..<end]))}"
                index = end
                continue
            }
            if "/()".contains(c) || (c.isASCII && c.isNumber) { out.append(c); index += 1; continue }
            var end: Int = index
            while end < characters.count, !" */^()·⋅".contains(characters[end]) { end += 1 }
            out += DrillUnit.symbolTeX(String(characters[index..<end]))
            index = end
        }
        return "\\mathrm{\(out)}"
    }

    private static func symbolTeX(_ symbol: String) -> String {
        switch symbol {
        case "ohm", "Ω": return "\\Omega "
        case "degC", "℃": return "{}^{\\circ}C"
        case "%": return "\\%"
        case "個", "回": return "\\text{\(symbol)}"
        default: break
        }
        if plain[symbol] != nil || prefixable[symbol] != nil { return symbol }
        if symbol.hasPrefix("u") || symbol.hasPrefix("μ") { return "\\mu " + symbolTeX(String(symbol.dropFirst())) }
        if let prefix: Character = symbol.first, prefixable[String(symbol.dropFirst())] != nil { return String(prefix) + symbolTeX(String(symbol.dropFirst())) }
        return symbol
    }

    /// 数と単位の間に空きを入れるか(度と % は詰める)。
    var attachesDirectly: Bool { ["deg", "°", "%", "degC", "℃"].contains(source) }
}
