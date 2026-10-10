import GRDB
import XCTest
@testable import strius

/// 待ち時間の体験(配信Skillの説明)の、画面の外で確かめられる部分。
/// 分解・領域・チップの切り出しは入力から拾えたものだけであること、先回りと 1 問目の先出しが台帳でどう動くか。
final class WaitingExperienceTests: XCTestCase {
    private func makeCoordinator() throws -> (Ledger, TurnCoordinator) {
        let ledger = try Ledger.inMemory()
        return (ledger, TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: MockTurnRunner()))
    }

    private func seedSubunit(_ ledger: Ledger, stage: Int, n: Int = 5) async throws -> String {
        try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let unitID = machine.createUnit(title: "二次関数", outcome: "", source: "consult", subunits: [.init(title: "頂点", outcome: "頂点を求める", n: n)], firstStage: stage)
            return (machine.events, machine.orderedSubunits(unitID: unitID)[0].id)
        }
    }

    private func poll(_ label: String, timeout: Int = 400, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<timeout {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("timed out: \(label)")
    }

    // MARK: - §4.1 分解

    func testDecomposerPicksOnlyWhatTheLearnerWrote() {
        let chips = UnitCreationDecomposer.chips([
            .init(questionKey: "current", text: "中3で二次関数をやってる"),
            .init(questionKey: "test", text: "10月15日に期末テスト"),
            .init(questionKey: "stumble", text: "判別式のところがよくわからない"),
        ])
        XCTAssertEqual(chips.map(\.kind), [.grade, .unit, .date, .stumble])
        guard chips.count == 4 else { return } // Preserve the failure without crashing the remaining suite.
        XCTAssertEqual(chips[0].label, "中3")
        XCTAssertEqual(chips[1].label, "2次関数", "単元名は一覧の名前に整える")
        XCTAssertEqual(chips[2].label, "テスト 10/15", "日付は規則で整える")
        XCTAssertEqual(chips[3].label, "判別式のところがよくわからない", "つまずきは学習者の言葉のまま")
        // 色をつける範囲は、答えの中の元の文字。
        let current = Array("中3で二次関数をやってる")
        XCTAssertEqual(String(current[chips[0].range]), "中3")
        XCTAssertEqual(String(current[chips[1].range]), "二次関数")
    }

    func testExplicitJapaneseDatesKeepOriginalRanges() {
        let text = "📘 予定は０２０２８年２月２９日と10月15日です"
        let chips = UnitCreationDecomposer.dates(text, answerIndex: 2, isTestAnswer: true)
        XCTAssertEqual(chips.map(\.label), ["テスト 2/29", "テスト 10/15"])
        XCTAssertEqual(chips.map(\.answerIndex), [2, 2])
        let characters = Array(text)
        XCTAssertEqual(chips.map { String(characters[$0.range]) }, ["０２０２８年２月２９日", "10月15日"])
    }

    func testInvalidJapaneseDatesDoNotRollOverOrInferDays() {
        for text in ["2月30日", "13月15日", "0月15日", "100月10日", "10月100日", "2026年2月29日", "999年2月29日", "２０２５０年１０月１５日", "999999999999999999999999年10月15日", "来月くらい", "10月"] {
            XCTAssertTrue(UnitCreationDecomposer.dates(text, answerIndex: 0, isTestAnswer: true).isEmpty, text)
        }
    }

    func testContextualDatesKeepFoundationDetectionAndRanges() throws {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        for text in ["来年10月15日", "再来年2月29日", "令和6年10月15日", "平成31年4月30日", "next year 10月15日"] {
            let expected = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter {
                guard $0.date != nil, let range = Range($0.range, in: text) else { return false }
                return text[range].contains("日")
            }
            let actual = UnitCreationDecomposer.dates(text, answerIndex: 0, isTestAnswer: false)
            XCTAssertEqual(actual.count, expected.count, text)
            let characters = Array(text)
            for (chip, match) in zip(actual, expected) {
                let range = try XCTUnwrap(Range(match.range, in: text))
                XCTAssertEqual(String(characters[chip.range]), String(text[range]), text)
                let date = try XCTUnwrap(match.date)
                let components = Calendar(identifier: .gregorian).dateComponents(in: match.timeZone ?? .current, from: date)
                XCTAssertEqual(chip.label, "\(try XCTUnwrap(components.month))/\(try XCTUnwrap(components.day))", text)
            }
        }
    }

    func testDecomposerMakesNoChipsItCouldNotFind() {
        let chips = UnitCreationDecomposer.chips([
            .init(questionKey: "current", text: "よくわからない"),
            .init(questionKey: "test", text: "来月くらい"),
            .init(questionKey: "stumble", text: ""),
        ])
        XCTAssertTrue(chips.isEmpty, "拾えなかった要素はチップにしない: \(chips.map(\.label))")
    }

    func testDecomposerPrefersLongerSubjectNames() {
        let chips = UnitCreationDecomposer.chips([.init(questionKey: "current", text: "数学Ⅱの三角関数")])
        XCTAssertEqual(chips.map(\.label), ["数学Ⅱ", "三角関数"], "「数学Ⅱ」の中の「数学」を別に拾わない")
    }

    // MARK: - §4.2 ふるい

    @MainActor
    func testSieveKeepsOnlyCandidatesMatchingTheResult() {
        let candidates = UnitCatalog.candidates
        let matched = UnitSieveModel.matches(titles: ["平方完成", "2次関数の最大・最小", "カタログに無い小単元"], in: candidates)
        XCTAssertEqual(matched.map(\.title), ["平方完成", "2次関数の最大・最小"], "結果にあって候補に無い小単元は候補から作らない")
        let grade = UnitCreationDecomposer.Chip(kind: .grade, label: "中3", answerIndex: 0, range: 0..<2, key: "中3")
        XCTAssertTrue(candidates.filter(grade.keeps).allSatisfy { $0.unit.grades.contains("中3") })
        let interleaved = UnitSieveModel.interleaved(candidates)
        XCTAssertEqual(Set(interleaved.map(\.id)).count, candidates.count, "並べ替えても候補は減らない")
    }

    // MARK: - §5.1 領域

    func testAnswerRegionsSplitAtProblemNumbers() {
        let lines: [(rect: CGRect, text: String)] = [
            (CGRect(x: 0.1, y: 0.05, width: 0.3, height: 0.03), "名前"),
            (CGRect(x: 0.1, y: 0.15, width: 0.6, height: 0.04), "(1) x = 3"),
            (CGRect(x: 0.15, y: 0.21, width: 0.5, height: 0.04), "よって 3"),
            (CGRect(x: 0.1, y: 0.40, width: 0.6, height: 0.04), "(2) y = 2x + 1"),
            (CGRect(x: 0.1, y: 0.60, width: 0.6, height: 0.04), "(3) 5"),
        ]
        let regions = WorkbookAnswerRegions.regions(from: lines)
        XCTAssertEqual(regions.map(\.label), [1, 2, 3], "番号の行から次の番号の手前まで")
        XCTAssertEqual(regions[0].lines.count, 2)
        XCTAssertFalse(regions[0].rect.contains(CGPoint(x: 0.2, y: 0.06)), "番号より上の行(名前)は含めない")
        let assignment = WorkbookAnswerRegions.assign(verdictLabels: ["(2)", "問1", "(3)"], regions: regions)
        XCTAssertEqual(assignment, [0: 1, 1: 0, 2: 2], "判定の label の番号と領域の番号で結ぶ")
    }

    func testAnswerRegionsFallBackToGapsAndUnmatchedVerdictsStayInTheList() {
        let lines: [(rect: CGRect, text: String)] = [
            (CGRect(x: 0.1, y: 0.10, width: 0.6, height: 0.04), "x=3"),
            (CGRect(x: 0.1, y: 0.15, width: 0.6, height: 0.04), "y=2"),
            (CGRect(x: 0.1, y: 0.50, width: 0.6, height: 0.04), "z=1"),
        ]
        let regions = WorkbookAnswerRegions.regions(from: lines)
        XCTAssertEqual(regions.count, 2, "番号が無ければ大きな空きで区切る")
        XCTAssertEqual(WorkbookAnswerRegions.assign(verdictLabels: ["問1", "問2"], regions: regions), [0: 0, 1: 1], "数が同じなら順に結ぶ")
        XCTAssertTrue(WorkbookAnswerRegions.assign(verdictLabels: ["問1", "問2", "問3"], regions: regions).isEmpty, "数が合わず番号でも結べない判定は一覧だけ")
        XCTAssertTrue(WorkbookAnswerRegions.regions(from: []).isEmpty, "行が無ければ呼び手が写真全体を 1 つにする")
        XCTAssertEqual(WorkbookAnswerRegions.labelNumber("（３）答え"), 3)
        XCTAssertEqual(WorkbookAnswerRegions.labelNumber("② 2x"), 2)
        XCTAssertNil(WorkbookAnswerRegions.labelNumber("x = 3"))
    }

    // MARK: - §6 要点から運ぶ語

    func testMarkedSpansTakeMathAndBoldInOrder() {
        let text = "二次関数は **頂点** が大事。$y = a(x-p)^2 + q$ の形にすると、\\(p, q\\) が読める。**平方完成** も使う。"
        let spans = StruisMarkedSpans.spans(text, limit: 3)
        XCTAssertEqual(spans.map(\.body), ["頂点", "y = a(x-p)^2 + q", "p, q"], "書式による先頭から最大 3 つ")
        XCTAssertEqual(spans.map(\.kind), [.bold, .math(display: false), .math(display: false)])
        XCTAssertTrue(StruisMarkedSpans.spans("数式も強調も無い説明。", limit: 3).isEmpty, "1 つも無ければチップは出さない")
    }

    // MARK: - §3.2 一枚は 1 問できたら出す

    func testPracticeSetOpensFirstProblemBeforeTheRest() async throws {
        XCTAssertEqual(TurnComposer.setTurnCount(total: 5, filled: 0), 1)
        XCTAssertEqual(TurnComposer.setTurnCount(total: 5, filled: 1), 4)
        XCTAssertEqual(TurnComposer.setTurnCount(total: 1, filled: 0), 1)
        let (ledger, turns) = try makeCoordinator()
        let subunitID = try await seedSubunit(ledger, stage: 4, n: 5)
        let setID = try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let id = machine.insertGeneratingSet(subunitID: subunitID, spec: try machine.nextSetSpec(subunitID: subunitID))
            return (machine.events, id)
        }
        await turns.startSetGeneration(setID: setID)
        try await poll("set opened") {
            try await ledger.read { db in try WorkbookSetRecord.fetchOne(db, key: setID)?.status } == "open"
        }
        let kinds = try await ledger.read { db in
            try StoredLedgerEvent.filter(Column("entity_id") == setID).order(Column("seq")).fetchAll(db).map(\.kind)
        }
        XCTAssertTrue(kinds.contains("set.partial"), "1 問目だけで一度出す: \(kinds)")
        let partial = try await ledger.read { db in
            try StoredLedgerEvent.filter(Column("entity_id") == setID).filter(Column("kind") == "set.partial").fetchOne(db)
        }
        XCTAssertEqual(partial.flatMap { LedgerJSON.parse($0.payload) }?["problem_ids"]?.arrayValue?.count, 1)
        let set = try await ledger.read { db in try WorkbookMachine(loading: db).setView(id: setID) }
        XCTAssertEqual(set.problems.count, 5)
        XCTAssertEqual(Set(set.problems.map(\.prompt)).count, 5, "残りは 1 問目と違う問題")
    }

    // MARK: - §3.1 先回り

    func testPrefetchedSetStaysHiddenUntilItsStage() async throws {
        let (ledger, _) = try makeCoordinator()
        let subunitID = try await seedSubunit(ledger, stage: 2)
        let setID = try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let id = machine.insertPrefetchedSet(subunitID: subunitID, stage: 3)
            return (machine.events, id)
        }
        XCTAssertNotNil(setID)
        var summary = try await ledger.read { db in try WorkbookMachine(loading: db).subunitSummary(id: subunitID) }
        XCTAssertNil(summary.openSetId, "例題の段では類題の一枚を出さない")
        summary = try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            var row = try XCTUnwrap(machine.subunits[subunitID])
            row.metadata = WorkbookMachine.merge(row.metadata, ["example_ready": .object(["round": .number(0), "message_id": .string("m")])])
            machine.put("subunit.example_ready", row)
            _ = try machine.advance(subunitID: subunitID)
            return (machine.events, try machine.subunitSummary(id: subunitID))
        }
        XCTAssertEqual(summary.openSetId, setID, "類題に来たら、先回りで組んだ一枚がそのまま一枚になる")
        let again = try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            return (machine.events, machine.insertPrefetchedSet(subunitID: subunitID, stage: 3))
        }
        XCTAssertNil(again, "同じ段の一枚を二重に組まない")
    }

    func testExamplePrefetchIsAdoptedOnAdvance() async throws {
        let (ledger, turns) = try makeCoordinator()
        let subunitID = try await seedSubunit(ledger, stage: 1)
        let started = await turns.kickoffSubunit(subunitID: subunitID)
        XCTAssertEqual(started, .started)
        try await poll("example prefetched") { await turns.examplePrefetches[subunitID]?.ready == true }
        let threadID = try await turns.subunitThread(subunitID: subunitID)
        let before = try await ledger.read { db in try ChatRepository.messages(db, threadID: threadID).count }
        XCTAssertEqual(before, 2, "先回りは台帳に書かない(学習者には見えない)")

        let adopted = await turns.adoptPrefetchedExample(subunitID: subunitID, advancing: true)
        let summary = try XCTUnwrap(adopted)
        XCTAssertEqual(summary.stage, 2)
        XCTAssertEqual(summary.exampleProblem, "y = x^2 - 4x + 3 の頂点の座標を求めよ", "進むのと同時に例題が出る(待ちが無い)")
        XCTAssertNotNil(summary.kickoffMessageId, "起動を記録して二重に起こさない")
        let rows = try await ledger.read { db in try ChatRepository.messages(db, threadID: threadID) }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[2].metadata["hidden"]?.boolValue, true)
        XCTAssertEqual(rows[3].status, "completed")
        XCTAssertFalse((rows[3].plainText ?? "").contains("struis_workbook_example"))
        let kickoff = await turns.kickoffSubunit(subunitID: subunitID)
        XCTAssertEqual(kickoff, .alreadyStarted, "例題の段でもう一度起こさない")
    }

    func testExamplePrefetchIsDroppedWhenTheConversationMoves() async throws {
        let (ledger, turns) = try makeCoordinator()
        let subunitID = try await seedSubunit(ledger, stage: 1)
        let started = await turns.kickoffSubunit(subunitID: subunitID)
        XCTAssertEqual(started, .started)
        try await poll("example prefetched") { await turns.examplePrefetches[subunitID]?.ready == true }
        let threadID = try await turns.subunitThread(subunitID: subunitID)
        _ = try await turns.sendChat(TurnCoordinator.ChatSend(threadID: threadID, text: "頂点ってなに？", attachments: [], workbookView: nil))
        let dropped = await turns.examplePrefetches[subunitID]
        XCTAssertNil(dropped, "会話が進んだら分岐の時点の例題は使わない")
        try await poll("question answered") {
            try await ledger.read { db in try ChatRepository.messages(db, threadID: threadID) }.last?.status == "completed"
        }
        // 返事が終わったら、その時点から作り直す。
        try await poll("prefetched again") { await turns.examplePrefetches[subunitID]?.ready == true }
    }

    // MARK: - §7 N秒考えました

    func testThinkingSecondsComeFromTheTurn() async throws {
        let (ledger, _) = try makeCoordinator()
        let threadID = LedgerID.make()
        let userID = LedgerID.make()
        let assistantID = LedgerID.make()
        try await ledger.commit { db in
            let thread = ChatRepository.createThread(id: threadID, title: "質問").1
            let user = ChatRepository.createMessage(id: userID, threadID: threadID, role: "user", status: "completed", plainText: "なんで？", blocks: .emptyArray, metadata: .object(["hidden": .bool(false)])).1
            var (assistant, _) = ChatRepository.createMessage(id: assistantID, threadID: threadID, role: "assistant", status: "pending", plainText: nil, blocks: .emptyArray, metadata: .emptyObject)
            assistant.status = "completed"
            let turn = TurnRecord(
                id: LedgerID.make(), kind: "chat", targetId: assistantID, threadId: threadID, status: "completed", round: 1, plan: .emptyObject,
                outcome: nil, codexThreadId: nil, codexTurnId: nil, executions: .emptyArray, error: nil,
                createdAt: "2026-09-26T10:00:00.000Z", startedAt: "2026-09-26T10:00:01.000Z", completedAt: "2026-09-26T10:00:23.400Z"
            )
            return ([thread, user, .upsert("message.created", assistant), .upsert("turn.completed", turn)], ())
        }
        let messages = try await ledger.read { db in try ChatRepository.chatMessages(db, rows: try ChatRepository.messages(db, threadID: threadID)) }
        let reply = try XCTUnwrap(messages.last)
        XCTAssertTrue(reply.answersLearner)
        XCTAssertEqual(reply.thinkingSeconds, 23, "送った時点(ターンの created_at)から出来上がりまで")
        XCTAssertEqual(ChatThinkingRow.visibleSeconds(3), nil, "3 秒までは秒数を出さない")
        XCTAssertEqual(ChatThinkingRow.visibleSeconds(12), 12)
    }
}
