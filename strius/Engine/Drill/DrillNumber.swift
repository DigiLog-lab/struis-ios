import Foundation

/// オフライン反復の「問題の型」で使う数(docs/offline-drill/format.md「数の持ち方」)。
/// 分数と平方根は誤差なしで持ち、三角関数や対数など誤差なしで持てない値だけ実数(Double)にする。
/// 式を式のまま変形する数式処理はしない。扱うのは数どうしの計算だけ。

/// 既約分数。分母は正。計算が整数の型からあふれたら nil を返す(呼び出し側が、桁の多い型か実数に切り替える)。
/// ふだんは `DrillRational`(Int)を使う。プランク定数のように Int に収まらない桁の数だけ `DrillWideRational`(Int128)で持ち、
/// 有効数字の丸めを誤差なしで行う。
nonisolated struct DrillFraction<Integer: FixedWidthInteger & SignedInteger & Sendable>: Hashable, Sendable {
    let numerator: Integer
    let denominator: Integer

    static var zero: DrillFraction<Integer> { DrillFraction<Integer>(integer: 0) }
    static var one: DrillFraction<Integer> { DrillFraction<Integer>(integer: 1) }

    init(integer: Integer) {
        self.numerator = integer
        self.denominator = 1
    }

    init?(_ numerator: Integer, _ denominator: Integer) {
        guard denominator != 0, numerator != Integer.min, denominator != Integer.min else { return nil }
        let top: Integer = numerator < 0 ? -numerator : numerator
        let bottom: Integer = denominator < 0 ? -denominator : denominator
        let divisor: Integer = DrillFraction<Integer>.gcd(top, bottom)
        self.numerator = (denominator < 0 ? -numerator : numerator) / divisor
        self.denominator = bottom / divisor
    }

    private init(unchecked numerator: Integer, _ denominator: Integer) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// 最大公約数(どちらも 0 以上)。gcd(0, n) = n。
    static func gcd(_ a: Integer, _ b: Integer) -> Integer {
        var x: Integer = a
        var y: Integer = b
        while y != 0 {
            let r: Integer = x % y
            x = y
            y = r
        }
        return x == 0 ? 1 : x
    }

    private static func magnitude(_ value: Integer) -> Integer { value < 0 ? -value : value }

    var isZero: Bool { numerator == 0 }
    var isInteger: Bool { denominator == 1 }
    var isNegative: Bool { numerator < 0 }
    var doubleValue: Double { Double(numerator) / Double(denominator) }
    var negated: DrillFraction<Integer> { DrillFraction<Integer>(unchecked: -numerator, denominator) }
    var magnitude: DrillFraction<Integer> { DrillFraction<Integer>(unchecked: DrillFraction<Integer>.magnitude(numerator), denominator) }

    func adding(_ other: DrillFraction<Integer>) -> DrillFraction<Integer>? {
        let divisor: Integer = DrillFraction<Integer>.gcd(denominator, other.denominator)
        let leftScale: Integer = other.denominator / divisor
        let rightScale: Integer = denominator / divisor
        let (left, overflowLeft): (Integer, Bool) = numerator.multipliedReportingOverflow(by: leftScale)
        let (right, overflowRight): (Integer, Bool) = other.numerator.multipliedReportingOverflow(by: rightScale)
        let (sum, overflowSum): (Integer, Bool) = left.addingReportingOverflow(right)
        let (common, overflowCommon): (Integer, Bool) = denominator.multipliedReportingOverflow(by: leftScale)
        guard !overflowLeft, !overflowRight, !overflowSum, !overflowCommon else { return nil }
        return DrillFraction<Integer>(sum, common)
    }

    func subtracting(_ other: DrillFraction<Integer>) -> DrillFraction<Integer>? {
        adding(other.negated)
    }

    func multiplied(by other: DrillFraction<Integer>) -> DrillFraction<Integer>? {
        // 先に斜めに約分して、あふれにくくする。
        let first: Integer = DrillFraction<Integer>.gcd(DrillFraction<Integer>.magnitude(numerator), other.denominator)
        let second: Integer = DrillFraction<Integer>.gcd(DrillFraction<Integer>.magnitude(other.numerator), denominator)
        let (top, overflowTop): (Integer, Bool) = (numerator / first).multipliedReportingOverflow(by: other.numerator / second)
        let (bottom, overflowBottom): (Integer, Bool) = (denominator / second).multipliedReportingOverflow(by: other.denominator / first)
        guard !overflowTop, !overflowBottom else { return nil }
        return DrillFraction<Integer>(top, bottom)
    }

    /// 0 で割る時は nil。
    func divided(by other: DrillFraction<Integer>) -> DrillFraction<Integer>? {
        guard let inverse: DrillFraction<Integer> = other.reciprocal else { return nil }
        return multiplied(by: inverse)
    }

    var reciprocal: DrillFraction<Integer>? {
        DrillFraction<Integer>(denominator, numerator)
    }

    /// 整数乗。0 の負の数乗と、あふれは nil。
    func power(_ exponent: Int) -> DrillFraction<Integer>? {
        if exponent == 0 { return DrillFraction<Integer>.one }
        if exponent < 0 {
            guard exponent != Int.min, let inverse: DrillFraction<Integer> = reciprocal else { return nil }
            return inverse.power(-exponent)
        }
        var result: DrillFraction<Integer> = DrillFraction<Integer>.one
        var base: DrillFraction<Integer> = self
        var remaining: Int = exponent
        while remaining > 0 {
            if remaining & 1 == 1 {
                guard let next: DrillFraction<Integer> = result.multiplied(by: base) else { return nil }
                result = next
            }
            remaining >>= 1
            if remaining > 0 {
                guard let squared: DrillFraction<Integer> = base.multiplied(by: base) else { return nil }
                base = squared
            }
        }
        return result
    }

    static func < (left: DrillFraction<Integer>, right: DrillFraction<Integer>) -> Bool {
        let (a, overflowA): (Integer, Bool) = left.numerator.multipliedReportingOverflow(by: right.denominator)
        let (b, overflowB): (Integer, Bool) = right.numerator.multipliedReportingOverflow(by: left.denominator)
        if overflowA || overflowB { return left.doubleValue < right.doubleValue }
        return a < b
    }

    /// 床関数。
    var floorValue: Integer {
        let quotient: Integer = numerator / denominator
        return (numerator % denominator != 0 && numerator < 0) ? quotient - 1 : quotient
    }

    /// 四捨五入(0.5 は 0 から遠い方へ)。あふれは nil。
    var roundedValue: Integer? {
        let (doubled, overflow): (Integer, Bool) = DrillFraction<Integer>.magnitude(numerator).multipliedReportingOverflow(by: 2)
        let (shifted, overflowShift): (Integer, Bool) = doubled.addingReportingOverflow(denominator)
        let (bottom, overflowBottom): (Integer, Bool) = denominator.multipliedReportingOverflow(by: 2)
        guard !overflow, !overflowShift, !overflowBottom else { return nil }
        let size: Integer = shifted / bottom
        return numerator < 0 ? -size : size
    }

    /// 10 の整数乗。あふれは nil。
    static func powerOfTen(_ exponent: Int) -> DrillFraction<Integer>? {
        guard abs(exponent) <= 38 else { return nil }
        return DrillFraction<Integer>(integer: 10).power(exponent)
    }

    /// 10 進の文字列("12"、"-0.25"、"6.02e23")を誤差なしで読む。整数の型に収まらなければ nil。
    init?(decimal text: String) {
        var mantissa: Substring = Substring(text)
        var exponent: Int = 0
        if let marker: String.Index = mantissa.firstIndex(where: { (c: Character) -> Bool in c == "e" || c == "E" }) {
            guard let parsed: Int = Int(mantissa[mantissa.index(after: marker)...].replacingOccurrences(of: "+", with: "")) else { return nil }
            exponent = parsed
            mantissa = mantissa[..<marker]
        }
        var negative: Bool = false
        if mantissa.hasPrefix("-") {
            negative = true
            mantissa = mantissa.dropFirst()
        } else if mantissa.hasPrefix("+") {
            mantissa = mantissa.dropFirst()
        }
        let pieces: [Substring] = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2, !mantissa.isEmpty else { return nil }
        let whole: Substring = pieces[0]
        let fraction: Substring = pieces.count == 2 ? pieces[1] : Substring("")
        guard !(whole.isEmpty && fraction.isEmpty) else { return nil }
        guard (whole + fraction).allSatisfy({ (c: Character) -> Bool in c.isASCII && c.isNumber }) else { return nil }
        guard let digits: Integer = Integer(String(whole + fraction)) else { return nil }
        exponent -= fraction.count
        guard let scale: DrillFraction<Integer> = DrillFraction<Integer>.powerOfTen(exponent),
              let value: DrillFraction<Integer> = DrillFraction<Integer>(integer: negative ? -digits : digits).multiplied(by: scale) else { return nil }
        self = value
    }

    /// 別の整数の型の分数から作る。収まらなければ nil。
    init?<Other: FixedWidthInteger & SignedInteger & Sendable>(converting other: DrillFraction<Other>) {
        guard let top: Integer = Integer(exactly: other.numerator), let bottom: Integer = Integer(exactly: other.denominator) else { return nil }
        self.init(unchecked: top, bottom)
    }
}

/// ふだん使う分数(Int)。
typealias DrillRational = DrillFraction<Int>
/// Int に収まらない桁の分数(Int128)。
typealias DrillWideRational = DrillFraction<Int128>

/// 誤差なしで持つ数。有理数 × 平方根の和: Σ 係数 × √(根号の中)。
/// 根号の中は平方因数を持たない 0 でない整数で、1 は有理数の項、負の数 -k は i√k(-1 は虚数単位 i)。
/// 例: 3/2 は [1: 3/2]、(1+√5)/2 は [1: 1/2, 5: 1/2]、2+3i は [1: 2, -1: 3]。
nonisolated struct DrillExact: Hashable, Sendable {
    private(set) var terms: [Int: DrillRational]

    static let zero: DrillExact = DrillExact(terms: [:])
    static let one: DrillExact = DrillExact(rational: DrillRational.one)
    static let imaginaryUnit: DrillExact = DrillExact(terms: [-1: DrillRational.one])

    init(terms: [Int: DrillRational]) {
        self.terms = terms.filter { (_: Int, coefficient: DrillRational) -> Bool in !coefficient.isZero }
    }

    init(rational: DrillRational) {
        self.init(terms: [1: rational])
    }

    init(integer: Int) {
        self.init(rational: DrillRational(integer: integer))
    }

    var isZero: Bool { terms.isEmpty }

    /// 有理数ならその値。
    var rational: DrillRational? {
        if terms.isEmpty { return DrillRational.zero }
        guard terms.count == 1, let value: DrillRational = terms[1] else { return nil }
        return value
    }

    var integer: Int? {
        guard let value: DrillRational = rational, value.isInteger else { return nil }
        return value.numerator
    }

    /// 虚数の項(根号の中が負)を持つか。
    var hasImaginary: Bool {
        terms.keys.contains { (radicand: Int) -> Bool in radicand < 0 }
    }

    /// 実数としての値。虚数の項があれば nil。
    var doubleValue: Double? {
        guard !hasImaginary else { return nil }
        return terms.reduce(0.0) { (sum: Double, term: (key: Int, value: DrillRational)) -> Double in
            sum + term.value.doubleValue * Double(term.key).squareRoot()
        }
    }

    /// 複素数としての値(実部・虚部)。
    var complexValue: (real: Double, imaginary: Double) {
        var real: Double = 0
        var imaginary: Double = 0
        for (radicand, coefficient): (Int, DrillRational) in terms {
            if radicand > 0 {
                real += coefficient.doubleValue * Double(radicand).squareRoot()
            } else {
                imaginary += coefficient.doubleValue * Double(-radicand).squareRoot()
            }
        }
        return (real, imaginary)
    }

    var realPart: DrillExact {
        DrillExact(terms: terms.filter { (radicand: Int, _: DrillRational) -> Bool in radicand > 0 })
    }

    /// 虚部(i を外した実数)。
    var imaginaryPart: DrillExact {
        var result: [Int: DrillRational] = [:]
        for (radicand, coefficient): (Int, DrillRational) in terms where radicand < 0 {
            result[-radicand] = coefficient
        }
        return DrillExact(terms: result)
    }

    var conjugate: DrillExact {
        var result: [Int: DrillRational] = [:]
        for (radicand, coefficient): (Int, DrillRational) in terms {
            result[radicand] = radicand < 0 ? coefficient.negated : coefficient
        }
        return DrillExact(terms: result)
    }

    var negated: DrillExact {
        DrillExact(terms: terms.mapValues { (coefficient: DrillRational) -> DrillRational in coefficient.negated })
    }

    func adding(_ other: DrillExact) -> DrillExact? {
        var result: [Int: DrillRational] = terms
        for (radicand, coefficient): (Int, DrillRational) in other.terms {
            guard let sum: DrillRational = (result[radicand] ?? DrillRational.zero).adding(coefficient) else { return nil }
            result[radicand] = sum
        }
        return DrillExact(terms: result)
    }

    func subtracting(_ other: DrillExact) -> DrillExact? {
        adding(other.negated)
    }

    func multiplied(by other: DrillExact) -> DrillExact? {
        var result: [Int: DrillRational] = [:]
        for (leftRadicand, leftCoefficient): (Int, DrillRational) in terms {
            for (rightRadicand, rightCoefficient): (Int, DrillRational) in other.terms {
                // √a × √b = g × √(ab / g²)(g は最大公約数)。虚数どうしは i × i = -1。
                let leftSize: Int = abs(leftRadicand)
                let rightSize: Int = abs(rightRadicand)
                let common: Int = DrillRational.gcd(leftSize, rightSize)
                let (size, overflow): (Int, Bool) = (leftSize / common).multipliedReportingOverflow(by: rightSize / common)
                guard !overflow else { return nil }
                let bothImaginary: Bool = leftRadicand < 0 && rightRadicand < 0
                let oneImaginary: Bool = (leftRadicand < 0) != (rightRadicand < 0)
                let radicand: Int = oneImaginary ? -size : size
                let factor: DrillRational = DrillRational(integer: bothImaginary ? -common : common)
                guard let product: DrillRational = leftCoefficient.multiplied(by: rightCoefficient)?.multiplied(by: factor),
                      let sum: DrillRational = (result[radicand] ?? DrillRational.zero).adding(product) else { return nil }
                result[radicand] = sum
            }
        }
        return DrillExact(terms: result)
    }

    /// 逆数。項が 1 つか 2 つの時だけ誤差なしで求まる(2 つの時は共役を掛ける)。0 と、3 項以上は nil。
    var reciprocal: DrillExact? {
        let sorted: [(key: Int, value: DrillRational)] = terms.sorted { (a: (key: Int, value: DrillRational), b: (key: Int, value: DrillRational)) -> Bool in a.key < b.key }
        if sorted.count == 1 {
            // 1 / (c√r) = √r / (c r)
            let radicand: Int = sorted[0].key
            guard let scaled: DrillRational = sorted[0].value.multiplied(by: DrillRational(integer: radicand)),
                  let coefficient: DrillRational = scaled.reciprocal else { return nil }
            return DrillExact(terms: [radicand: coefficient])
        }
        if sorted.count == 2 {
            // (A + B)(A - B) = A² - B² は有理数。
            let first: DrillExact = DrillExact(terms: [sorted[0].key: sorted[0].value])
            let second: DrillExact = DrillExact(terms: [sorted[1].key: sorted[1].value])
            guard let conjugated: DrillExact = first.subtracting(second),
                  let norm: DrillRational = multiplied(by: conjugated)?.rational,
                  let inverse: DrillRational = norm.reciprocal else { return nil }
            return conjugated.multiplied(by: DrillExact(rational: inverse))
        }
        return nil
    }

    /// 平方因数をくくり出す: n = s² × f(f は平方因数なし)。大きすぎる数は nil。
    static func squareParts(of value: Int) -> (root: Int, free: Int)? {
        guard value > 0, value <= 10_000_000_000 else { return nil }
        var remaining: Int = value
        var root: Int = 1
        var divisor: Int = 2
        while divisor * divisor <= remaining {
            let square: Int = divisor * divisor
            while remaining % square == 0 {
                remaining /= square
                root *= divisor
            }
            divisor += 1
        }
        return (root, remaining)
    }

    /// 有理数の平方根を誤差なしで持つ: √(p/q) = √(pq) / q。負の数は i を付ける。
    static func squareRoot(of value: DrillRational) -> DrillExact? {
        if value.isZero { return DrillExact.zero }
        let (product, overflow): (Int, Bool) = abs(value.numerator).multipliedReportingOverflow(by: value.denominator)
        guard !overflow, let parts: (root: Int, free: Int) = squareParts(of: product),
              let coefficient: DrillRational = DrillRational(parts.root, value.denominator) else { return nil }
        return DrillExact(terms: [value.isNegative ? -parts.free : parts.free: coefficient])
    }

    /// 根号の中の小さい順(有理数の項、実数の根号、虚数の順)に並べた項。
    var orderedTerms: [(radicand: Int, coefficient: DrillRational)] {
        let real: [(radicand: Int, coefficient: DrillRational)] = terms
            .filter { (radicand: Int, _: DrillRational) -> Bool in radicand > 0 }
            .sorted { (a: (key: Int, value: DrillRational), b: (key: Int, value: DrillRational)) -> Bool in a.key < b.key }
            .map { (term: (key: Int, value: DrillRational)) -> (radicand: Int, coefficient: DrillRational) in (term.key, term.value) }
        let imaginary: [(radicand: Int, coefficient: DrillRational)] = terms
            .filter { (radicand: Int, _: DrillRational) -> Bool in radicand < 0 }
            .sorted { (a: (key: Int, value: DrillRational), b: (key: Int, value: DrillRational)) -> Bool in a.key > b.key }
            .map { (term: (key: Int, value: DrillRational)) -> (radicand: Int, coefficient: DrillRational) in (term.key, term.value) }
        return real + imaginary
    }
}

/// 数。誤差なしの値か、実数(Double)。
nonisolated enum DrillNumber: Hashable, Sendable {
    case exact(DrillExact)
    /// Int に収まらない桁の有理数(6.6 × 10⁻³⁴ など)。有効数字の丸めを誤差なしで行うために持つ。
    case wide(DrillWideRational)
    case real(Double)

    static let zero: DrillNumber = DrillNumber.exact(DrillExact.zero)
    static let one: DrillNumber = DrillNumber.exact(DrillExact.one)

    init(integer: Int) {
        self = DrillNumber.exact(DrillExact(integer: integer))
    }

    init(rational: DrillRational) {
        self = DrillNumber.exact(DrillExact(rational: rational))
    }

    /// JSON の数(Double)を、10 進の表記どおりに誤差なしで読む。
    init(json value: Double) {
        self = DrillNumber(decimal: "\(value)") ?? DrillNumber.real(value)
    }

    /// 10 進の文字列を誤差なしで読む。Int に収まらなければ Int128 で持つ。どちらにも収まらなければ nil。
    init?(decimal text: String) {
        if let rational: DrillRational = DrillRational(decimal: text) {
            self = DrillNumber.exact(DrillExact(rational: rational))
        } else if let wide: DrillWideRational = DrillWideRational(decimal: text) {
            self = DrillNumber.wide(wide)
        } else {
            return nil
        }
    }

    /// 桁の多い有理数を、Int に収まるなら普通の分数に戻して持つ。
    init(wide: DrillWideRational) {
        if let rational: DrillRational = DrillRational(converting: wide) {
            self = DrillNumber.exact(DrillExact(rational: rational))
        } else {
            self = DrillNumber.wide(wide)
        }
    }

    /// 有理数なら、桁の多い型での値。
    var wideRational: DrillWideRational? {
        switch self {
        case DrillNumber.exact(let value): return value.rational.flatMap { (rational: DrillRational) -> DrillWideRational? in DrillWideRational(converting: rational) }
        case DrillNumber.wide(let value): return value
        case DrillNumber.real: return nil
        }
    }

    var exactValue: DrillExact? {
        if case DrillNumber.exact(let value) = self { return value }
        return nil
    }

    var rational: DrillRational? { exactValue?.rational }
    var integer: Int? { exactValue?.integer }

    /// 実数としての値。虚数を含む時は nil。
    var doubleValue: Double? {
        switch self {
        case DrillNumber.exact(let value): return value.doubleValue
        case DrillNumber.wide(let value): return value.doubleValue
        case DrillNumber.real(let value): return value
        }
    }

    var isZero: Bool {
        switch self {
        case DrillNumber.exact(let value): return value.isZero
        case DrillNumber.wide(let value): return value.isZero
        case DrillNumber.real(let value): return value == 0
        }
    }

    /// 誤差なしで持っているか。
    var isExact: Bool {
        if case DrillNumber.real = self { return false }
        return true
    }
}

/// 物理量の次元。SI の基本単位(m・kg・s・A・K・mol)の指数。
nonisolated struct DrillDimension: Hashable, Sendable {
    static let baseSymbols: [String] = ["m", "kg", "s", "A", "K", "mol"]
    var exponents: [DrillRational]

    static let none: DrillDimension = DrillDimension(exponents: Array(repeating: DrillRational.zero, count: 6))

    static func base(_ index: Int) -> DrillDimension {
        var exponents: [DrillRational] = Array(repeating: DrillRational.zero, count: 6)
        exponents[index] = DrillRational.one
        return DrillDimension(exponents: exponents)
    }

    var isNone: Bool { exponents.allSatisfy { (e: DrillRational) -> Bool in e.isZero } }

    func multiplied(by other: DrillDimension) -> DrillDimension {
        DrillDimension(exponents: zip(exponents, other.exponents).map { (a: DrillRational, b: DrillRational) -> DrillRational in a.adding(b) ?? DrillRational.zero })
    }

    func divided(by other: DrillDimension) -> DrillDimension {
        DrillDimension(exponents: zip(exponents, other.exponents).map { (a: DrillRational, b: DrillRational) -> DrillRational in a.subtracting(b) ?? DrillRational.zero })
    }

    func power(_ exponent: DrillRational) -> DrillDimension {
        DrillDimension(exponents: exponents.map { (e: DrillRational) -> DrillRational in e.multiplied(by: exponent) ?? DrillRational.zero })
    }

    /// 読める形("kg·m/s^2" のような SI の基本単位の積)。点検の指摘に使う。
    var text: String {
        if isNone { return "無次元" }
        var pieces: [String] = []
        for (index, exponent): (Int, DrillRational) in exponents.enumerated() where !exponent.isZero {
            let symbol: String = DrillDimension.baseSymbols[index]
            if exponent == DrillRational.one {
                pieces.append(symbol)
            } else if exponent.isInteger {
                pieces.append("\(symbol)^\(exponent.numerator)")
            } else {
                pieces.append("\(symbol)^(\(exponent.numerator)/\(exponent.denominator))")
            }
        }
        return pieces.joined(separator: "·")
    }
}

/// 次元つきの数。`number` は SI の組立単位での値(km で書いた長さも m で持つ)。
nonisolated struct DrillQuantity: Hashable, Sendable {
    var number: DrillNumber
    var dimension: DrillDimension

    init(_ number: DrillNumber, dimension: DrillDimension = DrillDimension.none) {
        self.number = number
        self.dimension = dimension
    }

    init(integer: Int) {
        self.init(DrillNumber(integer: integer))
    }
}

/// 型の式が扱う値。
nonisolated indirect enum DrillValue: Hashable, Sendable {
    case quantity(DrillQuantity)
    case text(String)
    case bool(Bool)
    /// 選択肢 1 つが持つ、名前つきの値の組(`f.tex`、`f.sign` のように読む)。
    case record([String: DrillValue])

    static func number(_ number: DrillNumber) -> DrillValue {
        DrillValue.quantity(DrillQuantity(number))
    }

    static func integer(_ value: Int) -> DrillValue {
        DrillValue.quantity(DrillQuantity(integer: value))
    }
}
