import GRDB
import XCTest
@testable import strius

/// タイムライン (#46) と iCloud 同期 (#51) を合わせた時の受け入れ (Issue #57)。`LedgerSyncTests` と同じ偽の transport で
/// 2台の台帳をつなぎ、タイムラインの行・答案の写真・依頼の振る舞いが2台で正しく揃うかを見る。
final class TimelineSyncTests: XCTestCase {
    typealias F = TimelineFixture

    private struct Device {
        let ledger: Ledger
        let engine: LedgerSyncEngine
        var root: URL { ledger.deletionRoot }
    }

    private func device(_ cloud: FakeCloud) throws -> Device {
        let ledger = try Ledger.inMemory()
        return Device(ledger: ledger, engine: LedgerSyncEngine(ledger: ledger, transport: FakeTransport(cloud: cloud), build: "1 (1)", eventBatch: 7, fileBatch: 2))
    }

    private func read(_ path: String, in device: Device) -> String? {
        (try? Data(contentsOf: device.root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func timeline(_ ledger: Ledger) async throws -> TimelineMachine {
        try await ledger.read { db in try TimelineMachine(loading: db) }
    }

    private func createUnit(_ ledger: Ledger, title: String) async throws -> (unitID: String, subunitID: String) {
        try await ledger.commit { db in
            var workbook = try WorkbookMachine(loading: db)
            let unitID = workbook.createUnit(title: title, outcome: "", source: "consult", subunits: [.init(title: "最大と最小", n: 2)], firstStage: 4)
            let subunitID = workbook.orderedSubunits(unitID: unitID)[0].id
            var subunit = workbook.subunits[subunitID]!
            subunit.status = "active"
            workbook.put("test", subunit)
            return (workbook.events, (unitID, subunitID))
        }
    }

    /// 単元を作り、タイムラインで 1 問を撮って解き、採点まで済ませる(`TimelineTurnsTests` の往復と同じ)。
    private func solveOnTimeline(_ device: Device) async throws -> (unitID: String, subunitID: String, attemptID: String, capture: String) {
        let (unitID, subunitID) = try await createUnit(device.ledger, title: "二次関数")
        let capture = "timeline-sync.jpg"
        try FileManager.default.createDirectory(at: device.root.appendingPathComponent("captures"), withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: device.root.appendingPathComponent("captures/\(capture)"))
        let attemptID: String = try await device.ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            var skill = F.skill("quad.vertex_form")
            skill.unitId = unitID
            timeline.put("test", skill)
            _ = timeline.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: nil, levelCap: nil)
            timeline.put("test", F.card("card-sync", level: 3, skills: ["quad.vertex_form"], subunitID: subunitID))
            let attempt = timeline.recordCapture(cardID: "card-sync", capturePath: capture, seconds: 20, assisted: false)
            return (timeline.events, attempt)
        }
        let turn = TurnOutcome(planID: "p", round: 1, status: .completed, codexThreadID: nil, codexTurnID: nil,
                               finalText: String(decoding: try JSONSerialization.data(withJSONObject: ["readable": true, "verdict": "correct", "key_suspect": false]), as: UTF8.self),
                               executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: 0)
        try await device.ledger.commit { db in
            let applied = try TimelineTurns.apply(kind: .timelineGrading, targetID: attemptID, outcome: turn, model: "m", db: db)
            return (applied.events, ())
        }
        // 採点のモデルが元の解像度で見た部分(`timeline_view_capture`)。
        let views = device.root.appendingPathComponent("captures/\(TimelineCaptureImage.viewDirectory)")
        try FileManager.default.createDirectory(at: views, withIntermediateDirectories: true)
        try Data("view".utf8).write(to: views.appendingPathComponent("\(attemptID)-0a1b2c3d.jpg"))
        return (unitID, subunitID, attemptID, capture)
    }

    /// 裏で走る store の処理を待つ。
    private func eventually(_ seconds: Double = 3, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await condition()
    }

    // MARK: - 端末Aで解いたタイムラインが、端末Bにそのまま届く

    func testTimelineSolvedOnOneDeviceReachesTheOther() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        let solved = try await solveOnTimeline(a)
        try await a.engine.sync()
        try await b.engine.sync()

        let digestA = try await a.ledger.projectionDigest()
        let digestB = try await b.ledger.projectionDigest()
        XCTAssertEqual(digestA, digestB)
        let onB = try await timeline(b.ledger)
        XCTAssertNotNil(onB.skills["quad.vertex_form"], "スキル")
        XCTAssertEqual(onB.cards["card-sync"]?.status, "answered", "カード")
        XCTAssertEqual(onB.attempts[solved.attemptID]?.verdict, "correct", "答案と採点")
        XCTAssertEqual(onB.attempts[solved.attemptID]?.capturePath, solved.capture)
        XCTAssertEqual(onB.batches.values.filter { $0.purpose == "cards" }.count, 1)
        XCTAssertFalse(onB.log.isEmpty, "今日の記録")
        XCTAssertEqual(read("captures/\(solved.capture)", in: b), "jpeg", "答案の写真")
        XCTAssertEqual(read("captures/\(TimelineCaptureImage.viewDirectory)/\(solved.attemptID)-0a1b2c3d.jpg", in: b), "view")
        // 単元ホームに数えた問題(タイムラインの解答から足す)も届く。
        let sources = try await b.ledger.read { db in try WorkbookMachine(loading: db).problemsOf(subunitID: solved.subunitID).map(\.source) }
        XCTAssertEqual(sources, ["timeline"])
        let pending = try await b.ledger.syncCounts()
        XCTAssertEqual(pending.pending, 0, "タイムラインの表は保留にならない")
        try await b.ledger.rebuild()
        let rebuilt = try await b.ledger.projectionDigest()
        XCTAssertEqual(rebuilt, digestA)
    }

    // MARK: - 単元の削除で、もう片方のタイムラインの行と答案の写真も消える

    func testUnitDeletionErasesTimelineRowsAndCapturesOnTheOtherDevice() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        let solved = try await solveOnTimeline(a)
        // 消さない単元(残ることを見る)。
        let (keptUnit, _) = try await createUnit(a.ledger, title: "三角比")
        try await a.engine.sync()
        try await b.engine.sync()
        XCTAssertEqual(read("captures/\(solved.capture)", in: b), "jpeg")

        let fact = try await a.ledger.deleteUnit(id: solved.unitID)
        for key in [LedgerEntity.timelineSkills, .timelineCards, .timelineAttempts, .timelineLog] {
            XCTAssertFalse(fact.scope.ids[key.rawValue, default: []].isEmpty, "\(key.rawValue) が削除の範囲に入る")
        }
        XCTAssertNil(read("captures/\(solved.capture)", in: a), "消した端末から答案の写真が消える")
        try await a.engine.sync()
        try await b.engine.sync()
        try await a.engine.sync()

        let onB = try await timeline(b.ledger)
        XCTAssertNil(onB.skills["quad.vertex_form"])
        XCTAssertNil(onB.cards["card-sync"])
        XCTAssertNil(onB.attempts[solved.attemptID])
        XCTAssertFalse(onB.log.values.contains { $0.attemptId == solved.attemptID || $0.unitId == solved.unitID })
        XCTAssertNil(read("captures/\(solved.capture)", in: b), "もう片方からも答案の写真が消える")
        for device in [a, b] {
            XCTAssertNil(read("captures/\(TimelineCaptureImage.viewDirectory)/\(solved.attemptID)-0a1b2c3d.jpg", in: device), "モデルに見せた部分も消える")
        }
        let events = try await b.ledger.events()
        XCTAssertFalse(events.contains { $0.entity.hasPrefix("timeline_") && $0.payload.contains(solved.attemptID) }, "範囲のイベントが残っている")
        let units = try await b.ledger.read { db in try WorkbookUnitRecord.fetchAll(db).map(\.id) }
        XCTAssertEqual(units, [keptUnit])
        let digestA = try await a.ledger.projectionDigest()
        let digestB = try await b.ledger.projectionDigest()
        XCTAssertEqual(digestA, digestB)
    }

    // MARK: - 仮説1: 他端末で作った単元が届いても、こちらで知識グラフを重ねて頼まない

    @MainActor func testUnitFromAnotherDeviceDoesNotMakeThisDeviceAskForTheGraph() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        // 最初の単元の知識グラフは、もう頼んである(終わっている)。
        let (first, _) = try await createUnit(a.ledger, title: "二次関数")
        try await a.ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            let id = timeline.insertBatchRequest(purpose: "graph_build", request: .object(["units": .array([.object(["id": .string(first)])])]), accuracy: nil, levelCap: nil)
            timeline.failBatch(id: id, error: "test")
            return (timeline.events, ())
        }
        try await a.engine.sync()
        try await b.engine.sync()
        // B でタイムラインを開いている。
        let storeB = TimelineStore(ledger: b.ledger, turns: TurnCoordinator(ledger: b.ledger, assets: AssetCache(lenient: true), runner: MockTurnRunner()))
        await storeB.start()
        try await b.engine.sync()
        try await a.engine.sync()

        // A で新しい単元を作る(A ではまだタイムラインを開いていない)。B に届く。
        let (unitID, _) = try await createUnit(a.ledger, title: "三角比")
        try await a.engine.sync()
        try await b.engine.sync()
        func graphRequests(_ ledger: Ledger) async throws -> Int {
            try await timeline(ledger).batches.values.filter {
                ($0.purpose == "graph_build" || $0.purpose == "graph_extend") && TimelineGraphSchedule.unitIDs(in: $0.request).contains(unitID)
            }.count
        }
        try await Task.sleep(for: .milliseconds(600))
        let askedOnB = try await graphRequests(b.ledger)
        XCTAssertEqual(askedOnB, 0, "他端末の単元が届いただけで、B は知識グラフを頼まない")

        // A がタイムラインを開くと、A が頼む。2台で1回だけ。
        let storeA = TimelineStore(ledger: a.ledger, turns: TurnCoordinator(ledger: a.ledger, assets: AssetCache(lenient: true), runner: MockTurnRunner()))
        await storeA.start()
        let askedOnA = try await eventually { try await graphRequests(a.ledger) == 1 }
        XCTAssertTrue(askedOnA)
        try await Task.sleep(for: .milliseconds(300))
        try await a.engine.sync()
        try await b.engine.sync()
        try await a.engine.sync()
        try await Task.sleep(for: .milliseconds(300))
        let totalA = try await graphRequests(a.ledger)
        let totalB = try await graphRequests(b.ledger)
        XCTAssertEqual(totalA, 1)
        XCTAssertEqual(totalB, 1)
        _ = (storeA, storeB)
    }

    // MARK: - 仮説2: 他端末の「頼んでいる最中」の5枚で、こちらの端末が待ったままにならない

    @MainActor func testAnotherDevicesPendingBatchDoesNotKeepThisDeviceWaiting() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        _ = try await createUnit(a.ledger, title: "二次関数")
        // A が5枚を頼んだ直後に閉じた(行は `requested` のまま)。
        let pendingOnA: String = try await a.ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            let id = timeline.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: nil, levelCap: nil)
            return (timeline.events, id)
        }
        try await a.engine.sync()
        try await b.engine.sync()
        let arrived = try await timeline(b.ledger)
        XCTAssertEqual(arrived.pendingBatch(purpose: "cards")?.id, pendingOnA)

        let storeB = TimelineStore(ledger: b.ledger, turns: TurnCoordinator(ledger: b.ledger, assets: AssetCache(lenient: true), runner: MockTurnRunner()))
        await storeB.start()
        let gotCards = try await eventually { try await self.timeline(b.ledger).queue.count > 0 }
        XCTAssertTrue(gotCards, "B は自分で5枚を頼んで解き始められる")
        let ownBatches = try await timeline(b.ledger).batches.values.filter { $0.purpose == "cards" && $0.id != pendingOnA }
        XCTAssertEqual(ownBatches.count, 1)
        // A の行はそのまま(A が次に開いた時に A が続きを回す)。
        let aRow = try await timeline(b.ledger).batches[pendingOnA]
        XCTAssertEqual(aRow?.status, "requested")
        _ = storeB
    }

    // MARK: - 仮説3: 他端末から届いた今日の記録が、こちらの端末の依頼の先頭を書き換えない

    func testLogFromAnotherDeviceDoesNotRewriteThisDevicesPrefix() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        func append(_ ledger: Ledger, _ text: String) async throws {
            try await ledger.commit { db in
                var timeline = try TimelineMachine(loading: db)
                timeline.appendLog(kind: "note", text: text)
                return (timeline.events, ())
            }
        }
        func prefix(_ ledger: Ledger) async throws -> String {
            let log = TimelineTurns.answerLog(timeline: try await timeline(ledger))
            return String(log.dropLast(ClaudeTranslation.logEnd.count))
        }
        // 同じ日に、同期の前に2台で書く。
        try await append(a.ledger, "A の1件目")
        try await append(a.ledger, "A の2件目")
        try await Task.sleep(for: .milliseconds(5))
        try await append(b.ledger, "B の1件目")
        let beforeA = try await prefix(a.ledger)
        let beforeB = try await prefix(b.ledger)

        try await a.engine.sync()
        try await b.engine.sync()
        try await a.engine.sync()
        let afterA = try await prefix(a.ledger)
        let afterB = try await prefix(b.ledger)
        XCTAssertTrue(afterA.hasPrefix(beforeA), "A に B の記録が届いても、A が前に送った先頭は変わらない:\n\(afterA)")
        XCTAssertTrue(afterB.hasPrefix(beforeB), "B に A の記録が届いても、B が前に送った先頭は変わらない:\n\(afterB)")
        XCTAssertTrue(afterA.contains("B の1件目"))
        XCTAssertTrue(afterB.contains("A の2件目"))

        // 届いた後に書いた分は、それぞれの端末で最後に付く。
        try await append(a.ledger, "A の3件目")
        let nextA = try await prefix(a.ledger)
        XCTAssertTrue(nextA.hasPrefix(afterA))
        XCTAssertTrue(nextA.hasSuffix("A の3件目"))
        // 作り直しても同じ並び。
        try await a.ledger.rebuild()
        let rebuilt = try await prefix(a.ledger)
        XCTAssertEqual(rebuilt, nextA)
    }
}
