import Foundation

/// オフライン反復の「問題の型」で使う数(docs/offline-drill/format.md「数の持ち方」)。
/// 分数と平方根は誤差なしで持ち、三角関数や対数など誤差なしで持てない値だけ実数(Double)にする。
/// 式を式のまま変形する数式処理はしない。扱うのは数どうしの計算だけ。

/// 既約分数。分母は正。計算が Int からあふれたら nil を返す(呼び出し側が実数に切り替える)。
nonisolated struct DrillRational: Hashable, Sendable {
    let numerator: Int
    let denominator: Int

    static let zero: DrillRational = DrillRational(integer: 0)
    static let one: DrillRational = DrillRational(integer: 1)

    init(integer: Int) {
        self.numerator = integer
        self.denominator = 1
    }

    init?(_ numerator: Int, _ denominator: Int) {
        guard denominator != 0, numerator != Int.min, denominator != Int.min else { return nil }
        let divisor: Int = DrillRational.gcd(abs(numerator), abs(denominator))
        let sign: Int = denominator < 0 ? -1 : 1
        self.numerator = sign * (numerator / divisor)
        self.denominator = abs(denominator) / divisor
    }

    /// 最大公約数(どちらも 0 以上)。gcd(0, n) = n。
    static func gcd(_ a: Int, _ b: Int) -> Int {
        var x: Int = a
        var y: Int = b
        while y != 0 {
            let r: Int = x % y
            x = y
            y = r
        }
        return x == 0 ? 1 : x
    }

    var isZero: Bool { numerator == 0 }
    var isInteger: Bool { denominator == 1 }
    var isNegative: Bool { numerator < 0 }
    var doubleValue: Double { Double(numerator) / Double(denominator) }
    var negated: DrillRational { DrillRational(unchecked: -numerator, denominator) }
    var magnitude: DrillRational { DrillRational(unchecked: abs(numerator), denominator) }

    private init(unchecked numerator: Int, _ denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    func adding(_ other: DrillRational) -> DrillRational? {
        let divisor: Int = DrillRational.gcd(denominator, other.denominator)
        let leftScale: Int = other.denominator / divisor
        let rightScale: Int = denominator / divisor
        let (left, overflowLeft): (Int, Bool) = numerator.multipliedReportingOverflow(by: leftScale)
        let (right, overflowRight): (Int, Bool) = other.numerator.multipliedReportingOverflow(by: rightScale)
        let (sum, overflowSum): (Int, Bool) = left.addingReportingOverflow(right)
        let (common, overflowCommon): (Int, Bool) = denominator.multipliedReportingOverflow(by: leftScale)
        guard !overflowLeft, !overflowRight, !overflowSum, !overflowCommon else { return nil }
        return DrillRational(sum, common)
    }

    func subtracting(_ other: DrillRational) -> DrillRational? {
        adding(other.negated)
    }

    func multiplied(by other: DrillRational) -> DrillRational? {
        // 先に斜めに約分して、あふれにくくする。
        let first: Int = DrillRational.gcd(abs(numerator), other.denominator)
        let second: Int = DrillRational.gcd(abs(other.numerator), denominator)
        let (top, overflowTop): (Int, Bool) = (numerator / first).multipliedReportingOverflow(by: other.numerator / second)
        let (bottom, overflowBottom): (Int, Bool) = (denominator / second).multipliedReportingOverflow(by: other.denominator / first)
        guard !overflowTop, !overflowBottom else { return nil }
        return DrillRational(top, bottom)
    }

    /// 0 で割る時は nil。
    func divided(by other: DrillRational) -> DrillRational? {
        guard let inverse: DrillRational = other.reciprocal else { return nil }
        return multiplied(by: inverse)
    }

    var reciprocal: DrillRational? {
        DrillRational(denominator, numerator)
    }

    /// 整数乗。0 の負の数乗と、あふれは nil。
    func power(_ exponent: Int) -> DrillRational? {
        if exponent == 0 { return DrillRational.one }
        if exponent < 0 {
            guard exponent != Int.min, let inverse: DrillRational = reciprocal else { return nil }
            return inverse.power(-exponent)
        }
        var result: DrillRational = DrillRational.one
        var base: DrillRational = self
        var remaining: Int = exponent
        while remaining > 0 {
            if remaining & 1 == 1 {
                guard let next: DrillRational = result.multiplied(by: base) else { return nil }
                result = next
            }
            remaining >>= 1
            if remaining > 0 {
                guard let squared: DrillRational = base.multiplied(by: base) else { return nil }
                base = squared
            }
        }
        return result
    }

    static func < (left: DrillRational, right: DrillRational) -> Bool {
        let (a, overflowA): (Int, Bool) = left.numerator.multipliedReportingOverflow(by: right.denominator)
        let (b, overflowB): (Int, Bool) = right.numerator.multipliedReportingOverflow(by: left.denominator)
        if overflowA || overflowB { return left.doubleValue < right.doubleValue }
        return a < b
    }

    /// 床関数。
    var floorValue: Int {
        let quotient: Int = numerator / denominator
        return (numerator % denominator != 0 && numerator < 0) ? quotient - 1 : quotient
    }

    /// 四捨五入(0.5 は 0 から遠い方へ)。あふれは nil。
    var roundedValue: Int? {
        let (doubled, overflow): (Int, Bool) = abs(numerator).multipliedReportingOverflow(by: 2)
        let (shifted, overflowShift): (Int, Bool) = doubled.addingReportingOverflow(denominator)
        let (bottom, overflowBottom): (Int, Bool) = denominator.multipliedReportingOverflow(by: 2)
        guard !overflow, !overflowShift, !overflowBottom else { return nil }
        let magnitude: Int = shifted / bottom
        return numerator < 0 ? -magnitude : magnitude
    }

    /// 10 進の文字列("12"、"-0.25"、"6.02e23")を誤差なしで読む。Int に収まらなければ nil。
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
        guard let digits: Int = Int(String(whole + fraction)) else { return nil }
        exponent -= fraction.count
        guard abs(exponent) <= 18 else { return nil }
        var scale: Int = 1
        for _ in 0..<abs(exponent) { scale *= 10 }
        let signed: Int = negative ? -digits : digits
        if exponent >= 0 {
            let (value, overflow): (Int, Bool) = signed.multipliedReportingOverflow(by: scale)
            guard !overflow else { return nil }
            self.init(integer: value)
        } else {
            self.init(signed, scale)
        }
    }
}

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
    case real(Double)

    static let zero: DrillNumber = DrillNumber.exact(DrillExact.zero)
    static let one: DrillNumber = DrillNumber.exact(DrillExact.one)

    init(integer: Int) {
        self = DrillNumber.exact(DrillExact(integer: integer))
    }

    init(rational: DrillRational) {
        self = DrillNumber.exact(DrillExact(rational: rational))
    }

    /// JSON の数(Double)を、10 進の表記どおりに誤差なしで読む。Int に収まらない大きさだけ実数にする。
    init(json value: Double) {
        if let rational: DrillRational = DrillRational(decimal: "\(value)") {
            self = DrillNumber.exact(DrillExact(rational: rational))
        } else {
            self = DrillNumber.real(value)
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
        case DrillNumber.real(let value): return value
        }
    }

    var isZero: Bool {
        switch self {
        case DrillNumber.exact(let value): return value.isZero
        case DrillNumber.real(let value): return value == 0
        }
    }

    var isExact: Bool {
        if case DrillNumber.exact = self { return true }
        return false
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
