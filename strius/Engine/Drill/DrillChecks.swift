import Foundation

/// 数値計算の道具(差分・数値積分)。数値の点検にだけ使う。
nonisolated enum DrillNumerics {
    /// 文字に入れる値(きりの悪い数にして、たまたま合うことを避ける)。
    static let samples: [Double] = [0.7, -1.3, 2.1, -0.4, 1.6, 3.2, -2.3, 0.3]
    private static let fractions: [Double] = [0.13, 0.29, 0.41, 0.57, 0.73, 0.89, 0.37, 0.67]

    static func points(range: [Double]?) -> [Double] {
        guard let range: [Double] = range, range.count == 2, range[0] < range[1] else { return samples }
        return fractions.map { (t: Double) -> Double in range[0] + (range[1] - range[0]) * t }
    }

    /// 中心差分(5 点)で導関数を近似する。`order` は 1 か 2。
    static func derivative(_ f: (Double) -> DrillComplex?, at x: Double, order: Int, scale: Double = 1) -> DrillComplex? {
        let h: Double = (order == 1 ? 1e-3 : 1e-2) * max(1, abs(x)) * scale
        guard let a: DrillComplex = f(x - 2 * h), let b: DrillComplex = f(x - h), let c: DrillComplex = f(x), let d: DrillComplex = f(x + h), let e: DrillComplex = f(x + 2 * h) else { return nil }
        if order == 1 {
            return (a - DrillComplex(8) * b + DrillComplex(8) * d - e) / DrillComplex(12 * h)
        }
        return (DrillComplex(16) * (b + d) - a - e - DrillComplex(30) * c) / DrillComplex(12 * h * h)
    }

    /// 差分で求めた導関数が `expected` と合うか。特異点の近くでは差分の幅を縮めて確かめ直す。
    static func derivativeMatches(_ f: (Double) -> DrillComplex?, at x: Double, order: Int, expected: DrillComplex, tolerance: Double) -> (matches: Bool, value: DrillComplex?) {
        var first: DrillComplex? = nil
        for scale: Double in [1, 0.1, 0.01] {
            guard let slope: DrillComplex = derivative(f, at: x, order: order, scale: scale) else { continue }
            if first == nil { first = slope }
            if slope.isClose(to: expected, tolerance: tolerance) { return (true, slope) }
        }
        return (false, first)
    }

    /// ガウス・ルジャンドル(5 点)を小区間に分けて当てる数値積分。
    static func integral(_ f: (Double) -> DrillComplex?, from a: Double, to b: Double) -> DrillComplex? {
        if a == b { return DrillComplex.zero }
        let nodes: [Double] = [0, 0.5384693101056831, -0.5384693101056831, 0.906179845938664, -0.906179845938664]
        let weights: [Double] = [0.5688888888888889, 0.47862867049936647, 0.47862867049936647, 0.23692688505618908, 0.23692688505618908]
        let panels: Int = 256
        let width: Double = (b - a) / Double(panels)
        var total: DrillComplex = DrillComplex.zero
        for panel: Int in 0..<panels {
            let middle: Double = a + (Double(panel) + 0.5) * width
            for (node, weight): (Double, Double) in zip(nodes, weights) {
                guard let value: DrillComplex = f(middle + node * width / 2) else { return nil }
                total = total + DrillComplex(weight * width / 2) * value
            }
        }
        return total.isFinite ? total : nil
    }
}

/// 読み取り済みの点検 1 つ。型の式と LaTeX を先に読み取っておき、作った問題ごとに数値で確かめる。
nonisolated struct DrillCompiledCheck: Sendable {
    let check: DrillCheck
    let place: String
    private let texts: [String: DrillText]
    private let expressions: [String: DrillExpression]
    private let solutions: [DrillText]
    private let equations: [(left: DrillText, right: DrillText)]
    private let values: [String: DrillText]
    private let at: [String: DrillExpression]
    private let conditions: [(source: String, expression: DrillExpression)]

    static let kinds: Set<String> = ["identity", "value", "derivative", "antiderivative", "definite_integral", "root", "system", "inequality", "assert", "series", "limit", "ode"]

    /// 数値の点検に落ちた・実行できなかった理由。
    nonisolated struct Failure: Error, Equatable, Sendable {
        let message: String
    }

    init(_ check: DrillCheck, index: Int, compiled: DrillCompiledTemplate) throws {
        self.check = check
        let place: String = "checks[\(index)](\(check.kind))"
        self.place = place
        guard DrillCompiledCheck.kinds.contains(check.kind) else {
            throw DrillFailure(message: "\(place): kind「\(check.kind)」はありません(\(DrillCompiledCheck.kinds.sorted().joined(separator: "・")))")
        }
        var texts: [String: DrillText] = [:]
        var expressions: [String: DrillExpression] = [:]
        let valueNames: Set<String> = Set(compiled.variables.map { (variable: DrillCompiledTemplate.Variable) -> String in variable.name })
            .union(compiled.lets.map { (entry: DrillCompiledTemplate.Let) -> String in entry.name })

        func text(_ key: String, _ source: String?, required: Bool = true) throws {
            guard let source: String = source else {
                if required { throw DrillFailure(message: "\(place): 「\(key)」が要ります") }
                return
            }
            texts[key] = try DrillText.parse(source, names: compiled.names)
        }
        func parse(_ source: String, extra: Set<String> = []) throws -> DrillExpression {
            let parsed: DrillExpression
            do {
                parsed = try DrillExpression.parse(source)
            } catch let error as DrillExpression.SyntaxError {
                throw DrillFailure(message: "\(place): \(error.message)")
            }
            for name: String in parsed.names.sorted() where !valueNames.contains(name) && !extra.contains(name) && !DrillExpression.constants.contains(name) {
                throw DrillFailure(message: "\(place): 式「\(source)」の「\(name)」は変数にも lets にもありません")
            }
            for function: String in parsed.functionNames.sorted() where DrillFunctions.arity[function] == nil {
                throw DrillFailure(message: "\(place): 式「\(source)」の関数「\(function)」はありません")
            }
            return parsed
        }
        func expression(_ key: String, _ source: String?, required: Bool = true, extra: Set<String> = []) throws {
            guard let source: String = source else {
                if required { throw DrillFailure(message: "\(place): 「\(key)」が要ります") }
                return
            }
            expressions[key] = try parse(source, extra: extra)
        }
        func variable() throws -> String {
            guard let name: String = check.variable, !name.isEmpty else { throw DrillFailure(message: "\(place): 「variable」が要ります") }
            return name
        }

        var solutions: [DrillText] = []
        var equations: [(left: DrillText, right: DrillText)] = []
        var values: [String: DrillText] = [:]
        var conditions: [(source: String, expression: DrillExpression)] = []
        switch check.kind {
        case "identity":
            try text("left", check.left)
            try text("right", check.right)
        case "value":
            try text("tex", check.tex)
            try expression("equals", check.equals)
        case "derivative":
            try text("function", check.function)
            try text("answer", check.answer)
            _ = try variable()
            try expression("point", check.point, required: false)
            if let order: Int = check.order, order != 1, order != 2 { throw DrillFailure(message: "\(place): order は 1 か 2 です") }
        case "antiderivative":
            try text("integrand", check.integrand)
            try text("answer", check.answer)
            _ = try variable()
        case "definite_integral":
            try text("integrand", check.integrand)
            try text("answer", check.answer)
            _ = try variable()
            try expression("from", check.from)
            try expression("to", check.to)
        case "root":
            try text("left", check.left)
            try text("right", check.right ?? "0")
            _ = try variable()
            guard let sources: [String] = check.solutions, !sources.isEmpty else { throw DrillFailure(message: "\(place): 「solutions」が要ります") }
            solutions = try sources.map { (source: String) -> DrillText in try DrillText.parse(source, names: compiled.names) }
        case "system":
            guard let sources: [DrillEquation] = check.equations, !sources.isEmpty, let answers: [String: String] = check.values, !answers.isEmpty else {
                throw DrillFailure(message: "\(place): 「equations」と「values」が要ります")
            }
            equations = try sources.map { (equation: DrillEquation) -> (left: DrillText, right: DrillText) in
                (try DrillText.parse(equation.left, names: compiled.names), try DrillText.parse(equation.right, names: compiled.names))
            }
            values = try answers.mapValues { (source: String) -> DrillText in try DrillText.parse(source, names: compiled.names) }
        case "inequality":
            try text("left", check.left)
            try text("right", check.right)
            let name: String = try variable()
            guard !compiled.names.contains(name) else { throw DrillFailure(message: "\(place): variable「\(name)」が変数や lets の名前と重なっています") }
            try text("relation", check.relation)
            try expression("solution", check.solution, extra: [name])
            try expression("where", check.where, required: false, extra: [name])
        case "assert":
            guard let sources: [String] = check.conditions, !sources.isEmpty else { throw DrillFailure(message: "\(place): 「conditions」が要ります") }
            conditions = try sources.map { (source: String) -> (source: String, expression: DrillExpression) in (source, try parse(source)) }
        case "series":
            try text("term", check.term)
            try text("answer", check.answer)
            guard let index: String = check.index, !index.isEmpty else { throw DrillFailure(message: "\(place): 「index」が要ります") }
            try expression("from", check.from)
            try expression("to", check.to)
        case "limit":
            try text("function", check.function)
            try text("answer", check.answer)
            _ = try variable()
            guard let target: String = check.to else { throw DrillFailure(message: "\(place): 「to」が要ります") }
            if target != "inf" && target != "-inf" { try expression("to", target) }
        case "ode":
            try text("function", check.function)
            try text("left", check.left)
            try text("right", check.right ?? "0")
            _ = try variable()
        default:
            break
        }
        var at: [String: DrillExpression] = [:]
        for (symbol, source): (String, String) in check.at ?? [:] {
            at[symbol] = try parse(source)
        }
        self.texts = texts
        self.expressions = expressions
        self.solutions = solutions
        self.equations = equations
        self.values = values
        self.at = at
        self.conditions = conditions
    }

    // MARK: 確かめる

    /// 1 問について確かめる。合っていれば nil、合わなければ理由。
    func failure(for instance: DrillCompiledTemplate.Instance, compiled: DrillCompiledTemplate) -> String? {
        do {
            try run(instance, compiled)
            return nil
        } catch let error as Failure {
            return "\(place): \(error.message)"
        } catch let error as DrillFailure {
            return "\(place): \(error.message)"
        } catch let error as DrillTeX.ParseError {
            return "\(place): \(error.message)"
        } catch let error as DrillExpression.EvaluationError {
            return "\(place): \(error.message)"
        } catch {
            return "\(place): 確かめられませんでした"
        }
    }

    private var tolerance: Double { check.tolerance ?? 1e-6 }

    private func run(_ instance: DrillCompiledTemplate.Instance, _ compiled: DrillCompiledTemplate) throws {
        func rendered(_ text: DrillText) throws -> String {
            try compiled.render(text, scope: instance.scope, partTexts: instance.partTexts, place: place)
        }
        func tex(_ key: String) throws -> (source: String, items: [DrillTeX]) {
            guard let text: DrillText = texts[key] else { throw Failure(message: "「\(key)」がありません") }
            let source: String = try rendered(text)
            return (source, try DrillTeX.parse(source))
        }
        func single(_ key: String) throws -> (source: String, item: DrillTeX) {
            let parsed: (source: String, items: [DrillTeX]) = try tex(key)
            guard parsed.items.count == 1 else { throw Failure(message: "「\(key)」は式 1 つにしてください: \(parsed.source)") }
            return (parsed.source, parsed.items[0])
        }
        func complex(_ expression: DrillExpression, scope: [String: DrillValue]? = nil) throws -> DrillComplex {
            let quantity: DrillQuantity = try DrillExpression.quantity(try expression.evaluate(scope ?? instance.scope))
            guard quantity.dimension.isNone else {
                throw Failure(message: "単位のある値(\(quantity.dimension.text))をそのまま比べています。value(x, '単位') で数にしてください")
            }
            switch quantity.number {
            case DrillNumber.exact(let exact):
                let value: (real: Double, imaginary: Double) = exact.complexValue
                return DrillComplex(value.real, value.imaginary)
            case DrillNumber.real(let double):
                return DrillComplex(double)
            }
        }
        func real(_ key: String) throws -> Double {
            guard let expression: DrillExpression = expressions[key] else { throw Failure(message: "「\(key)」がありません") }
            let value: DrillComplex = try complex(expression)
            guard value.isReal else { throw Failure(message: "「\(key)」が実数ではありません") }
            return value.real
        }
        func fixed() throws -> [String: DrillComplex] {
            var bindings: [String: DrillComplex] = [:]
            for (symbol, expression): (String, DrillExpression) in at {
                bindings[symbol] = try complex(expression)
            }
            return bindings
        }
        /// 文字に値を入れた組を作る。`free` に無い文字が式にあれば投げる。
        func bindings(for free: [String], point: Int, base: [String: DrillComplex]) -> [String: DrillComplex] {
            let points: [Double] = DrillNumerics.points(range: check.range)
            var result: [String: DrillComplex] = base
            for (offset, symbol): (Int, String) in free.enumerated() where result[symbol] == nil {
                result[symbol] = DrillComplex(points[(point + offset * 3) % points.count] + Double(offset) * 0.11)
            }
            return result
        }
        func requireBound(_ items: [DrillTeX], _ allowed: Set<String>, _ source: String) throws {
            for item: DrillTeX in items {
                for symbol: String in item.symbols.sorted() where !allowed.contains(symbol) {
                    throw Failure(message: "式「\(source)」の文字「\(symbol)」に入れる値が決まっていません(over か at に書きます)")
                }
            }
        }
        func sorted(_ values: [DrillComplex]) -> [DrillComplex] {
            values.sorted { (a: DrillComplex, b: DrillComplex) -> Bool in a.real != b.real ? a.real < b.real : a.imaginary < b.imaginary }
        }
        func same(_ left: [DrillComplex], _ right: [DrillComplex], _ tolerance: Double) -> Bool {
            guard left.count == right.count else { return false }
            return zip(sorted(left), sorted(right)).allSatisfy { (a: DrillComplex, b: DrillComplex) -> Bool in a.isClose(to: b, tolerance: tolerance) }
        }
        func describe(_ values: [DrillComplex]) -> String {
            values.map { (value: DrillComplex) -> String in
                value.isReal ? String(format: "%.6g", value.real) : String(format: "%.6g%+.6gi", value.real, value.imaginary)
            }.joined(separator: ", ")
        }
        let base: [String: DrillComplex] = try fixed()
        let pointCount: Int = DrillNumerics.samples.count

        switch check.kind {
        case "identity":
            let left: (source: String, items: [DrillTeX]) = try tex("left")
            let right: (source: String, items: [DrillTeX]) = try tex("right")
            let symbols: Set<String> = (left.items + right.items).reduce(into: Set<String>()) { (set: inout Set<String>, item: DrillTeX) -> Void in set.formUnion(item.symbols) }
            let free: [String] = (check.over ?? symbols.subtracting(base.keys).sorted())
            try requireBound(left.items + right.items, Set(free).union(base.keys), left.source + " = " + right.source)
            var compared: Int = 0
            for point: Int in 0..<(free.isEmpty ? 1 : pointCount) {
                let bound: [String: DrillComplex] = bindings(for: free, point: point, base: base)
                guard let l: [DrillComplex] = DrillTeX.values(of: left.items, bindings: bound), let r: [DrillComplex] = DrillTeX.values(of: right.items, bindings: bound) else { continue }
                guard same(l, r, tolerance) else {
                    throw Failure(message: "「\(left.source)」と「\(right.source)」が等しくありません(\(describe(l)) と \(describe(r)))")
                }
                compared += 1
            }
            guard compared >= (free.isEmpty ? 1 : 3) else { throw Failure(message: "「\(left.source)」と「\(right.source)」を数値にできませんでした") }
        case "value":
            let shown: (source: String, items: [DrillTeX]) = try tex("tex")
            try requireBound(shown.items, Set(base.keys), shown.source)
            guard let expression: DrillExpression = expressions["equals"] else { throw Failure(message: "「equals」がありません") }
            let expected: DrillComplex = try complex(expression)
            guard let actual: [DrillComplex] = DrillTeX.values(of: shown.items, bindings: base) else { throw Failure(message: "「\(shown.source)」を数値にできませんでした") }
            guard same(actual, [expected], tolerance) else {
                throw Failure(message: "表示「\(shown.source)」(\(describe(actual)))が、式「\(check.equals ?? "")」の値(\(describe([expected])))と合いません")
            }
        case "derivative", "antiderivative":
            let isDerivative: Bool = check.kind == "derivative"
            let function: (source: String, item: DrillTeX) = try single(isDerivative ? "function" : "answer")
            let other: (source: String, item: DrillTeX) = try single(isDerivative ? "answer" : "integrand")
            let name: String = check.variable ?? "x"
            let order: Int = isDerivative ? (check.order ?? 1) : 1
            var constants: [String: DrillComplex] = base
            if !isDerivative, constants["C"] == nil { constants["C"] = DrillComplex(0.37) }
            let free: [String] = (check.over ?? function.item.symbols.union(other.item.symbols).subtracting(constants.keys).subtracting([name]).sorted())
            try requireBound([function.item, other.item], Set(free).union(constants.keys).union([name]), function.source)
            let derivativeTolerance: Double = max(tolerance, 1e-5)
            if isDerivative, expressions["point"] != nil {
                let x0: Double = try real("point")
                let bound: [String: DrillComplex] = bindings(for: free, point: 0, base: constants)
                let f: (Double) -> DrillComplex? = { (x: Double) -> DrillComplex? in
                    var local: [String: DrillComplex] = bound
                    local[name] = DrillComplex(x)
                    return function.item.evaluate(local)
                }
                guard let answer: DrillComplex = other.item.evaluate(bound) else { throw Failure(message: "答え「\(other.source)」を数値にできませんでした") }
                let result: (matches: Bool, value: DrillComplex?) = DrillNumerics.derivativeMatches(f, at: x0, order: order, expected: answer, tolerance: derivativeTolerance)
                guard let slope: DrillComplex = result.value else {
                    throw Failure(message: "「\(function.source)」の \(name) = \(x0) での微分係数を数値にできませんでした")
                }
                guard result.matches else {
                    throw Failure(message: "「\(function.source)」の \(name) = \(x0) での微分係数は \(describe([slope])) ですが、答えは「\(other.source)」(\(describe([answer])))です")
                }
                return
            }
            var compared: Int = 0
            for point: Int in 0..<pointCount {
                var bound: [String: DrillComplex] = bindings(for: free, point: point + 1, base: constants)
                let x0: Double = DrillNumerics.points(range: check.range)[point]
                let f: (Double) -> DrillComplex? = { (x: Double) -> DrillComplex? in
                    var local: [String: DrillComplex] = bound
                    local[name] = DrillComplex(x)
                    return function.item.evaluate(local)
                }
                bound[name] = DrillComplex(x0)
                guard let expected: DrillComplex = other.item.evaluate(bound) else { continue }
                let result: (matches: Bool, value: DrillComplex?) = DrillNumerics.derivativeMatches(f, at: x0, order: order, expected: expected, tolerance: derivativeTolerance)
                guard let slope: DrillComplex = result.value else { continue }
                guard result.matches else {
                    throw Failure(message: "「\(function.source)」を \(name) で微分した値(\(name) = \(x0) で \(describe([slope])))が、「\(other.source)」(\(describe([expected])))と合いません")
                }
                compared += 1
            }
            guard compared >= 3 else { throw Failure(message: "「\(function.source)」の導関数を数値にできませんでした(range で \(name) の範囲を決められます)") }
        case "definite_integral":
            let integrand: (source: String, item: DrillTeX) = try single("integrand")
            let answer: (source: String, items: [DrillTeX]) = try tex("answer")
            let name: String = check.variable ?? "x"
            try requireBound([integrand.item], Set(base.keys).union([name]), integrand.source)
            try requireBound(answer.items, Set(base.keys), answer.source)
            let from: Double = try real("from")
            let to: Double = try real("to")
            let f: (Double) -> DrillComplex? = { (x: Double) -> DrillComplex? in
                var local: [String: DrillComplex] = base
                local[name] = DrillComplex(x)
                return integrand.item.evaluate(local)
            }
            guard let total: DrillComplex = DrillNumerics.integral(f, from: from, to: to), let shown: [DrillComplex] = DrillTeX.values(of: answer.items, bindings: base) else {
                throw Failure(message: "「\(integrand.source)」の \(from) から \(to) までの積分を数値にできませんでした")
            }
            guard same(shown, [total], tolerance) else {
                throw Failure(message: "「\(integrand.source)」の \(from) から \(to) までの積分は \(describe([total])) ですが、答えは「\(answer.source)」(\(describe(shown)))です")
            }
        case "root":
            let left: (source: String, item: DrillTeX) = try single("left")
            let right: (source: String, item: DrillTeX) = try single("right")
            let name: String = check.variable ?? "x"
            try requireBound([left.item, right.item], Set(base.keys).union([name]), left.source)
            var roots: [DrillComplex] = []
            for solution: DrillText in solutions {
                let source: String = try rendered(solution)
                let items: [DrillTeX] = try DrillTeX.parse(source)
                try requireBound(items, Set(base.keys), source)
                guard let found: [DrillComplex] = DrillTeX.values(of: items, bindings: base) else { throw Failure(message: "解「\(source)」を数値にできませんでした") }
                roots += found
            }
            func residual(_ x: DrillComplex) -> (difference: Double, scale: Double)? {
                var local: [String: DrillComplex] = base
                local[name] = x
                guard let l: DrillComplex = left.item.evaluate(local), let r: DrillComplex = right.item.evaluate(local) else { return nil }
                return ((l - r).modulus, max(1, l.modulus, r.modulus))
            }
            for root: DrillComplex in roots {
                guard let at: (difference: Double, scale: Double) = residual(root) else {
                    throw Failure(message: "解 \(describe([root])) を「\(left.source) = \(right.source)」に代入できませんでした")
                }
                guard at.difference <= tolerance * at.scale * 100 else {
                    throw Failure(message: "解 \(describe([root])) を代入しても「\(left.source) = \(right.source)」が成り立ちません")
                }
            }
            // どんな値でも成り立つ式(恒等式)になっていないか。
            if let first: DrillComplex = roots.first, let shifted: (difference: Double, scale: Double) = residual(first + DrillComplex(0.731)),
               let shiftedAgain: (difference: Double, scale: Double) = residual(first + DrillComplex(1.913)),
               shifted.difference <= tolerance * shifted.scale, shiftedAgain.difference <= tolerance * shiftedAgain.scale {
                throw Failure(message: "「\(left.source) = \(right.source)」が、どんな \(name) でも成り立つ式になっています")
            }
        case "system":
            var bound: [String: DrillComplex] = base
            for (symbol, text): (String, DrillText) in values {
                let source: String = try rendered(text)
                let items: [DrillTeX] = try DrillTeX.parse(source)
                guard items.count == 1, let value: DrillComplex = items[0].evaluate(base) else { throw Failure(message: "解「\(symbol) = \(source)」を数値にできませんでした") }
                bound[symbol] = value
            }
            for equation: (left: DrillText, right: DrillText) in equations {
                let leftSource: String = try rendered(equation.left)
                let rightSource: String = try rendered(equation.right)
                let l: [DrillTeX] = try DrillTeX.parse(leftSource)
                let r: [DrillTeX] = try DrillTeX.parse(rightSource)
                try requireBound(l + r, Set(bound.keys), leftSource + " = " + rightSource)
                guard let lv: [DrillComplex] = DrillTeX.values(of: l, bindings: bound), let rv: [DrillComplex] = DrillTeX.values(of: r, bindings: bound) else {
                    throw Failure(message: "「\(leftSource) = \(rightSource)」を数値にできませんでした")
                }
                guard same(lv, rv, tolerance) else { throw Failure(message: "解を代入しても「\(leftSource) = \(rightSource)」が成り立ちません(\(describe(lv)) と \(describe(rv)))") }
            }
        case "inequality":
            let left: (source: String, item: DrillTeX) = try single("left")
            let right: (source: String, item: DrillTeX) = try single("right")
            let name: String = check.variable ?? "x"
            guard let relationText: DrillText = texts["relation"] else { throw Failure(message: "「relation」がありません") }
            // 不等号は差し込みでも書ける(`{rel.tex}`)。LaTeX の \le・\ge も読む。
            let relationSource: String = try rendered(relationText).trimmingCharacters(in: CharacterSet.whitespaces)
            let relations: [String: String] = ["<": "<", "<=": "<=", ">": ">", ">=": ">=", "\\le": "<=", "\\leq": "<=", "\\ge": ">=", "\\geq": ">=", "\\lt": "<", "\\gt": ">"]
            guard let relation: String = relations[relationSource] else { throw Failure(message: "relation「\(relationSource)」は <・<=・>・>= のどれかにしてください") }
            guard let solution: DrillExpression = expressions["solution"] else { throw Failure(message: "「solution」がありません") }
            try requireBound([left.item, right.item], Set(base.keys).union([name]), left.source)
            var compared: Int = 0
            var grid: [Double] = stride(from: -50.0, through: 50.0, by: 0.37).map { (x: Double) -> Double in x }
            grid += stride(from: -10.0, through: 10.0, by: 0.043).map { (x: Double) -> Double in x }
            for x: Double in grid {
                var local: [String: DrillComplex] = base
                local[name] = DrillComplex(x)
                guard let l: DrillComplex = left.item.evaluate(local), let r: DrillComplex = right.item.evaluate(local), l.isReal, r.isReal else { continue }
                // 境目のすぐ近くは誤差で判定が変わるので見ない。
                if abs(l.real - r.real) <= 1e-7 * max(1, abs(l.real), abs(r.real)) { continue }
                let holds: Bool
                switch relation {
                case "<", "<=": holds = l.real < r.real
                default: holds = l.real > r.real
                }
                var scope: [String: DrillValue] = instance.scope
                scope[name] = DrillValue.number(DrillNumber.real(x))
                if let restriction: DrillExpression = expressions["where"], !(try DrillExpression.bool(try restriction.evaluate(scope))) { continue }
                let claimed: Bool = try DrillExpression.bool(try solution.evaluate(scope))
                guard holds == claimed else {
                    throw Failure(message: "\(name) = \(String(format: "%.4g", x)) で、不等式「\(left.source) \(relation) \(right.source)」は\(holds ? "成り立つ" : "成り立たない")のに、解「\(check.solution ?? "")」は\(claimed ? "含んでいます" : "含んでいません")")
                }
                compared += 1
            }
            guard compared >= (expressions["where"] == nil ? 20 : 5) else { throw Failure(message: "不等式「\(left.source) \(relation) \(right.source)」を数値にできませんでした") }
        case "assert":
            for condition: (source: String, expression: DrillExpression) in conditions {
                guard try DrillExpression.bool(try condition.expression.evaluate(instance.scope)) else {
                    throw Failure(message: "条件「\(condition.source)」が成り立ちません")
                }
            }
        case "series":
            let term: (source: String, item: DrillTeX) = try single("term")
            let answer: (source: String, items: [DrillTeX]) = try tex("answer")
            let name: String = check.index ?? "k"
            try requireBound([term.item], Set(base.keys).union([name]), term.source)
            try requireBound(answer.items, Set(base.keys), answer.source)
            let from: Double = try real("from")
            let to: Double = try real("to")
            guard from == from.rounded(), to == to.rounded(), to >= from, to - from <= 100_000 else { throw Failure(message: "和の範囲(\(from) から \(to))が整数の範囲になっていません") }
            var total: DrillComplex = DrillComplex.zero
            for k: Int in Int(from)...Int(to) {
                var local: [String: DrillComplex] = base
                local[name] = DrillComplex(Double(k))
                guard let value: DrillComplex = term.item.evaluate(local) else { throw Failure(message: "「\(term.source)」の \(name) = \(k) の値が定まりません") }
                total = total + value
            }
            guard let shown: [DrillComplex] = DrillTeX.values(of: answer.items, bindings: base), same(shown, [total], tolerance) else {
                throw Failure(message: "「\(term.source)」の \(name) = \(Int(from)) から \(Int(to)) までの和は \(describe([total])) ですが、答えは「\(answer.source)」です")
            }
        case "limit":
            let function: (source: String, item: DrillTeX) = try single("function")
            let answer: (source: String, items: [DrillTeX]) = try tex("answer")
            let name: String = check.variable ?? "x"
            try requireBound([function.item], Set(base.keys).union([name]), function.source)
            guard let expected: [DrillComplex] = DrillTeX.values(of: answer.items, bindings: base), expected.count == 1 else {
                throw Failure(message: "答え「\(answer.source)」を数値にできませんでした")
            }
            let target: String = check.to ?? ""
            let approaches: [Double]
            if target == "inf" {
                approaches = [1e5, 1e6]
            } else if target == "-inf" {
                approaches = [-1e5, -1e6]
            } else {
                let a: Double = try real("to")
                approaches = [a + 1e-4, a - 1e-4, a + 1e-5, a - 1e-5]
            }
            var compared: Int = 0
            for x: Double in approaches {
                var local: [String: DrillComplex] = base
                local[name] = DrillComplex(x)
                guard let value: DrillComplex = function.item.evaluate(local) else { continue }
                guard value.isClose(to: expected[0], tolerance: max(tolerance, 2e-3)) else {
                    throw Failure(message: "「\(function.source)」は \(name) → \(target) で \(describe([value])) に近づきますが、答えは「\(answer.source)」(\(describe(expected)))です")
                }
                compared += 1
            }
            guard compared >= 1 else { throw Failure(message: "「\(function.source)」の極限を数値にできませんでした") }
        case "ode":
            let function: (source: String, item: DrillTeX) = try single("function")
            let left: (source: String, item: DrillTeX) = try single("left")
            let right: (source: String, item: DrillTeX) = try single("right")
            let name: String = check.variable ?? "x"
            var constants: [String: DrillComplex] = base
            for (offset, symbol): (Int, String) in function.item.symbols.subtracting(base.keys).subtracting([name]).sorted().enumerated() {
                // 任意定数(C、C_1、C_2 など)には適当な値を入れる。
                constants[symbol] = DrillComplex(0.83 + 0.59 * Double(offset))
            }
            let y: (Double) -> DrillComplex? = { (x: Double) -> DrillComplex? in
                var local: [String: DrillComplex] = constants
                local[name] = DrillComplex(x)
                return function.item.evaluate(local)
            }
            var compared: Int = 0
            for x0: Double in DrillNumerics.points(range: check.range) {
                guard let value: DrillComplex = y(x0), let first: DrillComplex = DrillNumerics.derivative(y, at: x0, order: 1), let second: DrillComplex = DrillNumerics.derivative(y, at: x0, order: 2) else { continue }
                var local: [String: DrillComplex] = constants
                local[name] = DrillComplex(x0)
                local["y"] = value
                local["y'"] = first
                local["y''"] = second
                try requireBound([left.item, right.item], Set(local.keys), left.source + " = " + right.source)
                guard let l: DrillComplex = left.item.evaluate(local), let r: DrillComplex = right.item.evaluate(local) else { continue }
                // 差分で求めた y'・y'' には誤差がある。各項の大きさに対して十分小さい食い違いは、合っているとみなす。
                var allowed: Double = max(tolerance, 1e-6) * max(1, l.modulus, r.modulus)
                for symbol: String in ["y", "y'", "y''"] {
                    guard let original: DrillComplex = local[symbol] else { continue }
                    var nudged: [String: DrillComplex] = local
                    nudged[symbol] = original * DrillComplex(1 + 1e-4)
                    if let nl: DrillComplex = left.item.evaluate(nudged), let nr: DrillComplex = right.item.evaluate(nudged) {
                        allowed += ((nl - nr) - (l - r)).modulus
                    }
                }
                guard (l - r).modulus <= allowed else {
                    throw Failure(message: "y = \(function.source) を代入しても「\(left.source) = \(right.source)」が成り立ちません(\(name) = \(x0) で \(describe([l])) と \(describe([r])))")
                }
                compared += 1
            }
            guard compared >= 3 else { throw Failure(message: "y = \(function.source) を微分方程式に代入できませんでした") }
        default:
            throw Failure(message: "kind「\(check.kind)」はありません")
        }
    }
}
