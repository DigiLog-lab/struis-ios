import GRDB
import XCTest
@testable import strius

/// 2026-10-24 の見直し「グラフを頼むタイミング」: 頼んだかは台帳の `timeline_batches` の行で決め、起動し直しても
/// 頼み直さない。小単元 ID を持つ点は、その小単元が属する単元の点として数える。
final class TimelineGraphScheduleTests: XCTestCase {
    typealias F = TimelineFixture

    /// 単元 1 つ(小単元 2 つ)の台帳。
    private func unitLedger() async throws -> (Ledger, unitID: String, subunitIDs: [String]) {
        let ledger = try Ledger.inMemory()
        let (unitID, subunitIDs): (String, [String]) = try await ledger.commit { db in
            var workbook = try WorkbookMachine(loading: db)
            let unitID = workbook.createUnit(title: "フーリエ級数", outcome: "", source: "consult",
                                             subunits: [.init(title: "係数を求める", n: 2), .init(title: "級数で書く", n: 2)], firstStage: 1)
            return (workbook.events, (unitID, workbook.orderedSubunits(unitID: unitID).map(\.id)))
        }
        return (ledger, unitID, subunitIDs)
    }

    private func skill(_ id: String, unitID: String?) -> TimelineSkillRecord {
        var row = F.skill(id)
        row.unitId = unitID
        return row
    }

    func testGraphOfSubunitNodesDoesNotAskToExtendTheUnit() async throws {
        let (ledger, _, subunitIDs) = try await unitLedger()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            // 前の版の構築: 依頼に単元の一覧が無く、点の unit_id には小単元の ID が入っていた。
            let id = timeline.insertBatchRequest(purpose: "graph_build", request: .emptyObject, accuracy: nil, levelCap: nil)
            var row = timeline.batches[id]!
            row.status = "ready"
            timeline.put("test", row)
            timeline.put("test", self.skill("fourier.coefficients", unitID: subunitIDs[0]))
            timeline.put("test", self.skill("fourier.write_series", unitID: subunitIDs[1]))
            timeline.put("test", self.skill("calc.integrate_by_parts", unitID: nil))
            return (timeline.events, ())
        }
        let (timeline, workbook) = try await ledger.read { db in (try TimelineMachine(loading: db), try WorkbookMachine(loading: db)) }
        XCTAssertNil(TimelineGraphSchedule.next(timeline: timeline, workbook: workbook))
    }

    func testUnitsListedInTheBuildRequestCountAsRequested() async throws {
        let (ledger, unitID, _) = try await unitLedger()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            let id = timeline.insertBatchRequest(purpose: "graph_build", request: .object(["units": .array([.object(["id": .string(unitID)])])]), accuracy: nil, levelCap: nil)
            timeline.failBatch(id: id, error: "prerequisite cycle")
            return (timeline.events, ())
        }
        let (timeline, workbook) = try await ledger.read { db in (try TimelineMachine(loading: db), try WorkbookMachine(loading: db)) }
        // グラフは空のままでも、構築を頼んだ単元の分は頼まない。
        XCTAssertNil(TimelineGraphSchedule.next(timeline: timeline, workbook: workbook))
        XCTAssertTrue(TimelineGraphSchedule.isBlocked(.extend(unitID: unitID), timeline: timeline))
        XCTAssertTrue(TimelineGraphSchedule.isBlocked(.build, timeline: timeline))
    }

    func testNewUnitIsExtendedOnceAndReviewIsAskedOncePerChangeList() async throws {
        let (ledger, unitID, _) = try await unitLedger()
        let second: String = try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            let id = timeline.insertBatchRequest(purpose: "graph_build", request: .object(["units": .array([.string(unitID)])]), accuracy: nil, levelCap: nil)
            var row = timeline.batches[id]!
            row.status = "ready"
            timeline.put("test", row)
            var workbook = try WorkbookMachine(loading: db)
            let second = workbook.createUnit(title: "数列", outcome: "", source: "consult", subunits: [.init(title: "等差数列", n: 2)], firstStage: 1)
            return (timeline.events + workbook.events, second)
        }
        let (loaded, workbook) = try await ledger.read { db in (try TimelineMachine(loading: db), try WorkbookMachine(loading: db)) }
        var timeline = loaded
        XCTAssertEqual(TimelineGraphSchedule.next(timeline: timeline, workbook: workbook), .extend(unitID: second))
        let extend = timeline.insertBatchRequest(purpose: "graph_extend", request: .object(["unit": .object(["id": .string(second)])]), accuracy: nil, levelCap: nil)
        // 頼んでいる最中は次を頼まない。失敗しても同じ単元は頼み直さない。
        XCTAssertNil(TimelineGraphSchedule.next(timeline: timeline, workbook: workbook))
        timeline.failBatch(id: extend, error: "x")
        XCTAssertNil(TimelineGraphSchedule.next(timeline: timeline, workbook: workbook))
        // アプリの変更が 3 つ溜まった: その一覧で 1 回だけ見直しを頼む。
        for index in 0..<3 { timeline.recordChange(kind: "add_prerequisite", detail: .emptyObject, attemptIDs: ["a\(index)"], source: "app") }
        let ids = TimelineGraphSchedule.pendingReviewChanges(timeline)
        XCTAssertEqual(TimelineGraphSchedule.next(timeline: timeline, workbook: workbook), .review(changeIDs: ids))
        let review = timeline.insertBatchRequest(purpose: "graph_review", request: .object(["change_ids": .array(ids.map(LedgerJSON.string))]), accuracy: nil, levelCap: nil)
        timeline.failBatch(id: review, error: "x")
        XCTAssertNil(TimelineGraphSchedule.next(timeline: timeline, workbook: workbook))
    }

    /// 学習中の見直しと 1 段下りる依頼は利用枠に数えないので、7 日に 1 回までしか頼まない。7 日たてば、溜まった変更をまとめて頼む。
    func testReviewAndDescendAreAskedAtMostOnceInSevenDays() async throws {
        let (ledger, unitID, _) = try await unitLedger()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            let id = timeline.insertBatchRequest(purpose: "graph_build", request: .object(["units": .array([.string(unitID)])]), accuracy: nil, levelCap: nil)
            var row = timeline.batches[id]!
            row.status = "ready"
            timeline.put("test", row)
            return (timeline.events, ())
        }
        let (loaded, workbook) = try await ledger.read { db in (try TimelineMachine(loading: db), try WorkbookMachine(loading: db)) }
        var timeline = loaded
        var clock: Date = LedgerClock.parse("2026-11-12T08:00:00.000000+00:00")!
        timeline.now = { LedgerClock.iso(clock) }
        for index in 0..<3 { timeline.recordChange(kind: "add_prerequisite", detail: .emptyObject, attemptIDs: ["a\(index)"], source: "app") }
        let first: [String] = TimelineGraphSchedule.pendingReviewChanges(timeline)
        XCTAssertEqual(TimelineGraphSchedule.next(timeline: timeline, workbook: workbook), .review(changeIDs: first))
        let review: String = timeline.insertBatchRequest(purpose: "graph_review", request: .object(["change_ids": .array(first.map(LedgerJSON.string))]), accuracy: nil, levelCap: nil)
        var row = timeline.batches[review]!
        row.status = "ready"
        timeline.put("test", row)
        // 同じ週のうちに変更がまた溜まっても、見直しは頼まない。
        clock = clock.addingTimeInterval(3 * 86_400)
        for index in 3..<6 { timeline.recordChange(kind: "add_prerequisite", detail: .emptyObject, attemptIDs: ["a\(index)"], source: "app") }
        XCTAssertFalse(TimelineGraphSchedule.upkeepAllowed(timeline))
        XCTAssertNil(TimelineGraphSchedule.next(timeline: timeline, workbook: workbook))
        // 7 日たてば、溜まった分をまとめて頼む。
        clock = clock.addingTimeInterval(4 * 86_400 + 60)
        XCTAssertTrue(TimelineGraphSchedule.upkeepAllowed(timeline))
        XCTAssertEqual(TimelineGraphSchedule.next(timeline: timeline, workbook: workbook), .review(changeIDs: TimelineGraphSchedule.pendingReviewChanges(timeline)))
    }

    /// 撮り足した授業の回(#132): 単元の分を頼んだ後に小単元が足されたら、その単元の分をもう一度頼む。頼んだ後は(失敗しても)頼み直さない。
    func testSubunitAppendedAfterTheGraphIsExtendedOnce() async throws {
        let (ledger, unitID, subunitIDs) = try await unitLedger()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            let id = timeline.insertBatchRequest(purpose: "graph_build", request: .object(["units": .array([.string(unitID)])]), accuracy: nil, levelCap: nil)
            var row = timeline.batches[id]!
            row.status = "ready"
            timeline.put("test", row)
            for subunitID in subunitIDs { timeline.put("test", self.skill("goal.\(subunitID)", unitID: subunitID)) }
            return (timeline.events, ())
        }
        var (loaded, workbook) = try await ledger.read { db in (try TimelineMachine(loading: db), try WorkbookMachine(loading: db)) }
        XCTAssertNil(TimelineGraphSchedule.next(timeline: loaded, workbook: workbook))
        XCTAssertTrue(TimelineGraphSchedule.isBlocked(.extend(unitID: unitID), timeline: loaded, workbook: workbook))

        try await Task.sleep(for: .milliseconds(5))
        try await ledger.commit { db in
            var workbook = try WorkbookMachine(loading: db)
            workbook.appendSubunit(unitID: unitID, spec: .init(title: "ジョルダン標準形", n: 5, ref: "第9回"))
            return (workbook.events, ())
        }
        (loaded, workbook) = try await ledger.read { db in (try TimelineMachine(loading: db), try WorkbookMachine(loading: db)) }
        var timeline = loaded
        XCTAssertEqual(TimelineGraphSchedule.next(timeline: timeline, workbook: workbook), .extend(unitID: unitID))
        XCTAssertFalse(TimelineGraphSchedule.isBlocked(.extend(unitID: unitID), timeline: timeline, workbook: workbook))
        let extend = try XCTUnwrap(TimelineTurns.insertGraphRequest(.extend(unitID: unitID), timeline: &timeline, workbook: workbook, profile: nil))
        XCTAssertTrue(timeline.skills.values.contains { $0.name == "ジョルダン標準形" }, "足した回が目標の点になる")
        timeline.failBatch(id: extend, error: "x")
        XCTAssertNil(TimelineGraphSchedule.next(timeline: timeline, workbook: workbook), "失敗しても頼み直さない")
    }

    @MainActor
    func testRelaunchAfterAFailedBuildDoesNotAskAgain() async throws {
        let (ledger, unitID, _) = try await unitLedger()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            let id = timeline.insertBatchRequest(purpose: "graph_build", request: .object(["units": .array([.object(["id": .string(unitID)])])]), accuracy: nil, levelCap: nil)
            timeline.failBatch(id: id, error: "prerequisite cycle fourier.poly_series -> fourier.write_series -> fourier.poly_series")
            // 前の版で作った点(印が無い): 前提の線が無い一番下の点だけ「まだ掘っていない」になる。
            timeline.put("test", self.skill("fourier.write_series", unitID: nil))
            timeline.put("test", self.skill("calc.product_rule", unitID: nil))
            timeline.addEdge(skillID: "fourier.write_series", requires: "calc.product_rule", relation: "prerequisite", source: "initial", note: "")
            return (timeline.events, ())
        }
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(), runner: MockTurnRunner())
        let store = TimelineStore(ledger: ledger, turns: turns)
        await store.start()
        await store.reload()
        // 起動し直し(新しい store)でも頼まない。
        let again = TimelineStore(ledger: ledger, turns: turns)
        await again.start()
        let timeline = try await ledger.read { db in try TimelineMachine(loading: db) }
        XCTAssertEqual(timeline.batches.values.filter { $0.purpose.hasPrefix("graph") }.count, 1)
        XCTAssertEqual(timeline.skills["calc.product_rule"]?.expansion, "unexplored")
        XCTAssertEqual(timeline.skills["fourier.write_series"]?.expansion, "done")
    }
}
