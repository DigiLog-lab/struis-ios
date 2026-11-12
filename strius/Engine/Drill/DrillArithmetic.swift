import Foundation

/// 数どうしの計算。誤差なしで求まる間は誤差なしで持ち、求まらなくなったところから実数にする。
/// 値が定まらない計算(0 で割る、負の数の平方根など)は nil を返す。
nonisolated enum DrillArithmetic {
    /// 実数どうしを等しいとみなす相対誤差。
    static let tolerance: Double = 1e-9

    private static func real(_ number: DrillNumber) -> Double {
        number.doubleValue ?? Double.nan
    }

    /// どちらも有理数なら、桁の多い型(Int128)で計算する。Int であふれた時と、桁の多い数が混ざった時に使う。
    private static func wide(_ left: DrillNumber, _ right: DrillNumber, _ operation: (DrillWideRational, DrillWideRational) -> DrillWideRational?) -> DrillNumber? {
        guard let a: DrillWideRational = left.wideRational, let b: DrillWideRational = right.wideRational, let result: DrillWideRational = operation(a, b) else { return nil }
        return DrillNumber(wide: result)
    }

    static func add(_ left: DrillNumber, _ right: DrillNumber) -> DrillNumber {
        if case DrillNumber.exact(let a) = left, case DrillNumber.exact(let b) = right, let sum: DrillExact = a.adding(b) {
            return DrillNumber.exact(sum)
        }
        if let sum: DrillNumber = wide(left, right, { (a: DrillWideRational, b: DrillWideRational) -> DrillWideRational? in a.adding(b) }) { return sum }
        return DrillNumber.real(real(left) + real(right))
    }

    static func negate(_ value: DrillNumber) -> DrillNumber {
        switch value {
        case DrillNumber.exact(let exact): return DrillNumber.exact(exact.negated)
        case DrillNumber.wide(let wide): return DrillNumber.wide(wide.negated)
        case DrillNumber.real(let double): return DrillNumber.real(-double)
        }
    }

    static func subtract(_ left: DrillNumber, _ right: DrillNumber) -> DrillNumber {
        add(left, negate(right))
    }

    static func multiply(_ left: DrillNumber, _ right: DrillNumber) -> DrillNumber {
        if case DrillNumber.exact(let a) = left, case DrillNumber.exact(let b) = right, let product: DrillExact = a.multiplied(by: b) {
            return DrillNumber.exact(product)
        }
        if let product: DrillNumber = wide(left, right, { (a: DrillWideRational, b: DrillWideRational) -> DrillWideRational? in a.multiplied(by: b) }) { return product }
        return DrillNumber.real(real(left) * real(right))
    }

    /// 0 で割る時は nil。
    static func divide(_ left: DrillNumber, _ right: DrillNumber) -> DrillNumber? {
        guard !right.isZero else { return nil }
        if case DrillNumber.exact(let a) = left, case DrillNumber.exact(let b) = right, let inverse: DrillExact = b.reciprocal,
           let quotient: DrillExact = a.multiplied(by: inverse) {
            return DrillNumber.exact(quotient)
        }
        if let quotient: DrillNumber = wide(left, right, { (a: DrillWideRational, b: DrillWideRational) -> DrillWideRational? in a.divided(by: b) }) { return quotient }
        let divisor: Double = real(right)
        guard divisor != 0 else { return nil }
        return DrillNumber.real(real(left) / divisor)
    }

    /// 平方根。負の数は nil(複素数の範囲で求める時は `complexSquareRoot`)。
    static func squareRoot(_ value: DrillNumber) -> DrillNumber? {
        if let rational: DrillRational = value.rational {
            guard !rational.isNegative else { return nil }
            if let exact: DrillExact = DrillExact.squareRoot(of: rational) { return DrillNumber.exact(exact) }
        }
        guard let double: Double = value.doubleValue, double >= 0 else { return nil }
        return DrillNumber.real(double.squareRoot())
    }

    /// 有理数の平方根を複素数の範囲で求める(√(-4) = 2i)。
    static func complexSquareRoot(_ value: DrillNumber) -> DrillNumber? {
        guard let rational: DrillRational = value.rational, let exact: DrillExact = DrillExact.squareRoot(of: rational) else { return squareRoot(value) }
        return DrillNumber.exact(exact)
    }

    /// 整数の k 乗根が整数ならその値。
    private static func integerRoot(_ value: Int, _ degree: Int) -> Int? {
        guard value >= 0, degree >= 1 else { return nil }
        let estimate: Int = Int(pow(Double(value), 1.0 / Double(degree)).rounded())
        for candidate: Int in [estimate - 1, estimate, estimate + 1] where candidate >= 0 {
            if DrillRational(integer: candidate).power(degree) == DrillRational(integer: value) { return candidate }
        }
        return nil
    }

    /// 累乗。0 の負の数乗、負の数の分数乗(奇数乗根で割り切れる時を除く)は nil。
    static func power(_ base: DrillNumber, _ exponent: DrillNumber) -> DrillNumber? {
        if let power: DrillRational = exponent.rational {
            if power.isZero { return DrillNumber.one }
            if case DrillNumber.exact(let exact) = base {
                if power.isInteger {
                    if let rational: DrillRational = exact.rational {
                        if rational.isZero && power.isNegative { return nil }
                        if let result: DrillRational = rational.power(power.numerator) { return DrillNumber(rational: result) }
                    } else if abs(power.numerator) <= 16 {
                        // 平方根を含む数の整数乗は、掛け算の繰り返しで誤差なしに求める。
                        var result: DrillExact = DrillExact.one
                        var failed: Bool = false
                        for _ in 0..<abs(power.numerator) {
                            guard let next: DrillExact = result.multiplied(by: exact) else { failed = true; break }
                            result = next
                        }
                        if !failed {
                            if !power.isNegative { return DrillNumber.exact(result) }
                            if let inverse: DrillExact = result.reciprocal { return DrillNumber.exact(inverse) }
                        }
                    }
                } else if let rational: DrillRational = exact.rational {
                    // 分数乗: p/q 乗 = (q 乗根)の p 乗。割り切れる時だけ誤差なし。
                    let negative: Bool = rational.isNegative
                    if negative && power.denominator % 2 == 0 { return nil }
                    if rational.isZero { return power.isNegative ? nil : DrillNumber.zero }
                    if power.denominator == 2, let root: DrillExact = DrillExact.squareRoot(of: rational),
                       let result: DrillNumber = DrillArithmetic.power(DrillNumber.exact(root), DrillNumber(integer: power.numerator)) {
                        return result
                    }
                    if let top: Int = integerRoot(abs(rational.numerator), power.denominator), let bottom: Int = integerRoot(rational.denominator, power.denominator),
                       let root: DrillRational = DrillRational(negative ? -top : top, bottom), let result: DrillRational = root.power(power.numerator) {
                        return DrillNumber(rational: result)
                    }
                    if negative { return nil }
                }
            }
        }
        // 桁の多い有理数の整数乗(c² の c = 3.0 × 10⁸ など)。
        if let power: Int = exponent.integer, let wide: DrillWideRational = base.wideRational, !(wide.isZero && power < 0), let result: DrillWideRational = wide.power(power) {
            return DrillNumber(wide: result)
        }
        guard let b: Double = base.doubleValue, let e: Double = exponent.doubleValue else { return nil }
        if b == 0 && e < 0 { return nil }
        let value: Double = pow(b, e)
        return value.isFinite ? DrillNumber.real(value) : nil
    }

    /// 大小。虚数を含む数は比べられない(nil)。
    static func compare(_ left: DrillNumber, _ right: DrillNumber) -> ComparisonResult? {
        if let a: DrillRational = left.rational, let b: DrillRational = right.rational {
            if a == b { return ComparisonResult.orderedSame }
            return a < b ? ComparisonResult.orderedAscending : ComparisonResult.orderedDescending
        }
        if left.isExact, right.isExact, left == right { return ComparisonResult.orderedSame }
        if let a: DrillWideRational = left.wideRational, let b: DrillWideRational = right.wideRational {
            if a == b { return ComparisonResult.orderedSame }
            return a < b ? ComparisonResult.orderedAscending : ComparisonResult.orderedDescending
        }
        guard let a: Double = left.doubleValue, let b: Double = right.doubleValue, a.isFinite, b.isFinite else { return nil }
        if !(left.isExact && right.isExact), abs(a - b) <= tolerance * max(1, abs(a), abs(b)) { return ComparisonResult.orderedSame }
        if a == b { return ComparisonResult.orderedSame }
        return a < b ? ComparisonResult.orderedAscending : ComparisonResult.orderedDescending
    }

    /// 等しいか。誤差なしの数どうしは厳密に、実数が混ざれば相対誤差 1e-9 で比べる。
    static func equal(_ left: DrillNumber, _ right: DrillNumber, tolerance: Double = DrillArithmetic.tolerance) -> Bool {
        if case DrillNumber.exact(let a) = left, case DrillNumber.exact(let b) = right { return a == b }
        if let a: DrillWideRational = left.wideRational, let b: DrillWideRational = right.wideRational { return a == b }
        guard let a: Double = left.doubleValue, let b: Double = right.doubleValue else { return false }
        return abs(a - b) <= tolerance * max(1, abs(a), abs(b))
    }

    /// 15° きざみの角の正弦(誤差なし)。それ以外の角は nil。
    static func exactSine(degrees: Int) -> DrillExact? {
        let reduced: Int = ((degrees % 360) + 360) % 360
        if reduced > 180 { return exactSine(degrees: reduced - 180)?.negated }
        if reduced > 90 { return exactSine(degrees: 180 - reduced) }
        func rational(_ n: Int, _ d: Int) -> DrillRational { DrillRational(n, d) ?? DrillRational.zero }
        switch reduced {
        case 0: return DrillExact.zero
        case 15: return DrillExact(terms: [6: rational(1, 4), 2: rational(-1, 4)])
        case 30: return DrillExact(rational: rational(1, 2))
        case 45: return DrillExact(terms: [2: rational(1, 2)])
        case 60: return DrillExact(terms: [3: rational(1, 2)])
        case 75: return DrillExact(terms: [6: rational(1, 4), 2: rational(1, 4)])
        case 90: return DrillExact.one
        default: return nil
        }
    }

    /// 底 b の対数が有理数で求まる時はその値(log_4 8 = 3/2)。
    static func exactLogarithm(base: DrillRational, of value: DrillRational) -> DrillRational? {
        guard !base.isNegative, !base.isZero, base != DrillRational.one, !value.isNegative, !value.isZero else { return nil }
        if value == DrillRational.one { return DrillRational.zero }
        for denominator: Int in 1...6 {
            guard let target: DrillRational = value.power(denominator) else { continue }
            for numerator: Int in -40...40 where numerator != 0 {
                if base.power(numerator) == target { return DrillRational(numerator, denominator) }
            }
        }
        return nil
    }

    static func isPrime(_ value: Int) -> Bool {
        guard value >= 2 else { return false }
        if value < 4 { return true }
        if value % 2 == 0 { return false }
        var divisor: Int = 3
        while divisor * divisor <= value {
            if value % divisor == 0 { return false }
            divisor += 2
        }
        return true
    }
}
