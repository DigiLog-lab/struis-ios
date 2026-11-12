import Foundation

/// 丸め。誤差なしの数は誤差なしで丸め、実数は丸めの境目に近すぎないか(`stable`)も返す。
nonisolated enum DrillRounding {
    /// 有効数字に丸めた結果。値 = ±mantissa × 10^(exponent - digits + 1)。mantissa は digits 桁の整数(値が 0 の時は 0)。
    nonisolated struct Significant: Equatable, Sendable {
        let negative: Bool
        let mantissa: Int
        let exponent: Int
        let digits: Int
        /// 丸めの境目(…5)から十分離れているか。実数の誤差で答えが変わらないことを確かめる。
        let stable: Bool
    }

    static func powerOfTen(_ exponent: Int) -> DrillRational? {
        guard abs(exponent) <= 18 else { return nil }
        return DrillRational(integer: 10).power(exponent)
    }

    static func significant(_ number: DrillNumber, digits: Int) -> Significant? {
        guard digits >= 1, digits <= 15 else { return nil }
        if number.isZero { return Significant(negative: false, mantissa: 0, exponent: 0, digits: digits, stable: true) }
        if let rational: DrillRational = number.rational, let exact: Significant = exactSignificant(rational, digits: digits) { return exact }
        guard let value: Double = number.doubleValue, value.isFinite else { return nil }
        let size: Double = abs(value)
        var exponent: Int = Int(log10(size).rounded(FloatingPointRoundingRule.down))
        var scaled: Double = size / pow(10.0, Double(exponent - digits + 1))
        let upper: Double = pow(10.0, Double(digits))
        if scaled >= upper { exponent += 1; scaled /= 10 }
        if scaled < upper / 10 { exponent -= 1; scaled *= 10 }
        var mantissa: Int = Int(scaled.rounded(FloatingPointRoundingRule.toNearestOrAwayFromZero))
        let fraction: Double = scaled - scaled.rounded(FloatingPointRoundingRule.down)
        let stable: Bool = abs(fraction - 0.5) > 1e-6
        if Double(mantissa) >= upper { mantissa /= 10; exponent += 1 }
        return Significant(negative: value < 0, mantissa: mantissa, exponent: exponent, digits: digits, stable: stable)
    }

    private static func exactSignificant(_ rational: DrillRational, digits: Int) -> Significant? {
        let size: DrillRational = rational.magnitude
        var exponent: Int = Int(log10(size.doubleValue).rounded(FloatingPointRoundingRule.down))
        for _ in 0..<3 {
            guard let low: DrillRational = powerOfTen(exponent), let high: DrillRational = powerOfTen(exponent + 1) else { return nil }
            if size < low { exponent -= 1 } else if !(size < high) { exponent += 1 } else { break }
        }
        guard let unit: DrillRational = powerOfTen(exponent - digits + 1), let scaled: DrillRational = size.divided(by: unit),
              var mantissa: Int = scaled.roundedValue, let upper: DrillRational = powerOfTen(digits) else { return nil }
        if mantissa >= upper.numerator { mantissa /= 10; exponent += 1 }
        return Significant(negative: rational.isNegative, mantissa: mantissa, exponent: exponent, digits: digits, stable: true)
    }

    /// 小数第 places 位に丸める(places が負なら十の位など)。
    static func decimals(_ number: DrillNumber, places: Int) -> (value: DrillRational, stable: Bool)? {
        guard let unit: DrillRational = powerOfTen(-places) else { return nil }
        if let rational: DrillRational = number.rational {
            guard let scaled: DrillRational = rational.divided(by: unit), let rounded: Int = scaled.roundedValue,
                  let value: DrillRational = DrillRational(integer: rounded).multiplied(by: unit) else { return nil }
            return (value, true)
        }
        guard let double: Double = number.doubleValue, double.isFinite else { return nil }
        let scaled: Double = double / unit.doubleValue
        guard abs(scaled) < 1e15 else { return nil }
        let rounded: Double = scaled.rounded(FloatingPointRoundingRule.toNearestOrAwayFromZero)
        let fraction: Double = abs(scaled) - abs(scaled).rounded(FloatingPointRoundingRule.down)
        guard let value: DrillRational = DrillRational(integer: Int(rounded)).multiplied(by: unit) else { return nil }
        return (value, abs(fraction - 0.5) > 1e-6)
    }

    /// 有効数字に丸めた値(誤差なし)。
    static func value(of significant: Significant) -> DrillRational? {
        guard let unit: DrillRational = powerOfTen(significant.exponent - significant.digits + 1) else { return nil }
        return DrillRational(integer: significant.negative ? -significant.mantissa : significant.mantissa).multiplied(by: unit)
    }
}

/// 型の式で使える関数(docs/offline-drill/format.md「関数」)。ここに無い名前は使えない。
nonisolated enum DrillFunctions {
    typealias EvaluationError = DrillExpression.EvaluationError

    /// 関数名と、引数の数(下限・上限)。
    static let arity: [String: ClosedRange<Int>] = [
        "abs": 1...1, "sqrt": 1...1, "csqrt": 1...1, "exp": 1...1, "ln": 1...1, "log10": 1...1, "log2": 1...1, "log": 2...2,
        "sin": 1...1, "cos": 1...1, "tan": 1...1, "asin": 1...1, "acos": 1...1, "atan": 1...1,
        "sind": 1...1, "cosd": 1...1, "tand": 1...1, "asind": 1...1, "acosd": 1...1, "atand": 1...1,
        "floor": 1...1, "ceil": 1...1, "round": 1...2, "sig": 2...2,
        "gcd": 2...8, "lcm": 2...8, "mod": 2...2, "quot": 2...2, "factorial": 1...1, "comb": 2...2, "perm": 2...2,
        "num": 1...1, "den": 1...1, "sign": 1...1, "min": 2...12, "max": 2...12, "median": 1...12, "nth": 2...13, "mean": 1...12,
        "is_integer": 1...1, "is_square": 1...1, "is_prime": 1...1, "to_base": 2...2, "divisors": 1...1,
        "if": 3...3, "approx": 2...3, "q": 2...2, "value": 2...2, "re": 1...1, "im": 1...1, "conj": 1...1, "pow": 2...2,
    ]

    static func call(_ name: String, _ arguments: [DrillExpression], _ scope: [String: DrillValue]) throws -> DrillValue {
        guard let range: ClosedRange<Int> = arity[name] else { throw EvaluationError.unknownFunction(name) }
        guard range.contains(arguments.count) else { throw EvaluationError.type("関数「\(name)」の引数の数が違います") }
        if name == "if" {
            return try DrillExpression.bool(try arguments[0].evaluate(scope)) ? try arguments[1].evaluate(scope) : try arguments[2].evaluate(scope)
        }
        if name == "q" || name == "value" {
            guard case DrillExpression.string(let unitText) = arguments[1] else { throw EvaluationError.type("関数「\(name)」の 2 つ目は 'm/s' のように単位を書いてください") }
            let unit: DrillUnit
            do { unit = try DrillUnit.parse(unitText) } catch let error as DrillUnit.ParseError { throw EvaluationError.type(error.message) }
            let quantity: DrillQuantity = try DrillExpression.quantity(try arguments[0].evaluate(scope))
            if name == "q" {
                guard quantity.dimension.isNone else { throw EvaluationError.dimension("q の 1 つ目は単位のない数にしてください") }
                return DrillValue.quantity(DrillQuantity(DrillArithmetic.multiply(quantity.number, unit.scale), dimension: unit.dimension))
            }
            guard quantity.dimension == unit.dimension else {
                throw EvaluationError.dimension("value の単位「\(unitText)」と量の次元(\(quantity.dimension.text))が合いません")
            }
            guard let number: DrillNumber = DrillArithmetic.divide(quantity.number, unit.scale) else { throw EvaluationError.undefined("単位の倍率が 0 です") }
            return DrillValue.number(number)
        }
        let values: [DrillQuantity] = try arguments.map { (argument: DrillExpression) -> DrillQuantity in try DrillExpression.quantity(try argument.evaluate(scope)) }
        let first: DrillQuantity = values[0]

        func plain(_ index: Int = 0) throws -> DrillNumber {
            guard values[index].dimension.isNone else { throw EvaluationError.dimension("関数「\(name)」には単位のない数を渡してください") }
            return values[index].number
        }
        func double(_ index: Int = 0) throws -> Double {
            guard let value: Double = try plain(index).doubleValue else { throw EvaluationError.undefined("関数「\(name)」に実数でない数を渡しています") }
            return value
        }
        func integer(_ index: Int = 0) throws -> Int {
            guard let value: Int = try plain(index).integer else { throw EvaluationError.undefined("関数「\(name)」には整数を渡してください") }
            return value
        }
        func real(_ value: Double) throws -> DrillValue {
            guard value.isFinite else { throw EvaluationError.undefined("関数「\(name)」の値が定まりません") }
            return DrillValue.number(DrillNumber.real(value))
        }
        func exact(_ rational: DrillRational?) throws -> DrillValue {
            guard let rational: DrillRational = rational else { throw EvaluationError.undefined("関数「\(name)」の値が大きすぎます") }
            return DrillValue.number(DrillNumber(rational: rational))
        }
        func sameDimension() throws -> DrillDimension {
            for value: DrillQuantity in values where value.dimension != first.dimension {
                throw EvaluationError.dimension("関数「\(name)」に次元の違う量を渡しています")
            }
            return first.dimension
        }

        switch name {
        case "abs":
            if let rational: DrillRational = first.number.rational { return DrillValue.quantity(DrillQuantity(DrillNumber(rational: rational.magnitude), dimension: first.dimension)) }
            if case DrillNumber.exact(let value) = first.number, value.hasImaginary {
                // 複素数の絶対値 √(実部² + 虚部²)。
                let realPart: DrillNumber = DrillNumber.exact(value.realPart)
                let imaginaryPart: DrillNumber = DrillNumber.exact(value.imaginaryPart)
                let sum: DrillNumber = DrillArithmetic.add(DrillArithmetic.multiply(realPart, realPart), DrillArithmetic.multiply(imaginaryPart, imaginaryPart))
                guard let root: DrillNumber = DrillArithmetic.squareRoot(sum) else { throw EvaluationError.undefined("絶対値が定まりません") }
                return DrillValue.quantity(DrillQuantity(root, dimension: first.dimension))
            }
            guard let value: Double = first.number.doubleValue else { throw EvaluationError.undefined("絶対値が定まりません") }
            return DrillValue.quantity(DrillQuantity(value < 0 ? DrillArithmetic.negate(first.number) : first.number, dimension: first.dimension))
        case "sqrt":
            guard let root: DrillNumber = DrillArithmetic.squareRoot(first.number) else { throw EvaluationError.undefined("負の数の平方根になっています") }
            return DrillValue.quantity(DrillQuantity(root, dimension: first.dimension.power(DrillRational(1, 2) ?? DrillRational.one)))
        case "csqrt":
            guard let root: DrillNumber = DrillArithmetic.complexSquareRoot(try plain()) else { throw EvaluationError.undefined("平方根が定まりません") }
            return DrillValue.number(root)
        case "exp": return try real(exp(try double()))
        case "ln":
            let x: Double = try double()
            guard x > 0 else { throw EvaluationError.undefined("対数の真数が正ではありません") }
            if try plain() == DrillNumber.one { return DrillValue.number(DrillNumber.zero) }
            return try real(log(x))
        case "log10", "log2", "log":
            let base: DrillNumber = name == "log10" ? DrillNumber(integer: 10) : (name == "log2" ? DrillNumber(integer: 2) : try plain(0))
            let argument: DrillNumber = name == "log" ? try plain(1) : try plain(0)
            guard let b: Double = base.doubleValue, let x: Double = argument.doubleValue, b > 0, b != 1, x > 0 else {
                throw EvaluationError.undefined("対数の底か真数が範囲の外です")
            }
            if let baseRational: DrillRational = base.rational, let argumentRational: DrillRational = argument.rational,
               let result: DrillRational = DrillArithmetic.exactLogarithm(base: baseRational, of: argumentRational) {
                return DrillValue.number(DrillNumber(rational: result))
            }
            return try real(log(x) / log(b))
        case "sin": return try real(sin(try double()))
        case "cos": return try real(cos(try double()))
        case "tan": return try real(tan(try double()))
        case "asin", "acos":
            let x: Double = try double()
            guard abs(x) <= 1 else { throw EvaluationError.undefined("逆三角関数の定義域の外です") }
            return try real(name == "asin" ? asin(x) : acos(x))
        case "atan": return try real(atan(try double()))
        case "sind", "cosd", "tand":
            if let degrees: Int = try plain().integer, degrees % 15 == 0,
               let sine: DrillExact = DrillArithmetic.exactSine(degrees: degrees), let cosine: DrillExact = DrillArithmetic.exactSine(degrees: 90 - degrees) {
                if name == "sind" { return DrillValue.number(DrillNumber.exact(sine)) }
                if name == "cosd" { return DrillValue.number(DrillNumber.exact(cosine)) }
                guard let tangent: DrillNumber = DrillArithmetic.divide(DrillNumber.exact(sine), DrillNumber.exact(cosine)) else {
                    throw EvaluationError.undefined("tan が定義されない角です")
                }
                return DrillValue.number(tangent)
            }
            let radians: Double = try double() * Double.pi / 180
            return try real(name == "sind" ? sin(radians) : (name == "cosd" ? cos(radians) : tan(radians)))
        case "asind", "acosd", "atand":
            let x: Double = try double()
            guard name == "atand" || abs(x) <= 1 else { throw EvaluationError.undefined("逆三角関数の定義域の外です") }
            let radians: Double = name == "asind" ? asin(x) : (name == "acosd" ? acos(x) : atan(x))
            let degrees: Double = radians * 180 / Double.pi
            // 15° きざみの角は整数で返す(誤差で 29.999… にならないように)。
            let nearest: Double = (degrees / 15).rounded() * 15
            if abs(degrees - nearest) < 1e-9 { return DrillValue.integer(Int(nearest)) }
            return try real(degrees)
        case "floor", "ceil":
            if let rational: DrillRational = try plain().rational {
                let floorValue: Int = rational.floorValue
                return DrillValue.integer(name == "floor" || rational.isInteger ? floorValue : floorValue + 1)
            }
            let x: Double = try double()
            guard abs(x) < 1e15 else { throw EvaluationError.undefined("関数「\(name)」の値が大きすぎます") }
            return DrillValue.integer(Int(name == "floor" ? x.rounded(FloatingPointRoundingRule.down) : x.rounded(FloatingPointRoundingRule.up)))
        case "round":
            let places: Int = values.count == 2 ? try integer(1) : 0
            guard let rounded: (value: DrillRational, stable: Bool) = DrillRounding.decimals(try plain(), places: places) else {
                throw EvaluationError.undefined("丸められない数です")
            }
            guard rounded.stable else { throw EvaluationError.undefined("丸めの境目にあって、値が定まりません") }
            return DrillValue.number(DrillNumber(rational: rounded.value))
        case "sig":
            guard let significant: DrillRounding.Significant = DrillRounding.significant(try plain(), digits: try integer(1)),
                  let value: DrillRational = DrillRounding.value(of: significant) else { throw EvaluationError.undefined("丸められない数です") }
            guard significant.stable else { throw EvaluationError.undefined("丸めの境目にあって、値が定まりません") }
            return DrillValue.number(DrillNumber(rational: value))
        case "gcd", "lcm":
            var result: Int = abs(try integer(0))
            for index: Int in 1..<values.count {
                let next: Int = abs(try integer(index))
                if name == "gcd" {
                    result = (result == 0 && next == 0) ? 0 : DrillRational.gcd(result, next)
                } else {
                    guard result != 0, next != 0 else { result = 0; continue }
                    let (product, overflow): (Int, Bool) = (result / DrillRational.gcd(result, next)).multipliedReportingOverflow(by: next)
                    guard !overflow else { throw EvaluationError.undefined("最小公倍数が大きすぎます") }
                    result = product
                }
            }
            return DrillValue.integer(result)
        case "mod", "quot":
            let a: Int = try integer(0)
            let b: Int = try integer(1)
            guard b != 0 else { throw EvaluationError.undefined("0 で割っています") }
            // 余りは 0 以上(割る数が正の時)。商は床。
            var quotient: Int = a / b
            var remainder: Int = a % b
            if remainder != 0, (remainder < 0) != (b < 0) { quotient -= 1; remainder += b }
            return DrillValue.integer(name == "mod" ? remainder : quotient)
        case "factorial":
            let n: Int = try integer()
            guard n >= 0, n <= 20 else { throw EvaluationError.undefined("階乗は 0 から 20 までです") }
            return DrillValue.integer((1...max(1, n)).reduce(1) { (product: Int, k: Int) -> Int in product * k })
        case "comb", "perm":
            let n: Int = try integer(0)
            let r: Int = try integer(1)
            guard n >= 0, r >= 0, r <= n, n <= 60 else { throw EvaluationError.undefined("関数「\(name)」の引数が範囲の外です") }
            var result: DrillRational = DrillRational.one
            for k: Int in 0..<r {
                let factor: DrillRational? = name == "comb" ? DrillRational(n - k, k + 1) : DrillRational(integer: n - k)
                guard let factor: DrillRational = factor, let next: DrillRational = result.multiplied(by: factor) else {
                    throw EvaluationError.undefined("関数「\(name)」の値が大きすぎます")
                }
                result = next
            }
            return try exact(result)
        case "num", "den":
            guard let rational: DrillRational = try plain().rational else { throw EvaluationError.undefined("関数「\(name)」には有理数を渡してください") }
            return DrillValue.integer(name == "num" ? rational.numerator : rational.denominator)
        case "sign":
            guard let order: ComparisonResult = DrillArithmetic.compare(first.number, DrillNumber.zero) else { throw EvaluationError.undefined("符号が定まりません") }
            return DrillValue.integer(order == ComparisonResult.orderedSame ? 0 : (order == ComparisonResult.orderedAscending ? -1 : 1))
        case "min", "max":
            let dimension: DrillDimension = try sameDimension()
            var best: DrillNumber = first.number
            for value: DrillQuantity in values.dropFirst() {
                guard let order: ComparisonResult = DrillArithmetic.compare(value.number, best) else { throw EvaluationError.undefined("大小を比べられない数です") }
                if (name == "min" && order == ComparisonResult.orderedAscending) || (name == "max" && order == ComparisonResult.orderedDescending) { best = value.number }
            }
            return DrillValue.quantity(DrillQuantity(best, dimension: dimension))
        case "median":
            let dimension: DrillDimension = try sameDimension()
            var failed: Bool = false
            let sorted: [DrillNumber] = values.map { (value: DrillQuantity) -> DrillNumber in value.number }.sorted { (a: DrillNumber, b: DrillNumber) -> Bool in
                guard let order: ComparisonResult = DrillArithmetic.compare(a, b) else { failed = true; return false }
                return order == ComparisonResult.orderedAscending
            }
            guard !failed else { throw EvaluationError.undefined("大小を比べられない数です") }
            let middle: Int = sorted.count / 2
            if sorted.count % 2 == 1 { return DrillValue.quantity(DrillQuantity(sorted[middle], dimension: dimension)) }
            guard let mean: DrillNumber = DrillArithmetic.divide(DrillArithmetic.add(sorted[middle - 1], sorted[middle]), DrillNumber(integer: 2)) else {
                throw EvaluationError.undefined("中央値が定まりません")
            }
            return DrillValue.quantity(DrillQuantity(mean, dimension: dimension))
        case "nth":
            // nth(k, a, b, c, …): 小さい順に並べた時の k 番目(1 から数える)。
            let k: Int = try integer(0)
            let rest: [DrillQuantity] = Array(values.dropFirst())
            guard k >= 1, k <= rest.count else { throw EvaluationError.undefined("nth の順番が範囲の外です") }
            for value: DrillQuantity in rest where value.dimension != rest[0].dimension { throw EvaluationError.dimension("nth に次元の違う量を渡しています") }
            var failed: Bool = false
            let sorted: [DrillQuantity] = rest.sorted { (a: DrillQuantity, b: DrillQuantity) -> Bool in
                guard let order: ComparisonResult = DrillArithmetic.compare(a.number, b.number) else { failed = true; return false }
                return order == ComparisonResult.orderedAscending
            }
            guard !failed else { throw EvaluationError.undefined("大小を比べられない数です") }
            return DrillValue.quantity(sorted[k - 1])
        case "mean":
            let dimension: DrillDimension = try sameDimension()
            var total: DrillNumber = DrillNumber.zero
            for value: DrillQuantity in values { total = DrillArithmetic.add(total, value.number) }
            guard let mean: DrillNumber = DrillArithmetic.divide(total, DrillNumber(integer: values.count)) else { throw EvaluationError.undefined("平均が定まりません") }
            return DrillValue.quantity(DrillQuantity(try DrillExpression.finite(mean, "平均"), dimension: dimension))
        case "is_integer":
            return DrillValue.bool(first.number.integer != nil)
        case "is_square":
            guard let rational: DrillRational = first.number.rational, !rational.isNegative else { return DrillValue.bool(false) }
            func isSquare(_ value: Int) -> Bool {
                let root: Int = Int(Double(value).squareRoot().rounded())
                return [root - 1, root, root + 1].contains { (candidate: Int) -> Bool in candidate >= 0 && candidate * candidate == value }
            }
            return DrillValue.bool(isSquare(rational.numerator) && isSquare(rational.denominator))
        case "is_prime":
            guard let value: Int = first.number.integer else { return DrillValue.bool(false) }
            return DrillValue.bool(DrillArithmetic.isPrime(value))
        case "divisors":
            // 正の約数の個数。
            let n: Int = try integer()
            guard n >= 1, n <= 10_000_000 else { throw EvaluationError.undefined("divisors は 1 以上 1000 万以下の整数にしてください") }
            var count: Int = 0
            var divisor: Int = 1
            while divisor * divisor <= n {
                if n % divisor == 0 { count += divisor * divisor == n ? 1 : 2 }
                divisor += 1
            }
            return DrillValue.integer(count)
        case "to_base":
            // n を b 進法で書いた時の数字の並びを、10 進の整数として返す(to_base(5, 2) = 101)。
            var n: Int = try integer(0)
            let base: Int = try integer(1)
            guard n >= 0, base >= 2, base <= 10 else { throw EvaluationError.undefined("to_base は 0 以上の整数と 2〜10 の底にしてください") }
            var digits: [Int] = []
            repeat { digits.append(n % base); n /= base } while n > 0
            guard digits.count <= 18 else { throw EvaluationError.undefined("桁が多すぎます") }
            return DrillValue.integer(digits.reversed().reduce(0) { (value: Int, digit: Int) -> Int in value * 10 + digit })
        case "approx":
            guard first.dimension == values[1].dimension || first.number.isZero || values[1].number.isZero else {
                throw EvaluationError.dimension("approx の両側の次元が合いません(\(first.dimension.text) と \(values[1].dimension.text))")
            }
            let tolerance: Double = values.count == 3 ? try double(2) : 1e-9
            return DrillValue.bool(DrillArithmetic.equal(first.number, values[1].number, tolerance: tolerance))
        case "re", "im", "conj":
            guard case DrillNumber.exact(let value) = try plain() else {
                if name == "im" { return DrillValue.number(DrillNumber.zero) }
                return DrillValue.number(first.number)
            }
            return DrillValue.number(DrillNumber.exact(name == "re" ? value.realPart : (name == "im" ? value.imaginaryPart : value.conjugate)))
        case "pow":
            return try DrillExpression.binary("^", arguments[0], arguments[1]).evaluate(scope)
        default:
            throw EvaluationError.unknownFunction(name)
        }
    }
}
