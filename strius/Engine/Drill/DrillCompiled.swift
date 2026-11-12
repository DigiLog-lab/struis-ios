import Foundation

/// 型から作った問題 1 問。
nonisolated struct DrillProblem: Equatable, Sendable {
    /// 問題文(文の中の式は `$…$`)。
    let prompt: String
    /// 大きく出す式(LaTeX。無ければ空)。
    let math: String
    /// 答え(文の中の式は `$…$`)。
    let answer: String

    /// 同じ問題かどうかを比べる鍵(画面に出る問題文と式)。
    var key: String { prompt + "\u{1F}" + math }
}

/// 型を読めなかった・問題を作れなかった理由。
nonisolated struct DrillFailure: Error, Equatable, Sendable {
    let message: String
}

/// 差し込みを含む文字列を、文字と差し込みの並びに分けたもの。
nonisolated struct DrillText: Hashable, Sendable {
    nonisolated enum Segment: Hashable, Sendable {
        case literal(String)
        /// `{name}`、`{name.field|+coef}`。`keepBraces` は、差し込んだ後も波かっこで囲むか(`^`・`_`・命令の直後)。
        case placeholder(name: String, field: String?, spec: DrillFormatSpec, keepBraces: Bool)
    }

    let source: String
    let segments: [Segment]

    /// 差し込みで使っている名前。
    var names: Set<String> {
        Set(segments.compactMap { (segment: Segment) -> String? in
            if case Segment.placeholder(let name, _, _, _) = segment { return name }
            return nil
        })
    }

    private static func isNameStart(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c == "_") }
    private static func isNameBody(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_") }

    /// `{` の位置から差し込みとして読めるか試す。読めたら(名前、項目、書き方、閉じかっこの次の位置)。
    private static func placeholder(_ characters: [Character], at open: Int) -> (name: String, field: String?, modifiers: [String], end: Int)? {
        var index: Int = open + 1
        guard index < characters.count, isNameStart(characters[index]) else { return nil }
        var end: Int = index
        while end < characters.count, isNameBody(characters[end]) { end += 1 }
        let name: String = String(characters[index..<end])
        index = end
        var field: String? = nil
        if index < characters.count, characters[index] == ".", index + 1 < characters.count, isNameStart(characters[index + 1]) {
            end = index + 1
            while end < characters.count, isNameBody(characters[end]) { end += 1 }
            field = String(characters[(index + 1)..<end])
            index = end
        }
        var modifiers: [String] = []
        while index < characters.count, characters[index] == "|" {
            end = index + 1
            while end < characters.count, !"{}|".contains(characters[end]) { end += 1 }
            modifiers.append(String(characters[(index + 1)..<end]).trimmingCharacters(in: CharacterSet.whitespaces))
            index = end
        }
        guard index < characters.count, characters[index] == "}" else { return nil }
        return (name, field, modifiers, index + 1)
    }

    /// 差し込みの直前が `^`・`_`・`}`・命令(`\frac` など)なら、差し込んだ後も波かっこで囲む。
    /// `x^{n}` の n が 12 の時に `x^12`(x の 1 乗に 2)にならないようにするため。
    private static func keepsBraces(_ characters: [Character], before open: Int) -> Bool {
        guard open > 0 else { return false }
        let previous: Character = characters[open - 1]
        if previous == "^" || previous == "_" || previous == "}" { return true }
        guard previous.isASCII, previous.isLetter else { return false }
        var index: Int = open - 1
        while index >= 0, characters[index].isASCII, characters[index].isLetter { index -= 1 }
        return index >= 0 && characters[index] == "\\"
    }

    /// 直後の `{…}` が文字そのものになる命令(`\mathrm{pH}`、`\vec{a}`、`\begin{cases}`)。この直後の `{名前}` は差し込みにしない。
    static let literalCommands: Set<String> = ["mathrm", "text", "operatorname", "mathbf", "mathit", "boldsymbol", "bm", "textbf", "begin", "end",
                                               "vec", "overrightarrow", "bar", "hat", "overline", "underline", "dot", "ddot", "tilde"]

    /// `{` の直前が、中身を文字そのものにする命令か。
    private static func followsLiteralCommand(_ characters: [Character], before open: Int) -> Bool {
        var index: Int = open - 1
        while index >= 0, characters[index].isASCII, characters[index].isLetter { index -= 1 }
        guard index >= 0, characters[index] == "\\", index + 1 < open else { return false }
        return literalCommands.contains(String(characters[(index + 1)..<open]))
    }

    /// `names` にある名前だけを差し込みとして読む。それ以外の `{…}` は LaTeX の波かっこ。
    static func parse(_ source: String, names: Set<String>) throws -> DrillText {
        let characters: [Character] = Array(source)
        var segments: [Segment] = []
        var literal: String = ""
        var index: Int = 0
        // 直前の差し込みの終わりと、それが波かっこを残したか(`\frac{a}{b}` の b は残し、`{k|coef}{p|paren}` の p は残さない)。
        var previousEnd: Int = -1
        var previousKept: Bool = false
        while index < characters.count {
            if characters[index] == "{", let found: (name: String, field: String?, modifiers: [String], end: Int) = placeholder(characters, at: index) {
                let isLiteral: Bool = found.field == nil && found.modifiers.isEmpty && followsLiteralCommand(characters, before: index)
                if names.contains(found.name), !isLiteral {
                    let spec: DrillFormatSpec
                    do {
                        spec = try DrillFormatSpec.parse(found.modifiers)
                    } catch let error as DrillFormatSpec.ParseError {
                        throw DrillFailure(message: "「\(source)」: \(error.message)")
                    }
                    if !literal.isEmpty { segments.append(Segment.literal(literal)); literal = "" }
                    let keep: Bool = index == previousEnd ? previousKept : keepsBraces(characters, before: index)
                    segments.append(Segment.placeholder(name: found.name, field: found.field, spec: spec, keepBraces: keep))
                    previousEnd = found.end
                    previousKept = keep
                    index = found.end
                    continue
                }
                if !found.modifiers.isEmpty || found.field != nil {
                    throw DrillFailure(message: "「\(source)」の差し込み「\(found.name)」という名前がありません")
                }
                // 前に命令も ^ も _ も無い `{名前}` は、LaTeX の波かっことしては意味が無い。宣言し忘れた差し込みとして断る。
                if !names.contains(found.name), !keepsBraces(characters, before: index), index != previousEnd {
                    throw DrillFailure(message: "「\(source)」の「{\(found.name)}」という名前が、変数にも lets にも parts にもありません")
                }
            }
            literal.append(characters[index])
            index += 1
        }
        if !literal.isEmpty { segments.append(Segment.literal(literal)) }
        return DrillText(source: source, segments: segments)
    }
}

/// 読み取り済みの型。式と差し込みを先に読み取っておき、変数の値の組から問題を作る。
nonisolated struct DrillCompiledTemplate: Sendable {
    nonisolated struct Variable: Sendable {
        let name: String
        /// 取り得る値(単位つきの変数は SI の値)。
        let domain: [DrillValue]
    }

    nonisolated struct Let: Sendable {
        let name: String
        let expression: DrillExpression
        let unit: DrillUnit?
    }

    nonisolated struct Constraint: Sendable {
        let source: String
        let expression: DrillExpression
    }

    nonisolated struct Term: Sendable {
        let coefficient: DrillExpression
        let powers: [(base: DrillText, exponent: DrillExpression)]
        let body: DrillText?
        let times: Bool
    }

    nonisolated enum PartBody: Sendable {
        case sum(terms: [Term], spec: DrillFormatSpec)
        case product(powers: [(base: DrillText, exponent: DrillExpression)], separator: String, empty: String)
        case text(DrillText)
        case select(cases: [(when: DrillExpression, tex: DrillText)], otherwise: DrillText)
        case list(items: [DrillExpression], sort: Bool, unique: Bool, separator: String, spec: DrillFormatSpec)
        case plusMinus(center: DrillExpression, radicand: DrillExpression, scale: DrillExpression?)
    }

    nonisolated struct Part: Sendable {
        let name: String
        let body: PartBody
    }

    /// 変数の値の組から作った 1 問と、その時の値。
    nonisolated struct Instance: Sendable {
        let scope: [String: DrillValue]
        let partTexts: [String: String]
        let problem: DrillProblem
    }

    let template: DrillTemplate
    let variables: [Variable]
    let lets: [Let]
    let constraints: [Constraint]
    let parts: [Part]
    let prompt: DrillText
    let math: DrillText
    let answer: DrillText
    let displays: [String: DrillDisplay]
    /// 変数・lets・parts の名前。
    let names: Set<String>

    static let maxDomain: Int = 50_000
    static let reserved: Set<String> = DrillExpression.constants.union(["and", "or", "not"])

    // MARK: 読み取る

    init(_ template: DrillTemplate) throws {
        self.template = template
        guard template.format == DrillTemplate.currentFormat else {
            throw DrillFailure(message: "format は \(DrillTemplate.currentFormat) にしてください")
        }
        var declared: Set<String> = []
        func declare(_ name: String, _ place: String) throws {
            let characters: [Character] = Array(name)
            guard let first: Character = characters.first, first.isASCII, first.isLetter,
                  characters.allSatisfy({ (c: Character) -> Bool in c.isASCII && (c.isLetter || c.isNumber || c == "_") }) else {
                throw DrillFailure(message: "\(place)の名前「\(name)」は、英字で始まる英数字と _ にしてください")
            }
            guard !DrillCompiledTemplate.reserved.contains(name) else { throw DrillFailure(message: "\(place)の名前「\(name)」は定数や演算の名前(pi・e・i・true・false・and・or・not)なので使えません") }
            guard !declared.contains(name) else { throw DrillFailure(message: "名前「\(name)」が 2 回出てきます") }
            declared.insert(name)
        }
        func expression(_ source: String, _ place: String) throws -> DrillExpression {
            let parsed: DrillExpression
            do {
                parsed = try DrillExpression.parse(source)
            } catch let error as DrillExpression.SyntaxError {
                throw DrillFailure(message: "\(place): \(error.message)")
            }
            for name: String in parsed.names.sorted() where !declared.contains(name) && !DrillExpression.constants.contains(name) {
                throw DrillFailure(message: "\(place): 式「\(source)」の「\(name)」という名前が、ここより前にありません")
            }
            for function: String in parsed.functionNames.sorted() where DrillFunctions.arity[function] == nil {
                throw DrillFailure(message: "\(place): 式「\(source)」の関数「\(function)」はありません")
            }
            return parsed
        }
        func unit(_ source: String?, _ place: String) throws -> DrillUnit? {
            guard let source: String = source else { return nil }
            do {
                return try DrillUnit.parse(source)
            } catch let error as DrillUnit.ParseError {
                throw DrillFailure(message: "\(place): \(error.message)")
            }
        }
        func text(_ source: String) throws -> DrillText {
            try DrillText.parse(source, names: declared)
        }
        func spec(_ source: String?, _ place: String) throws -> DrillFormatSpec {
            guard let source: String = source, !source.isEmpty else { return DrillFormatSpec.plain }
            do {
                return try DrillFormatSpec.parse(source.split(separator: "|").map { (piece: Substring) -> String in String(piece) })
            } catch let error as DrillFormatSpec.ParseError {
                throw DrillFailure(message: "\(place): \(error.message)")
            }
        }

        var displays: [String: DrillDisplay] = [:]
        var variables: [Variable] = []
        guard !template.variables.isEmpty else { throw DrillFailure(message: "variables が空です。数字を入れ替える変数が要ります") }
        for variable: DrillVariable in template.variables {
            let place: String = "変数「\(variable.name)」"
            try declare(variable.name, "変数")
            let parsedUnit: DrillUnit? = try unit(variable.unit, place)
            if let digits: Int = variable.sig, digits < 1 || digits > 15 { throw DrillFailure(message: "\(place): sig は 1 から 15 にしてください") }
            displays[variable.name] = DrillDisplay(unit: parsedUnit, sig: variable.sig, decimal: variable.kind == "decimal" || variable.kind == "constant" || variable.kind == "choice")
            let domain: [DrillValue] = try DrillCompiledTemplate.domain(of: variable, unit: parsedUnit, place: place)
            guard !domain.isEmpty else { throw DrillFailure(message: "\(place): 取り得る値がありません") }
            variables.append(Variable(name: variable.name, domain: domain))
        }
        self.variables = variables

        var lets: [Let] = []
        for entry: DrillLet in template.lets {
            let place: String = "lets「\(entry.name)」"
            let parsed: DrillExpression = try expression(entry.expr, place)
            try declare(entry.name, "lets ")
            let parsedUnit: DrillUnit? = try unit(entry.unit, place)
            if let digits: Int = entry.sig, digits < 1 || digits > 15 { throw DrillFailure(message: "\(place): sig は 1 から 15 にしてください") }
            displays[entry.name] = DrillDisplay(unit: parsedUnit, sig: entry.sig, decimal: false)
            lets.append(Let(name: entry.name, expression: parsed, unit: parsedUnit))
        }
        self.lets = lets
        self.constraints = try template.constraints.map { (source: String) -> Constraint in
            Constraint(source: source, expression: try expression(source, "constraints"))
        }

        var parts: [Part] = []
        for part: DrillPart in template.parts {
            let place: String = "parts「\(part.name)」"
            let body: PartBody
            switch part.kind {
            case "sum":
                guard let terms: [DrillTerm] = part.terms, !terms.isEmpty else { throw DrillFailure(message: "\(place): sum には terms が要ります") }
                body = PartBody.sum(terms: try terms.map { (term: DrillTerm) -> Term in
                    Term(coefficient: try expression(term.coef, place),
                         powers: try (term.powers ?? []).map { (power: DrillPower) -> (base: DrillText, exponent: DrillExpression) in (try text(power.base), try expression(power.exp, place)) },
                         body: try term.body.map { (source: String) -> DrillText in try text(source) },
                         times: term.times ?? false)
                }, spec: try spec(part.format, place))
            case "product":
                guard let powers: [DrillPower] = part.powers, !powers.isEmpty else { throw DrillFailure(message: "\(place): product には powers が要ります") }
                body = PartBody.product(powers: try powers.map { (power: DrillPower) -> (base: DrillText, exponent: DrillExpression) in (try text(power.base), try expression(power.exp, place)) },
                                        separator: part.separator ?? "", empty: part.otherwise ?? "1")
            case "text":
                guard let source: String = part.tex else { throw DrillFailure(message: "\(place): text には tex が要ります") }
                body = PartBody.text(try text(source))
            case "select":
                guard let cases: [DrillCase] = part.cases, !cases.isEmpty, let otherwise: String = part.otherwise else {
                    throw DrillFailure(message: "\(place): select には cases と otherwise が要ります")
                }
                body = PartBody.select(cases: try cases.map { (entry: DrillCase) -> (when: DrillExpression, tex: DrillText) in (try expression(entry.when, place), try text(entry.tex)) },
                                       otherwise: try text(otherwise))
            case "list":
                guard let items: [String] = part.items, !items.isEmpty else { throw DrillFailure(message: "\(place): list には items が要ります") }
                body = PartBody.list(items: try items.map { (source: String) -> DrillExpression in try expression(source, place) },
                                     sort: part.sort ?? false, unique: part.unique ?? false, separator: part.separator ?? ",\\ ", spec: try spec(part.format, place))
            case "pm":
                guard let center: String = part.center, let radicand: String = part.radicand else { throw DrillFailure(message: "\(place): pm には center と radicand が要ります") }
                body = PartBody.plusMinus(center: try expression(center, place), radicand: try expression(radicand, place),
                                          scale: try part.scale.map { (source: String) -> DrillExpression in try expression(source, place) })
            default:
                throw DrillFailure(message: "\(place): kind「\(part.kind)」はありません(sum・product・text・select・list・pm)")
            }
            try declare(part.name, "parts ")
            parts.append(Part(name: part.name, body: body))
        }
        self.parts = parts
        self.displays = displays
        self.names = declared
        self.prompt = try text(template.prompt)
        self.math = try text(template.math)
        self.answer = try text(template.answer)
    }

    /// 変数が取り得る値を並べる。
    private static func domain(of variable: DrillVariable, unit: DrillUnit?, place: String) throws -> [DrillValue] {
        func scaled(_ number: DrillNumber) -> DrillValue {
            guard let unit: DrillUnit = unit else { return DrillValue.number(number) }
            return DrillValue.quantity(DrillQuantity(DrillArithmetic.multiply(number, unit.scale), dimension: unit.dimension))
        }
        func rational(_ value: Double?, _ what: String) throws -> DrillRational {
            guard let value: Double = value, let exact: DrillRational = DrillNumber(json: value).rational else {
                throw DrillFailure(message: "\(place): \(what) が要ります")
            }
            return exact
        }
        switch variable.kind {
        case "integer", "decimal":
            let low: DrillRational = try rational(variable.min, "min")
            let high: DrillRational = try rational(variable.max, "max")
            let step: DrillRational = variable.kind == "integer" && variable.step == nil ? DrillRational.one : try rational(variable.step, "step")
            if variable.kind == "integer" {
                guard low.isInteger, high.isInteger, step.isInteger else { throw DrillFailure(message: "\(place): 整数の変数の min・max・step は整数にしてください") }
            }
            guard !step.isNegative, !step.isZero, !(high < low) else { throw DrillFailure(message: "\(place): min ≤ max、step > 0 にしてください") }
            guard let span: DrillRational = high.subtracting(low)?.divided(by: step) else { throw DrillFailure(message: "\(place): 範囲が読めません") }
            let count: Int = span.floorValue + 1
            guard count <= maxDomain else { throw DrillFailure(message: "\(place): 取り得る値が多すぎます(\(count) 通り)。範囲を狭めるか step を大きくしてください") }
            let excluded: [DrillRational] = (variable.exclude ?? []).compactMap { (value: Double) -> DrillRational? in DrillNumber(json: value).rational }
            var values: [DrillValue] = []
            for index: Int in 0..<count {
                guard let value: DrillRational = step.multiplied(by: DrillRational(integer: index))?.adding(low) else { continue }
                if excluded.contains(value) { continue }
                values.append(scaled(DrillNumber(rational: value)))
            }
            return values
        case "fraction":
            guard let numerator: DrillIntegerRange = variable.numerator, let denominator: DrillIntegerRange = variable.denominator,
                  numerator.min <= numerator.max, denominator.min <= denominator.max, denominator.min >= 1 else {
                throw DrillFailure(message: "\(place): fraction には numerator と denominator(min・max、分母は 1 以上)が要ります")
            }
            guard (numerator.max - numerator.min + 1) * (denominator.max - denominator.min + 1) <= maxDomain else {
                throw DrillFailure(message: "\(place): 取り得る値が多すぎます")
            }
            var seen: Set<DrillRational> = []
            var values: [DrillValue] = []
            for bottom: Int in denominator.min...denominator.max {
                for top: Int in numerator.min...numerator.max {
                    // 約分して分母が 2 以上になる分数だけ(整数になるものは除く)。
                    guard top != 0, DrillRational.gcd(abs(top), bottom) == 1, bottom >= 2, let value: DrillRational = DrillRational(top, bottom), !seen.contains(value) else { continue }
                    seen.insert(value)
                    values.append(scaled(DrillNumber(rational: value)))
                }
            }
            return values
        case "choice":
            guard let options: [DrillOption] = variable.options, !options.isEmpty else { throw DrillFailure(message: "\(place): choice には options が要ります") }
            return options.map { (option: DrillOption) -> DrillValue in
                if case DrillValue.quantity(let quantity) = option.value { return scaled(quantity.number) }
                return option.value
            }
        case "constant":
            guard let value: Double = variable.value else { throw DrillFailure(message: "\(place): constant には value が要ります") }
            return [scaled(DrillNumber(json: value))]
        default:
            throw DrillFailure(message: "\(place): kind「\(variable.kind)」はありません(integer・decimal・fraction・choice・constant)")
        }
    }

    /// 変数の値の組の総数。
    var combinationCount: Double {
        variables.reduce(1.0) { (product: Double, variable: Variable) -> Double in product * Double(variable.domain.count) }
    }

    // MARK: 問題を作る

    /// 変数の値(`variables` と同じ順)から 1 問作る。条件を満たさない組は nil。値が定まらない時は投げる。
    func instance(values: [DrillValue]) throws -> Instance? {
        var scope: [String: DrillValue] = [:]
        for (variable, value): (Variable, DrillValue) in zip(variables, values) {
            scope[variable.name] = value
        }
        var failure: DrillFailure? = nil
        for entry: Let in lets {
            do {
                let value: DrillValue = try entry.expression.evaluate(scope)
                if let unit: DrillUnit = entry.unit {
                    guard case DrillValue.quantity(let quantity) = value else { throw DrillFailure(message: "単位を付けられるのは数だけです") }
                    guard quantity.dimension == unit.dimension else {
                        throw DrillFailure(message: "式の次元(\(quantity.dimension.text))と単位「\(unit.source)」が合いません")
                    }
                }
                scope[entry.name] = value
            } catch let error as DrillExpression.EvaluationError {
                failure = failure ?? DrillFailure(message: "lets「\(entry.name)」: \(error.message)")
            } catch let error as DrillFailure {
                failure = failure ?? DrillFailure(message: "lets「\(entry.name)」: \(error.message)")
            }
        }
        // 条件を先に見る。条件で外れる組は、lets の値が定まらなくても構わない。
        for constraint: Constraint in constraints {
            do {
                guard case DrillValue.bool(let holds) = try constraint.expression.evaluate(scope) else {
                    throw DrillFailure(message: "constraints「\(constraint.source)」が真偽の式ではありません")
                }
                if !holds { return nil }
            } catch let error as DrillExpression.EvaluationError {
                failure = failure ?? DrillFailure(message: "constraints「\(constraint.source)」: \(error.message)")
            }
        }
        if let failure: DrillFailure = failure { throw failure }

        var partTexts: [String: String] = [:]
        for part: Part in parts {
            do {
                partTexts[part.name] = try render(part, scope: scope, partTexts: partTexts)
            } catch let error as DrillExpression.EvaluationError {
                throw DrillFailure(message: "parts「\(part.name)」: \(error.message)")
            } catch let error as DrillFormat.FormatError {
                throw DrillFailure(message: "parts「\(part.name)」: \(error.message)")
            }
        }
        let problem: DrillProblem = DrillProblem(prompt: try render(prompt, scope: scope, partTexts: partTexts, place: "prompt"),
                                                 math: try render(math, scope: scope, partTexts: partTexts, place: "math"),
                                                 answer: try render(answer, scope: scope, partTexts: partTexts, place: "answer"))
        return Instance(scope: scope, partTexts: partTexts, problem: problem)
    }

    /// 差し込みを入れた文字列にする。
    func render(_ text: DrillText, scope: [String: DrillValue], partTexts: [String: String], place: String) throws -> String {
        do {
            return try render(text, scope: scope, partTexts: partTexts)
        } catch let error as DrillExpression.EvaluationError {
            throw DrillFailure(message: "\(place): \(error.message)")
        } catch let error as DrillFormat.FormatError {
            throw DrillFailure(message: "\(place): \(error.message)")
        }
    }

    private func render(_ text: DrillText, scope: [String: DrillValue], partTexts: [String: String]) throws -> String {
        var out: String = ""
        for segment: DrillText.Segment in text.segments {
            switch segment {
            case DrillText.Segment.literal(let literal):
                out += literal
            case DrillText.Segment.placeholder(let name, let field, let spec, let keepBraces):
                let inserted: String = try insertion(name: name, field: field, spec: spec, scope: scope, partTexts: partTexts)
                out += keepBraces ? "{\(inserted)}" : inserted
            }
        }
        return out
    }

    private func insertion(name: String, field: String?, spec: DrillFormatSpec, scope: [String: DrillValue], partTexts: [String: String]) throws -> String {
        if let partText: String = partTexts[name] {
            guard field == nil else { throw DrillFormat.FormatError(message: "部品「\(name)」に「.\(field ?? "")」は使えません") }
            switch spec.sign {
            case DrillFormatSpec.Sign.plain:
                return partText
            case DrillFormatSpec.Sign.paren:
                // 項が 2 つ以上あるか、負の符号で始まる時だけかっこで囲む。
                return DrillCompiledTemplate.needsParentheses(partText) ? "(\(partText))" : partText
            default:
                throw DrillFormat.FormatError(message: "部品「\(name)」に使える書き方は paren だけです")
            }
        }
        guard var value: DrillValue = scope[name] else { throw DrillExpression.EvaluationError.unknownName(name) }
        if let field: String = field {
            guard case DrillValue.record(let fields) = value, let inner: DrillValue = fields[field] else {
                throw DrillFormat.FormatError(message: "「\(name).\(field)」という項目がありません")
            }
            value = inner
        }
        switch value {
        case DrillValue.quantity(let quantity):
            return try DrillFormat.text(of: quantity, spec: spec, display: field == nil ? (displays[name] ?? DrillDisplay.none) : DrillDisplay.none)
        case DrillValue.text(let text):
            guard spec == DrillFormatSpec.plain else { throw DrillFormat.FormatError(message: "文字列「\(name)」に数の書き方は使えません") }
            return text
        case DrillValue.bool:
            throw DrillFormat.FormatError(message: "真偽の値「\(name)」は表示できません")
        case DrillValue.record:
            throw DrillFormat.FormatError(message: "「\(name)」は値の組です。「{\(name).項目}」のように項目を選んでください")
        }
    }

    /// いちばん外側(かっこの外)に + か - があるか、- で始まるか。
    static func needsParentheses(_ text: String) -> Bool {
        var depth: Int = 0
        var first: Bool = true
        for c: Character in text {
            if c == " " { continue }
            if c == "{" || c == "(" || c == "[" { depth += 1 }
            if c == "}" || c == ")" || c == "]" { depth -= 1 }
            if depth == 0, c == "+" || c == "-" {
                if first && c == "+" { first = false; continue }
                return true
            }
            first = false
        }
        return false
    }

    // MARK: 部品

    private func number(_ expression: DrillExpression, _ scope: [String: DrillValue]) throws -> DrillQuantity {
        try DrillExpression.quantity(try expression.evaluate(scope))
    }

    private func render(_ part: Part, scope: [String: DrillValue], partTexts: [String: String]) throws -> String {
        switch part.body {
        case PartBody.text(let text):
            return try render(text, scope: scope, partTexts: partTexts)
        case PartBody.select(let cases, let otherwise):
            for entry: (when: DrillExpression, tex: DrillText) in cases where try DrillExpression.bool(try entry.when.evaluate(scope)) {
                return try render(entry.tex, scope: scope, partTexts: partTexts)
            }
            return try render(otherwise, scope: scope, partTexts: partTexts)
        case PartBody.product(let powers, let separator, let empty):
            var pieces: [String] = []
            for power: (base: DrillText, exponent: DrillExpression) in powers {
                let exponent: DrillQuantity = try number(power.exponent, scope)
                guard let value: DrillRational = exponent.number.rational else { throw DrillFormat.FormatError(message: "指数は有理数にしてください") }
                if value.isZero { continue }
                let base: String = try render(power.base, scope: scope, partTexts: partTexts)
                pieces.append(value == DrillRational.one ? base : "\(base)^{\(try DrillFormat.text(of: exponent, spec: DrillFormatSpec.plain, display: DrillDisplay.none))}")
            }
            return pieces.isEmpty ? empty : pieces.joined(separator: separator)
        case PartBody.sum(let terms, let spec):
            var out: String = ""
            for term: Term in terms {
                let coefficient: DrillQuantity = try number(term.coefficient, scope)
                if coefficient.number.isZero { continue }
                var tail: String = ""
                for power: (base: DrillText, exponent: DrillExpression) in term.powers {
                    let exponent: DrillQuantity = try number(power.exponent, scope)
                    guard let value: DrillRational = exponent.number.rational else { throw DrillFormat.FormatError(message: "指数は有理数にしてください") }
                    if value.isZero { continue }
                    let base: String = try render(power.base, scope: scope, partTexts: partTexts)
                    tail += value == DrillRational.one ? base : "\(base)^{\(try DrillFormat.text(of: exponent, spec: DrillFormatSpec.plain, display: DrillDisplay.none))}"
                }
                if let body: DrillText = term.body { tail += try render(body, scope: scope, partTexts: partTexts) }
                var body: DrillFormat.Body = try DrillFormat.body(of: coefficient, spec: spec, display: DrillDisplay.none)
                if body.compound, body.negative {
                    // -(1+√2) のような係数は、符号を外に出してかっこで囲む。
                    body = DrillFormat.Body(negative: true, text: "(\(body.text))")
                } else if body.compound, !tail.isEmpty {
                    body = DrillFormat.Body(negative: false, text: "(\(body.text))")
                }
                var piece: String
                if tail.isEmpty {
                    piece = body.text
                } else if body.text == "1" {
                    piece = tail
                } else {
                    piece = body.text + (term.times ? " \\cdot " : "") + tail
                }
                if out.isEmpty {
                    piece = (body.negative ? "-" : "") + piece
                } else {
                    piece = (body.negative ? " - " : " + ") + piece
                }
                out += piece
            }
            return out.isEmpty ? "0" : out
        case PartBody.list(let items, let sort, let unique, let separator, let spec):
            var values: [DrillQuantity] = try items.map { (item: DrillExpression) -> DrillQuantity in try number(item, scope) }
            if unique {
                var kept: [DrillQuantity] = []
                for value: DrillQuantity in values where !kept.contains(where: { (other: DrillQuantity) -> Bool in DrillArithmetic.equal(other.number, value.number) }) {
                    kept.append(value)
                }
                values = kept
            }
            if sort {
                var failed: Bool = false
                values.sort { (a: DrillQuantity, b: DrillQuantity) -> Bool in
                    guard let order: ComparisonResult = DrillArithmetic.compare(a.number, b.number) else { failed = true; return false }
                    return order == ComparisonResult.orderedAscending
                }
                if failed { throw DrillFormat.FormatError(message: "大小を比べられない数は並べ替えられません") }
            }
            return try values.map { (value: DrillQuantity) -> String in try DrillFormat.text(of: value, spec: spec, display: DrillDisplay.none) }.joined(separator: separator)
        case PartBody.plusMinus(let centerExpression, let radicandExpression, let scaleExpression):
            guard let center: DrillRational = try number(centerExpression, scope).number.rational, let radicand: DrillRational = try number(radicandExpression, scope).number.rational,
                  let scale: DrillRational = try scaleExpression.map({ (source: DrillExpression) -> DrillRational? in try number(source, scope).number.rational }) ?? DrillRational.one else {
                throw DrillFormat.FormatError(message: "pm の center・radicand・scale は有理数にしてください")
            }
            return try DrillCompiledTemplate.plusMinus(center: center, radicand: radicand, scale: scale)
        }
    }

    /// center ± scale√radicand を整理して書く(\frac{-1 \pm \sqrt{5}}{2})。根号が外れる時は 2 つの値を小さい順に並べる。
    static func plusMinus(center: DrillRational, radicand: DrillRational, scale: DrillRational) throws -> String {
        guard let root: DrillExact = DrillExact.squareRoot(of: radicand), let offset: DrillExact = root.multiplied(by: DrillExact(rational: scale.magnitude)) else {
            throw DrillFormat.FormatError(message: "pm の根号の中が大きすぎます")
        }
        let centerText: String = DrillFormat.apply(DrillFormatSpec.Sign.plain, to: DrillFormat.body(of: DrillExact(rational: center)))
        guard let term: (radicand: Int, coefficient: DrillRational) = offset.orderedTerms.first else { return centerText }
        if term.radicand == 1 {
            guard let low: DrillRational = center.subtracting(term.coefficient), let high: DrillRational = center.adding(term.coefficient) else {
                throw DrillFormat.FormatError(message: "pm の値が大きすぎます")
            }
            let lowText: String = DrillFormat.apply(DrillFormatSpec.Sign.plain, to: DrillFormat.body(of: DrillExact(rational: low)))
            let highText: String = DrillFormat.apply(DrillFormatSpec.Sign.plain, to: DrillFormat.body(of: DrillExact(rational: high)))
            return "\(lowText),\\ \(highText)"
        }
        let common: Int = center.denominator / DrillRational.gcd(center.denominator, term.coefficient.denominator) * term.coefficient.denominator
        let top: Int = center.numerator * (common / center.denominator)
        let multiple: Int = term.coefficient.numerator * (common / term.coefficient.denominator)
        let unit: String = term.radicand == -1 ? "i" : "\\sqrt{\(abs(term.radicand))}" + (term.radicand < 0 ? "i" : "")
        let rootText: String = multiple == 1 ? unit : "\(multiple)\(unit)"
        if center.isZero {
            return common == 1 ? "\\pm \(rootText)" : "\\pm \\frac{\(rootText)}{\(common)}"
        }
        let numerator: String = "\(top) \\pm \(rootText)"
        return common == 1 ? numerator : "\\frac{\(numerator)}{\(common)}"
    }
}
