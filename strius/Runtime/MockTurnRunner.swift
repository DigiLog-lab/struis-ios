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

    /// 返事の本文を流した後、後ろの記録(進み具合)を書いている時間(`STRUIS_MOCK_TAIL_DELAY_MS`)。0 なら本文も流さない。
    /// 本物のモデルが長い記録を書いている間の画面(送信・「先に進む」)を確かめる時に延ばす。
    nonisolated private static var tailDelay: Int {
        Int(ProcessInfo.processInfo.environment["STRUIS_MOCK_TAIL_DELAY_MS"] ?? "") ?? 0
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
            if Self.tailDelay > 0, await streamWithSlowTail(plan, text: text, progress: progress) {
                return TurnOutcome(
                    planID: plan.id, round: plan.round, status: .interrupted, codexThreadID: plan.thread.codexThreadID, codexTurnID: nil,
                    finalText: "", executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: Self.tailDelay
                )
            }
        case .lunaLookup: text = Self.json(["findings": [], "missing_information": [], "uncertainties": [], "failure_reasons": []])
        case .threadFork, .threadInject: text = ""
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
    private func streamWithSlowTail(_ plan: TurnPlan, text: String, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async -> Bool {
        func delta(_ value: String) {
            progress(TurnProgressEvent(kind: .replyDelta(itemID: "msg_mock_\(plan.id)", text: value), label: "返事を書いています", progressID: nil, allowDuplicate: true))
        }
        let split = text.range(of: "\n<struis_")?.lowerBound ?? text.endIndex
        delta(String(text[..<split]))
        let ready = "\n<struis_workbook_example_ready/>"
        if text.contains(ready) { delta(ready) }
        delta("\n<struis_progress_update>\n{\"goals\": [{\"title\": \"頂点の座標を求める\", \"status\": ")
        let deadline = Date().addingTimeInterval(Double(Self.tailDelay) / 1000)
        while Date() < deadline {
            if interrupted.remove(plan.id) != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return interrupted.remove(plan.id) != nil
    }

    // MARK: - Canned answers

    nonisolated private static func request(from text: String) -> JSONObject {
        guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? JSONObject else { return [:] }
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
}
#endif
