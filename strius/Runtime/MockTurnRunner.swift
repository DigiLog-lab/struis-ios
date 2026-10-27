#if DEBUG
import Foundation

/// Deterministic replies for turns in the simulator (`STRUIS_DEVICE_TURNS=mock`),
/// a port of `backend/src/struis/services/workbook_mock.py`. The Engine, the
/// ledger and every screen run their real code paths; only the model answer is
/// canned. Never used in release builds.
actor MockTurnRunner: TurnRunning {
    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["STRUIS_DEVICE_TURNS"] == "mock"
    }

    private var counter = 0
    private var interrupted: Set<String> = []
    /// 記録を書いた返事の数(返事ごとの記録の時間を選ぶ)。
    private var tails = 0
    /// UI テストが記録を終わらせる合図を待つ返事(`STRUIS_CI_TAIL_TOKEN`・`STRUIS_CI_TAIL_GATES` を渡した時だけ作る)。
    private var benchmarkGates: [CIBenchmarkTailGate] = []

    /// 返事の本文を流した後、後ろの記録(進み具合)を書いている時間(`STRUIS_MOCK_TAIL_DELAY_MS`)。0 なら本文も流さない。
    /// 本物のモデルが長い記録を書いている間の画面(送信・「先に進む」)を確かめる時に延ばす。
    /// 「40000,3000」のようにカンマで並べると、返事の順に使う(最後の値をその後の返事にも使う)。1 つ目の返事の記録の間に
    /// 送る場面を、Simulator の速さに左右されずに作る(並べた返事の記録は短くして待ち時間を延ばさない)。
    nonisolated static func tailDelay(forReply index: Int, setting: String?) -> Int {
        let values = (setting ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let last = values.last else { return 0 }
        return index < values.count ? values[index] : last
    }

    nonisolated private static var tailDelaySetting: String? {
        ProcessInfo.processInfo.environment["STRUIS_MOCK_TAIL_DELAY_MS"]
    }

    /// 返事までの時間(`STRUIS_MOCK_TURN_DELAY_MS`。待ちの演出を目で確かめる時に延ばす)。
    nonisolated private static var delay: Int {
        Int(ProcessInfo.processInfo.environment["STRUIS_MOCK_TURN_DELAY_MS"] ?? "") ?? 250
    }

    func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome {
        try? await Task.sleep(for: .milliseconds(plan.kind == .threadFork || plan.kind == .threadInject ? 50 : Self.delay))
        counter += 1
        let request = Self.request(from: plan.turn?.text ?? "")
        let text: String
        switch plan.kind {
        case .workbookGrading: text = Self.json(Self.grading(request))
        case .workbookSet: text = Self.json(Self.set(request))
        case .workbookUnit: text = Self.json(Self.unit(request))
        case .chat:
            progress(TurnProgressEvent(label: "説明を組み立てます", progressID: nil, allowDuplicate: false))
            text = Self.chat(plan)
            let tailDelay = Self.tailDelay(forReply: tails, setting: Self.tailDelaySetting)
            if tailDelay > 0 {
                tails += 1
                if try await streamWithSlowTail(plan, text: text, tailDelay: tailDelay, replyIndex: tails - 1, progress: progress) {
                    return TurnOutcome(
                        planID: plan.id, round: plan.round, status: .interrupted, codexThreadID: plan.thread.codexThreadID, codexTurnID: nil,
                        finalText: "", executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: tailDelay
                    )
                }
            }
        case .lunaLookup: text = Self.json(["findings": [], "missing_information": [], "uncertainties": [], "failure_reasons": []])
        case .threadFork, .threadInject: text = ""
        case .timelineBatch: text = Self.json(Self.timelineBatch(request, round: counter))
        case .timelineGrading: text = Self.json(Self.timelineGrading(request))
        case .timelineGraph: text = Self.json(Self.timelineGraph(request))
        case .timelineReview: text = Self.json(["skill_results": [], "notes": ""])
        }
        let threadID = plan.thread.codexThreadID ?? "thr_mock_\(UUID().uuidString.prefix(16).lowercased())"
        return TurnOutcome(
            planID: plan.id, round: plan.round, status: .completed, codexThreadID: threadID,
            codexTurnID: "turn_mock_\(counter)", finalText: text,
            executions: [.object(["execution_id": .string(UUID().uuidString), "task_type": .string(plan.kind.rawValue), "status": .string("completed"), "requested_model": .string(plan.thread.model), "billing_source": .string("byo_chatgpt")])],
            rateLimits: nil, files: [], error: nil, elapsedMs: 250
        )
    }

    func interrupt(planID: String) async { interrupted.insert(planID) }

    /// 本文を流し、準備OK(あれば本文のすぐ後)と記録の書き出しを流してから、記録を書いている時間だけ待つ。止められたら true。
    private func streamWithSlowTail(
        _ plan: TurnPlan, text: String, tailDelay: Int, replyIndex: Int, progress: @escaping @Sendable (TurnProgressEvent) -> Void
    ) async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let indices = Set((environment["STRUIS_CI_TAIL_GATES"] ?? "").split(separator: ",").compactMap { Int($0) })
        let gate = environment["STRUIS_CI_TAIL_TOKEN"].flatMap { token in
            indices.contains(replyIndex) ? CIBenchmarkTailGate(name: "com.digiloglab.strius.ci-tail.\(token).\(replyIndex)") : nil
        }
        if let gate { benchmarkGates.append(gate) }
        func delta(_ value: String) {
            progress(TurnProgressEvent(kind: .replyDelta(itemID: "msg_mock_\(plan.id)", text: value), label: "返事を書いています", progressID: nil, allowDuplicate: true))
        }
        let split = text.range(of: "\n<struis_")?.lowerBound ?? text.endIndex
        delta(String(text[..<split]))
        let ready = "\n<struis_workbook_example_ready/>"
        if text.contains(ready) { delta(ready) }
        delta("\n<struis_progress_update>\n{\"goals\": [{\"title\": \"頂点の座標を求める\", \"status\": ")
        let deadline = Date().addingTimeInterval(gate == nil ? Double(tailDelay) / 1000 : 180)
        while gate.map({ !$0.isReleased }) ?? (Date() < deadline) {
            if interrupted.remove(plan.id) != nil { return true }
            if gate != nil, Date() >= deadline {
                throw NSError(domain: "StruisCIBenchmark", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "UI test did not release reply \(replyIndex)"])
            }
            try await Task.sleep(for: .milliseconds(gate == nil ? 100 : 10))
        }
        return interrupted.remove(plan.id) != nil
    }

    // MARK: - Canned answers

    nonisolated private static func request(from text: String) -> JSONObject {
        // タイムラインの発話は「今回の仕事」の後ろに「# 今回の材料」と JSON を置く。
        let body = text.range(of: "# 今回の材料").map { String(text[$0.upperBound...]) } ?? text
        guard let data = body.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? JSONObject else { return [:] }
        return value
    }

    nonisolated private static func json(_ object: JSONObject) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    nonisolated(unsafe) private static var photosBySet: [String: Int] = [:]
    nonisolated private static let photosLock = NSLock()

    nonisolated static func grading(_ request: JSONObject) -> JSONObject {
        let subunits = request["subunits"] as? [JSONObject] ?? []
        let problems = subunits.flatMap { $0["problems"] as? [JSONObject] ?? [] }
        if problems.isEmpty {
            return [
                "readable": true,
                "items": [["label": "問1", "prompt_text": "y = x^2 - 4x + 3 の頂点の座標を求めよ", "matched_problem_id": NSNull(), "verdict": "correct", "error_tag": "", "note": "平方完成が正しい"]],
                "candidates": [],
                "new_subunit": ["unit_title": "二次関数", "subunit_title": "頂点の座標が求められる", "outcome": "平方完成で頂点を求められる", "n": 5, "scoring_unit": "1問ごとに正誤"],
                "note": "",
            ]
        }
        let scope = request["scope"] as? JSONObject ?? [:]
        if scope["mode"] as? String == "all_active", problems.count > 1 {
            return [
                "readable": true,
                "items": [["label": "問1", "prompt_text": problems[0]["prompt"] ?? "", "matched_problem_id": NSNull(), "verdict": "correct", "error_tag": "", "note": "計算は合っている"]],
                "candidates": problems.prefix(3).map { ["problem_id": $0["id"] ?? "", "reason": "同じ形の式"] },
                "new_subunit": NSNull(),
                "note": "",
            ]
        }
        var items: [JSONObject] = []
        var shown = Array(problems.enumerated())
        let lastOnly = ProcessInfo.processInfo.environment["STRUIS_MOCK_GRADING_LAST_ONLY"] == "1"
        if lastOnly, let last = shown.last {
            // 問題の画面から 1 問だけを撮った時(いちばん後ろの 1 問だけが写っていて、正解)。
            shown = [last]
        }
        if scope["mode"] as? String == "set", let setID = scope["set_id"] as? String,
           let perPhoto = Int(ProcessInfo.processInfo.environment["STRUIS_MOCK_GRADING_PER_PHOTO"] ?? ""), perPhoto > 0 {
            // 一枚を何枚の写真に分けて撮った時(分割採点): 1 枚の写真には一枚の問題が perPhoto 問ずつ順に写っている。
            // まとめて撮った答案(一括採点)は、そのページ数ぶんの写真を 1 回で判定する。
            let pages = max(1, request["page_count"] as? Int ?? 1)
            let photo = photosLock.withLock { () -> Int in
                let index = photosBySet[setID, default: 0]
                photosBySet[setID] = index + pages
                return index
            }
            shown = Array(shown.dropFirst(photo * perPhoto).prefix(perPhoto * pages))
        }
        for (index, problem) in shown {
            let wrong = !lastOnly && problems.count >= 3 && index == problems.count - 1
            items.append([
                "label": "問\(index + 1)", "prompt_text": problem["prompt"] ?? "", "matched_problem_id": problem["id"] ?? "",
                "verdict": wrong ? "wrong" : "correct", "error_tag": wrong ? "符号ミス" : "", "note": wrong ? "符号を確認" : "手順が正しい",
            ])
        }
        return ["readable": true, "items": items, "candidates": [], "new_subunit": NSNull(), "note": ""]
    }

    nonisolated static func set(_ request: JSONObject) -> JSONObject {
        let count = request["count"] as? Int ?? 1
        let title = (request["subunit"] as? JSONObject)?["title"] as? String ?? "問題"
        let existing = (request["existing_prompts"] as? [Any])?.count ?? 0
        var problems: [JSONObject] = []
        for index in 0..<count {
            let k = existing + index + 1
            problems.append([
                "prompt": "\(title): y = x^2 - \(2 * k)x + \(k * k - 1) の頂点の座標を求めよ",
                "answer_key": "(\(k), -1)",
                "checkpoints": ["平方完成", "頂点の読み取り"],
            ])
        }
        return ["problems": problems]
    }

    nonisolated static func unit(_ request: JSONObject) -> JSONObject {
        let text = request["request"] as? String ?? ""
        let unitTitle = text.contains("二次") ? "二次関数" : (text.isEmpty ? "学習単元" : String(text.prefix(20)))
        return [
            "unit_title": unitTitle,
            "outcome": "\(unitTitle)の基本問題が自力で解ける",
            "subunits": [
                ["title": "頂点の座標が求められる", "outcome": "平方完成で頂点を求める", "n": 5, "scoring_unit": "1問ごとに正誤"],
                ["title": "グラフの平行移動がわかる", "outcome": "移動後の式を書ける", "n": 5, "scoring_unit": "1問ごとに正誤"],
                ["title": "最大値・最小値が求められる", "outcome": "定義域つきで最大最小を求める", "n": 6, "scoring_unit": "1問ごとに正誤"],
            ],
        ]
    }

    /// A learner-facing reply with valid private blocks: memory `NO_UPDATE` and a
    /// `not_learning` progress update whose quotes appear in the reply.
    nonisolated static func chat(_ plan: TurnPlan) -> String {
        let text = plan.turn?.text ?? ""
        let revision = Self.baseRevision(in: text)
        let learner = Self.learnerMessage(in: text)
        var reply = "いいですね。まず、今書いた式の中で自信がある行と、少し怪しい行を分けてみましょう。"
        var extra = ""
        if learner.contains("[Struis からの単元づくりの依頼") {
            // 単元づくりの最初の問いへの答えがそろった(§3.3): 問いを重ねず、全体像の提案を出す。
            reply = "全体像のカードを出すね。よければ「はじめる」を押してね。"
            let answers = learner.components(separatedBy: "\n").filter { $0.hasPrefix("- ") && $0.contains("→") }.joined(separator: " ")
            extra = "\n<struis_workbook_proposal>{\"request\": \"\(answers.replacingOccurrences(of: "\"", with: ""))\"}</struis_workbook_proposal>"
        } else if learner.contains("[Struis からの起動メッセージ") {
            // 学習者が打つ前にモデルが話し始める(§13.12 / §13.13)。
            if learner.contains("「単元を作る」") {
                reply = "こんにちは。いま学校では何を勉強していますか？"
            } else if learner.contains("段階 2「例題」") {
                reply = "例題を一緒に解こう。まず式を平方完成の形に直すね。\n\n1 手目: $x^2 - 4x$ を $(x - 2)^2 - 4$ にする。\n\n次の 1 行をノートに書いて見せて。"
                extra = "\n<struis_workbook_example>{\"prompt\": \"y = x^2 - 4x + 3 の頂点の座標を求めよ\"}</struis_workbook_example>"
            } else {
                reply = "要点を話すね。この小単元では二次関数の頂点を求めます。\n\n- 全体像: 式を平方完成すると頂点が読める\n- 具体例: ボールを投げたときの一番高い点\n- できるようになること: 頂点の座標を自分で求める\n\n読み終えたら下の「先に進む」で例題へ進もう。"
            }
        } else if learner.contains("積分") {
            // 数式と強調の混じった返事(書いている途中・記録を書いている間の見え方を確かめる)。
            reply = "前の行までは合っています。残りの積分を計算する部分でつまずいているので、そこを見ていこう。\n\n**問題の箇所**\n\n$$\\int\\left(\\frac{1}{2}-\\sin^2 x\\right)dx=\\frac{1}{2}x-\\left(\\frac{1}{2}-\\frac{1}{2}\\cos 2x\\right)$$\n\nこの行では、$x$ をつけて $\\frac{1}{2}x$ にした最初の項だけが積分されています。$\\sin^2 x$ のほうは積分されず、$\\frac{1}{2}-\\frac{1}{2}\\cos 2x$ に書き換えただけになっています。\n\n**手がかり**\n\n$\\cos 2x$ は、このまま直接積分できます。"
        } else if learner.contains("できた") {
            // 段階 2 で学習者が例題を解けた(UI テスト用): 準備OKを出して「先に進む」を出させる(§13.13 の 5)。
            reply = "よくできました。類題へ進もう。下の「先に進む」を押してね。"
            extra = "\n<struis_workbook_example_ready/>"
        } else if learner.contains("予習") || learner.contains("一から") || learner.contains("学びたい") {
            extra = "\n<struis_workbook_proposal>{\"request\": \"\(learner.replacingOccurrences(of: "\"", with: ""))\"}</struis_workbook_proposal>"
        }
        let quote = reply.components(separatedBy: "。").first.map { $0 + "。" } ?? reply
        let update = json([
            "schema_version": 1, "base_revision": revision, "goals": [], "problems": [], "attempts": [],
            "current_goal_id": NSNull(), "disposition": "not_learning", "next_action": "", "waiting_for": NSNull(),
            "wait_reason": "", "waiting_problem_id": NSNull(), "return_stack": [], "reply_quotes": [quote],
        ])
        return reply + "\n<struis_memory_update>\nNO_UPDATE\n</struis_memory_update>\n<struis_progress_update>\n" + update + "\n</struis_progress_update>" + extra
    }

    nonisolated private static func baseRevision(in text: String) -> Int {
        guard let range = text.range(of: "\"revision\":") ?? text.range(of: "\"revision\": ") else { return 0 }
        let tail = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let digits = tail.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    nonisolated private static func learnerMessage(in text: String) -> String {
        guard let range = text.range(of: "The learner's current message:\n") else { return "" }
        let rest = text[range.upperBound...]
        // The message is followed by a blank line and the private desk context (memory etc.).
        let end = rest.range(of: "\n\n")?.lowerBound ?? rest.range(of: "\nStruis progress contract:")?.lowerBound ?? rest.endIndex
        var body = String(rest[..<end])
        if let viewEnd = body.range(of: "</struis_current_view>\n") { body = String(body[viewEnd.upperBound...]) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 学習タイムライン(Issue #46)

    /// 固定の知識グラフ(数学I・二次関数の最大と最小)。
    nonisolated static let timelineSkillIDs = ["quad.expand", "quad.vertex_form", "quad.axis_vs_range", "quad.case_split", "quad.min_moving_range"]

    nonisolated static func timelineGraph(_ request: JSONObject) -> JSONObject {
        let task = request["task"] as? String ?? "build"
        if task == "decompose" { return timelineDecomposition(request) }
        if task == "misconceptions" {
            let nodes = (request["nodes"] as? [JSONObject] ?? []).compactMap { $0["id"] as? String }
            return ["items": nodes.prefix(1).map { ["node_id": $0, "misconceptions": ["範囲の端だけを比べて、頂点を見落とす"]] }, "notes": ""]
        }
        if task == "review" {
            return ["nodes": [], "edges": [], "ops": [], "start_node_id": NSNull(), "notes": "見直し: 変更なし"]
        }
        let existing = Set((request["existing_nodes"] as? [JSONObject] ?? []).compactMap { $0["id"] as? String })
        let unitID = (request["unit"] as? JSONObject)?["id"] as? String
        let nodes: [JSONObject] = [
            ["id": "quad.expand", "name": "展開", "kind": "procedure", "unit_id": unitID ?? NSNull()],
            ["id": "quad.vertex_form", "name": "平方完成", "kind": "procedure", "unit_id": unitID ?? NSNull()],
            ["id": "quad.axis_vs_range", "name": "軸と範囲の位置", "kind": "concept", "unit_id": unitID ?? NSNull()],
            ["id": "quad.case_split", "name": "場合分け", "kind": "procedure", "unit_id": unitID ?? NSNull()],
            ["id": "quad.min_moving_range", "name": "範囲が動くときの最小値", "kind": "combination", "unit_id": unitID ?? NSNull()],
        ].filter { !existing.contains($0["id"] as! String) }
        let edges: [JSONObject] = [
            ["from": "quad.expand", "to": "quad.vertex_form", "relation": "prerequisite", "note": ""],
            ["from": "quad.vertex_form", "to": "quad.min_moving_range", "relation": "prerequisite", "note": ""],
            ["from": "quad.axis_vs_range", "to": "quad.min_moving_range", "relation": "prerequisite", "note": ""],
            ["from": "quad.case_split", "to": "quad.min_moving_range", "relation": "prerequisite", "note": ""],
            ["from": "quad.axis_vs_range", "to": "quad.axis_vs_range", "relation": "misconception", "note": "範囲の端だけを比べて頂点を見落とす"],
        ].filter { edge in nodes.contains { node in node["id"] as? String == (edge["to"] as? String) } }
        return ["nodes": nodes, "edges": edges, "ops": [], "start_node_id": nodes.isEmpty ? NSNull() : "quad.vertex_form", "notes": "固定のグラフ"]
    }

    /// 1段ずつ分解する(固定の答え)。一番上の点は二次関数の最大最小に、その下は前に習う内容として置くだけにする。
    nonisolated static func timelineDecomposition(_ request: JSONObject) -> JSONObject {
        let nodes = (request["nodes"] as? [JSONObject] ?? []).compactMap { $0["id"] as? String }
        let descend = request["mode"] as? String == "descend"
        let items: [JSONObject] = nodes.map { id in
            let uses: [JSONObject]
            if descend {
                uses = [["id": "\(id).basis", "name": "基礎の計算", "kind": "procedure", "in_unit": false]]
            } else if id.hasPrefix("goal.") {
                uses = [["id": "quad.vertex_form", "name": "平方完成", "kind": "procedure", "in_unit": true],
                        ["id": "quad.axis_vs_range", "name": "軸と範囲の位置", "kind": "concept", "in_unit": true]]
            } else if id == "quad.vertex_form" {
                uses = [["id": "quad.expand", "name": "展開", "kind": "procedure", "in_unit": false]]
            } else {
                uses = [["id": "quad.graph_axis", "name": "グラフの軸と頂点", "kind": "concept", "in_unit": false]]
            }
            return ["node_id": id, "problem": "y = 2x^2 - 8x + 3(0 ≤ x ≤ 3)の最小値", "steps": [["text": "平方完成して軸を出す", "uses": uses]]]
        }
        return ["items": items, "notes": ""]
    }

    nonisolated static func timelineBatch(_ request: JSONObject, round: Int) -> JSONObject {
        let allowed = Set(request["allowed_skill_ids"] as? [String] ?? [])
        let ids = timelineSkillIDs.filter { allowed.isEmpty || allowed.contains($0) }
        func skills(_ wanted: [String]) -> [String] { wanted.filter { ids.contains($0) } }
        let k = round % 4 + 2
        let steps = ["y = 2x^2 - 8x + 3", "= 2(x^2 - 4x) + 3", "= 2(x - 2)^2 - 5", "軸は x = 2", "最小値 -5(x = 2)"]
        let mistakes: [JSONObject] = [["step": 3, "wrong": "= 2(x - 2)^2 + 5"], ["step": 4, "wrong": "軸は x = -2"]]
        func card(_ kind: String, level: Int, skillIDs: [String], prompt: String, math: String, question: String, answer: String, answerExpr: String,
                  checks: [JSONObject], chain: Any, easier: Any, howto: Any = NSNull(), facts: JSONObject = ["answer_value": -5, "vertex": [2, -5], "axis": 2], seconds: Int = 60,
                  reason: Any = NSNull()) -> JSONObject {
            ["kind": kind, "level": level, "skills": skills(skillIDs), "type_name": "二次関数の最大最小", "prompt": prompt, "math": math, "question": question,
             "answer_key": answer, "answer_expr": answerExpr, "checks": checks, "checkpoints": ["平方完成 y = 2(x - 2)^2 - 5", "軸 x = 2 は範囲の中", "最小値 -5(x = 2)"],
             "common_mistakes": ["範囲の端だけを比べて、頂点を見落とす"], "steps": steps, "mistake_steps": mistakes, "estimated_seconds": seconds,
             "chain": chain, "easier": easier, "subunit_id": NSNull(), "facts": facts, "compare": NSNull(), "reason": reason, "howto": howto, "diagnostic": NSNull(),
             "reveal": (chain as? JSONObject)?["position"] as? Int == 3 ? "入試でよく出る形です。" : ""]
        }
        let easier: JSONObject = ["level": 1, "prompt": "次の放物線の最小値を求めなさい。", "math": "y = 2(x - 2)^2 - 5", "question": "最小値は？", "answer_key": "-5(x = 2)", "answer_expr": "-5", "checkpoints": ["最小値 -5"]]
        let howto: JSONObject = ["skill": "場合分け", "note": "軸が範囲のどこにあるかで、最小になる点が変わる", "diagram": [
            "kind": "range_vs_axis", "cases": [
                ["label": "a + 1 < 2", "position": "left", "min_at": "right_end"],
                ["label": "a ≤ 2 ≤ a + 1", "position": "straddle", "min_at": "vertex"],
                ["label": "2 < a", "position": "right", "min_at": "left_end"],
            ]]]
        let reason: JSONObject = ["question": "なぜ x = 0 で最大？", "options": ["軸から遠い端だから", "範囲の左端だから", "y 切片だから"], "answer_index": 0]
        let cards: [JSONObject] = [
            card("solve", level: 2, skillIDs: ["quad.vertex_form", "quad.axis_vs_range"], prompt: "次の関数の最大値と最小値を求めなさい。", math: "y = 2x^2 - 8x + 3 \\quad (0 \\le x \\le \(k + 1))",
                 question: "最大値と最小値は？", answer: "最小値 -5(x = 2)", answerExpr: "-5", checks: [["left": "2*x^2-8*x+3", "right": "2*(x-2)^2-5"]],
                 chain: ["position": 1, "total": 3, "changed": NSNull(), "previous": NSNull()], easier: easier, seconds: 120, reason: reason),
            card("solve", level: 3, skillIDs: ["quad.vertex_form", "quad.axis_vs_range"], prompt: "", math: "y = 2x^2 - 8x + 3",
                 question: "0 ≤ x ≤ a（a > 0）のとき、最小値は？", answer: "0 < a < 2 のとき 2a^2 - 8a + 3、2 ≤ a のとき -5", answerExpr: "",
                 checks: [["left": "2*2^2-8*2+3", "right": "-5"]], chain: ["position": 2, "total": 3, "changed": "a", "previous": "0 ≤ x ≤ \(k + 1)"], easier: easier, seconds: 180),
            card("sort", level: 2, skillIDs: ["quad.axis_vs_range"], prompt: "", math: "", question: "", answer: "", answerExpr: "", checks: [],
                 chain: NSNull(), easier: NSNull(), seconds: 20),
            card("solve", level: 4, skillIDs: ["quad.vertex_form", "quad.axis_vs_range", "quad.case_split"], prompt: "", math: "y = 2x^2 - 8x + 3",
                 question: "a ≤ x ≤ a + 1 のとき、最小値は？（a の式で）", answer: "a < 1 のとき 2a^2 - 4a - 3、1 ≤ a ≤ 2 のとき -5、2 < a のとき 2a^2 - 8a + 3", answerExpr: "",
                 checks: [["left": "2*(1+1)^2-8*(1+1)+3", "right": "-5"]], chain: ["position": 3, "total": 3, "changed": "a ≤ x ≤ a + 1", "previous": "0 ≤ x ≤ a"],
                 easier: easier, howto: howto, seconds: 300),
            card("order", level: 2, skillIDs: ["quad.vertex_form"], prompt: "y = 2x^2 - 8x + 3 の最小値", math: "", question: "", answer: "", answerExpr: "", checks: [],
                 chain: NSNull(), easier: NSNull(), seconds: 30),
        ]
        let rapid: [JSONObject] = (0..<3).map { i in
            let h = i + 1, v = (i + 2) * (i % 2 == 0 ? 1 : -1)
            return ["skill": ids.contains("quad.vertex_form") ? "quad.vertex_form" : "", "prompt": "頂点は？", "math": "y = 2(x - \(h))^2 + \(v)", "answer_key": "(\(h), \(v))", "answer_expr": "(\(h), \(v))"]
        }
        return ["reason": "平方完成が定着しているので、範囲つきの最大最小を続きで上げる", "cards": cards, "rapid": rapid, "wanted_prerequisites": [], "graph_ops": []]
    }

    nonisolated static func timelineGrading(_ request: JSONObject) -> JSONObject {
        let wrong = ProcessInfo.processInfo.environment["STRUIS_MOCK_TIMELINE_WRONG"] == "1"
        let key = request["answer_key"] as? String ?? ""
        return [
            "readable": true, "grade": wrong ? "wrong" : "correct",
            "learner_answer": request["target_vertex"] != nil ? "2(x-2)^2-5" : (wrong ? "-3" : key),
            "skill_ids": [], "transcript": wrong ? "y = 2(x-2)^2 - 5\n最小値 -3" : key, "notes": wrong ? "a ≥ 2 の場合を書いていません。" : "",
            "comment": wrong ? "a ≥ 2 の場合が抜けています。" : "", "key_suspect": false,
        ]
    }

}

/// XCTest からアプリへ、画面を変えずに届く合図(Darwin 通知)。最初の本文を流す前に登録し、
/// MockTurnRunner がアプリの終了まで持つ。
nonisolated private final class CIBenchmarkTailGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let name: String

    init(name: String) {
        self.name = name
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
                guard let observer else { return }
                let gate = Unmanaged<CIBenchmarkTailGate>.fromOpaque(observer).takeUnretainedValue()
                gate.lock.withLock { gate.released = true }
            }, name as CFString, nil, .deliverImmediately)
    }

    var isReleased: Bool { lock.withLock { released } }

    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(), CFNotificationName(rawValue: name as CFString), nil)
    }

}
#endif
