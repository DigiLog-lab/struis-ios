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
        let cards = try TimelineCardRecord.fetchAll(db).filter { $0.skills.contains(skillID) }
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let attempts = try TimelineAttemptRecord.order(Column("created_at").desc).fetchAll(db)
            .filter { byID[$0.cardId] != nil && $0.verdict != "grading" }
            .prefix(limit)
        return attempts.map { attempt in
            let card = byID[attempt.cardId]!
            return .object([
                "prompt": .string(card.prompt + (card.math.isEmpty ? "" : " " + card.math)),
                "verdict": .string(attempt.verdict), "errors": attempt.errors, "learner_answer": .string(attempt.learnerAnswer),
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
        default:
            return "query は prerequisites・misconceptions・history・combination のどれかです。"
        }
    }

    /// native tool の定義(タイムラインのターンだけに出す)。
    nonisolated static var toolDefinition: JSONObject {
        ["type": "function", "name": "timeline_query",
         "description": "Query the learner's knowledge graph and answer ledger on this device (prerequisites, misconceptions, history, combination). Use only after repeated wrong answers.",
         "inputSchema": ["type": "object", "properties": [
            "query": ["type": "string", "enum": ["prerequisites", "misconceptions", "history", "combination"]],
            "skill_id": ["type": "string"], "other_skill_id": ["type": "string"],
         ], "required": ["query", "skill_id"], "additionalProperties": false]]
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
}
