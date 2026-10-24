import Foundation
import GRDB

/// 学習者ごとの知識グラフ(Issue #46「知識グラフ」)。点は「できること」、線は「○○を解くには××が要る」(前提)か
/// 「○○でよくある勘違い」(典型的な誤解)。上位モデルが返した点と線・操作の列は、ここで点検してから台帳に入れる:
/// ID の重複、存在しない点への線、前提がぐるぐる回る線は受け取らない。前提を何段もたどる処理は AI にやらせず、
/// 台帳の SQLite で再帰の SQL(WITH RECURSIVE)を実行して結果だけを返す。
nonisolated enum TimelineGraph {
    static let kinds: Set<String> = ["procedure", "concept", "combination", "memorized"]
    static let kindLabels: [String: String] = ["procedure": "手順", "concept": "概念", "combination": "組み合わせ", "memorized": "暗記事項"]
    static let statusLabels: [String: String] = ["mastered": "定着", "practicing": "練習中", "assumed": "できると推定"]

    nonisolated struct Node: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var kind: String
        var unitId: String?
        enum CodingKeys: String, CodingKey {
            case id, name, kind
            case unitId = "unit_id"
        }
    }

    nonisolated struct Edge: Codable, Hashable, Sendable {
        var from: String
        var to: String
        var relation: String
        var note: String
    }

    nonisolated struct Operation: Codable, Hashable, Sendable {
        var op: String
        var node: Node?
        var nodeIds: [String]
        var into: [Node]
        var edge: Edge?
        var evidence: [String]
        var reason: String
        enum CodingKeys: String, CodingKey {
            case op, node, into, edge, evidence, reason
            case nodeIds = "node_ids"
        }
    }

    nonisolated struct Output: Codable, Sendable {
        var nodes: [Node]
        var edges: [Edge]
        var ops: [Operation]
        var startNodeId: String?
        var notes: String
        enum CodingKeys: String, CodingKey {
            case nodes, edges, ops, notes
            case startNodeId = "start_node_id"
        }
    }

    nonisolated enum Problem: Equatable, Sendable, CustomStringConvertible {
        case duplicateNode(String)
        case unknownNode(String)
        case cycle([String])
        case invalidKind(String)
        case emptyID

        var description: String {
            switch self {
            case .duplicateNode(let id): "duplicate node \(id)"
            case .unknownNode(let id): "edge to unknown node \(id)"
            case .cycle(let path): "prerequisite cycle " + path.joined(separator: " -> ")
            case .invalidKind(let kind): "invalid kind \(kind)"
            case .emptyID: "empty node id"
            }
        }
    }

    /// 点の ID に使える形にする(英小文字・数字・`.`・`_`)。
    static func normalizedID(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "." || scalar == "_" { return Character(scalar) }
            return scalar.properties.isAlphabetic ? Character(scalar) : "_"
        }
        return String(mapped)
    }

    /// 前提の線(元 → 先)に輪があるか。あればその輪の点の列。
    static func cycle(in edges: [(from: String, to: String)]) -> [String]? {
        var adjacency: [String: [String]] = [:]
        for edge in edges where edge.from != edge.to { adjacency[edge.from, default: []].append(edge.to) }
        var state: [String: Int] = [:]  // 1 = 調べている途中, 2 = 済み
        var stack: [String] = []
        func visit(_ node: String) -> [String]? {
            state[node] = 1
            stack.append(node)
            for next in adjacency[node, default: []].sorted() {
                if state[next] == 1 {
                    let start = stack.firstIndex(of: next) ?? 0
                    return Array(stack[start...]) + [next]
                }
                if state[next] == nil, let found = visit(next) { return found }
            }
            stack.removeLast()
            state[node] = 2
            return nil
        }
        for node in adjacency.keys.sorted() where state[node] == nil {
            if let found = visit(node) { return found }
        }
        // 自分自身を前提にする線も輪。
        if let selfLoop = edges.first(where: { $0.from == $0.to }) { return [selfLoop.from, selfLoop.to] }
        return nil
    }

    /// 最初に作る・単元の分を足すグラフを点検する。`existing` は今のグラフの点。
    static func validate(nodes: [Node], edges: [Edge], existing: [String: TimelineSkillRecord], existingEdges: [TimelineSkillEdgeRecord]) -> [Problem] {
        var problems: [Problem] = []
        var seen = Set<String>()
        for node in nodes {
            if node.id.isEmpty { problems.append(.emptyID) }
            if !seen.insert(node.id).inserted || existing[node.id] != nil { problems.append(.duplicateNode(node.id)) }
            if !kinds.contains(node.kind) { problems.append(.invalidKind(node.kind)) }
        }
        let known = seen.union(existing.keys)
        for edge in edges {
            for id in [edge.from, edge.to] where !known.contains(id) { problems.append(.unknownNode(id)) }
        }
        let prerequisites = existingEdges.filter { $0.relation == "prerequisite" }.map { (from: $0.requiresSkillId, to: $0.skillId) }
            + edges.filter { $0.relation == "prerequisite" && $0.from != $0.to }.map { (from: $0.from, to: $0.to) }
        if let found = cycle(in: prerequisites) { problems.append(.cycle(found)) }
        return problems
    }

    /// 見直しの操作の列を、今のグラフに当てはめた結果(点検の後に台帳へ入れる)。
    nonisolated struct Plan: Sendable {
        var addNodes: [Node] = []
        var removeNodes: [String] = []
        /// 分けた・まとめた元 → 先(記録の引き継ぎ)。
        var replacements: [String: [String]] = [:]
        var addEdges: [Edge] = []
        var removeEdges: [Edge] = []
        var problems: [Problem] = []
    }

    static func plan(_ ops: [Operation], existing: [String: TimelineSkillRecord], existingEdges: [TimelineSkillEdgeRecord]) -> Plan {
        var plan = Plan()
        var nodes = Set(existing.filter { $0.value.isActive }.keys)
        var edges = existingEdges.map { Edge(from: $0.requiresSkillId, to: $0.skillId, relation: $0.relation, note: $0.note) }
        func addNode(_ node: Node) {
            if node.id.isEmpty { plan.problems.append(.emptyID); return }
            if nodes.contains(node.id) || existing[node.id] != nil { plan.problems.append(.duplicateNode(node.id)); return }
            if !kinds.contains(node.kind) { plan.problems.append(.invalidKind(node.kind)); return }
            nodes.insert(node.id)
            plan.addNodes.append(node)
        }
        for op in ops {
            switch op.op {
            case "add_node":
                if let node = op.node { addNode(node) }
            case "remove_node":
                for id in op.nodeIds + [op.node?.id].compactMap({ $0 }) {
                    guard nodes.remove(id) != nil else { plan.problems.append(.unknownNode(id)); continue }
                    plan.removeNodes.append(id)
                    edges.removeAll { $0.from == id || $0.to == id }
                }
            case "split_node", "merge_nodes":
                let sources = op.op == "split_node" ? (op.nodeIds.first.map { [$0] } ?? [op.node?.id].compactMap { $0 }) : op.nodeIds
                guard !sources.isEmpty, !op.into.isEmpty else { plan.problems.append(.emptyID); continue }
                for id in sources where !nodes.contains(id) { plan.problems.append(.unknownNode(id)) }
                for node in op.into { addNode(node) }
                for id in sources {
                    nodes.remove(id)
                    plan.replacements[id] = op.into.map(\.id)
                    // 元の点の線は、分けた・まとめた先へ付け替える。
                    var moved: [Edge] = []
                    for edge in edges where edge.from == id || edge.to == id {
                        for target in op.into {
                            var copy = edge
                            if copy.from == id { copy.from = target.id }
                            if copy.to == id { copy.to = target.id }
                            if copy.from != copy.to || copy.relation == "misconception" { moved.append(copy) }
                        }
                    }
                    edges.removeAll { $0.from == id || $0.to == id }
                    edges.append(contentsOf: moved)
                    plan.addEdges.append(contentsOf: moved)
                }
            case "add_edge":
                guard let edge = op.edge else { continue }
                for id in [edge.from, edge.to] where !nodes.contains(id) { plan.problems.append(.unknownNode(id)) }
                edges.append(edge)
                plan.addEdges.append(edge)
            case "remove_edge":
                guard let edge = op.edge else { continue }
                edges.removeAll { $0.from == edge.from && $0.to == edge.to && $0.relation == edge.relation }
                plan.removeEdges.append(edge)
            default:
                continue
            }
        }
        let prerequisites = edges.filter { $0.relation == "prerequisite" && $0.from != $0.to }.map { (from: $0.from, to: $0.to) }
        if let found = cycle(in: prerequisites) { plan.problems.append(.cycle(found)) }
        return plan
    }

    // MARK: 1段ずつ分解する(2026-10-24)

    /// 分解の 1 回分の答え: 渡した点ごとに、典型的な問題を手順に分けて書き、各手順で使う、より小さい「できること」。
    nonisolated struct Decomposition: Codable, Sendable {
        nonisolated struct Use: Codable, Sendable {
            var id: String
            var name: String
            var kind: String
            /// 今の単元の中身か(false なら前に習う内容で、置くだけにして掘らない)。
            var inUnit: Bool
            enum CodingKeys: String, CodingKey {
                case id, name, kind
                case inUnit = "in_unit"
            }
            init(id: String, name: String, kind: String, inUnit: Bool) {
                self.id = id; self.name = name; self.kind = kind; self.inUnit = inUnit
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
                name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
                kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "procedure"
                inUnit = try c.decodeIfPresent(Bool.self, forKey: .inUnit) ?? false
            }
        }
        nonisolated struct Step: Codable, Sendable {
            var text: String
            var uses: [Use]
        }
        nonisolated struct Item: Codable, Sendable {
            var nodeId: String
            var problem: String
            var steps: [Step]
            enum CodingKeys: String, CodingKey {
                case problem, steps
                case nodeId = "node_id"
            }
        }
        var items: [Item]
        var notes: String

        static func parse(_ text: String) throws -> Decomposition {
            try JSONDecoder().decode(Decomposition.self, from: Data(text.utf8))
        }
    }

    /// よくある勘違いの 1 回分の答え(形が決まった後に別の依頼で付ける)。
    nonisolated struct Misconceptions: Codable, Sendable {
        nonisolated struct Item: Codable, Sendable {
            var nodeId: String
            var misconceptions: [String]
            enum CodingKeys: String, CodingKey {
                case misconceptions
                case nodeId = "node_id"
            }
        }
        var items: [Item]
        var notes: String
    }

    /// 1段ごとにコードが点検した結果。出力全体は失敗にせず、受け取れない線だけを捨てる。
    nonisolated struct StepPlan: Sendable {
        /// 新しく置く点(ID は正規化済み、同じ ID は 1 つにまとめた)。
        var addNodes: [Node] = []
        /// 新しく置く点の印(pending / unexplored)。
        var expansion: [String: String] = [:]
        /// 受け取る前提の線(元 = 前提、先 = 使う側)。
        var addEdges: [(from: String, to: String)] = []
        /// 循環を作るので捨てた線。
        var droppedCycles: [(from: String, to: String)] = []
        /// 分解を受け取った点(done にする)。
        var dugNodes: [String] = []
        /// 点ごとの典型的な問題(記録用)。
        var problems: [String: String] = [:]
    }

    /// 分解の答えを点検する。`requested` は渡した点(ID → 新しい点に付ける単元 ID)、`descend` は 1段下りる依頼
    /// (新しい点はすべて「まだ掘っていない」)。既にある点の ID を使った時は、元の紐づけのまま線だけを引く。
    static func plan(decomposition: Decomposition, requested: [String: String?], descend: Bool,
                     existing: [String: TimelineSkillRecord], existingEdges: [TimelineSkillEdgeRecord]) -> StepPlan {
        var plan = StepPlan()
        var accepted = existingEdges.filter { $0.relation == "prerequisite" && $0.requiresSkillId != $0.skillId }.map { (from: $0.requiresSkillId, to: $0.skillId) }
        var newIDs = Set<String>()
        for item in decomposition.items {
            let parent = normalizedID(item.nodeId)
            guard let unitID = requested[parent], existing[parent]?.isActive == true else { continue }
            plan.dugNodes.append(parent)
            if !item.problem.isEmpty { plan.problems[parent] = item.problem }
            for use in item.steps.flatMap(\.uses) {
                let id = normalizedID(use.id)
                guard !id.isEmpty, id != parent else { continue }
                if let known = existing[id] {
                    guard known.isActive else { continue }
                } else if newIDs.insert(id).inserted {
                    let name = use.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    plan.addNodes.append(Node(id: id, name: name.isEmpty ? id : name, kind: kinds.contains(use.kind) ? use.kind : "procedure", unitId: unitID))
                    plan.expansion[id] = descend || !use.inUnit ? "unexplored" : "pending"
                }
                guard !accepted.contains(where: { $0.from == id && $0.to == parent }) else { continue }
                // 循環を作る線だけを捨てる(出力全体は失敗にしない)。
                if cycle(in: accepted + [(from: id, to: parent)]) != nil {
                    plan.droppedCycles.append((from: id, to: parent))
                    continue
                }
                accepted.append((from: id, to: parent))
                plan.addEdges.append((from: id, to: parent))
            }
        }
        return plan
    }

    /// 他の点を経由して届く直接の線(元 → 先)。直前の前提だけを残すために消す。
    static func redundantEdges(_ edges: [(from: String, to: String)]) -> [(from: String, to: String)] {
        var adjacency: [String: Set<String>] = [:]
        for edge in edges where edge.from != edge.to { adjacency[edge.from, default: []].insert(edge.to) }
        func reaches(_ start: String, _ target: String, skipping direct: (from: String, to: String)) -> Bool {
            var stack = [start]
            var seen: Set<String> = [start]
            while let node = stack.popLast() {
                for next in adjacency[node, default: []] {
                    if node == direct.from && next == direct.to { continue }
                    if next == target { return true }
                    if seen.insert(next).inserted { stack.append(next) }
                }
            }
            return false
        }
        var seenEdges = Set<String>()
        return edges.filter { edge in
            guard edge.from != edge.to, seenEdges.insert(edge.from + "->" + edge.to).inserted else { return false }
            return reaches(edge.from, edge.to, skipping: edge)
        }
    }

    // MARK: 台帳への問い合わせ(Skill)

    /// 前提をたどる: 未定着の前提を、何段先かと一緒に(WITH RECURSIVE)。
    static func unmasteredPrerequisites(db: Database, skillID: String, maxDepth: Int = 8) throws -> [(id: String, name: String, status: String, depth: Int)] {
        let rows = try Row.fetchAll(db, sql: """
            WITH RECURSIVE prereq(id, depth) AS (
                SELECT requires_skill_id, 1 FROM timeline_skill_edges WHERE skill_id = ? AND relation = 'prerequisite' AND requires_skill_id != skill_id
                UNION
                SELECT e.requires_skill_id, p.depth + 1 FROM timeline_skill_edges e JOIN prereq p ON e.skill_id = p.id
                WHERE e.relation = 'prerequisite' AND e.requires_skill_id != e.skill_id AND p.depth < ?
            )
            SELECT s.id, s.name, s.status, MIN(p.depth) AS depth FROM prereq p JOIN timeline_skills s ON s.id = p.id
            WHERE s.status != 'mastered' AND s.replaced_by = '[]'
            GROUP BY s.id ORDER BY depth, s.name
            """, arguments: [skillID, maxDepth])
        return rows.map { (id: $0["id"], name: $0["name"], status: $0["status"], depth: $0["depth"]) }
    }

    /// すべての前提(定着しているかに関係なく)。
    static func allPrerequisites(db: Database, skillID: String, maxDepth: Int = 8) throws -> [(id: String, depth: Int)] {
        let rows = try Row.fetchAll(db, sql: """
            WITH RECURSIVE prereq(id, depth) AS (
                SELECT requires_skill_id, 1 FROM timeline_skill_edges WHERE skill_id = ? AND relation = 'prerequisite' AND requires_skill_id != skill_id
                UNION
                SELECT e.requires_skill_id, p.depth + 1 FROM timeline_skill_edges e JOIN prereq p ON e.skill_id = p.id
                WHERE e.relation = 'prerequisite' AND e.requires_skill_id != e.skill_id AND p.depth < ?
            )
            SELECT id, MIN(depth) AS depth FROM prereq GROUP BY id ORDER BY depth
            """, arguments: [skillID, maxDepth])
        return rows.map { (id: $0["id"], depth: $0["depth"]) }
    }

    /// 典型的な誤解を引く: その点と、その前提に付いた誤解。
    static func misconceptions(db: Database, skillID: String) throws -> [(skill: String, note: String)] {
        let ids = [skillID] + (try allPrerequisites(db: db, skillID: skillID, maxDepth: 2).map(\.id))
        var result: [(skill: String, note: String)] = []
        for id in ids {
            let rows = try Row.fetchAll(db, sql: "SELECT e.note, s.name FROM timeline_skill_edges e JOIN timeline_skills s ON s.id = e.skill_id WHERE e.skill_id = ? AND e.relation = 'misconception'", arguments: [id])
            result += rows.map { (skill: $0["name"], note: $0["note"]) }
        }
        return result
    }

    /// 過去の解答: その点を使ったカードの直近5回(種類だけでなく、書いたもの・詳細も)。
    static func history(db: Database, skillID: String, limit: Int = 5) throws -> [LedgerJSON] {
        let byID = Dictionary(uniqueKeysWithValues: try TimelineCardRecord.fetchAll(db).map { ($0.id, $0) })
        let attempts = try TimelineAttemptRecord.order(Column("created_at").desc).fetchAll(db)
            .filter { attempt in
                guard attempt.verdict != "grading", let card = byID[attempt.cardId] else { return false }
                return attempt.skillIds.map { $0.contains(skillID) } ?? card.skills.contains(skillID)
            }
            .prefix(limit)
        return attempts.map { attempt in
            let card = byID[attempt.cardId]!
            return .object([
                "attempt_id": .string(attempt.id),
                "prompt": .string(card.prompt + (card.math.isEmpty ? "" : " " + card.math)),
                "verdict": .string(attempt.grade ?? attempt.verdict), "skill_result": attempt.skillMarks?[skillID].map(LedgerJSON.string) ?? .null,
                "errors": attempt.errors, "learner_answer": .string(attempt.learnerAnswer),
                "notes": .string(attempt.notes ?? ""), "transcript": .string(attempt.transcript ?? ""), "review": .string(attempt.reviewNotes ?? ""),
                "date": .string(TimelineRules.day(attempt.createdAt) ?? ""), "type_name": .string(card.typeName),
            ])
        }
    }

    /// 組み合わせを確かめる: それぞれの ○ の数と、両方を使う問題の結果。
    static func combination(db: Database, skillID: String, otherSkillID: String) throws -> LedgerJSON {
        let cards = try TimelineCardRecord.fetchAll(db)
        let attempts = Dictionary(grouping: try TimelineAttemptRecord.fetchAll(db), by: \.cardId)
        func tally(_ predicate: (TimelineCardRecord) -> Bool) -> (correct: Int, wrong: Int) {
            var correct = 0, wrong = 0
            for card in cards where predicate(card) {
                for attempt in attempts[card.id] ?? [] {
                    if attempt.verdict == "correct" { correct += 1 } else if attempt.verdict == "wrong" { wrong += 1 }
                }
            }
            return (correct, wrong)
        }
        let a = tally { $0.skills.contains(skillID) && !$0.skills.contains(otherSkillID) }
        let b = tally { $0.skills.contains(otherSkillID) && !$0.skills.contains(skillID) }
        let both = tally { $0.skills.contains(skillID) && $0.skills.contains(otherSkillID) }
        return .object([
            skillID: .object(["correct": .number(Double(a.correct)), "wrong": .number(Double(a.wrong))]),
            otherSkillID: .object(["correct": .number(Double(b.correct)), "wrong": .number(Double(b.wrong))]),
            "both": .object(["correct": .number(Double(both.correct)), "wrong": .number(Double(both.wrong))]),
        ])
    }

    /// `struis.timeline_query` の 1 回分(結果は文にして返す)。
    static func query(db: Database, arguments: [String: LedgerJSON]) throws -> String {
        let query = arguments["query"]?.stringValue ?? ""
        let skillID = arguments["skill_id"]?.stringValue ?? ""
        let name = try TimelineSkillRecord.fetchOne(db, key: skillID)?.name ?? skillID
        switch query {
        case "prerequisites":
            let rows = try unmasteredPrerequisites(db: db, skillID: skillID)
            if rows.isEmpty { return "「\(name)」の前提はすべて定着しています。" }
            return "「\(name)」の未定着の前提: " + rows.map { "\($0.name)(\($0.id)、\(statusLabels[$0.status] ?? $0.status)、\($0.depth)段先)" }.joined(separator: "、")
        case "misconceptions":
            let rows = try misconceptions(db: db, skillID: skillID)
            if rows.isEmpty { return "「\(name)」に関係する誤解は、まだ記録がありません。" }
            return "「\(name)」に関係する誤解: " + rows.map { "\($0.skill): \($0.note)" }.joined(separator: " / ")
        case "history":
            let rows = try history(db: db, skillID: skillID)
            if rows.isEmpty { return "「\(name)」の解答はまだありません。" }
            return "「\(name)」の直近の解答(新しい順): " + TurnComposer.dump(.array(rows))
        case "combination":
            let other = arguments["other_skill_id"]?.stringValue ?? ""
            return "組み合わせの記録: " + TurnComposer.dump(try combination(db: db, skillID: skillID, otherSkillID: other))
        case "sql":
            return try sql(db: db, arguments["sql"]?.stringValue ?? "")
        default:
            return "query は sql・prerequisites・misconceptions・history・combination のどれかです。"
        }
    }

    static let sqlRowLimit = 200
    static let sqlCellLimit = 4000

    /// 読み取りの SQL(SELECT か WITH)。書き込みは台帳の読み取りの接続が断る。結果は 1 行 1 つの JSON。
    static func sql(db: Database, _ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.prefix(6).lowercased()
        guard head.hasPrefix("select") || head.hasPrefix("with") else { return "SELECT か WITH で始まる読み取りの SQL だけを実行できます。" }
        do {
            let cursor = try Row.fetchCursor(db, sql: trimmed)
            var lines: [String] = []
            while let row = try cursor.next() {
                guard lines.count < sqlRowLimit else { lines.append("(\(sqlRowLimit) 行で打ち切りました)"); break }
                var object: [String: LedgerJSON] = [:]
                for (column, value) in row {
                    switch value.storage {
                    case .null: object[column] = .null
                    case .int64(let number): object[column] = .number(Double(number))
                    case .double(let number): object[column] = .number(number)
                    case .string(let string): object[column] = .string(string.count > sqlCellLimit ? String(string.prefix(sqlCellLimit)) + "…" : string)
                    case .blob: object[column] = .string("(blob)")
                    }
                }
                lines.append(TurnComposer.dump(.object(object)))
            }
            return lines.isEmpty ? "(0 行)" : lines.joined(separator: "\n")
        } catch {
            return "SQL を実行できませんでした: \(error)"
        }
    }

    /// native tool の定義(タイムラインのターンだけに出す)。
    nonisolated static var toolDefinition: JSONObject {
        ["type": "function", "name": "timeline_query",
         "description": "Read the learner's ledger on this device. query=sql runs one read-only SELECT/WITH statement. The other queries take skill_id (prerequisites, misconceptions, history, combination with other_skill_id).",
         "inputSchema": ["type": "object", "properties": [
            "query": ["type": "string", "enum": ["sql", "prerequisites", "misconceptions", "history", "combination"]],
            "sql": ["type": "string"], "skill_id": ["type": "string"], "other_skill_id": ["type": "string"],
         ], "required": ["query"], "additionalProperties": false]]
    }

    /// 見直しなどで使う、台帳に書く tool(採点・出題・見直しで同じ定義にして、キャッシュの先頭を揃える)。
    nonisolated static var writeToolDefinitions: [JSONObject] {
        [
            ["type": "function", "name": "timeline_add_card",
             "description": "Put one checking problem at the position the learner solves next.",
             "inputSchema": ["type": "object", "properties": [
                "prompt": ["type": "string"], "math": ["type": "string", "description": "LaTeX"], "question": ["type": "string"],
                "answer_key": ["type": "string"], "skill_ids": ["type": "array", "items": ["type": "string"]], "level": ["type": "integer"],
                "note": ["type": "string", "description": "Why this problem (kept in the ledger)."],
             ], "required": ["prompt", "answer_key", "skill_ids", "note"], "additionalProperties": false]],
            ["type": "function", "name": "timeline_ask",
             "description": "Ask the learner to choose one option (for example how to read their handwriting). Shown next; the choice appears in today's answers.",
             "inputSchema": ["type": "object", "properties": [
                "question": ["type": "string"], "options": ["type": "array", "items": ["type": "string"]], "about_attempt_id": ["type": "string"],
             ], "required": ["question", "options"], "additionalProperties": false]],
            ["type": "function", "name": "timeline_revise",
             "description": "Withdraw an earlier judgement and correct it: the grade of an answer and optionally the result per skill.",
             "inputSchema": ["type": "object", "properties": [
                "attempt_id": ["type": "string"], "grade": ["type": "string", "enum": ["correct", "partial", "wrong"]],
                "skill_results": ["type": "array", "items": ["type": "object", "properties": [
                    "skill_id": ["type": "string"], "result": ["type": "string", "enum": ["correct", "wrong"]],
                ], "required": ["skill_id", "result"], "additionalProperties": false]],
                "note": ["type": "string"],
             ], "required": ["attempt_id", "grade", "note"], "additionalProperties": false]],
            ["type": "function", "name": "timeline_notice",
             "description": "Show the learner a short message card next (for example that an earlier judgement was corrected).",
             "inputSchema": ["type": "object", "properties": [
                "text": ["type": "string"], "about_attempt_id": ["type": "string"],
             ], "required": ["text"], "additionalProperties": false]],
        ]
    }
}

/// 知識グラフをいつ頼むか(2026-10-24 の見直し)。「もう頼んだか」は台帳の `timeline_batches` の行で決める(起動し直しても
/// 消えない)。失敗した依頼も頼んだ扱いにして、自動では頼み直さない(作り直しは今ある「1回だけ」で終わり)。
nonisolated enum TimelineGraphSchedule {
    nonisolated enum Request: Equatable, Sendable {
        /// タイムラインを初めて開いた時の構築。
        case build
        /// 新しい単元ができた時の、その単元の分。
        case extend(unitID: String)
        /// アプリが直した行が溜まった時の見直し(対象の変更 ID の一覧)。
        case review(changeIDs: [String])
    }

    /// 点の単元。小単元 ID を持つ点は、その小単元が属する単元の点として扱う。
    static func unitID(of skill: TimelineSkillRecord, workbook: WorkbookMachine) -> String? {
        guard let id = skill.unitId else { return nil }
        return workbook.subunits[id]?.unitId ?? id
    }

    /// 依頼の `units` に入っていた単元(前の版は単元の JSON、今の版は ID の文字列)。
    static func unitIDs(in request: LedgerJSON) -> Set<String> {
        var ids = Set((request["units"]?.arrayValue ?? []).compactMap { $0.stringValue ?? $0["id"]?.stringValue })
        if let unit = request["unit"]?["id"]?.stringValue ?? request["unit_id"]?.stringValue { ids.insert(unit) }
        return ids
    }

    /// 単元の分をもう頼んだ単元(構築の依頼に入っていた単元と、単元の分の依頼)。
    static func requestedUnits(_ timeline: TimelineMachine) -> Set<String> {
        timeline.batches.values.filter { $0.purpose == "graph_build" || $0.purpose == "graph_extend" }.reduce(into: Set<String>()) { $0.formUnion(unitIDs(in: $1.request)) }
    }

    static func changeIDs(in request: LedgerJSON) -> [String] {
        (request["change_ids"]?.arrayValue ?? []).compactMap(\.stringValue).sorted()
    }

    /// 見直しに渡す、まだ見直していないアプリの変更。
    static func pendingReviewChanges(_ timeline: TimelineMachine) -> [String] {
        timeline.changes.values.filter { !$0.reviewed && $0.source == "app" }.map(\.id).sorted()
    }

    /// 1段下りる依頼を、その点でもう出したか。
    static func descendRequested(_ timeline: TimelineMachine, skillID: String) -> Bool {
        timeline.batches.values.contains { $0.purpose == "graph_descend" && $0.request["skill_id"]?.stringValue == skillID }
    }

    /// その依頼をもう出したか、グラフの依頼が走っている最中か(行を書く書き込みの中で確かめ直す)。
    static func isBlocked(_ request: Request, timeline: TimelineMachine) -> Bool {
        if timeline.batches.values.contains(where: { $0.purpose.hasPrefix("graph") && $0.status == "requested" }) { return true }
        switch request {
        case .build: return timeline.batches.values.contains { $0.purpose == "graph_build" }
        case .extend(let unitID): return requestedUnits(timeline).contains(unitID)
        case .review(let ids): return timeline.batches.values.contains { $0.purpose == "graph_review" && changeIDs(in: $0.request) == ids }
        }
    }

    /// 次に頼むもの(無ければ nil)。タイムラインを開いた時・単元ができた時・採点結果を反映した時だけ呼ぶ。
    static func next(timeline: TimelineMachine, workbook: WorkbookMachine) -> Request? {
        let units = workbook.orderedUnits()
        guard !units.isEmpty else { return nil }
        // 頼んでいる最中のグラフの依頼があれば、終わるまで次を頼まない。
        guard !timeline.batches.values.contains(where: { $0.purpose.hasPrefix("graph") && $0.status == "requested" }) else { return nil }
        let built = timeline.batches.values.contains { $0.purpose == "graph_build" }
        let graphSkills = timeline.activeSkills.filter { $0.source != "batch" }
        if !built {
            // 構築の行が無く、グラフも無い: 初めて開いた。
            return graphSkills.isEmpty ? .build : nil
        }
        let requested = requestedUnits(timeline)
        let covered = Set(graphSkills.compactMap { unitID(of: $0, workbook: workbook) })
        if let unit = units.first(where: { !requested.contains($0.id) && !covered.contains($0.id) }) {
            return .extend(unitID: unit.id)
        }
        if timeline.needsReview {
            let ids = pendingReviewChanges(timeline)
            let asked = timeline.batches.values.contains { $0.purpose == "graph_review" && changeIDs(in: $0.request) == ids }
            if !ids.isEmpty, !asked { return .review(changeIDs: ids) }
        }
        return nil
    }
}

/// `struis.timeline_query` が読む台帳(起動時に `LearnerData` が設定する)。
nonisolated enum TimelineQueryHost {
    nonisolated(unsafe) private static var ledger: Ledger?
    private static let lock = NSLock()

    static func install(_ ledger: Ledger) {
        lock.withLock { self.ledger = ledger }
    }

    static func handle(_ arguments: JSONObject) async -> String {
        guard let ledger = lock.withLock({ self.ledger }) else { return "台帳を読めませんでした。" }
        let args = LedgerJSON(any: arguments).objectValue ?? [:]
        do {
            return try await ledger.read { db in try TimelineGraph.query(db: db, arguments: args) }
        } catch {
            return "台帳を読めませんでした。"
        }
    }

    static let writeToolNames: Set<String> = ["timeline_add_card", "timeline_ask", "timeline_revise", "timeline_notice"]

    /// 台帳に書く tool(確かめの 1 問・生徒に選ばせる問い・判定の取り消し・お知らせ)。結果は文にして返す。
    static func handleWrite(name: String, arguments: JSONObject) async -> (success: Bool, text: String) {
        guard let ledger = lock.withLock({ self.ledger }) else { return (false, "台帳に書けませんでした。") }
        let args = LedgerJSON(any: arguments).objectValue ?? [:]
        do {
            return try await ledger.commit { db in
                var machine = try TimelineMachine(loading: db)
                let result = TimelineWriteTools.apply(name: name, arguments: args, machine: &machine)
                return (machine.events, result)
            }
        } catch {
            return (false, "台帳に書けませんでした: \(error)")
        }
    }
}

/// 台帳に書く tool の中身(端末の台帳だけを変える。テストから直接呼べるように、台帳の読み書きから分けておく)。
nonisolated enum TimelineWriteTools {
    static func apply(name: String, arguments args: [String: LedgerJSON], machine: inout TimelineMachine) -> (success: Bool, text: String) {
        func text(_ key: String) -> String { args[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        switch name {
        case "timeline_add_card":
            guard !text("prompt").isEmpty || !text("math").isEmpty else { return (false, "prompt か math が要ります。") }
            let id = machine.addReviewCard(prompt: text("prompt"), math: text("math"), question: text("question"), answerKey: text("answer_key"),
                                           skillIDs: (args["skill_ids"]?.arrayValue ?? []).compactMap(\.stringValue), level: args["level"]?.intValue ?? 1, note: text("note"))
            return (true, "カード \(id) を、生徒が次に解く位置に入れました。")
        case "timeline_ask":
            let options = (args["options"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
            guard !text("question").isEmpty, options.count >= 2 else { return (false, "question と 2 つ以上の options が要ります。") }
            let about = text("about_attempt_id")
            let id = machine.addAsk(question: text("question"), options: options, aboutAttemptID: about.isEmpty ? nil : about)
            return (true, "問い \(id) を、次に出す位置に入れました。生徒が選んだものは今日の答案の一覧に載ります。")
        case "timeline_revise":
            let marks = args["skill_results"]?.arrayValue.map { items in
                Dictionary(items.compactMap { item -> (String, String)? in
                    guard let id = item["skill_id"]?.stringValue, let result = item["result"]?.stringValue else { return nil }
                    return (id, result)
                }, uniquingKeysWith: { _, last in last })
            }
            if let problem = machine.revise(attemptID: text("attempt_id"), grade: text("grade"), marks: marks, note: text("note")) {
                return (false, problem)
            }
            return (true, "答案 \(text("attempt_id")) の判定を直しました。")
        case "timeline_notice":
            guard !text("text").isEmpty else { return (false, "text が要ります。") }
            let about = text("about_attempt_id")
            let id = machine.addNotice(text: text("text"), aboutAttemptID: about.isEmpty ? nil : about)
            return (true, "お知らせ \(id) を、次に出す位置に入れました。")
        default:
            return (false, "unsupported tool \(name)")
        }
    }
}
