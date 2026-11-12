import Foundation

/// 差し込みの書き方(docs/offline-drill/format.md「差し込みと書き方」)。`{a|+coef}` の `|` の後ろ。
nonisolated struct DrillFormatSpec: Hashable, Sendable {
    /// 符号の扱い。
    nonisolated enum Sign: String, Sendable {
        /// そのまま(-3、3)。
        case plain
        /// 必ず符号を付ける(+3、-3)。
        case signed
        /// 係数(1 は書かず、-1 は - だけ)。
        case coefficient
        /// 符号つきの係数(+、-、+3、-3)。
        case signedCoefficient
        /// 負の数だけかっこで囲む((-3)、3)。
        case paren
        /// 符号を付けてかっこで囲む((+3)、(-3))。
        case signedParen
        /// 絶対値。
        case magnitude
    }

    /// 数の書き方。
    nonisolated enum Style: Hashable, Sendable {
        /// 名前の宣言に従う(有効数字があれば有効数字、小数の変数は小数、それ以外は分数)。
        case automatic
        /// 小数(桁数を書かなければ、割り切れる桁まで)。
        case decimal(Int?)
        /// 有効数字(大きさによって a × 10^n の形にする)。
        case significant(Int)
        /// 必ず a × 10^n の形。
        case scientific(Int)
        /// π の何倍か(2/3 → \frac{2}{3}\pi)。
        case timesPi
        /// π 分の何か(4 → \frac{4}{\pi})。
        case overPi
    }

    var sign: Sign = Sign.plain
    var style: Style = Style.automatic
    /// 単位を付けるか。
    var withUnit: Bool = false
    /// 単位だけを出すか。
    var unitOnly: Bool = false

    static let plain: DrillFormatSpec = DrillFormatSpec()

    nonisolated struct ParseError: Error, Equatable, Sendable {
        let message: String
    }

    /// `+coef`、`dec:1`、`q` などを読む。`|` で重ねられる(`paren|dec:1`)。
    static func parse(_ modifiers: [String]) throws -> DrillFormatSpec {
        var spec: DrillFormatSpec = DrillFormatSpec()
        for modifier: String in modifiers {
            let pieces: [Substring] = modifier.split(separator: ":", maxSplits: 1)
            let name: String = pieces.first.map { (piece: Substring) -> String in String(piece) } ?? ""
            let argument: Int? = pieces.count == 2 ? Int(pieces[1]) : nil
            if pieces.count == 2, argument == nil { throw ParseError(message: "書き方「\(modifier)」の桁数が読めません") }
            switch name {
            case "+": spec.sign = Sign.signed
            case "coef": spec.sign = Sign.coefficient
            case "+coef": spec.sign = Sign.signedCoefficient
            case "paren": spec.sign = Sign.paren
            case "+paren": spec.sign = Sign.signedParen
            case "abs": spec.sign = Sign.magnitude
            case "dec": spec.style = Style.decimal(argument)
            case "sig":
                guard let digits: Int = argument, digits >= 1 else { throw ParseError(message: "「sig」には桁数を書いてください(sig:2)") }
                spec.style = Style.significant(digits)
            case "sci":
                guard let digits: Int = argument, digits >= 1 else { throw ParseError(message: "「sci」には桁数を書いてください(sci:2)") }
                spec.style = Style.scientific(digits)
            case "pi": spec.style = Style.timesPi
            case "overpi": spec.style = Style.overPi
            case "q": spec.withUnit = true
            case "unit": spec.unitOnly = true
            default: throw ParseError(message: "書き方「\(modifier)」はありません")
            }
        }
        return spec
    }
}

/// 名前の宣言から決まる表示(単位・有効数字・小数の変数か)。
nonisolated struct DrillDisplay: Hashable, Sendable {
    var unit: DrillUnit?
    var sig: Int?
    var decimal: Bool = false

    static let none: DrillDisplay = DrillDisplay()
}

/// 数を LaTeX にする。
nonisolated enum DrillFormat {
    nonisolated struct FormatError: Error, Equatable, Sendable {
        let message: String
    }

    /// 符号を外した本体と、負かどうか。`compound` は項が 2 つ以上(かっこが要る)。
    nonisolated struct Body: Equatable, Sendable {
        var negative: Bool
        var text: String
        var compound: Bool = false
        var isZero: Bool = false
    }

    // MARK: 誤差なしの数

    private static func fraction(_ numerator: String, _ denominator: Int) -> String {
        denominator == 1 ? numerator : "\\frac{\(numerator)}{\(denominator)}"
    }

    /// 項 1 つ(係数 × √)。符号は外す。
    private static func termText(coefficient: DrillRational, radicand: Int) -> String {
        let size: DrillRational = coefficient.magnitude
        if radicand == 1 { return fraction("\(size.numerator)", size.denominator) }
        if radicand == -1 {
            // 虚数単位: 2i、\frac{3}{4}i
            if size == DrillRational.one { return "i" }
            return fraction("\(size.numerator)", size.denominator) + "i"
        }
        let root: String = "\\sqrt{\(abs(radicand))}"
        let top: String = size.numerator == 1 ? root : "\(size.numerator)\(root)"
        return fraction(top, size.denominator) + (radicand < 0 ? "i" : "")
    }

    /// 分母をそろえた和(\frac{1+\sqrt{5}}{2})。全部の項が負の時は符号を外に出す(`factorsSign` が偽なら、分数になる時だけ外に出す)。
    private static func compoundText(_ terms: [(radicand: Int, coefficient: DrillRational)], factorsSign: Bool = true) -> (negative: Bool, text: String) {
        var common: Int = 1
        for term: (radicand: Int, coefficient: DrillRational) in terms {
            common = common / DrillRational.gcd(common, term.coefficient.denominator) * term.coefficient.denominator
        }
        let allNegative: Bool = (factorsSign || common > 1) && terms.allSatisfy { (term: (radicand: Int, coefficient: DrillRational)) -> Bool in term.coefficient.isNegative }
        var top: String = ""
        for (index, term): (Int, (radicand: Int, coefficient: DrillRational)) in terms.enumerated() {
            let scaled: Int = abs(term.coefficient.numerator) * (common / term.coefficient.denominator)
            let negative: Bool = term.coefficient.isNegative && !allNegative
            let piece: String = termText(coefficient: DrillRational(integer: scaled), radicand: term.radicand)
            if index == 0 {
                top += (negative ? "-" : "") + piece
            } else {
                top += (negative ? "-" : "+") + piece
            }
        }
        return (allNegative, fraction(top, common))
    }

    static func body(of exact: DrillExact) -> Body {
        let terms: [(radicand: Int, coefficient: DrillRational)] = exact.orderedTerms
        if terms.isEmpty { return Body(negative: false, text: "0", isZero: true) }
        if terms.count == 1 {
            return Body(negative: terms[0].coefficient.isNegative, text: termText(coefficient: terms[0].coefficient, radicand: terms[0].radicand))
        }
        if exact.hasImaginary {
            // 複素数は実部と虚部に分けて書く(2+3i、\frac{1}{2}+\frac{\sqrt{3}}{2}i)。
            let realTerms: [(radicand: Int, coefficient: DrillRational)] = terms.filter { (term: (radicand: Int, coefficient: DrillRational)) -> Bool in term.radicand > 0 }
            let imaginaryTerms: [(radicand: Int, coefficient: DrillRational)] = terms.filter { (term: (radicand: Int, coefficient: DrillRational)) -> Bool in term.radicand < 0 }
            func piece(_ group: [(radicand: Int, coefficient: DrillRational)], imaginary: Bool) -> (negative: Bool, text: String) {
                if group.count == 1 { return (group[0].coefficient.isNegative, termText(coefficient: group[0].coefficient, radicand: group[0].radicand)) }
                let asReal: [(radicand: Int, coefficient: DrillRational)] = group.map { (term: (radicand: Int, coefficient: DrillRational)) -> (radicand: Int, coefficient: DrillRational) in (abs(term.radicand), term.coefficient) }
                // 実部は符号を外に出さずに並べる(-√2-√6)。虚部はかっこで囲むので外に出してよい(-(√2+√6)i)。
                let joined: (negative: Bool, text: String) = compoundText(asReal, factorsSign: imaginary)
                if !imaginary || joined.text.hasPrefix("\\frac") { return (joined.negative, imaginary ? joined.text + "i" : joined.text) }
                return (joined.negative, "(\(joined.text))i")
            }
            var text: String = ""
            if !realTerms.isEmpty {
                let real: (negative: Bool, text: String) = piece(realTerms, imaginary: false)
                text += (real.negative ? "-" : "") + real.text
            }
            let imaginary: (negative: Bool, text: String) = piece(imaginaryTerms, imaginary: true)
            text += (imaginary.negative ? "-" : (text.isEmpty ? "" : "+")) + imaginary.text
            return Body(negative: false, text: text, compound: true)
        }
        let joined: (negative: Bool, text: String) = compoundText(terms)
        return Body(negative: joined.negative, text: joined.text, compound: !joined.text.hasPrefix("\\frac"))
    }

    // MARK: 小数・有効数字

    /// 割り切れる小数にする(分母が 2 と 5 だけ)。割り切れなければ nil。
    static func terminatingDecimal(_ rational: DrillRational) -> String? {
        var denominator: Int = rational.denominator
        var places: Int = 0
        var twos: Int = 0
        var fives: Int = 0
        while denominator % 2 == 0 { denominator /= 2; twos += 1 }
        while denominator % 5 == 0 { denominator /= 5; fives += 1 }
        guard denominator == 1 else { return nil }
        places = max(twos, fives)
        return fixedDecimal(rational.magnitude, places: places)
    }

    /// 小数第 places 位までの表記(符号なし。値は丸め済みで割り切れること)。
    static func fixedDecimal(_ size: DrillRational, places: Int) -> String? {
        guard places >= 0, let scale: DrillRational = DrillRounding.powerOfTen(places), let scaled: DrillRational = size.multiplied(by: scale), scaled.isInteger else { return nil }
        var digits: String = String(scaled.numerator)
        if places == 0 { return digits }
        while digits.count <= places { digits = "0" + digits }
        let split: String.Index = digits.index(digits.endIndex, offsetBy: -places)
        return String(digits[..<split]) + "." + String(digits[split...])
    }

    /// 有効数字の表記(符号なし)。`forceScientific` でなければ、桁をそのまま書ける大きさの時は普通の小数で書く。
    static func significantText(_ significant: DrillRounding.Significant, forceScientific: Bool) -> String {
        let digits: Int = significant.digits
        if significant.mantissa == 0 {
            return digits == 1 ? "0" : "0." + String(repeating: "0", count: digits - 1)
        }
        let mantissa: String = String(significant.mantissa)
        let exponent: Int = significant.exponent
        // 普通に書ける範囲: 最後の有効数字が一の位以下にあり、小さすぎない(0.001 以上)。
        if !forceScientific, exponent <= digits - 1, exponent >= -3 {
            if exponent >= 0 {
                let whole: String = String(mantissa.prefix(exponent + 1))
                let rest: String = String(mantissa.dropFirst(exponent + 1))
                return rest.isEmpty ? whole : whole + "." + rest
            }
            return "0." + String(repeating: "0", count: -exponent - 1) + mantissa
        }
        let head: String = String(mantissa.prefix(1))
        let tail: String = String(mantissa.dropFirst())
        let lead: String = tail.isEmpty ? head : head + "." + tail
        if exponent == 0 { return lead }
        if exponent == 1 { return lead + " \\times 10" }
        return lead + " \\times 10^{\(exponent)}"
    }

    // MARK: 数 → 本体

    /// 数を、書き方に従って「符号を外した本体」にする。`display` は名前の宣言(単位・有効数字)。
    static func body(of quantity: DrillQuantity, spec: DrillFormatSpec, display: DrillDisplay) throws -> Body {
        var number: DrillNumber = quantity.number
        if let unit: DrillUnit = display.unit {
            guard unit.dimension == quantity.dimension else {
                throw FormatError(message: "単位「\(unit.source)」と値の次元(\(quantity.dimension.text))が合いません")
            }
            guard let scaled: DrillNumber = DrillArithmetic.divide(number, unit.scale) else { throw FormatError(message: "単位の倍率が 0 です") }
            number = scaled
        } else if !quantity.dimension.isNone {
            throw FormatError(message: "次元(\(quantity.dimension.text))のある値を、単位を決めずに表示しています。lets に unit を書いてください")
        }
        var style: DrillFormatSpec.Style = spec.style
        if style == DrillFormatSpec.Style.automatic {
            if let digits: Int = display.sig {
                style = DrillFormatSpec.Style.significant(digits)
            } else if display.decimal {
                style = DrillFormatSpec.Style.decimal(nil)
            }
        }
        switch style {
        case DrillFormatSpec.Style.automatic:
            guard case DrillNumber.exact(let exact) = number else {
                throw FormatError(message: "分数や平方根で表せない数を、桁数を決めずに表示しています。「dec:2」や「sig:2」のように桁数を書いてください")
            }
            return body(of: exact)
        case DrillFormatSpec.Style.decimal(let places):
            if let places: Int = places {
                guard let rounded: (value: DrillRational, stable: Bool) = DrillRounding.decimals(number, places: places), rounded.stable,
                      let text: String = fixedDecimal(rounded.value.magnitude, places: max(places, 0)) else {
                    throw FormatError(message: "小数第 \(places) 位に丸められません(丸めの境目にあるか、数が大きすぎます)")
                }
                return Body(negative: rounded.value.isNegative, text: text, isZero: rounded.value.isZero)
            }
            guard let rational: DrillRational = number.rational, let text: String = terminatingDecimal(rational) else {
                throw FormatError(message: "割り切れない数を小数で表示しています。「dec:2」のように桁数を書いてください")
            }
            return Body(negative: rational.isNegative, text: text, isZero: rational.isZero)
        case DrillFormatSpec.Style.significant(let digits), DrillFormatSpec.Style.scientific(let digits):
            guard let significant: DrillRounding.Significant = DrillRounding.significant(number, digits: digits) else {
                throw FormatError(message: "有効数字 \(digits) 桁に丸められません")
            }
            guard significant.stable else { throw FormatError(message: "有効数字の丸めの境目にあって、表示が定まりません") }
            var forceScientific: Bool = false
            if case DrillFormatSpec.Style.scientific = style { forceScientific = true }
            let text: String = significantText(significant, forceScientific: forceScientific)
            return Body(negative: significant.negative, text: text, compound: text.contains("\\times"), isZero: significant.mantissa == 0)
        case DrillFormatSpec.Style.timesPi, DrillFormatSpec.Style.overPi:
            guard let rational: DrillRational = number.rational else { throw FormatError(message: "π の倍数として表示できるのは有理数だけです") }
            if rational.isZero { return Body(negative: false, text: "0", isZero: true) }
            let size: DrillRational = rational.magnitude
            let text: String
            if style == DrillFormatSpec.Style.timesPi {
                if size.denominator == 1 {
                    text = size.numerator == 1 ? "\\pi" : "\(size.numerator)\\pi"
                } else {
                    text = size.numerator == 1 ? "\\frac{\\pi}{\(size.denominator)}" : "\\frac{\(size.numerator)}{\(size.denominator)}\\pi"
                }
            } else {
                text = "\\frac{\(size.numerator)}{\(size.denominator == 1 ? "" : "\(size.denominator)")\\pi}"
            }
            return Body(negative: rational.isNegative, text: text)
        }
    }

    /// 本体に符号の扱いを当てる。
    static func apply(_ sign: DrillFormatSpec.Sign, to body: Body) -> String {
        let text: String = body.compound && sign != DrillFormatSpec.Sign.plain ? "(\(body.text))" : body.text
        switch sign {
        case DrillFormatSpec.Sign.plain:
            return (body.negative ? "-" : "") + (body.compound && body.negative ? "(\(body.text))" : body.text)
        case DrillFormatSpec.Sign.signed:
            return (body.negative ? "-" : "+") + text
        case DrillFormatSpec.Sign.coefficient:
            return (body.negative ? "-" : "") + (text == "1" ? "" : text)
        case DrillFormatSpec.Sign.signedCoefficient:
            return (body.negative ? "-" : "+") + (text == "1" ? "" : text)
        case DrillFormatSpec.Sign.paren:
            return body.negative ? "(-\(body.text))" : body.text
        case DrillFormatSpec.Sign.signedParen:
            if body.isZero { return body.text }
            return "(\(body.negative ? "-" : "+")\(body.text))"
        case DrillFormatSpec.Sign.magnitude:
            return text
        }
    }

    /// 数を LaTeX にする(符号・桁・単位まで)。
    static func text(of quantity: DrillQuantity, spec: DrillFormatSpec, display: DrillDisplay) throws -> String {
        if spec.unitOnly {
            guard let unit: DrillUnit = display.unit else { throw FormatError(message: "単位のない名前に「unit」を使っています") }
            return unit.tex
        }
        let body: Body = try body(of: quantity, spec: spec, display: display)
        let number: String = apply(spec.sign, to: body)
        guard spec.withUnit else { return number }
        guard let unit: DrillUnit = display.unit else { throw FormatError(message: "単位のない名前に「q」を使っています") }
        return unit.attachesDirectly ? number + unit.tex : number + "\\," + unit.tex
    }
}
