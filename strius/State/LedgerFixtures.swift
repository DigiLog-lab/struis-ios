#if DEBUG
import Foundation
import GRDB

/// シミュレータ既定(バックエンド無し)で画面を回すための最小の問題集を台帳に入れる。
/// 本番経路の代替ではなく、DEBUG + simulator の既定フィクスチャ。空の台帳にだけ入れる。
nonisolated enum LedgerFixtures {
    static func seedWorkbookIfEmpty(_ ledger: Ledger) async {
        let empty = (try? await ledger.read { db in try WorkbookUnitRecord.fetchCount(db) == 0 }) ?? false
        // 単元の無い初回(オンボーディング → 単元づくり)を確かめる時は入れない。
        guard empty, !ProcessInfo.processInfo.arguments.contains("-workbook-empty") else { return }
        let introduction = ProcessInfo.processInfo.arguments.contains("-workbook-model-stage")
        try? await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            var ids = ["unit-1", "sub-1", "sub-2", "sub-3"]
            machine.newID = { ids.isEmpty ? LedgerID.make() : ids.removeFirst() }
            machine.createUnit(
                title: "二次関数", outcome: "二次関数の基本問題が自力で解ける", source: "consult",
                subunits: [
                    WorkbookMachine.SubunitSpec(title: "頂点の座標が求められる", outcome: "平方完成で頂点を求める", n: 5, scoringUnit: "1問ごとに正誤"),
                    WorkbookMachine.SubunitSpec(title: "グラフの平行移動がわかる", outcome: "移動後の式を書ける", n: 5, scoringUnit: "1問ごとに正誤"),
                    WorkbookMachine.SubunitSpec(title: "最大値・最小値が求められる", outcome: "定義域つきで最大最小を求める", n: 6, scoringUnit: "1問ごとに正誤"),
                ],
                overview: .object(["unit_title": .string("二次関数"), "outcome": .string("二次関数の基本問題が自力で解ける")]),
                firstStage: introduction ? 1 : 3
            )
            if ProcessInfo.processInfo.arguments.contains("-ci-practice-ready") {
                try seedBenchmarkPractice(&machine, subunitID: "sub-1")
            }
            if ProcessInfo.processInfo.arguments.contains("-texture-demo") {
                seedDemoCaptures(&machine)
            }
            var chatEvents: [LedgerEvent] = []
            if ProcessInfo.processInfo.arguments.contains("-workbook-long-chat") {
                chatEvents = try seedLongSubunitChat(&machine, subunitID: "sub-1")
            }
            if ProcessInfo.processInfo.arguments.contains("-screens-fixture") {
                chatEvents += try seedScreensFixture(&machine, subunitID: "sub-1")
            }
            return (machine.events + chatEvents, ())
        }
    }

    /// Same domain operations as the UI setup: pass the example, then open five practice problems.
    /// Keeps setup independent from the split-grading assertions; no projections are patched directly.
    static func seedBenchmarkPractice(_ machine: inout WorkbookMachine, subunitID: String) throws {
        let firstSpec = try machine.nextSetSpec(subunitID: subunitID)
        let firstSet = machine.insertGeneratingSet(subunitID: subunitID, spec: firstSpec)
        let firstIDs = machine.addProblems(subunitID: subunitID,
            problems: [.init(prompt: "類題: y = x^2 - 2x の頂点の座標を求めよ")], source: "generated")
        machine.fillSet(setID: firstSet, problemIDs: firstIDs)
        let captureID = LedgerID.make()
        _ = try machine.createCapture(id: captureID, imagePath: "ci-setup.jpg", contentType: "image/jpeg",
            sha256: "0", byteCount: 1, subunitID: nil, setID: firstSet)
        let context = machine.gradingContext(capture: machine.captures[captureID]!)
        _ = try machine.applyGradingResult(captureID: captureID,
            graded: .init(readable: true, items: firstIDs.map {
                .init(label: "問1", promptText: "", matchedProblemId: $0, verdict: "correct", errorTag: "", note: "")
            }, candidates: [], newSubunit: nil, note: ""), context: context)
        let spec = try machine.nextSetSpec(subunitID: subunitID)
        let setID = machine.insertGeneratingSet(subunitID: subunitID, spec: spec)
        let ids = machine.addProblems(subunitID: subunitID,
            problems: (0..<spec.count).map { .init(prompt: "演習 \($0 + 1): 頂点の座標を求めよ") }, source: "generated")
        machine.fillSet(setID: setID, problemIDs: ids)
    }

    /// 固まらないことの確認用(E2E H2): 小単元 1 の会話に、数式入りの返事と全体像カードを含む 40 往復を入れる。
    /// その段の起動は済んだものとして記録する(新しいターンを起こさない)。
    private static func seedLongSubunitChat(_ machine: inout WorkbookMachine, subunitID: String) throws -> [LedgerEvent] {
        let (threadID, threadEvents) = try machine.ensureThread(subunitID: subunitID)
        var events = threadEvents
        let base = Date().addingTimeInterval(-7_200)
        var kickoffMessageID: String?
        for index in 0..<40 {
            let userID = LedgerID.make()
            let assistantID = LedgerID.make()
            let userText = index == 0 ? "[Struis からの起動メッセージ] 段階 1「要点」" : "質問 \(index): なぜ $(x - \(index))^2$ を展開すると $x^2 - \(2 * index)x + \(index * index)$ になるの？"
            let reply = index % 3 == 0
                ? "展開の確認です。\n\n$$ (x - \(index))^2 = x^2 - \(2 * index)x + \(index * index) $$\n\n- 1 行目: 2 乗を分ける\n- 2 行目: 係数をまとめる\n\n次の行を書いてみよう。"
                : "いい質問です。\(index) 回目の確認として、符号と係数を 1 つずつ見ていきましょう。まず $x$ の係数から。"
            let at = LedgerClock.iso(base.addingTimeInterval(Double(index) * 90))
            let later = LedgerClock.iso(base.addingTimeInterval(Double(index) * 90 + 30))
            events.append(.upsert("message.created", MessageRecord(
                id: userID, threadId: threadID, role: "user", status: "completed", plainText: userText,
                blocks: .array([.object(["kind": .string("text"), "payload": .object(["text": .string(userText)])])]),
                metadata: .object(index == 0 ? ["hidden": .bool(true)] : [:]), createdAt: at, completedAt: at
            )))
            var metadata: [String: LedgerJSON] = [:]
            if index == 20 { metadata["workbook_proposal_id"] = .string("fixture-proposal") }
            events.append(.upsert("message.created", MessageRecord(
                id: assistantID, threadId: threadID, role: "assistant", status: "completed", plainText: reply,
                blocks: .array([.object(["kind": .string("text"), "payload": .object(["text": .string(reply)])])]),
                metadata: .object(metadata), createdAt: later, completedAt: later
            )))
            if index == 0 { kickoffMessageID = userID }
        }
        if let kickoffMessageID { _ = machine.recordKickoff(subunitID: subunitID, key: "1:0", messageID: kickoffMessageID) }
        machine.put("proposal.created", WorkbookProposalRecord(
            id: "fixture-proposal", threadId: threadID, messageId: nil, status: "started", request: "二次関数",
            overview: .object([
                "unit_title": .string("二次関数"), "outcome": .string("二次関数の基本問題が自力で解ける"),
                "subunits": .array((1...6).map { .object(["title": .string("小単元 \($0)"), "outcome": .string("到達目標 \($0)"), "n": .number(10)]) }),
            ]),
            unitId: "unit-1", error: nil, createdAt: LedgerClock.now(), updatedAt: LedgerClock.now()
        ))
        return events
    }

    /// 画面の不整合の確認用(レーン D、2026-10-03)。実 Codex を使わずに、次の状態を台帳に作る。
    /// - 小単元 1 の会話: 長い表示用の数式(D5)、数式で始まる箇条書き(D6)、止まった返事と次の返事(D8・D15)
    /// - 自由質問の会話: 一覧のプレビューに LaTeX(D7)
    /// - 整理中の答案: 2 問の紙、同じ書き出しの候補、問題がまだ無い「判別式」の小単元(D12)
    private static func seedScreensFixture(_ machine: inout WorkbookMachine, subunitID: String) throws -> [LedgerEvent] {
        let (threadID, threadEvents) = try machine.ensureThread(subunitID: subunitID)
        var events = threadEvents
        let base = Date().addingTimeInterval(-3_600)
        var kickoffMessageID: String?
        let lines: [(role: String, status: String, text: String, retryable: Bool)] = [
            ("user", "completed", "[Struis からの起動メッセージ] 段階 1「要点」", false),
            ("assistant", "completed", "括弧の前の数は、括弧の中の各項に掛けます。\n\n係数が付いていても同じです。\n$$-2(3x-4)+5x=(-2)\\times 3x+(-2)\\times(-4)+5x=-6x+8+5x=-x+8$$\n\n判別式 $D=b^2-4ac$ の符号で、解の個数が決まります。\n- $D>0$: 異なる実数の解が2つ\n- $D=0$: 実数の解が1つ（重解）\n- $D<0$: 実数の解はない\n\n読み終えたら下の「先に進む」で例題へ進もう。", false),
            ("user", "completed", "x^2-6x+5 を平方完成して", false),
            ("assistant", "completed", "$x^2-6x+5=(x-3)^2-4$ です。頂点は $(3,-4)$ になります。", false),
            ("user", "completed", "判別式ってなんで b^2-4ac なの？", false),
            ("assistant", "failed", "停止しました。", true),
            ("user", "completed", "やっぱり、解の公式から説明して", false),
            ("assistant", "completed", "解の公式 $x=\\dfrac{-b\\pm\\sqrt{b^2-4ac}}{2a}$ の、根号の中が判別式です。根号の中が負だと実数の解はありません。", false),
        ]
        for (index, line) in lines.enumerated() {
            let id = LedgerID.make()
            let at = LedgerClock.iso(base.addingTimeInterval(Double(index) * 60))
            var metadata: [String: LedgerJSON] = [:]
            if index == 0 { metadata["hidden"] = .bool(true); kickoffMessageID = id }
            if line.retryable { metadata["retryable"] = .bool(true) }
            events.append(.upsert("message.created", MessageRecord(
                id: id, threadId: threadID, role: line.role, status: line.status, plainText: line.text,
                blocks: .array([.object(["kind": .string("text"), "payload": .object(["text": .string(line.text)])])]),
                metadata: .object(metadata), createdAt: at, completedAt: line.status == "completed" ? at : nil
            )))
        }
        if let kickoffMessageID { _ = machine.recordKickoff(subunitID: subunitID, key: "1:0", messageID: kickoffMessageID) }

        // D7: 自由質問の会話の一覧のプレビューに LaTeX。
        var (question, created) = ChatRepository.createThread(title: "新しい会話", preview: "\\(D>0\\) のときは解が 2 つです。")
        question.lastMessageAt = LedgerClock.iso(base.addingTimeInterval(600))
        events.append(created)
        events.append(.upsert("thread.touched", question))

        // D12: 問題がまだ無い「判別式」の小単元と、括弧の問題が並ぶ小単元、2 問の紙の整理中の答案。
        let unitID = machine.createUnit(
            title: "判別式と二次不等式", outcome: "判別式で解の個数を判断できる", source: "consult",
            subunits: [
                WorkbookMachine.SubunitSpec(title: "判別式を計算できる", outcome: "係数から判別式の値を計算する", n: 5, scoringUnit: "1問ごとに正誤"),
                WorkbookMachine.SubunitSpec(title: "判別式で解の個数がわかる", outcome: "判別式の符号から解の個数を答える", n: 5, scoringUnit: "1問ごとに正誤"),
            ],
            overview: .object(["unit_title": .string("判別式と二次不等式")]), firstStage: 4
        )
        _ = unitID
        let bracketIDs = machine.addProblems(
            subunitID: "sub-2",
            problems: ["$-2(3x-4)+5x$", "$3(x+2)-(x-5)$", "$-(2x-1)+4(x+3)$"].map {
                WorkbookMachine.ProblemSpec(prompt: "次の式の括弧を外し、同類項をまとめなさい。\($0)")
            },
            source: "fixture"
        )
        let at = LedgerClock.iso(Date().addingTimeInterval(-30))
        machine.put("capture.triaged", WorkbookCaptureRecord(
            id: "screens-triage", status: "triage", imagePath: "", contentType: "image/jpeg", sha256: "", byteCount: 0,
            context: .emptyObject, subunitId: nil, setId: nil,
            verdicts: .array([
                .object(["label": .string("(1)"), "prompt_text": .string("2x^2+3x-1=0 の判別式を求めよ。"), "verdict": .string("correct"), "error_tag": .string(""), "note": .string("")]),
                .object(["label": .string("(2)"), "prompt_text": .string("x^2-4x+4=0 の判別式を求めよ。"), "verdict": .string("wrong"), "error_tag": .string("符号"), "note": .string("")]),
            ]),
            summary: .object(["outcome": .string("unmatched")]),
            candidates: .array(bracketIDs.map { id in
                .object([
                    "problem_id": .string(id), "subunit_id": .string("sub-2"), "subunit_title": .string("グラフの平行移動がわかる"),
                    "prompt": .string(machine.problems[id]?.prompt ?? ""), "reason": .string(""),
                ])
            }),
            error: nil, createdAt: at, updatedAt: at, gradedAt: at
        ))
        return events
    }

    /// 質感の検証用。「最近」に判定済み 2 枚と判定中 1 枚を置く(台帳の行の見え方を撮るため)。
    private static func seedDemoCaptures(_ machine: inout WorkbookMachine) {
        let papers: [(String, String, [Bool]?, TimeInterval)] = [
            ("demo-cap-1", "sub-1", [true, true, false, true, true], -1_200),
            ("demo-cap-2", "sub-2", [true, false, false, true, false], -5_700),
            ("demo-cap-3", "sub-2", nil, -20),
        ]
        for (id, subunitID, marks, offset) in papers {
            let at = LedgerClock.iso(Date().addingTimeInterval(offset))
            if let marks {
                // マスの見え方(正解・誤答・未着手)を撮るため、問題と試行も入れる。
                let problemIDs = machine.addProblems(
                    subunitID: subunitID,
                    problems: marks.indices.map { WorkbookMachine.ProblemSpec(prompt: "例題 \($0 + 1)") }, source: "fixture"
                )
                _ = machine.recordAttempts(
                    captureID: id, subunitID: subunitID, setID: nil,
                    verdicts: zip(problemIDs, marks).map { WorkbookMachine.Verdict(problemID: $0, verdict: $1 ? "correct" : "wrong", errorTag: "", note: "") },
                    capturedAt: at
                )
            }
            let verdicts: [LedgerJSON] = (marks ?? []).enumerated().map { index, ok in
                .object(["label": .string("\(index + 1)"), "verdict": .string(ok ? "correct" : "wrong")])
            }
            let correct = (marks ?? []).filter { $0 }.count
            let summary: LedgerJSON = marks == nil ? .emptyObject : .object(["result": .object([
                "correct": .number(Double(correct)), "total": .number(5), "score": .number(Double(correct) / 5), "passed": .bool(correct >= 4),
            ])])
            machine.put(marks == nil ? "capture.created" : "capture.graded", WorkbookCaptureRecord(
                id: id, status: marks == nil ? "identifying" : "graded", imagePath: "", contentType: "image/jpeg", sha256: "", byteCount: 0,
                context: .emptyObject, subunitId: subunitID, setId: nil, verdicts: .array(verdicts), summary: summary,
                candidates: .array([]), error: nil, createdAt: at, updatedAt: at, gradedAt: marks == nil ? nil : at
            ))
        }
    }

    /// 旧 in-memory フィクスチャと同じ「前回の続き」の会話 1 本 (UI テストの前提)。
    static let chatThreadID = "10000000-0000-0000-0000-000000000001"

    static func seedChatIfEmpty(_ ledger: Ledger) async {
        let empty = (try? await ledger.read { db in try ThreadRecord.fetchCount(db) == 0 }) ?? false
        guard empty else { return }
        let base = Date().addingTimeInterval(-600)
        let lines: [(String, String, String)] = [
            ("20000000-0000-0000-0000-000000000101", "assistant", "二次関数の途中式ですね。前回は、答えだけでなく途中式を自分の言葉で確認するところまで進めました。"),
            ("20000000-0000-0000-0000-000000000102", "user", "ここからもう一回確認したいです。"),
            ("20000000-0000-0000-0000-000000000103", "assistant", "了解です。まず式を一行ずつ見ます。どの行で符号が変わったかを声に出して説明してみてください。"),
            ("20000000-0000-0000-0000-000000000104", "user", "写真で送ります。"),
        ]
        try? await ledger.commit { db in
            var events: [LedgerEvent] = []
            let (thread, created) = ChatRepository.createThread(id: chatThreadID, title: "二次関数の途中式")
            events.append(created)
            for (index, line) in lines.enumerated() {
                let at = LedgerClock.iso(base.addingTimeInterval(Double(index) * 60))
                let row = MessageRecord(
                    id: line.0, threadId: chatThreadID, role: line.1, status: "completed", plainText: line.2,
                    blocks: .array([.object(["kind": .string("text"), "payload": .object(["text": .string(line.2)])])]),
                    metadata: .object([:]), createdAt: at, completedAt: at
                )
                events.append(.upsert("message.created", row))
            }
            var touched = thread
            touched.latestPreview = lines.last?.2
            touched.lastMessageAt = LedgerClock.iso(base.addingTimeInterval(Double(lines.count) * 60))
            events.append(.upsert("thread.touched", touched))
            return (events, ())
        }
    }
}
#endif

