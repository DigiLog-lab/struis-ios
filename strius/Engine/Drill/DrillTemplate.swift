import Foundation

/// オフライン反復の「問題の型」(docs/offline-drill/format.md)。知識グラフの点が定着した時にオンラインの AI が 1 回だけ書く JSON。
/// 端末はこれをデータとして読み、変数に数を入れて問題文と答えを作る。
nonisolated struct DrillTemplate: Codable, Equatable, Sendable {
    /// 書式の版。
    static let currentFormat: Int = 1

    var format: Int
    /// 対応する知識グラフの点(`TimelineSkillRecord.id`)。
    var skillId: String
    /// 点の名前(人が読む用)。
    var title: String
    /// math | physics | chemistry | other
    var subject: String
    var variables: [DrillVariable]
    /// 変数から計算する値(上から順に計算し、前の行の名前を使える)。
    var lets: [DrillLet]
    /// 変数の組が満たす条件(真偽の式)。
    var constraints: [String]
    /// 表示の部品(多項式など、整形の規則を当てて組み立てる LaTeX)。
    var parts: [DrillPart]
    /// 問題文(日本語の文。文の中の式は `$…$`)。
    var prompt: String
    /// 問題文の下に大きく出す式(LaTeX。無ければ空)。
    var math: String
    /// 答え(文の中の式は `$…$`)。
    var answer: String
    /// 数値で確かめる点検。
    var checks: [DrillCheck]
    /// 数値で確かめられない時の理由(`checks` が空の時に書く)。
    var noNumericCheck: String?

    enum CodingKeys: String, CodingKey {
        case format, title, subject, variables, lets, constraints, parts, prompt, math, answer, checks
        case skillId = "skill_id"
        case noNumericCheck = "no_numeric_check"
    }

    init(format: Int = DrillTemplate.currentFormat, skillId: String, title: String, subject: String, variables: [DrillVariable], lets: [DrillLet] = [],
         constraints: [String] = [], parts: [DrillPart] = [], prompt: String, math: String = "", answer: String, checks: [DrillCheck] = [], noNumericCheck: String? = nil) {
        self.format = format
        self.skillId = skillId
        self.title = title
        self.subject = subject
        self.variables = variables
        self.lets = lets
        self.constraints = constraints
        self.parts = parts
        self.prompt = prompt
        self.math = math
        self.answer = answer
        self.checks = checks
        self.noNumericCheck = noNumericCheck
    }

    init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(Int.self, forKey: CodingKeys.format)
        skillId = try container.decode(String.self, forKey: CodingKeys.skillId)
        title = try container.decode(String.self, forKey: CodingKeys.title)
        subject = try container.decode(String.self, forKey: CodingKeys.subject)
        variables = try container.decode([DrillVariable].self, forKey: CodingKeys.variables)
        lets = try container.decodeIfPresent([DrillLet].self, forKey: CodingKeys.lets) ?? []
        constraints = try container.decodeIfPresent([String].self, forKey: CodingKeys.constraints) ?? []
        parts = try container.decodeIfPresent([DrillPart].self, forKey: CodingKeys.parts) ?? []
        prompt = try container.decode(String.self, forKey: CodingKeys.prompt)
        math = try container.decodeIfPresent(String.self, forKey: CodingKeys.math) ?? ""
        answer = try container.decode(String.self, forKey: CodingKeys.answer)
        checks = try container.decodeIfPresent([DrillCheck].self, forKey: CodingKeys.checks) ?? []
        noNumericCheck = try container.decodeIfPresent(String.self, forKey: CodingKeys.noNumericCheck)
    }

    /// 読み込めなかった理由(AI に返す文)。
    nonisolated struct DecodeError: Error, Equatable, Sendable {
        let message: String
    }

    /// JSON の文字列から読む。知らないキーがあれば、書き間違いとして断る。
    static func decode(json text: String) throws -> DrillTemplate {
        let data: Data = Data(text.utf8)
        let tree: DrillJSON
        do {
            tree = try JSONDecoder().decode(DrillJSON.self, from: data)
        } catch {
            throw DecodeError(message: "JSON として読めません")
        }
        let unknown: [String] = DrillTemplateKeys.unknownKeys(in: tree)
        guard unknown.isEmpty else { throw DecodeError(message: "書式に無いキーがあります: " + unknown.joined(separator: "、")) }
        do {
            return try JSONDecoder().decode(DrillTemplate.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            throw DecodeError(message: "必要なキー「\(DrillTemplate.path(context.codingPath + [key]))」がありません")
        } catch let DecodingError.typeMismatch(_, context) {
            throw DecodeError(message: "「\(DrillTemplate.path(context.codingPath))」の値の種類が違います")
        } catch let DecodingError.valueNotFound(_, context) {
            throw DecodeError(message: "「\(DrillTemplate.path(context.codingPath))」の値がありません")
        } catch let DecodingError.dataCorrupted(context) {
            throw DecodeError(message: "「\(DrillTemplate.path(context.codingPath))」が読めません: \(context.debugDescription)")
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.map { (key: CodingKey) -> String in key.intValue.map { (index: Int) -> String in "[\(index)]" } ?? key.stringValue }.joined(separator: ".")
    }

    /// 保存や比較に使う、キーの順を固定した JSON。
    func canonicalJSON() throws -> String {
        let encoder: JSONEncoder = JSONEncoder()
        encoder.outputFormatting = [JSONEncoder.OutputFormatting.sortedKeys, JSONEncoder.OutputFormatting.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// 変数 1 つ。問題ごとに乱数で値を選ぶ。
nonisolated struct DrillVariable: Codable, Equatable, Sendable {
    var name: String
    /// integer(整数)| decimal(小数)| fraction(分数)| choice(選択肢)| constant(定数)
    var kind: String
    /// integer・decimal の範囲(両端を含む)と刻み。
    var min: Double?
    var max: Double?
    var step: Double?
    /// 範囲から除く値。
    var exclude: [Double]?
    /// fraction の分子・分母の範囲。約分した形で分母が 2 以上のものだけを選ぶ。
    var numerator: DrillIntegerRange?
    var denominator: DrillIntegerRange?
    /// choice の選択肢。数・文字列か、名前つきの値の組。
    var options: [DrillOption]?
    /// constant の値。
    var value: Double?
    /// 単位(物理・化学)。値はこの単位で書き、式の中では SI の値として扱う。
    var unit: String?
    /// 画面に出す時の有効数字。
    var sig: Int?

    init(name: String, kind: String, min: Double? = nil, max: Double? = nil, step: Double? = nil, exclude: [Double]? = nil, numerator: DrillIntegerRange? = nil,
         denominator: DrillIntegerRange? = nil, options: [DrillOption]? = nil, value: Double? = nil, unit: String? = nil, sig: Int? = nil) {
        self.name = name
        self.kind = kind
        self.min = min
        self.max = max
        self.step = step
        self.exclude = exclude
        self.numerator = numerator
        self.denominator = denominator
        self.options = options
        self.value = value
        self.unit = unit
        self.sig = sig
    }
}

nonisolated struct DrillIntegerRange: Codable, Equatable, Sendable {
    var min: Int
    var max: Int
}

/// 選択肢の中の 1 つの値。
nonisolated enum DrillScalar: Codable, Equatable, Sendable {
    case number(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        if let number: Double = try? container.decode(Double.self) {
            self = DrillScalar.number(number)
        } else {
            self = DrillScalar.text(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container: SingleValueEncodingContainer = encoder.singleValueContainer()
        switch self {
        case DrillScalar.number(let number): try container.encode(number)
        case DrillScalar.text(let text): try container.encode(text)
        }
    }

    var value: DrillValue {
        switch self {
        case DrillScalar.number(let number): return DrillValue.number(DrillNumber(json: number))
        case DrillScalar.text(let text): return DrillValue.text(text)
        }
    }
}

/// 選択肢 1 つ。数・文字列か、名前つきの値の組(`{"tex": "\\sin", "sign": 1}`)。
nonisolated enum DrillOption: Codable, Equatable, Sendable {
    case scalar(DrillScalar)
    case record([String: DrillScalar])

    init(from decoder: Decoder) throws {
        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        if let record: [String: DrillScalar] = try? container.decode([String: DrillScalar].self) {
            self = DrillOption.record(record)
        } else {
            self = DrillOption.scalar(try container.decode(DrillScalar.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container: SingleValueEncodingContainer = encoder.singleValueContainer()
        switch self {
        case DrillOption.scalar(let scalar): try container.encode(scalar)
        case DrillOption.record(let record): try container.encode(record)
        }
    }

    var value: DrillValue {
        switch self {
        case DrillOption.scalar(let scalar): return scalar.value
        case DrillOption.record(let record): return DrillValue.record(record.mapValues { (scalar: DrillScalar) -> DrillValue in scalar.value })
        }
    }
}

/// 変数から計算する値。
nonisolated struct DrillLet: Codable, Equatable, Sendable {
    var name: String
    var expr: String
    /// 画面に出す時の単位。式の次元と合わなければ点検で落ちる。
    var unit: String?
    /// 画面に出す時の有効数字。
    var sig: Int?

    init(name: String, expr: String, unit: String? = nil, sig: Int? = nil) {
        self.name = name
        self.expr = expr
        self.unit = unit
        self.sig = sig
    }
}

/// 表示の部品。整形の規則(係数 1 を書かない、+- を - にする、x^1 を x にする、0 の項を書かない)を当てて LaTeX を組み立てる。
nonisolated struct DrillPart: Codable, Equatable, Sendable {
    var name: String
    /// sum(項の和)| product(べきの積)| text(文字列の組み立て)| select(条件で選ぶ)| list(値の並び)| pm(a ± b√c)
    var kind: String
    /// sum の項。
    var terms: [DrillTerm]?
    /// product のべき(指数が 0 のものは書かず、1 なら指数を書かない)。
    var powers: [DrillPower]?
    /// text の中身。
    var tex: String?
    /// select の場合分け(上から順に、最初に成り立ったものを使う)。
    var cases: [DrillCase]?
    /// select でどれも成り立たない時。
    var otherwise: String?
    /// list の中身(式)。
    var items: [String]?
    /// list を小さい順に並べるか。
    var sort: Bool?
    /// list から同じ値を除くか。
    var unique: Bool?
    /// list の区切り(既定は `,\ `)。product の区切り(既定は無し。素因数分解なら ` \times `)。
    var separator: String?
    /// sum の係数・list の値の書き方(`dec:1`、`sig:2` など)。
    var format: String?
    /// pm: center ± scale × √radicand。
    var center: String?
    var radicand: String?
    var scale: String?

    init(name: String, kind: String, terms: [DrillTerm]? = nil, powers: [DrillPower]? = nil, tex: String? = nil, cases: [DrillCase]? = nil, otherwise: String? = nil, items: [String]? = nil,
         sort: Bool? = nil, unique: Bool? = nil, separator: String? = nil, format: String? = nil, center: String? = nil, radicand: String? = nil, scale: String? = nil) {
        self.name = name
        self.kind = kind
        self.terms = terms
        self.powers = powers
        self.tex = tex
        self.cases = cases
        self.otherwise = otherwise
        self.items = items
        self.sort = sort
        self.unique = unique
        self.separator = separator
        self.format = format
        self.center = center
        self.radicand = radicand
        self.scale = scale
    }
}

/// sum の項: 係数 × (べきの積) × 本体。
nonisolated struct DrillTerm: Codable, Equatable, Sendable {
    /// 係数(式)。0 ならこの項は書かない。
    var coef: String
    /// 文字のべき(指数が 0 なら書かず、1 なら指数を書かない)。
    var powers: [DrillPower]?
    /// 係数の後ろに置く LaTeX(`x^{2}`、`\sin x` など)。
    var body: String?
    /// 係数と本体の間に `\cdot` を置くか(本体が数で始まる時)。
    var times: Bool?

    init(coef: String, powers: [DrillPower]? = nil, body: String? = nil, times: Bool? = nil) {
        self.coef = coef
        self.powers = powers
        self.body = body
        self.times = times
    }
}

nonisolated struct DrillPower: Codable, Equatable, Sendable {
    /// 底の LaTeX(`x`、`(x+1)` など)。
    var base: String
    /// 指数(式)。
    var exp: String
}

nonisolated struct DrillCase: Codable, Equatable, Sendable {
    var when: String
    var tex: String
}

/// 連立方程式の 1 本。
nonisolated struct DrillEquation: Codable, Equatable, Sendable {
    var left: String
    var right: String
}

/// 数値で確かめる点検 1 つ(docs/offline-drill/format.md「数値の点検」)。`kind` ごとに使う項目が決まっている。
nonisolated struct DrillCheck: Codable, Equatable, Sendable {
    /// identity | value | derivative | antiderivative | definite_integral | root | system | inequality | assert | series | limit | ode
    var kind: String
    var left: String?
    var right: String?
    /// 値を入れて比べる文字(`["x"]`)。
    var over: [String]?
    /// 文字に入れる値の範囲(下限・上限)。
    var range: [Double]?
    var tex: String?
    var equals: String?
    /// LaTeX の中の文字に入れる値(文字 → 式)。
    var at: [String: String]?
    var function: String?
    var answer: String?
    var variable: String?
    /// 何階の導関数か(既定は 1)。
    var order: Int?
    /// 微分係数を求める点(式)。
    var point: String?
    var integrand: String?
    var from: String?
    var to: String?
    var solutions: [String]?
    var equations: [DrillEquation]?
    /// 連立方程式の解(文字 → LaTeX)。
    var values: [String: String]?
    /// 不等式の解(変数を使った真偽の式)。
    var solution: String?
    /// 不等号(`<`、`<=`、`>`、`>=`)。
    var relation: String?
    /// 不等式を確かめる変数の範囲(変数を使った真偽の式。定義域のある最大・最小など)。
    var `where`: String?
    var conditions: [String]?
    var term: String?
    var index: String?
    /// 比べる時の相対誤差(既定は 1e-6)。
    var tolerance: Double?

    init(kind: String, left: String? = nil, right: String? = nil, over: [String]? = nil, range: [Double]? = nil, tex: String? = nil, equals: String? = nil,
         at: [String: String]? = nil, function: String? = nil, answer: String? = nil, variable: String? = nil, order: Int? = nil, point: String? = nil,
         integrand: String? = nil, from: String? = nil, to: String? = nil, solutions: [String]? = nil, equations: [DrillEquation]? = nil,
         values: [String: String]? = nil, solution: String? = nil, relation: String? = nil, where: String? = nil, conditions: [String]? = nil, term: String? = nil,
         index: String? = nil, tolerance: Double? = nil) {
        self.kind = kind
        self.left = left
        self.right = right
        self.over = over
        self.range = range
        self.tex = tex
        self.equals = equals
        self.at = at
        self.function = function
        self.answer = answer
        self.variable = variable
        self.order = order
        self.point = point
        self.integrand = integrand
        self.from = from
        self.to = to
        self.solutions = solutions
        self.equations = equations
        self.values = values
        self.solution = solution
        self.relation = relation
        self.where = `where`
        self.conditions = conditions
        self.term = term
        self.index = index
        self.tolerance = tolerance
    }
}

/// JSON の木(キーの書き間違いを見つけるために、いったんこの形で読む)。
nonisolated indirect enum DrillJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DrillJSON])
    case object([String: DrillJSON])

    init(from decoder: Decoder) throws {
        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = DrillJSON.null
        } else if let flag: Bool = try? container.decode(Bool.self) {
            self = DrillJSON.bool(flag)
        } else if let number: Double = try? container.decode(Double.self) {
            self = DrillJSON.number(number)
        } else if let text: String = try? container.decode(String.self) {
            self = DrillJSON.string(text)
        } else if let items: [DrillJSON] = try? container.decode([DrillJSON].self) {
            self = DrillJSON.array(items)
        } else {
            self = DrillJSON.object(try container.decode([String: DrillJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container: SingleValueEncodingContainer = encoder.singleValueContainer()
        switch self {
        case DrillJSON.null: try container.encodeNil()
        case DrillJSON.bool(let flag): try container.encode(flag)
        case DrillJSON.number(let number): try container.encode(number)
        case DrillJSON.string(let text): try container.encode(text)
        case DrillJSON.array(let items): try container.encode(items)
        case DrillJSON.object(let fields): try container.encode(fields)
        }
    }
}

/// 書式にあるキーの一覧。
nonisolated enum DrillTemplateKeys {
    static let template: Set<String> = ["format", "skill_id", "title", "subject", "variables", "lets", "constraints", "parts", "prompt", "math", "answer", "checks", "no_numeric_check"]
    static let variable: Set<String> = ["name", "kind", "min", "max", "step", "exclude", "numerator", "denominator", "options", "value", "unit", "sig"]
    static let range: Set<String> = ["min", "max"]
    static let letKeys: Set<String> = ["name", "expr", "unit", "sig"]
    static let part: Set<String> = ["name", "kind", "terms", "powers", "tex", "cases", "otherwise", "items", "sort", "unique", "separator", "format", "center", "radicand", "scale"]
    static let term: Set<String> = ["coef", "powers", "body", "times"]
    static let power: Set<String> = ["base", "exp"]
    static let caseKeys: Set<String> = ["when", "tex"]
    static let equation: Set<String> = ["left", "right"]
    static let check: Set<String> = ["kind", "left", "right", "over", "range", "tex", "equals", "at", "function", "answer", "variable", "order", "point", "integrand",
                                     "from", "to", "solutions", "equations", "values", "solution", "relation", "where", "conditions", "term", "index", "tolerance"]

    private static func extra(_ value: DrillJSON?, _ known: Set<String>, _ path: String) -> [String] {
        guard case DrillJSON.object(let fields)? = value else { return [] }
        return fields.keys.filter { (key: String) -> Bool in !known.contains(key) }.sorted().map { (key: String) -> String in "\(path).\(key)" }
    }

    private static func items(_ value: DrillJSON?) -> [DrillJSON] {
        guard case DrillJSON.array(let items)? = value else { return [] }
        return items
    }

    private static func field(_ value: DrillJSON, _ key: String) -> DrillJSON? {
        guard case DrillJSON.object(let fields) = value else { return nil }
        return fields[key]
    }

    static func unknownKeys(in tree: DrillJSON) -> [String] {
        var found: [String] = extra(tree, template, "型")
        for (index, variable): (Int, DrillJSON) in items(field(tree, "variables")).enumerated() {
            found += extra(variable, DrillTemplateKeys.variable, "variables[\(index)]")
            found += extra(field(variable, "numerator"), range, "variables[\(index)].numerator")
            found += extra(field(variable, "denominator"), range, "variables[\(index)].denominator")
        }
        for (index, entry): (Int, DrillJSON) in items(field(tree, "lets")).enumerated() {
            found += extra(entry, letKeys, "lets[\(index)]")
        }
        for (index, part): (Int, DrillJSON) in items(field(tree, "parts")).enumerated() {
            found += extra(part, DrillTemplateKeys.part, "parts[\(index)]")
            for (termIndex, term): (Int, DrillJSON) in items(field(part, "terms")).enumerated() {
                found += extra(term, DrillTemplateKeys.term, "parts[\(index)].terms[\(termIndex)]")
                for power: DrillJSON in items(field(term, "powers")) {
                    found += extra(power, DrillTemplateKeys.power, "parts[\(index)].terms[\(termIndex)].powers")
                }
            }
            for power: DrillJSON in items(field(part, "powers")) {
                found += extra(power, DrillTemplateKeys.power, "parts[\(index)].powers")
            }
            for entry: DrillJSON in items(field(part, "cases")) {
                found += extra(entry, caseKeys, "parts[\(index)].cases")
            }
        }
        for (index, check): (Int, DrillJSON) in items(field(tree, "checks")).enumerated() {
            found += extra(check, DrillTemplateKeys.check, "checks[\(index)]")
            for equation: DrillJSON in items(field(check, "equations")) {
                found += extra(equation, DrillTemplateKeys.equation, "checks[\(index)].equations")
            }
        }
        return found
    }
}
