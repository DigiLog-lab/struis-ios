import GRDB
import SwiftUI
import UIKit
import XCTest
@testable import strius

/// 図形の問題の図(2026-11-19 のプロトタイプ)を、実際の Anthropic で出題させて確かめる(手動の測定)。
///
/// `TEST_RUNNER_STRUIS_FIGURE_LIVE=<出力先>` と `TEST_RUNNER_STRUIS_DEBUG_ANTHROPIC_KEY_FILE` を渡した時だけ動く。
/// 中2「図形の性質と証明」に絞ったタイムラインで5枚を頼み(`STRUIS_FIGURE_LIVE_BATCHES` 回、既定 2)、受け取ったカード・
/// 断ったカードの理由・費用を `<出力先>/figure_live.json` に、カードの画面(iPhone の幅)を `<出力先>/card-<番号>.png` に書く。
/// `STRUIS_FIGURE_LIVE_LIMIT`(ドル、既定 2)に達したら止める。
final class TimelineFigureLiveTests: XCTestCase {
    private static let unitID = "u-geo"

    private static let skills: [(id: String, name: String)] = [
        ("geo.parallel_angles", "平行線の同位角・錯角を使って角の大きさを求める"),
        ("geo.triangle_angles", "三角形の内角の和・外角の性質を使って角の大きさを求める"),
        ("geo.congruence_conditions", "三角形の合同条件を使い分ける"),
        ("geo.congruent_parts", "合同な図形の対応する辺・角を使って長さや角を求める"),
        ("geo.congruence_proof", "三角形の合同を証明する"),
    ]

    @MainActor
    func testGeometryCardsComeWithFigures() async throws {
        let env = ProcessInfo.processInfo.environment
        let folder = env["STRUIS_FIGURE_LIVE"] ?? ""
        let keyFile = env["STRUIS_DEBUG_ANTHROPIC_KEY_FILE"] ?? ""
        try XCTSkipIf(folder.isEmpty || keyFile.isEmpty, "手動の測定(TEST_RUNNER_STRUIS_FIGURE_LIVE と鍵のファイルが要る)")
        let limit: Double = Double(env["STRUIS_FIGURE_LIVE_LIMIT"] ?? "") ?? 2.0
        let rounds: Int = Int(env["STRUIS_FIGURE_LIVE_BATCHES"] ?? "") ?? 2
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let key = try String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        let assets = AssetCache()
        let upstream = ClaudeUpstream(baseURL: URL(string: "https://api.anthropic.com")!, apiKey: { key }, gate: OpenUsageGate())
        let runner = ClaudeTurnRunner(assets: assets, conversations: try ClaudeConversationStore.temporary(), upstream: upstream,
                                      contextStore: ThreadContextStore(url: nil), prepareCommands: {})
        let composer = TurnComposer(assets: assets)

        // 台帳: 単元(固定して頼む)と、そのスキル。
        let ledger = try Ledger.inMemory()
        TimelineQueryHost.install(ledger)
        try StruisPaths.prepare()
        let previousScope = TimelineScope.unitID
        TimelineScope.unitID = Self.unitID
        defer { TimelineScope.unitID = previousScope }
        let now = LedgerClock.now()
        try await ledger.commit { db in
            let unit = WorkbookUnitRecord(id: Self.unitID, title: "図形の性質と証明", outcome: "三角形の合同を使って角の大きさを求め、合同を証明できる",
                                          status: "active", source: "manual", position: 0, overview: .emptyObject, createdAt: now, updatedAt: now, passedAt: nil)
            var timeline = try TimelineMachine(loading: db)
            for skill in Self.skills {
                timeline.put("test", TimelineSkillRecord(id: skill.id, name: skill.name, kind: "procedure", unitId: Self.unitID, status: "practicing",
                                                         correctDates: [], masteryThreshold: 3, attempts: 0, lastCorrectAt: nil, nextReviewAt: nil,
                                                         reviewCount: 0, replacedBy: [], source: "initial", createdAt: now, updatedAt: now, expansion: "done"))
            }
            return ([.upsert("test", unit)] + timeline.events, ())
        }

        var spent: Double = 0
        var report: [[String: Any]] = []
        for index in 1...rounds {
            guard spent < limit else { print("FIGURE_LIVE stopped at the limit before batch \(index)"); break }
            let batchID: String = try await ledger.commit { db in
                var timeline = try TimelineMachine(loading: db)
                // 前の5枚は解き終えたことにする(次の5枚が同じ所を繰り返さないように)。
                for card in timeline.queue { timeline.markShown(card.id) }
                let id = timeline.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: nil, levelCap: nil)
                return (timeline.events, id)
            }
            var round = 0
            var repair: String?
            var record: [String: Any] = ["batch": index]
            while round < 2, spent < limit {
                round += 1
                let (workbook, timeline): (WorkbookMachine, TimelineMachine) = try await ledger.commit { db in
                    let workbook = try WorkbookMachine(loading: db)
                    var timeline = try TimelineMachine(loading: db)
                    TimelineTurns.syncLog(workbook: workbook, timeline: &timeline)
                    return (timeline.events, (workbook, timeline))
                }
                let plan = try await TimelineTurns.batch(composer: composer, planID: "figure-live-\(index)-\(round)", batchID: batchID,
                                                         workbook: workbook, timeline: timeline, repair: repair)
                let begin = Date()
                let outcome = try await runner.run(plan) { _ in }
                WorkspaceStager.cleanup(plan: plan)
                let cost = outcome.executions.compactMap { $0["estimated_cost_usd"]?.doubleValue }.last ?? 0
                spent += cost
                let followUp: TimelineTurns.FollowUp = try await ledger.commit { db in
                    try TimelineTurns.apply(kind: .timelineBatch, targetID: batchID, outcome: outcome, model: plan.thread.model, db: db)
                }
                var rounds = (record["rounds"] as? [[String: Any]]) ?? []
                rounds.append(["round": round, "status": outcome.status.rawValue, "cost": cost, "seconds": Date().timeIntervalSince(begin),
                               "model": plan.thread.model, "error": outcome.errorDetail ?? "", "retry": followUp.retry,
                               "commands": outcome.executions.reduce(0) { $0 + ($1["commands"]?.arrayValue?.count ?? 0) }])
                record["rounds"] = rounds
                print(String(format: "FIGURE_LIVE batch=%d round=%d status=%@ cost=$%.4f retry=%@", index, round, outcome.status.rawValue, cost,
                             followUp.retry ? "yes" : "no"))
                guard followUp.retry else { break }
                repair = followUp.repair
            }
            let batch: TimelineBatchRecord? = try await ledger.read { db in try TimelineMachine(loading: db).batches[batchID] }
            record["rejected"] = batch?.rejected ?? []
            record["status"] = batch?.status ?? ""
            record["reason"] = batch?.reason ?? ""
            report.append(record)
        }

        // 受け取ったカード(図の有無・中身)。
        let cards: [TimelineCardRecord] = try await ledger.read { db in
            try TimelineMachine(loading: db).cards.values.filter { $0.origin == "batch" }.sorted { $0.position < $1.position }
        }
        let rows: [[String: Any]] = cards.map { card in
            ["id": card.id, "kind": card.kind, "level": card.level, "skills": card.skills, "prompt": card.prompt, "math": card.math,
             "question": card.question, "answer_key": card.answerKey, "steps": card.payload["steps"]?.any ?? [],
             "figure": card.payload["figure"]?.any ?? NSNull(), "easier": card.payload["easier"]?.any ?? NSNull(),
             "variant": card.payload["variant"]?.any ?? NSNull()]
        }
        let summary: [String: Any] = ["spent_usd": spent, "batches": report, "cards": rows,
                                      "with_figure": cards.filter { TimelineFigure($0.payload["figure"]) != nil }.count, "total": cards.count]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("figure_live.json"))
        print(String(format: "FIGURE_LIVE spent=$%.4f cards=%d with_figure=%d", spent, cards.count, summary["with_figure"] as? Int ?? 0))

        // カードの画面を、実際の画面と同じ部品(`TimelineProblemView`)で撮る。
        let store = TimelineStore(ledger: ledger, turns: TurnCoordinator(ledger: ledger, assets: AssetCache(), runner: MockTurnRunner()))
        await store.reload()
        for (number, card) in cards.enumerated() {
            for (device, size) in [("iphone", CGSize(width: 402, height: 874)), ("ipad", CGSize(width: 820, height: 1180))] {
                let png = try snapshot(TimelineFigureLiveScreen(card: card, store: store), size: size)
                try png.write(to: out.appendingPathComponent(String(format: "card-%02d-%@.png", number + 1, device)))
            }
        }
        XCTAssertGreaterThan(cards.count, 0)
    }

    /// 画面に組んでから撮る(数式は UIKit で描くので、`ImageRenderer` では写らない)。
    @MainActor
    private func snapshot<V: View>(_ view: V, size: CGSize) throws -> Data {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}

/// タイムラインの 1 枚と同じ並び(上に寄せた問題、左右の余白)。
private struct TimelineFigureLiveScreen: View {
    let card: TimelineCardRecord
    let store: TimelineStore

    var body: some View {
        ScrollView {
            TimelineProblemView(card: card, store: store)
                .padding(.horizontal, 24)
                .padding(.top, 70)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.ground.ignoresSafeArea())
    }
}
