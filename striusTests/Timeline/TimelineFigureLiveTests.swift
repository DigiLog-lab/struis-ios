import GRDB
import SwiftUI
import UIKit
import XCTest
@testable import strius

/// 図形の問題の図(2026-11-19 のプロトタイプ)を、実際の Anthropic で出題させて確かめる(手動の測定)。
///
/// `TEST_RUNNER_STRUIS_FIGURE_LIVE=<出力先>` と `TEST_RUNNER_STRUIS_DEBUG_ANTHROPIC_KEY_FILE` を渡した時だけ動く。
/// 図やグラフが前提になる単元(`STRUIS_FIGURE_LIVE_UNITS`)ごとに、その単元に絞ったタイムラインで5枚を頼み
/// (`STRUIS_FIGURE_LIVE_BATCHES` 回、既定 1)、受け取ったカード・断ったカードの理由・費用を `<出力先>/figure_live.json` に書く。
/// 画面は `TimelineFigureShotsUITests` が、このファイルのカードを実際のタイムラインに出して撮る。
/// `STRUIS_FIGURE_LIVE_LIMIT`(ドル、既定 2)に達したら止める。
final class TimelineFigureLiveTests: XCTestCase {
    private struct Unit {
        var key: String
        var title: String
        var outcome: String
        var skills: [String]
    }

    /// 図やグラフが前提になる単元(中学・高校)。`STRUIS_FIGURE_LIVE_UNITS`(「congruence,graphs」)で選ぶ。既定は合同だけ。
    private static let units: [Unit] = [
        Unit(key: "congruence", title: "図形の性質と証明", outcome: "三角形の合同を使って角の大きさを求め、合同を証明できる", skills: [
            "回したり重ねたりした合同な三角形の対応から、角の大きさを求める", "平行線と合同を組み合わせて角の大きさを求める",
            "交点のある図で、三角形の合同を証明する", "図から合同条件を選ぶ", "二等辺三角形・平行四辺形の性質を使って角や辺を求める"]),
        Unit(key: "similarity", title: "相似な図形と円", outcome: "相似・円周角・三平方の定理で長さと角を求められる", skills: [
            "相似な三角形を見つけて辺の長さを求める", "平行線と線分の比を使う", "円周角の定理で角の大きさを求める",
            "円と相似を使って証明する", "三平方の定理で平面図形の長さを求める"]),
        Unit(key: "space", title: "空間図形", outcome: "立体の見取図から長さ・角・体積・表面積を求められる", skills: [
            "見取図から辺や面の位置関係(平行・垂直・ねじれ)を読む", "角柱・角錐・円柱・円錐の体積と表面積を求める",
            "三平方の定理を立体に使って対角線や高さを求める", "立体の切り口の形と面積を求める", "おうぎ形の弧の長さと面積を求める"]),
        Unit(key: "functions", title: "一次関数と関数 y=ax²", outcome: "グラフから式・交点・面積を求められる", skills: [
            "一次関数のグラフから式を求める", "2 直線の交点の座標を求める", "放物線 y=ax² と直線の交点を求める",
            "グラフ上の三角形の面積を求める", "変化の割合をグラフから求める"]),
        Unit(key: "quadratic", title: "二次関数と図形と計量", outcome: "二次関数のグラフと三角比を使える", skills: [
            "二次関数のグラフの頂点と軸を求める", "定義域のある二次関数の最大値・最小値を求める", "グラフと x 軸の共有点から二次不等式を解く",
            "グラフの平行移動・対称移動", "正弦定理・余弦定理で三角形の辺と角を求める"]),
        Unit(key: "trig", title: "三角関数・指数関数・対数関数・図形と方程式", outcome: "グラフを読んで式・値・領域を求められる", skills: [
            "三角関数のグラフの周期・振幅・平行移動を読む", "単位円で三角関数の値を求める", "指数関数・対数関数のグラフを比べる",
            "円と直線の位置関係を調べる", "不等式の表す領域を図示して最大・最小を求める"]),
        Unit(key: "calculus", title: "微分と積分", outcome: "接線・増減・面積をグラフと結びつけて求められる", skills: [
            "接線の方程式を求める", "増減表とグラフから極値を求める", "曲線と直線で囲まれた部分の面積を求める",
            "2 曲線で囲まれた部分の面積を求める", "媒介変数で表された曲線を読む"]),
        Unit(key: "vectors", title: "ベクトルと平面上の曲線", outcome: "ベクトルを図で表し、内分点・内積・2次曲線を扱える", skills: [
            "平面ベクトルの和と差を図で表す", "位置ベクトルで内分点を表す", "内積でベクトルのなす角を求める",
            "空間ベクトルで立体の点の位置を表す", "楕円・双曲線のグラフから式を求める"]),
    ]

    @MainActor
    func testFigureCardsComeWithFigures() async throws {
        let env = ProcessInfo.processInfo.environment
        let folder = env["STRUIS_FIGURE_LIVE"] ?? ""
        let keyFile = env["STRUIS_DEBUG_ANTHROPIC_KEY_FILE"] ?? ""
        try XCTSkipIf(folder.isEmpty || keyFile.isEmpty, "手動の測定(TEST_RUNNER_STRUIS_FIGURE_LIVE と鍵のファイルが要る)")
        let limit: Double = Double(env["STRUIS_FIGURE_LIVE_LIMIT"] ?? "") ?? 2.0
        let rounds: Int = Int(env["STRUIS_FIGURE_LIVE_BATCHES"] ?? "") ?? 1
        let wanted = Set((env["STRUIS_FIGURE_LIVE_UNITS"] ?? "congruence").split(separator: ",").map(String.init))
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let key = try String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        let assets = AssetCache()
        let upstream = ClaudeUpstream(baseURL: URL(string: "https://api.anthropic.com")!, apiKey: { key }, gate: OpenUsageGate())
        let composer = TurnComposer(assets: assets)
        try StruisPaths.prepare()
        let previousScope = TimelineScope.unitID
        defer { TimelineScope.unitID = previousScope }

        var spent: Double = 0
        var report: [[String: Any]] = []
        var rows: [[String: Any]] = []
        for unit in Self.units where wanted.contains(unit.key) {
            guard spent < limit else { print("FIGURE_LIVE stopped at the limit before \(unit.key)"); break }
            let runner = ClaudeTurnRunner(assets: assets, conversations: try ClaudeConversationStore.temporary(), upstream: upstream,
                                          contextStore: ThreadContextStore(url: nil), prepareCommands: {})
            let ledger = try Ledger.inMemory()
            TimelineQueryHost.install(ledger)
            let unitID = "u-\(unit.key)"
            TimelineScope.unitID = unitID
            try await seed(ledger, unit: unit, unitID: unitID, warm: env["STRUIS_FIGURE_LIVE_WARM"] != "0")
            for index in 1...rounds {
                guard spent < limit else { break }
                let batchID: String = try await ledger.commit { db in
                    var timeline = try TimelineMachine(loading: db)
                    // 前の5枚は解き終えたことにする(次の5枚が同じ所を繰り返さないように)。
                    for card in timeline.queue { timeline.markShown(card.id) }
                    let id = timeline.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: nil, levelCap: nil)
                    return (timeline.events, id)
                }
                var round = 0
                var repair: String?
                var record: [String: Any] = ["unit": unit.key, "batch": index]
                var roundsDone: [[String: Any]] = []
                while round < 2, spent < limit {
                    round += 1
                    let (workbook, timeline): (WorkbookMachine, TimelineMachine) = try await ledger.commit { db in
                        let workbook = try WorkbookMachine(loading: db)
                        var timeline = try TimelineMachine(loading: db)
                        TimelineTurns.syncLog(workbook: workbook, timeline: &timeline)
                        return (timeline.events, (workbook, timeline))
                    }
                    let plan = try await TimelineTurns.batch(composer: composer, planID: "figure-live-\(unit.key)-\(index)-\(round)", batchID: batchID,
                                                             workbook: workbook, timeline: timeline, repair: repair)
                    let begin = Date()
                    let outcome = try await runner.run(plan) { _ in }
                    WorkspaceStager.cleanup(plan: plan)
                    let cost = outcome.executions.compactMap { $0["estimated_cost_usd"]?.doubleValue }.last ?? 0
                    spent += cost
                    let followUp: TimelineTurns.FollowUp = try await ledger.commit { db in
                        try TimelineTurns.apply(kind: .timelineBatch, targetID: batchID, outcome: outcome, model: plan.thread.model, db: db)
                    }
                    let rejectedNow: [String] = try await ledger.read { db in try TimelineMachine(loading: db).batches[batchID]?.rejected ?? [] }
                    roundsDone.append(["round": round, "status": outcome.status.rawValue, "cost": cost, "seconds": Date().timeIntervalSince(begin),
                                       "model": plan.thread.model, "error": outcome.errorDetail ?? "", "retry": followUp.retry, "rejected": rejectedNow])
                    print(String(format: "FIGURE_LIVE unit=%@ batch=%d round=%d status=%@ cost=$%.4f retry=%@ rejected=%d", unit.key, index, round,
                                 outcome.status.rawValue, cost, followUp.retry ? "yes" : "no", rejectedNow.count))
                    guard followUp.retry else { break }
                    repair = followUp.repair
                }
                let batch: TimelineBatchRecord? = try await ledger.read { db in try TimelineMachine(loading: db).batches[batchID] }
                record["rounds"] = roundsDone
                record["status"] = batch?.status ?? ""
                record["reason"] = batch?.reason ?? ""
                report.append(record)
            }
            // 受け取ったカード(図の有無・中身)。
            let cards: [TimelineCardRecord] = try await ledger.read { db in
                try TimelineMachine(loading: db).cards.values.filter { $0.origin == "batch" && !$0.id.hasPrefix("warm-") }.sorted { $0.position < $1.position }
            }
            rows += cards.map { card in
                ["unit": unit.key, "id": card.id, "kind": card.kind, "level": card.level, "skills": card.skills, "prompt": card.prompt, "math": card.math,
                 "question": card.question, "answer_key": card.answerKey, "steps": card.payload["steps"]?.any ?? [],
                 "figure": card.payload["figure"]?.any ?? NSNull(), "easier": card.payload["easier"]?.any ?? NSNull(),
                 "variant": card.payload["variant"]?.any ?? NSNull()]
            }
        }
        let withFigure = rows.filter { !($0["figure"] is NSNull) }.count
        let summary: [String: Any] = ["spent_usd": spent, "batches": report, "cards": rows, "with_figure": withFigure, "total": rows.count]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("figure_live.json"))
        print(String(format: "FIGURE_LIVE spent=$%.4f cards=%d with_figure=%d", spent, rows.count, withFigure))
        XCTAssertGreaterThan(rows.count, 0)
    }

    /// 単元とスキル。`warm` なら、どのスキルも昨日 5 問中 5 問 ○ だったことにする(段 1〜2 の易しい問題から先へ進ませ、
    /// 重なった三角形のような難しい図を出させる)。
    private func seed(_ ledger: Ledger, unit: Unit, unitID: String, warm: Bool) async throws {
        let now = LedgerClock.now()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        let yesterday = formatter.string(from: Date().addingTimeInterval(-86_400))
        try await ledger.commit { db in
            let record = WorkbookUnitRecord(id: unitID, title: unit.title, outcome: unit.outcome, status: "active", source: "manual", position: 0,
                                            overview: .emptyObject, createdAt: now, updatedAt: now, passedAt: nil)
            var timeline = try TimelineMachine(loading: db)
            for (number, name) in unit.skills.enumerated() {
                let skillID = "\(unit.key).s\(number + 1)"
                timeline.put("test", TimelineSkillRecord(id: skillID, name: name, kind: "procedure", unitId: unitID, status: "practicing",
                                                         correctDates: [], masteryThreshold: 3, attempts: 0, lastCorrectAt: nil, nextReviewAt: nil,
                                                         reviewCount: 0, replacedBy: [], source: "initial", createdAt: now, updatedAt: now, expansion: "done"))
                guard warm else { continue }
                for n in 1...5 {
                    let cardID = "warm-\(skillID)-\(n)"
                    timeline.put("test", TimelineCardRecord(
                        id: cardID, batchId: nil, position: -100 + n, kind: "solve", level: 2, skills: [skillID], typeName: "練習",
                        prompt: "\(name)(練習 \(n))", math: "", question: "", answerKey: "", answerExpr: "", checkpoints: [], commonMistakes: [],
                        estimatedSeconds: 60, chain: nil, easierOf: nil, subunitId: nil, unitId: unitID, payload: .emptyObject, origin: "batch",
                        status: "answered", createdAt: yesterday, updatedAt: yesterday))
                    timeline.put("test", TimelineAttemptRecord(
                        id: "warm-a-\(skillID)-\(n)", cardId: cardID, capturePath: nil, verdict: "correct", checkpointResults: .emptyArray,
                        errors: .emptyArray, learnerAnswer: "", cause: "unknown", seconds: 60, firstTry: true, assisted: false, skipReason: nil,
                        keySuspect: false, countsForAccuracy: true, feedback: "", createdAt: yesterday, gradedAt: yesterday))
                }
            }
            return ([.upsert("test", record)] + timeline.events, ())
        }
    }

    /// 前に保存した `figure_live.json` のカードを、今の描き方で撮り直す(API は使わない)。
    /// `TEST_RUNNER_STRUIS_FIGURE_REPLAY=<figure_live.json>` と `TEST_RUNNER_STRUIS_FIGURE_LIVE=<出力先>` を渡した時だけ動く。
    @MainActor
    func testReplayRendersSavedCards() async throws {
        let env = ProcessInfo.processInfo.environment
        let replay = env["STRUIS_FIGURE_REPLAY"] ?? "", folder = env["STRUIS_FIGURE_LIVE"] ?? ""
        try XCTSkipIf(replay.isEmpty || folder.isEmpty, "手動の撮り直し(TEST_RUNNER_STRUIS_FIGURE_REPLAY が要る)")
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let summary = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: replay))) as? [String: Any])
        let rows = try XCTUnwrap(summary["cards"] as? [[String: Any]])
        let ledger = try Ledger.inMemory()
        let now = LedgerClock.now()
        let cards: [TimelineCardRecord] = try rows.enumerated().map { index, row in
            let figure = try JSONDecoder().decode(LedgerJSON.self, from: JSONSerialization.data(withJSONObject: row["figure"] ?? NSNull(), options: .fragmentsAllowed))
            return TimelineCardRecord(
                id: row["id"] as? String ?? "r\(index)", batchId: nil, position: index, kind: row["kind"] as? String ?? "solve", level: row["level"] as? Int ?? 1,
                skills: [], typeName: "", prompt: row["prompt"] as? String ?? "", math: row["math"] as? String ?? "", question: row["question"] as? String ?? "",
                answerKey: row["answer_key"] as? String ?? "", answerExpr: "", checkpoints: [], commonMistakes: [], estimatedSeconds: 60, chain: nil,
                easierOf: nil, subunitId: nil, unitId: nil, payload: .object(["figure": figure]), origin: "batch", status: "unused", createdAt: now, updatedAt: now)
        }
        let store = TimelineStore(ledger: ledger, turns: TurnCoordinator(ledger: ledger, assets: AssetCache(), runner: MockTurnRunner()))
        for (number, card) in cards.enumerated() where TimelineFigure(card.payload["figure"]) != nil {
            let png = try snapshot(TimelineFigureLiveScreen(card: card, store: store), size: CGSize(width: 402, height: 874))
            try png.write(to: out.appendingPathComponent(String(format: "replay-%02d-iphone.png", number + 1)))
        }
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
