import GRDB
import XCTest
@testable import strius

/// 補習と自動降格の廃止(2026-09-24、配信Skillの説明 §2.1)の受け入れ。
/// 間違えても段は下げない。合格の窓は段階 4 の演習の試行だけを数える。次の一枚と
/// 「例題に戻る」は学習者が選ぶ。
final class WorkbookRulesTests: XCTestCase {
    private var clock = 0

    private func machine() -> WorkbookMachine {
        var machine = WorkbookMachine()
        machine.now = { [unowned self] in
            clock += 1
            return String(format: "2026-09-24T00:%02d:%02d.000Z", clock / 60 % 60, clock % 60)
        }
        return machine
    }

    /// 段階 `stage` で active な小単元(n 問)を 1 つ持つ単元。
    private func unit(_ machine: inout WorkbookMachine, n: Int, stage: Int) -> String {
        let unitID = machine.createUnit(title: "連立方程式", outcome: "", source: "consult", subunits: [.init(title: "式を作る", n: n), .init(title: "解く", n: 10)], firstStage: stage)
        return machine.orderedSubunits(unitID: unitID)[0].id
    }

    /// 現在段階の一枚を作り、`correct` 問正解・残り誤答として判定する。戻り値は答案の summary。
    @discardableResult
    private func solveSet(_ machine: inout WorkbookMachine, subunitID: String, correct: Int) throws -> [String: LedgerJSON] {
        let spec = try machine.nextSetSpec(subunitID: subunitID)
        let setID = machine.insertGeneratingSet(subunitID: subunitID, spec: spec)
        let ids = machine.addProblems(
            subunitID: subunitID,
            problems: (0..<spec.count).map { .init(prompt: "問題 \(setID)-\($0)") },
            source: "generated"
        )
        machine.fillSet(setID: setID, problemIDs: ids)
        let captureID = "cap-\(setID)"
        _ = try machine.createCapture(id: captureID, imagePath: "\(captureID).jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, subunitID: nil, setID: setID)
        let context = machine.gradingContext(capture: machine.captures[captureID]!)
        let items = ids.enumerated().map { index, id in
            WorkbookMachine.GradingResult.Item(
                label: "(\(index + 1))", promptText: "", matchedProblemId: id,
                verdict: index < correct ? "correct" : "wrong", errorTag: index < correct ? "" : "個数の文字の抜け", note: ""
            )
        }
        let outcome = try machine.applyGradingResult(
            captureID: captureID,
            graded: .init(readable: true, items: items, candidates: [], newSubunit: nil, note: ""),
            context: context
        )
        XCTAssertEqual(outcome.status, "graded")
        return machine.captures[captureID]!.summary.objectValue ?? [:]
    }

    // MARK: 一枚を何枚の写真に分けて撮る(配信Skillの説明)

    /// 今の段の一枚(`count` 問)を作る。
    private func openSet(_ machine: inout WorkbookMachine, subunitID: String, count: Int) throws -> (setID: String, ids: [String]) {
        var spec = try machine.nextSetSpec(subunitID: subunitID)
        spec.count = count
        let setID = machine.insertGeneratingSet(subunitID: subunitID, spec: spec)
        let ids = machine.addProblems(subunitID: subunitID, problems: (0..<count).map { .init(prompt: "問題 \(setID)-\($0)") }, source: "generated")
        machine.fillSet(setID: setID, problemIDs: ids)
        return (setID, ids)
    }

    /// 一枚から 1 枚撮り、写っていた問題(`problems`)を判定する。`wrong` の問題は誤答。
    @discardableResult
    private func capture(_ machine: inout WorkbookMachine, id: String, setID: String, problems: [String], wrong: Set<String> = []) throws -> WorkbookCaptureDTO {
        _ = try machine.createCapture(id: id, imagePath: "\(id).jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, subunitID: nil, setID: setID)
        let context = machine.gradingContext(capture: machine.captures[id]!)
        let items = problems.map { pid in
            WorkbookMachine.GradingResult.Item(
                label: "", promptText: "", matchedProblemId: pid,
                verdict: wrong.contains(pid) ? "wrong" : "correct", errorTag: wrong.contains(pid) ? "符号の取り違え" : "", note: ""
            )
        }
        let outcome = try machine.applyGradingResult(captureID: id, graded: .init(readable: true, items: items, candidates: [], newSubunit: nil, note: ""), context: context)
        XCTAssertEqual(outcome.status, "graded")
        return try machine.captureView(id: id)
    }

    func testSetCapturedInThreePhotosIsGradedAsOneSet() throws {
        var machine = machine()
        let subunitID = unit(&machine, n: 15, stage: 4)
        let (setID, ids) = try openSet(&machine, subunitID: subunitID, count: 15)
        let wrong: Set<String> = [ids[2], ids[6], ids[11]]

        let first = try capture(&machine, id: "cap-1", setID: setID, problems: Array(ids[0..<5]), wrong: wrong)
        XCTAssertTrue(first.isPartial, "1 枚目で一枚を締めた")
        XCTAssertEqual(first.setProgress?.missingPositions, Array(6...15))
        XCTAssertEqual(first.result?.actions, [.captureMore, .closeSet, .ask])
        XCTAssertEqual(machine.sets[setID]?.status, "open", "途中で一枚が締まった")
        XCTAssertNil(machine.subunits[subunitID]?.metadata["practice_failed_sets"], "途中の答案を不合格に数えた")

        let second = try capture(&machine, id: "cap-2", setID: setID, problems: Array(ids[5..<10]), wrong: wrong)
        XCTAssertTrue(second.isPartial)
        XCTAssertEqual(second.setProgress?.missingPositions, Array(11...15))
        XCTAssertEqual(second.setProgress?.judgedCount, 10)

        let third = try capture(&machine, id: "cap-3", setID: setID, problems: Array(ids[10..<15]), wrong: wrong)
        XCTAssertFalse(third.isPartial)
        XCTAssertEqual(third.summary?.correct, 12, "一枚の集計になっていない")
        XCTAssertEqual(third.summary?.total, 15)
        XCTAssertEqual(third.result?.subunitPassed, true)
        XCTAssertEqual(machine.sets[setID]?.status, "graded")
        XCTAssertEqual(machine.sets[setID]?.result?["total"]?.intValue, 15)
        XCTAssertEqual(third.result?.windowTiles.filter(\.isCurrent).count, 15, "一枚で埋まったマスに印が付いていない")
        XCTAssertEqual(machine.subunits[subunitID]?.status, "passed")

        // 締めた後に開いた古い途中の答案: 撮り足す・締めるは出さない(R6)。
        XCTAssertEqual(try machine.captureView(id: "cap-1").result?.actions, [.ask])
    }

    func testClosingWithMissingProblemsGradesWhatWasFound() throws {
        var machine = machine()
        let subunitID = unit(&machine, n: 15, stage: 4)
        let (setID, ids) = try openSet(&machine, subunitID: subunitID, count: 15)
        let wrong: Set<String> = [ids[2], ids[6], ids[11]]
        try capture(&machine, id: "cap-1", setID: setID, problems: Array(ids[0..<5]), wrong: wrong)
        try capture(&machine, id: "cap-2", setID: setID, problems: Array(ids[5..<10]), wrong: wrong)
        let third = try capture(&machine, id: "cap-3", setID: setID, problems: Array(ids[10..<13]), wrong: wrong)
        XCTAssertEqual(third.setProgress?.missingPositions, [14, 15])
        XCTAssertEqual(WorkbookSetProgressDTO.positionsText([14, 15]), "14・15")
        XCTAssertEqual(WorkbookSetProgressDTO.positionsText(Array(6...15)), "6〜15")
        XCTAssertEqual(WorkbookSetProgressDTO.positionsText([1, 3, 4, 5]), "1・3〜5")

        let closed = try machine.closeSet(captureID: "cap-3")
        XCTAssertFalse(closed.isPartial)
        XCTAssertEqual(closed.summary?.correct, 10)
        XCTAssertEqual(closed.summary?.total, 13)
        XCTAssertEqual(closed.setProgress?.missingPositions, [14, 15], "未提出の番号が分からない")
        XCTAssertEqual(closed.result?.actions, ["retry", "return_to_example", "ask"].compactMap(WorkbookResultDTO.Action.init(rawValue:)))
        XCTAssertEqual(machine.sets[setID]?.status, "graded")
        XCTAssertEqual(machine.subunits[subunitID]?.metadata["practice_failed_sets"]?.intValue, 1)
        XCTAssertThrowsError(try machine.closeSet(captureID: "cap-3"), "締めた一枚をもう一度締めた")

        // 締めた後に残りを撮る: 一枚の集計に足し直し、不合格の回数は増やさない(R4)。
        let late = try capture(&machine, id: "cap-4", setID: setID, problems: Array(ids[13..<15]))
        XCTAssertFalse(late.isPartial)
        XCTAssertEqual(late.summary?.correct, 12)
        XCTAssertEqual(late.summary?.total, 15)
        XCTAssertEqual(machine.subunits[subunitID]?.metadata["practice_failed_sets"]?.intValue, 1, "締めた後の答案を不合格に数えた")
        XCTAssertEqual(machine.subunits[subunitID]?.status, "passed", "窓が届いたのに合格にならない")
    }

    func testExampleSetStillClosesWithOnePhoto() throws {
        var machine = machine()
        let subunitID = unit(&machine, n: 5, stage: 3)
        let (setID, ids) = try openSet(&machine, subunitID: subunitID, count: 1)
        let result = try capture(&machine, id: "cap-ex", setID: setID, problems: ids)
        XCTAssertFalse(result.isPartial)
        XCTAssertNil(result.setProgress)
        XCTAssertEqual(machine.subunits[subunitID]?.stage, 4)
    }

    func testNoRemedialPathExists() throws {
        var machine = machine()
        let subunitID = unit(&machine, n: 15, stage: 4)
        let summary = try solveSet(&machine, subunitID: subunitID, correct: 11)
        XCTAssertNil(summary["next_set_id"], "不合格の後に一枚を自動で作らない")
        XCTAssertFalse(machine.sets.values.contains { $0.kind == "remedial" })
        XCTAssertNil(machine.openSet(subunitID: subunitID))
        let spec = try machine.nextSetSpec(subunitID: subunitID)
        XCTAssertEqual(spec.kind, "practice")
        XCTAssertEqual(spec.count, 15, "やり直しは同じ段の新しい n 問")
        XCTAssertNotNil(spec.retryOf)
        XCTAssertEqual(spec.targetErrorTags, ["個数の文字の抜け"], "やり直しの一枚は直前の誤答の種類を持つ")
    }

    func testPractice11of15ThenThreeCorrectDoesNotPass() throws {
        var machine = machine()
        let subunitID = unit(&machine, n: 15, stage: 4)
        let first = try solveSet(&machine, subunitID: subunitID, correct: 11)
        XCTAssertEqual(first["subunit_passed"]?.boolValue, false)
        XCTAssertEqual(first["next_actions"]?.arrayValue?.compactMap(\.stringValue), ["retry", "return_to_example", "ask"])
        XCTAssertEqual(machine.subunits[subunitID]?.stage, 4)

        // 補習の時代の「3 問だけの一枚」を手で作っても合格しない(窓は直近 15 問で、足りない)。
        let setID = machine.insertGeneratingSet(subunitID: subunitID, spec: .init(stage: 4, kind: "practice", count: 3, n: 15, threshold: 0.8))
        let ids = machine.addProblems(subunitID: subunitID, problems: (0..<3).map { .init(prompt: "小さい一枚 \($0)") }, source: "generated")
        machine.fillSet(setID: setID, problemIDs: ids)
        _ = try machine.createCapture(id: "cap-small", imagePath: "cap-small.jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, subunitID: nil, setID: setID)
        let context = machine.gradingContext(capture: machine.captures["cap-small"]!)
        _ = try machine.applyGradingResult(
            captureID: "cap-small",
            graded: .init(readable: true, items: ids.map { .init(label: "", promptText: "", matchedProblemId: $0, verdict: "correct", errorTag: "", note: "") }, candidates: [], newSubunit: nil, note: ""),
            context: context
        )
        // 窓は直近 15 問: 最初の一枚の 12 問目以降(誤答 4 を含む)+ 3 問 → 11 + 3 - 3 = ... 合格ラインに届かない。
        let window = machine.passWindow(subunitID: subunitID)
        XCTAssertLessThan(window.correct, window.requiredCorrect)
        XCTAssertEqual(machine.subunits[subunitID]?.status, "active")
    }

    func testPractice11of15ThenNew15With12Passes() throws {
        var machine = machine()
        let subunitID = unit(&machine, n: 15, stage: 4)
        try solveSet(&machine, subunitID: subunitID, correct: 11)
        let second = try solveSet(&machine, subunitID: subunitID, correct: 12)
        XCTAssertEqual(second["subunit_passed"]?.boolValue, true)
        XCTAssertEqual(second["outcome"]?.stringValue, "subunit_passed")
        XCTAssertEqual(second["next_actions"]?.arrayValue?.compactMap(\.stringValue), ["next_subunit", "ask"])
        XCTAssertEqual(machine.subunits[subunitID]?.status, "passed")
        let tiles = second["window_tiles"]?.arrayValue ?? []
        XCTAssertEqual(tiles.count, 15)
        XCTAssertTrue(tiles.allSatisfy { $0["current"]?.boolValue == true }, "今回の一枚で埋まったマスが分かる")
        let result = try XCTUnwrap(WorkbookMachine.resultView(second))
        XCTAssertTrue(result.subunitPassed)
        XCTAssertEqual(result.window?.n, 15)
        XCTAssertEqual(result.window?.requiredCorrect, 12)
    }

    func testExampleWrongThreeTimesStaysAtStage3() throws {
        var machine = machine()
        let subunitID = unit(&machine, n: 10, stage: 3)
        for _ in 0..<3 {
            let summary = try solveSet(&machine, subunitID: subunitID, correct: 0)
            XCTAssertEqual(summary["next_actions"]?.arrayValue?.compactMap(\.stringValue), ["retry", "return_to_example", "ask"])
            XCTAssertEqual(machine.subunits[subunitID]?.stage, 3, "類題 × で段を下げない")
            XCTAssertNil(machine.openSet(subunitID: subunitID))
        }
        XCTAssertEqual(try machine.nextSetSpec(subunitID: subunitID).count, 1)
    }

    func testExampleCorrectDoesNotEnterWindow() throws {
        var machine = machine()
        let subunitID = unit(&machine, n: 10, stage: 3)
        let summary = try solveSet(&machine, subunitID: subunitID, correct: 1)
        XCTAssertEqual(summary["next_actions"]?.arrayValue?.compactMap(\.stringValue), ["practice", "ask"])
        XCTAssertEqual(machine.subunits[subunitID]?.stage, 4)
        let window = machine.passWindow(subunitID: subunitID)
        XCTAssertEqual(window.count, 0, "類題の ○ は合格の窓に数えない")
        XCTAssertEqual(try machine.subunitSummary(id: subunitID).windowTiles?.count, 0)
        XCTAssertEqual(machine.attemptsOf(subunitID: subunitID).count, 1, "試行そのものは記録する")
    }

    func testTilesAreWindowOnlyAndPushOldOnesOut() throws {
        var machine = machine()
        let subunitID = unit(&machine, n: 5, stage: 4)
        try solveSet(&machine, subunitID: subunitID, correct: 2)
        try solveSet(&machine, subunitID: subunitID, correct: 3)
        let tiles = try machine.subunitSummary(id: subunitID).windowTiles ?? []
        XCTAssertEqual(tiles.count, 5, "マスは n 個を超えない")
        XCTAssertEqual(tiles.map(\.state), [.correct, .correct, .correct, .wrong, .wrong], "新しい一枚が古いものを押し出す")
    }

    func testReturnToExampleIsLearnerActionAndAdvanceGoesBack() throws {
        var machine = machine()
        let subunitID = unit(&machine, n: 5, stage: 4)
        try solveSet(&machine, subunitID: subunitID, correct: 1)
        let before = machine.attemptsOf(subunitID: subunitID).count
        XCTAssertEqual(machine.subunits[subunitID]?.stage, 4, "判定だけでは段を動かさない")

        let returned = try machine.returnToExample(subunitID: subunitID)
        XCTAssertEqual(returned.stage, 2)
        XCTAssertEqual(returned.returnStage, 4)
        XCTAssertEqual(returned.kickoffKey, "2:1", "新しい例題の回")
        XCTAssertEqual(machine.attemptsOf(subunitID: subunitID).count, before, "戻っても記録は消えない")
        XCTAssertEqual(machine.events.filter { $0.kind == "subunit.returned_to_example" }.count, 1)

        XCTAssertThrowsError(try machine.advance(subunitID: subunitID), "準備OKが無ければ例題から進めない")
        machine.setExampleReady(subunitID: subunitID, messageID: "ready-1")
        let advanced = try machine.advance(subunitID: subunitID)
        XCTAssertEqual(advanced.stage, 4, "例題の「先に進む」は戻る前の段へ直接戻す")
        XCTAssertNil(advanced.returnStage)

        // 通常の段階 2 は 3 へ。
        var other = self.machine()
        let fresh = unit(&other, n: 5, stage: 2)
        XCTAssertThrowsError(try other.returnToExample(subunitID: fresh), "段階 1・2 からは戻らない")
        other.setExampleReady(subunitID: fresh, messageID: "ready-2")
        XCTAssertEqual(try other.advance(subunitID: fresh).stage, 3)
    }

    func testExampleReadyIsPerRound() throws {
        var machine = machine()
        let subunitID = unit(&machine, n: 5, stage: 2)
        XCTAssertEqual(try machine.subunitSummary(id: subunitID).exampleReady, false, "準備OKが出るまで「先に進む」を出さない")
        machine.setExampleReady(subunitID: subunitID, messageID: "ready-1")
        XCTAssertEqual(try machine.subunitSummary(id: subunitID).exampleReady, true)
        _ = try machine.advance(subunitID: subunitID)
        XCTAssertNil(try machine.subunitSummary(id: subunitID).exampleReady, "段階 3 では使わない")
        _ = try machine.returnToExample(subunitID: subunitID)
        XCTAssertEqual(try machine.subunitSummary(id: subunitID).exampleReady, false, "例題に戻ると新しい回は準備OKなしから")
        XCTAssertThrowsError(try machine.advance(subunitID: subunitID))

        // 段階 1 では記録しない。
        var other = self.machine()
        let intro = unit(&other, n: 5, stage: 1)
        other.setExampleReady(subunitID: intro, messageID: "ready-3")
        XCTAssertNil(other.subunits[intro]?.metadata["example_ready"])
    }

    func testKickoffIsIdempotentPerStageAndRound() throws {
        var machine = machine()
        let subunitID = unit(&machine, n: 5, stage: 1)
        let (threadID, events) = try machine.ensureThread(subunitID: subunitID)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(try machine.ensureThread(subunitID: subunitID).threadID, threadID)
        XCTAssertEqual(try machine.ensureThread(subunitID: subunitID).events.count, 0)
        XCTAssertTrue(machine.recordKickoff(subunitID: subunitID, key: "1:0", messageID: "m1"))
        XCTAssertFalse(machine.recordKickoff(subunitID: subunitID, key: "1:0", messageID: "m2"))
        XCTAssertEqual(try machine.subunitSummary(id: subunitID).kickoffMessageId, "m1")
        _ = try machine.advance(subunitID: subunitID)
        XCTAssertEqual(try machine.subunitSummary(id: subunitID).kickoffKey, "2:0")
        machine.setExampleProblem(subunitID: subunitID, prompt: "鉛筆とノートの連立方程式", messageID: "m3")
        XCTAssertEqual(try machine.subunitSummary(id: subunitID).exampleProblem, "鉛筆とノートの連立方程式")
    }

    func testLegacyRemedialSetsReadAsPractice() throws {
        var machine = machine()
        let subunitID = unit(&machine, n: 3, stage: 4)
        let setID = machine.insertGeneratingSet(subunitID: subunitID, spec: .init(stage: 4, kind: "remedial", count: 3, n: 3, threshold: 0.8))
        let ids = machine.addProblems(subunitID: subunitID, problems: (0..<3).map { .init(prompt: "旧補習 \($0)") }, source: "generated")
        machine.fillSet(setID: setID, problemIDs: ids)
        XCTAssertEqual(try machine.setView(id: setID).kind, .practice)
        _ = try machine.createCapture(id: "cap-legacy", imagePath: "x.jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, subunitID: nil, setID: setID)
        let context = machine.gradingContext(capture: machine.captures["cap-legacy"]!)
        _ = try machine.applyGradingResult(
            captureID: "cap-legacy",
            graded: .init(readable: true, items: ids.map { .init(label: "", promptText: "", matchedProblemId: $0, verdict: "correct", errorTag: "", note: "") }, candidates: [], newSubunit: nil, note: ""),
            context: context
        )
        XCTAssertEqual(machine.passWindow(subunitID: subunitID).count, 3, "旧補習の試行は演習として数える")
        // 旧い summary(補習の時代)も読める。
        let legacy = WorkbookMachine.resultView(["outcome": .string("remedial"), "stage_after": .number(4), "result": .object([:])])
        XCTAssertEqual(legacy?.actions, [.ask])
        // 旧い答案でも、合格・段が進んだ結果には次の行動を出す。
        XCTAssertEqual(WorkbookMachine.resultView(["outcome": .string("stage_advanced"), "stage_before": .number(3), "stage_after": .number(4)])?.actions, [.practice, .ask])
        XCTAssertEqual(WorkbookMachine.resultView(["outcome": .string("subunit_passed"), "stage_before": .number(4), "stage_after": .number(4), "next_subunit_id": .string("s2")])?.actions, [.nextSubunit, .ask])
        XCTAssertEqual(WorkbookMachine.resultView(["outcome": .string("unit_passed"), "stage_before": .number(4), "stage_after": .number(4), "unit_passed": .bool(true)])?.actions, [.finishUnit, .ask])
        XCTAssertEqual(try JSONDecoder().decode(WorkbookSetDTO.Kind.self, from: Data("\"remedial\"".utf8)), .practice)
    }

    func testLegacyStage3RemedialDoesNotCountTowardWindow() throws {
        // 過去の補習は段階 3 でも作られていた。段階 4 の一枚でなければ合格の窓に入れない。
        var machine = machine()
        let subunitID = unit(&machine, n: 3, stage: 3)
        let setID = machine.insertGeneratingSet(subunitID: subunitID, spec: .init(stage: 3, kind: "remedial", count: 3, n: 3, threshold: 0.8))
        let ids = machine.addProblems(subunitID: subunitID, problems: (0..<3).map { .init(prompt: "旧補習(類題) \($0)") }, source: "generated")
        machine.fillSet(setID: setID, problemIDs: ids)
        _ = try machine.createCapture(id: "cap-legacy-3", imagePath: "x.jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, subunitID: nil, setID: setID)
        let context = machine.gradingContext(capture: machine.captures["cap-legacy-3"]!)
        _ = try? machine.applyGradingResult(
            captureID: "cap-legacy-3",
            graded: .init(readable: true, items: ids.map { .init(label: "", promptText: "", matchedProblemId: $0, verdict: "correct", errorTag: "", note: "") }, candidates: [], newSubunit: nil, note: ""),
            context: context
        )
        XCTAssertEqual(machine.passWindow(subunitID: subunitID).count, 0, "段階 3 の旧補習の試行が窓に入った")
        XCTAssertNotEqual(try machine.subunitSummary(id: subunitID).status, .passed)
    }

    func testRegradingAnOldCaptureAfterTheStageChangedDoesNotMoveTheStage() throws {
        // 演習の答案の判定が失敗したまま「例題に戻る」→ 後から「判定し直す」: 記録だけで、段は動かさない。
        var machine = machine()
        let subunitID = unit(&machine, n: 2, stage: 4)
        let setID = machine.insertGeneratingSet(subunitID: subunitID, spec: .init(stage: 4, kind: "practice", count: 2, n: 2, threshold: 0.8))
        let ids = machine.addProblems(subunitID: subunitID, problems: (0..<2).map { .init(prompt: "演習 \($0)") }, source: "generated")
        machine.fillSet(setID: setID, problemIDs: ids)
        _ = try machine.createCapture(id: "cap-old", imagePath: "x.jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, subunitID: nil, setID: setID)
        let context = machine.gradingContext(capture: machine.captures["cap-old"]!)
        _ = try machine.returnToExample(subunitID: subunitID)
        _ = try? machine.applyGradingResult(
            captureID: "cap-old",
            graded: .init(readable: true, items: ids.map { .init(label: "", promptText: "", matchedProblemId: $0, verdict: "correct", errorTag: "", note: "") }, candidates: [], newSubunit: nil, note: ""),
            context: context
        )
        let summary = try machine.subunitSummary(id: subunitID)
        XCTAssertEqual(summary.stage, 2, "古い答案の判定で段が動いた")
        XCTAssertEqual(summary.status, .active, "古い答案の判定で小単元が合格になった")
    }

    func testRegradingASetlessCaptureAfterReturningToExampleDoesNotPass() throws {
        // 一枚の無い答案(小単元から撮った)も、撮った時の段で扱う。例題に戻った後に判定し直しても合格にしない。
        var machine = machine()
        let subunitID = unit(&machine, n: 2, stage: 4)
        let ids = machine.addProblems(subunitID: subunitID, problems: (0..<2).map { .init(prompt: "紙 \($0)") }, source: "capture")
        _ = try machine.createCapture(id: "cap-free", imagePath: "x.jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, subunitID: subunitID, setID: nil)
        XCTAssertEqual(machine.captures["cap-free"]?.context["stage"]?.intValue, 4, "撮った時の段が記録されていない")
        let context = machine.gradingContext(capture: machine.captures["cap-free"]!)
        _ = try machine.returnToExample(subunitID: subunitID)
        _ = try? machine.applyGradingResult(
            captureID: "cap-free",
            graded: .init(readable: true, items: ids.map { .init(label: "", promptText: "", matchedProblemId: $0, verdict: "correct", errorTag: "", note: "") }, candidates: [], newSubunit: nil, note: ""),
            context: context
        )
        let summary = try machine.subunitSummary(id: subunitID)
        XCTAssertEqual(summary.stage, 2)
        XCTAssertEqual(summary.status, .active, "例題の段にいる間に古い答案で合格になった")
    }

    func testLedgerRoundTripWithNewEvents() async throws {
        let ledger = try Ledger.inMemory()
        try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let unitID = machine.createUnit(title: "u", outcome: "", source: "consult", subunits: [.init(title: "s", n: 2)], firstStage: 4)
            let subunitID = machine.orderedSubunits(unitID: unitID)[0].id
            _ = try machine.returnToExample(subunitID: subunitID)
            let (_, events) = try machine.ensureThread(subunitID: subunitID)
            _ = machine.recordKickoff(subunitID: subunitID, key: "2:1", messageID: "m")
            return (machine.events + events, ())
        }
        let before = try await ledger.projectionDigest()
        try await ledger.rebuild()
        let after = try await ledger.projectionDigest()
        XCTAssertEqual(before, after)
    }

    func testOutcomeTextHasNoPlaceholdersOrPlanNotes() {
        XCTAssertEqual(
            WorkbookMachine.cleanOutcome("支援なしで取り組んだ直近n問の正答率80%以上を合格の目安とする。", n: 15),
            "支援なしで取り組んだ直近15問の正答率80%以上を合格の目安とする。"
        )
        XCTAssertEqual(WorkbookMachine.cleanOutcome("1週目前半に、文章題から連立方程式を立てられる。そのあと計算練習をする。"), "文章題から連立方程式を立てられる。")
        XCTAssertEqual(WorkbookMachine.cleanOutcome("直近n問で{required}問正解できる"), "直近の演習で8割正解できる")
        // 記号ごとに実際の値を入れる(15 問・8 割なら 12 問)。n を合格の正解数に流用しない。
        XCTAssertEqual(WorkbookMachine.cleanOutcome("直近{n}問で{required}問正解できる", n: 15), "直近15問で12問正解できる")
        XCTAssertEqual(WorkbookMachine.cleanOutcome("直近{n}問で{required}問正解できる", n: 10, threshold: 0.7), "直近10問で7問正解できる")
        XCTAssertEqual(WorkbookMachine.cleanOutcome("{window}式を立てられる", n: 5), "式を立てられる")
        XCTAssertEqual(WorkbookMachine.cleanOutcome("集合 {x} を考え、{A} の補集合を求められる"), "集合 {x} を考え、{A} の補集合を求められる", "集合の波かっこは残す")
        XCTAssertEqual(WorkbookMachine.cleanOutcome("n次方程式を解ける", n: 15), "n次方程式を解ける", "問題数ではない n は残す")
        XCTAssertEqual(WorkbookMachine.cleanOutcome("第2週に習う二次方程式を解ける"), "第2週に習う二次方程式を解ける", "読点の無い日程の言葉は目標の一部として残す")
        // 数式の波かっこは記号ではない: 中身ごと残す。
        XCTAssertEqual(
            WorkbookMachine.cleanOutcome(#"x^{2} と \frac{1}{2} と \text{cm} と {1,2,3} を扱える"#),
            #"x^{2} と \frac{1}{2} と \text{cm} と {1,2,3} を扱える"#
        )
        XCTAssertEqual(WorkbookMachine.cleanOutcome("x と y の連立方程式を解ける", n: 10), "x と y の連立方程式を解ける", "n 以外の英字は残す")
        let overview = WorkbookMachine.cleanOverview(.object([
            "unit_title": .string("連立方程式"), "outcome": .string("第2週に、文章題を解ける。"),
            "subunits": .array([.object(["title": .string("式を作る"), "outcome": .string("直近n問で8割"), "n": .number(10)])]),
        ]))
        XCTAssertEqual(overview["outcome"]?.stringValue, "文章題を解ける。")
        XCTAssertEqual(overview["subunits"]?.arrayValue?.first?["outcome"]?.stringValue, "直近10問で8割")
    }

    /// 判定・一枚・単元の失敗は、内部のエラー文ではなく日本語の一言を台帳に書く(§1.3)。
    func testFailuresStoreFixedLearnerFacingText() throws {
        var machine = machine()
        let subunitID = unit(&machine, n: 5, stage: 4)
        let setID = machine.insertGeneratingSet(subunitID: subunitID, spec: try machine.nextSetSpec(subunitID: subunitID))
        _ = try machine.createCapture(id: "cap-fail", imagePath: "x.jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, subunitID: subunitID, setID: nil)
        let proposalID = machine.insertProposal(request: "二次関数", threadID: nil, messageID: nil)
        let internalError = "Codex の応答がありません (item/completed,turn/completed)"
        let failed = TurnOutcome(planID: "p", round: 1, status: .failed, codexThreadID: nil, codexTurnID: nil, finalText: "", executions: [], rateLimits: nil, files: [], error: internalError, elapsedMs: 1)
        _ = TurnApplier.grading(machine: &machine, captureID: "cap-fail", outcome: failed, context: .init(scope: .emptyObject, subunits: []))
        TurnApplier.set(machine: &machine, setID: setID, outcome: failed)
        TurnApplier.unit(machine: &machine, proposalID: proposalID, outcome: failed)
        XCTAssertEqual(machine.captures["cap-fail"]?.error, TurnApplier.gradingFailure)
        XCTAssertEqual(machine.sets[setID]?.error, TurnApplier.setFailure)
        XCTAssertEqual(machine.proposals[proposalID]?.error, TurnApplier.unitFailure)
        for text in [TurnApplier.gradingFailure, TurnApplier.setFailure, TurnApplier.unitFailure] {
            XCTAssertNil(text.range(of: #"[A-Za-z]+/[A-Za-z]+"#, options: .regularExpression), "内部の言葉が出ている: \(text)")
        }
        // 読めない判定結果(内部の JSON エラー)でも同じ。
        _ = try machine.createCapture(id: "cap-bad", imagePath: "y.jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, subunitID: subunitID, setID: nil)
        var ok = failed
        ok.status = .completed
        ok.finalText = "{not json"
        _ = TurnApplier.grading(machine: &machine, captureID: "cap-bad", outcome: ok, context: .init(scope: .emptyObject, subunits: []))
        XCTAssertEqual(machine.captures["cap-bad"]?.error, TurnApplier.gradingFailure)
    }
}
