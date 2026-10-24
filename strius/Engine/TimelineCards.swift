import Foundation

/// タイムラインのカード(Issue #46「タイムラインに混ぜるカード10種」)。AI は問題ごとに「解き方の手順」と「よくある間違い」を
/// 1 回作り、アプリがそれを各パターンに組み替える: 01・02・04・05・06・07・08 はこれだけで作れる。03・10 は AI が作った文を使う。
/// 保存する前に数式で検算し、合わないカードは受け取らない(間違った問題は、問題がないより悪い)。
nonisolated enum TimelineCards {
    /// カードの種類。種類を増やすのは開発の作業(種類ごとに画面が要る)。
    nonisolated enum Kind: String, CaseIterable, Sendable {
        case solve
        case order          // 01 手順の並び替え
        case findError = "find_error"     // 02 間違い探し
        case compare        // 03 2つの解き方を比べる
        case fillLine = "fill_line"       // 04 1行だけ穴埋め
        case nextStep = "next_step"       // 05 次の一手を選ぶ
        case graphMatch = "graph_match"   // 06 グラフと式を結ぶ
        case sort           // 07 左右に仕分け
        case predict        // 08 解く前に予想
        case inverse        // 09 逆に作る
        case reason         // 10 理由を選ぶ
        case guide          // 使い始め: 単元を作るへの案内

        /// 撮る・指で書いて送る(読み取りと検算が要る)カードか。それ以外は端末の中で採点する。
        var needsReading: Bool { self == .solve || self == .fillLine || self == .inverse }
        /// 正答率に数える問題か(解いて撮る問題だけ)。
        var isProblem: Bool { self == .solve }

        var number: String? {
            switch self {
            case .order: "01"
            case .findError: "02"
            case .compare: "03"
            case .fillLine: "04"
            case .nextStep: "05"
            case .graphMatch: "06"
            case .sort: "07"
            case .predict: "08"
            case .inverse: "09"
            case .reason: "10"
            case .solve, .guide: nil
            }
        }

        var title: String {
            switch self {
            case .solve: "解いて撮る"
            case .order: "手順の並び替え"
            case .findError: "間違い探し"
            case .compare: "2つの解き方を比べる"
            case .fillLine: "1行だけ穴埋め"
            case .nextStep: "次の一手を選ぶ"
            case .graphMatch: "グラフと式を結ぶ"
            case .sort: "左右に仕分け"
            case .predict: "解く前に予想"
            case .inverse: "逆に作る"
            case .reason: "理由を選ぶ"
            case .guide: "はじめに"
            }
        }
    }

    // MARK: 5枚の呼び出しが返すもの

    nonisolated struct Draft: Codable, Sendable {
        nonisolated struct Check: Codable, Sendable { var left: String; var right: String }
        nonisolated struct MistakeStep: Codable, Sendable { var step: Int; var wrong: String }
        nonisolated struct Chain: Codable, Sendable {
            var position: Int
            var total: Int
            var changed: String?
            var previous: String?
        }
        nonisolated struct Easier: Codable, Sendable {
            var level: Int
            var prompt: String
            var math: String
            var question: String
            var answerKey: String
            var answerExpr: String
            var checkpoints: [String]
            enum CodingKeys: String, CodingKey {
                case level, prompt, math, question, checkpoints
                case answerKey = "answer_key"
                case answerExpr = "answer_expr"
            }
        }
        nonisolated struct Facts: Codable, Sendable {
            var answerValue: Double?
            var vertex: [Double]?
            var axis: Double?
            enum CodingKeys: String, CodingKey {
                case vertex, axis
                case answerValue = "answer_value"
            }
        }

        var kind: String
        var level: Int
        var skills: [String]
        var typeName: String
        var prompt: String
        var math: String
        var question: String
        var answerKey: String
        var answerExpr: String
        var checks: [Check]
        var checkpoints: [String]
        var commonMistakes: [String]
        var steps: [String]
        var mistakeSteps: [MistakeStep]
        var estimatedSeconds: Int
        var chain: Chain?
        var easier: Easier?
        /// 初めて間違えた時に次に出す、同じ点を数値だけ変えた問題。
        var variant: Easier?
        var subunitId: String?
        var facts: Facts?
        var compare: LedgerJSON?
        var reason: LedgerJSON?
        var howto: LedgerJSON?
        var diagnostic: LedgerJSON?

        enum CodingKeys: String, CodingKey {
            case kind, level, skills, prompt, math, question, checks, checkpoints, steps, chain, easier, variant, facts, compare, reason, howto, diagnostic
            case typeName = "type_name"
            case answerKey = "answer_key"
            case answerExpr = "answer_expr"
            case commonMistakes = "common_mistakes"
            case mistakeSteps = "mistake_steps"
            case estimatedSeconds = "estimated_seconds"
            case subunitId = "subunit_id"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "solve"
            level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 1
            skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
            typeName = try c.decodeIfPresent(String.self, forKey: .typeName) ?? ""
            prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
            math = try c.decodeIfPresent(String.self, forKey: .math) ?? ""
            question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
            answerKey = try c.decodeIfPresent(String.self, forKey: .answerKey) ?? ""
            answerExpr = try c.decodeIfPresent(String.self, forKey: .answerExpr) ?? ""
            checks = try c.decodeIfPresent([Check].self, forKey: .checks) ?? []
            checkpoints = try c.decodeIfPresent([String].self, forKey: .checkpoints) ?? []
            commonMistakes = try c.decodeIfPresent([String].self, forKey: .commonMistakes) ?? []
            steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
            mistakeSteps = try c.decodeIfPresent([MistakeStep].self, forKey: .mistakeSteps) ?? []
            estimatedSeconds = try c.decodeIfPresent(Int.self, forKey: .estimatedSeconds) ?? 60
            chain = try c.decodeIfPresent(Chain.self, forKey: .chain)
            easier = try c.decodeIfPresent(Easier.self, forKey: .easier)
            variant = try c.decodeIfPresent(Easier.self, forKey: .variant)
            subunitId = try c.decodeIfPresent(String.self, forKey: .subunitId)
            facts = try c.decodeIfPresent(Facts.self, forKey: .facts)
            compare = try c.decodeIfPresent(LedgerJSON.self, forKey: .compare)
            reason = try c.decodeIfPresent(LedgerJSON.self, forKey: .reason)
            howto = try c.decodeIfPresent(LedgerJSON.self, forKey: .howto)
            diagnostic = try c.decodeIfPresent(LedgerJSON.self, forKey: .diagnostic)
        }
    }

    nonisolated struct Rapid: Codable, Sendable {
        var skill: String
        var prompt: String
        var math: String?
        var answerKey: String
        var answerExpr: String?
        enum CodingKeys: String, CodingKey {
            case skill, prompt, math
            case answerKey = "answer_key"
            case answerExpr = "answer_expr"
        }
    }

    nonisolated struct Wanted: Codable, Sendable {
        var name: String
        var kind: String
        var requiredBy: String
        enum CodingKeys: String, CodingKey {
            case name, kind
            case requiredBy = "required_by"
        }
    }

    nonisolated struct Batch: Codable, Sendable {
        var reason: String
        var cards: [Draft]
        var rapid: [Rapid]
        var wantedPrerequisites: [Wanted]
        var graphOps: [TimelineGraph.Operation]
        enum CodingKeys: String, CodingKey {
            case reason, cards, rapid
            case wantedPrerequisites = "wanted_prerequisites"
            case graphOps = "graph_ops"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
            cards = try c.decodeIfPresent([Draft].self, forKey: .cards) ?? []
            rapid = try c.decodeIfPresent([Rapid].self, forKey: .rapid) ?? []
            wantedPrerequisites = try c.decodeIfPresent([Wanted].self, forKey: .wantedPrerequisites) ?? []
            graphOps = try c.decodeIfPresent([TimelineGraph.Operation].self, forKey: .graphOps) ?? []
        }

        static func parse(_ text: String) throws -> Batch {
            try JSONDecoder().decode(Batch.self, from: Data(text.utf8))
        }
    }

    // MARK: 受け取る前の点検

    /// 1 枚の欠け(受け取りを断る理由)。空なら受け取ってよい。
    static func defects(_ draft: Draft, allowedSkills: Set<String>, levelCap: Int?) -> [String] {
        var defects: [String] = []
        // 組み替えるカード(仕分け・並べ替えなど)の問題文はアプリが作るので、空でもよい。
        if Kind(rawValue: draft.kind)?.needsReading ?? true, [draft.prompt, draft.math, draft.question].allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            defects.append("empty prompt")
        }
        if Kind(rawValue: draft.kind) == nil || draft.kind == Kind.guide.rawValue { defects.append("unknown kind \(draft.kind)") }
        if !(1...4).contains(draft.level) { defects.append("level \(draft.level) out of 1...4") }
        if let levelCap, draft.level > levelCap { defects.append("level \(draft.level) exceeds cap \(levelCap)") }
        if !allowedSkills.isEmpty {
            let unknown = draft.skills.filter { !allowedSkills.contains($0) }
            if !unknown.isEmpty { defects.append("skills not in the learner's graph: " + unknown.joined(separator: ", ")) }
        }
        if draft.kind == Kind.solve.rawValue, draft.answerKey.trimmingCharacters(in: .whitespaces).isEmpty { defects.append("empty answer_key") }
        defects += verificationFailures(draft.checks.map { ($0.left, $0.right) })
        if let easier = draft.easier, easier.prompt.isEmpty && easier.math.isEmpty { defects.append("empty easier prompt") }
        switch Kind(rawValue: draft.kind) {
        case .order, .findError, .nextStep:
            if draft.steps.count < 3 { defects.append("\(draft.kind) needs 3+ steps") }
            if draft.kind != Kind.order.rawValue, draft.mistakeSteps.isEmpty { defects.append("\(draft.kind) needs mistake_steps") }
        case .compare:
            if draft.compare?["options"]?.arrayValue?.isEmpty ?? true { defects.append("compare needs options") }
        case .reason:
            if draft.reason?["options"]?.arrayValue?.isEmpty ?? true { defects.append("reason needs options") }
        case .sort:
            if draft.facts?.axis == nil { defects.append("sort needs facts.axis") }
        case .predict:
            if draft.facts?.answerValue == nil { defects.append("predict needs facts.answer_value") }
        case .inverse:
            if (draft.facts?.vertex?.count ?? 0) != 2 { defects.append("inverse needs facts.vertex") }
        case .graphMatch, .fillLine:
            if TimelineExpression.vertex(of: draft.answerExpr.isEmpty ? draft.math : draft.answerExpr) == nil && draft.kind == Kind.graphMatch.rawValue {
                defects.append("graph_match needs a quadratic answer_expr")
            }
            if draft.kind == Kind.fillLine.rawValue, draft.steps.count < 2 { defects.append("fill_line needs steps") }
        default: break
        }
        return defects
    }

    /// 検算: 等式の両辺を数値で比べて、合わないものを返す(読めない式は確かめられないので、欠けにはしない)。
    static func verificationFailures(_ checks: [(String, String)]) -> [String] {
        checks.compactMap { left, right in
            TimelineExpression.equivalent(left, right) == false ? "check failed: \(left) = \(right)" : nil
        }
    }

    // MARK: 組み替え

    /// 決まった並べ方(同じカードからは同じ並びになる)。
    nonisolated struct Shuffle {
        var state: UInt64
        init(seed: String) {
            var hash: UInt64 = 1469598103934665603
            for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
            state = hash == 0 ? 1 : hash
        }
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func shuffled<T>(_ items: [T]) -> [T] {
            var copy = items
            guard copy.count > 1 else { return copy }
            for i in stride(from: copy.count - 1, to: 0, by: -1) {
                let j = Int(next() % UInt64(i + 1))
                copy.swapAt(i, j)
            }
            return copy
        }
    }

    /// 元のカード(解いて撮る問題)の材料から、ほかの種類の中身(`payload` に足すもの)を作る。作れなければ nil。
    static func derive(_ kind: Kind, from base: TimelineCardRecord) -> (prompt: String, payload: [String: LedgerJSON])? {
        let steps = base.payload["steps"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let mistakes = (base.payload["mistake_steps"]?.arrayValue ?? []).compactMap { item -> (Int, String)? in
            guard let step = item["step"]?.intValue, let wrong = item["wrong"]?.stringValue, !wrong.isEmpty else { return nil }
            // AI は 1 始まりでも 0 始まりでも書く。範囲に入る方を使う。
            let index = step >= 1 && step <= steps.count ? step - 1 : step
            return steps.indices.contains(index) ? (index, wrong) : nil
        }
        var shuffle = Shuffle(seed: base.id + kind.rawValue)
        let problem = problemLine(prompt: base.payload["problem"]?.stringValue ?? base.prompt, math: base.math)
        switch kind {
        case .solve, .guide:
            return nil
        case .order:
            guard steps.count >= 3 else { return nil }
            var order = shuffle.shuffled(Array(steps.indices))
            if order == Array(steps.indices) { order.swapAt(0, order.count - 1) }
            return ("\(problem)。正しい順に並べなさい。", ["steps": .array(steps.map(LedgerJSON.string)), "shuffled": .array(order.map { .number(Double($0)) })])
        case .findError:
            guard steps.count >= 3, let mistake = mistakes.first else { return nil }
            var lines = steps
            lines[mistake.0] = mistake.1
            return ("誰かの答案です。違う行は？", ["lines": .array(lines.map(LedgerJSON.string)), "answer_index": .number(Double(mistake.0)), "problem": .string(problem), "correct_line": .string(steps[mistake.0])])
        case .nextStep:
            guard steps.count >= 2 else { return nil }
            let index = max(1, mistakes.first?.0 ?? steps.count - 1)
            let wrongs = mistakes.filter { $0.0 == index }.map(\.1) + mistakes.filter { $0.0 != index }.map(\.1)
            let distractors = Array(Set(wrongs).filter { $0 != steps[index] }).sorted().prefix(2)
            guard !distractors.isEmpty else { return nil }
            let options = shuffle.shuffled([steps[index]] + distractors)
            return ("次は？", ["shown": .array(steps.prefix(index).map(LedgerJSON.string)), "options": .array(options.map(LedgerJSON.string)),
                              "answer_index": .number(Double(options.firstIndex(of: steps[index]) ?? 0)), "problem": .string(problem)])
        case .fillLine:
            guard steps.count >= 2 else { return nil }
            let hidden = mistakes.first?.0 ?? steps.count / 2
            return ("途中の1行を書きなさい。", ["lines": .array(steps.map(LedgerJSON.string)), "hidden": .number(Double(hidden)), "problem": .string(problem)])
        case .graphMatch:
            let source = base.answerExpr.isEmpty ? base.math : base.answerExpr
            guard let f = try? TimelineExpression.parse(source), f.variables.count <= 1, TimelineExpression.vertex(of: source) != nil else { return nil }
            let variable = f.variables.first ?? "x"
            let core = TimelineExpression.normalize(source).components(separatedBy: "=").last ?? source
            let candidates = [core, "-(\(core))", "(\(core))+3"].map { $0.replacingOccurrences(of: " ", with: "") }
            var unique: [String] = []
            for candidate in candidates where !unique.contains(where: { TimelineExpression.equivalent($0, candidate) == true }) { unique.append(candidate) }
            guard unique.count == 3 else { return nil }
            let graphs = shuffle.shuffled(Array(unique.indices))
            return ("グラフと式を組にしなさい。", ["exprs": .array(unique.map(LedgerJSON.string)), "graph_order": .array(graphs.map { .number(Double($0)) }), "variable": .string(variable)])
        case .sort:
            guard let axis = base.payload["facts"]?["axis"]?.doubleValue else { return nil }
            var items: [LedgerJSON] = []
            let a = Int(axis.rounded())
            for (low, high) in [(a - 3, a - 1), (a - 1, a + 1), (a + 1, a + 4), (a - 2, a), (a + 2, a + 3)] {
                let contains = Double(low) <= axis && axis <= Double(high)
                items.append(.object(["text": .string("\(low) ≤ x ≤ \(high)"), "right": .bool(contains)]))
            }
            return ("軸 x = \(format(axis)) を含む？", ["items": .array(shuffle.shuffled(items)), "left_label": .string("含まない"), "right_label": .string("含む")])
        case .predict:
            guard let value = base.payload["facts"]?["answer_value"]?.doubleValue, value != 0 else { return nil }
            return ("答えは正？負？", ["options": .array([.string("＋"), .string("−")]), "answer_index": .number(value > 0 ? 0 : 1), "problem": .string(problem), "base_card_id": .string(base.id)])
        case .inverse:
            guard let vertex = base.payload["facts"]?["vertex"]?.arrayValue?.compactMap(\.doubleValue), vertex.count == 2 else { return nil }
            return ("頂点が (\(format(vertex[0])), \(format(vertex[1]))) になる式は？", ["vertex": .array(vertex.map { .number($0) }), "note": .string("答えは1つじゃなくていい")])
        case .compare:
            guard let compare = base.payload["compare"]?.objectValue, !(compare["options"]?.arrayValue?.isEmpty ?? true) else { return nil }
            return (compare["question"]?.stringValue ?? "どちらも何を出している？", compare)
        case .reason:
            guard let reason = base.payload["reason"]?.objectValue, !(reason["options"]?.arrayValue?.isEmpty ?? true) else { return nil }
            return (reason["question"]?.stringValue ?? "なぜ？", reason)
        }
    }

    /// 問題文と式を 1 行の読める文字にする(組み替えたカードの問題・下の帯)。
    static func problemLine(prompt: String, math: String) -> String {
        let readable = math.isEmpty ? "" : MathPlainText.preview("\\(" + math + "\\)")
        return [prompt, readable].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value).replacingOccurrences(of: "-", with: "−")
    }

    // MARK: 端末の中の採点

    /// タップ・ドラッグ・払うのカードの正誤。`answer` は種類ごとの答え(選んだ番号・並べた順・仕分け・組)。
    static func grade(_ card: TimelineCardRecord, answer: LedgerJSON) -> Bool {
        switch Kind(rawValue: card.kind) {
        case .order:
            let order = answer.arrayValue?.compactMap(\.intValue) ?? []
            let count = card.payload["steps"]?.arrayValue?.count ?? 0
            return order == Array(0..<count)
        case .findError, .nextStep, .compare, .reason, .predict:
            return answer.intValue == card.payload["answer_index"]?.intValue
        case .sort:
            let items = card.payload["items"]?.arrayValue ?? []
            let chosen = answer.arrayValue?.compactMap(\.boolValue) ?? []
            return chosen.count == items.count && zip(items, chosen).allSatisfy { $0["right"]?.boolValue == $1 }
        case .graphMatch:
            // 答え: グラフの並びの順に選んだ式の番号。
            let order = card.payload["graph_order"]?.arrayValue?.compactMap(\.intValue) ?? []
            return answer.arrayValue?.compactMap(\.intValue) == order
        default:
            return false
        }
    }

    /// 手書きを読み取った後の正誤(数式で判定する)。04 は隠した行、09 は頂点を計算して判定する(答えは何通りあってもよい)。
    static func gradeWritten(_ card: TimelineCardRecord, learnerExpr: String) -> Bool? {
        let written = learnerExpr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !written.isEmpty else { return nil }
        switch Kind(rawValue: card.kind) {
        case .inverse:
            guard let target = card.payload["vertex"]?.arrayValue?.compactMap(\.doubleValue), target.count == 2,
                  let vertex = TimelineExpression.vertex(of: written) else { return false }
            return abs(vertex.x - target[0]) < 1e-6 && abs(vertex.y - target[1]) < 1e-6
        case .fillLine:
            guard let hidden = card.payload["hidden"]?.intValue, let line = card.payload["lines"]?[hidden]?.stringValue else { return nil }
            return equivalentLines(line, written)
        case .solve:
            guard !card.answerExpr.isEmpty else { return nil }
            return TimelineExpression.equivalent(card.answerExpr, written)
        default:
            return nil
        }
    }

    /// 1 行の比べ方: `= 2(x - 2)^2 - 5` のような行は、最後の `=` の右側を比べる。
    static func equivalentLines(_ expected: String, _ written: String) -> Bool? {
        func rhs(_ text: String) -> String {
            let parts = TimelineExpression.normalize(text).components(separatedBy: "=")
            return (parts.last ?? text).trimmingCharacters(in: .whitespaces)
        }
        return TimelineExpression.equivalent(rhs(expected), rhs(written))
    }
}

extension LedgerJSON {
    /// 配列の要素(範囲外は nil)。
    nonisolated subscript(index: Int) -> LedgerJSON? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
