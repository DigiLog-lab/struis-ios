import GRDB
import XCTest
@testable import strius

/// 戻った時の計算練習(#155): 離れて戻ったら、計算のつまずきの点の易しい問題を 2〜3 問出してから元に戻る。
/// 正答率・点の ○×・今日の記録の 1 問ずつには数えない。
final class TimelineWarmupTests: XCTestCase {
    private typealias F = TimelineFixture

    private func exponentTemplate(skillID: String = "exp") throws -> DrillTemplate {
        let root = try XCTUnwrap(DrillTestSupport.fixturesRoot())
        var text = try String(contentsOf: root.appendingPathComponent("math/math.m2.exponent_laws.json"), encoding: .utf8)
        text = text.replacingOccurrences(of: "\"math.m2.exponent_laws\"", with: "\"\(skillID)\"")
        return try DrillTemplate.decode(json: text)
    }

    private func grading(_ grade: String, skills: [String] = []) throws -> TimelineMachine.Grading {
        let object: [String: Any] = ["readable": true, "grade": grade, "learner_answer": "0", "skill_ids": skills, "transcript": "",
                                     "notes": "", "comment": "", "key_suspect": false]
        return try TimelineMachine.Grading.parse(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    // MARK: いつ出すか・何問出すか

    func testTiming() {
        XCTAssertEqual(TimelineWarmup.timing(awaySeconds: 299, midCard: false), .none, "5分未満は出さない")
        XCTAssertEqual(TimelineWarmup.timing(awaySeconds: 300, midCard: false), .now)
        XCTAssertEqual(TimelineWarmup.timing(awaySeconds: 300, midCard: true), .afterAnswer, "解いている途中で 30 分未満: 答えを送った後")
        XCTAssertEqual(TimelineWarmup.timing(awaySeconds: 1799, midCard: true), .afterAnswer)
        XCTAssertEqual(TimelineWarmup.timing(awaySeconds: 1800, midCard: true), .now, "30 分以上: 先に出す")
    }

    func testTwoWhenBothCorrectOtherwiseThree() {
        XCTAssertTrue(TimelineWarmup.wantsAnother(results: []))
        XCTAssertTrue(TimelineWarmup.wantsAnother(results: [true]))
        XCTAssertFalse(TimelineWarmup.wantsAnother(results: [true, true]), "2 問とも ○ なら 2 問で戻る")
        XCTAssertTrue(TimelineWarmup.wantsAnother(results: [true, false]))
        XCTAssertTrue(TimelineWarmup.wantsAnother(results: [false, false]))
        XCTAssertFalse(TimelineWarmup.wantsAnother(results: [false, true, false]), "3 問で必ず戻る")
        XCTAssertNil(TimelineWarmup.note(skillName: "指数法則", results: [true, false, true]))
        XCTAssertNotNil(TimelineWarmup.note(skillName: "指数法則", results: [false, true, false]))
    }

    // MARK: 答えの式

    func testAnswerExprOnlyForNumbers() throws {
        XCTAssertEqual(TimelineWarmup.answerExpr(fromAnswer: "$16$"), "16")
        let fraction = TimelineWarmup.answerExpr(fromAnswer: "$\\frac{1}{8}$")
        XCTAssertEqual(try TimelineExpression.parse(fraction).evaluate([:]) ?? .nan, 0.125, accuracy: 1e-12)
        let negative = TimelineWarmup.answerExpr(fromAnswer: "$-\\dfrac{3}{4}$")
        XCTAssertEqual(try TimelineExpression.parse(negative).evaluate([:]) ?? .nan, -0.75, accuracy: 1e-12)
        let root = TimelineWarmup.answerExpr(fromAnswer: "$\\sqrt{2}$")
        XCTAssertEqual(try TimelineExpression.parse(root).evaluate([:]) ?? .nan, 2.0.squareRoot(), accuracy: 1e-12)
        // 文字・等号・単位・日本語の答えは、いつもの採点に回す。
        XCTAssertEqual(TimelineWarmup.answerExpr(fromAnswer: "$x^{2}+3x$"), "")
        XCTAssertEqual(TimelineWarmup.answerExpr(fromAnswer: "$x = 3$"), "")
        XCTAssertEqual(TimelineWarmup.answerExpr(fromAnswer: "$3.5\\ \\mathrm{m/s}$"), "")
        XCTAssertEqual(TimelineWarmup.answerExpr(fromAnswer: "$1 < x < 3$"), "")
        XCTAssertEqual(TimelineWarmup.answerExpr(fromAnswer: "最小値 $-5$"), "")
    }

    // MARK: 台帳

    /// 型から作った問題は、ふつうのカードと同じ形で出て、数えない。
    func testWarmupCardsAreNotCountedNotMarkedAndNotLoggedOneByOne() throws {
        var machine = F.machine()
        machine.put("test", F.skill("exp"))
        let generator = try DrillGenerator(template: try exponentTemplate())
        var random = DrillSeededRandom(seed: 7)
        let problem = try generator.next(using: &random)
        let id = machine.insertWarmup(skillID: "exp", problem: problem, title: "指数法則", session: "w1")
        let card = try XCTUnwrap(machine.cards[id])
        XCTAssertEqual(card.kind, "solve")
        XCTAssertEqual(card.origin, TimelineWarmup.origin)
        XCTAssertEqual(card.typeName, "指数法則")
        XCTAssertTrue(card.skills.isEmpty)
        XCTAssertFalse(card.answerExpr.isEmpty, "指数法則の答えは数なので、答えだけを読んで突き合わせる")
        XCTAssertFalse(machine.queue.contains { $0.id == id }, "5枚の手元には入れない")

        let attempt = machine.recordCapture(cardID: id, capturePath: "t.jpg", seconds: 20, assisted: false)
        XCTAssertEqual(machine.attempts[attempt]?.countsForAccuracy, false)
        _ = machine.applyGrading(attemptID: attempt, grading: try grading("wrong", skills: ["exp"]))
        XCTAssertEqual(machine.skills["exp"]?.attempts, 0, "点の ○× に数えない")
        XCTAssertTrue(machine.skillMarks(machine.attempts[attempt]!).isEmpty)
        XCTAssertFalse(machine.todayLog.contains { $0.attemptId == attempt }, "1 問ずつは今日の記録に残さない")
        XCTAssertTrue(machine.isFirstOfDay, "練習はその日の 1 問目に数えない")
        XCTAssertEqual(machine.warmupResults(session: "w1"), [false])

        // 2 問目も ×: 終えた時に 1 行だけ残す。
        let second = machine.insertWarmup(skillID: "exp", problem: try generator.next(using: &random, avoiding: problem), title: "指数法則", session: "w1")
        let secondAttempt = machine.recordCapture(cardID: second, capturePath: "t2.jpg", seconds: 20, assisted: false)
        _ = machine.applyGrading(attemptID: secondAttempt, grading: try grading("wrong"))
        XCTAssertEqual(machine.warmupResults(session: "w1"), [false, false])
        machine.finishWarmup(session: "w1")
        let line = try XCTUnwrap(machine.todayLog.last)
        XCTAssertEqual(line.kind, "warmup")
        XCTAssertTrue(line.text.contains("2 問中 2 問 ×"))
        XCTAssertTrue(TimelinePlanMode.recentAnswers(machine).contains(line.text), "新しい形の出題にも渡す")
    }

    /// 候補: 今日の詰まり → 直近 3 日の × 2 回以上 → 不意打ちの ×。型にできない種類(概念)は外す。
    func testCandidatesOrder() {
        var machine = F.machine()
        var concept = F.skill("concept")
        concept.kind = "concept"
        for skill in [F.skill("stuck"), F.skill("recent"), F.skill("surprise"), F.skill("once"), concept] { machine.put("test", skill) }
        var n = 0
        func answer(_ skill: String, _ verdict: String, at: String = F.now, payload: [String: LedgerJSON] = [:]) {
            n += 1
            machine.put("test", F.card("c\(n)", skills: [skill], payload: payload))
            machine.put("test", F.attempt("a\(n)", card: "c\(n)", verdict: verdict, createdAt: at))
        }
        for _ in 0..<3 { answer("stuck", "wrong") }
        answer("recent", "wrong", at: "2026-10-21T06:00:00.000000Z")
        answer("recent", "wrong", at: "2026-10-22T06:00:00.000000Z")
        answer("once", "wrong")
        answer("concept", "wrong")
        answer("concept", "wrong")
        answer("surprise", "wrong", at: "2026-10-18T06:00:00.000000Z", payload: ["surprise": .string("surprise")])
        // 4 日前の × は「直近 3 日」に入らない。
        answer("once", "wrong", at: "2026-10-20T06:00:00.000000Z")
        XCTAssertEqual(machine.warmupCandidates, ["stuck", "recent", "surprise"])
    }

    func testRapidCardCanStandInWithoutATemplate() {
        var machine = F.machine()
        machine.put("test", F.card("r1", origin: "rapid"))
        XCTAssertNotNil(machine.adoptRapidAsWarmup(cardID: "r1", session: "w1"))
        XCTAssertEqual(machine.cards["r1"]?.origin, TimelineWarmup.origin)
        XCTAssertTrue(machine.rapidCards.isEmpty, "速攻の手元からは外れる")
        XCTAssertEqual(machine.warmupCards(session: "w1").map(\.id), ["r1"])
    }

    // MARK: 型を書かせる

    private final class ScriptedTransport: DrillAuthoringTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String]
        private(set) var bodies: [[String: Any]] = []
        init(_ replies: [String]) { self.replies = replies }
        func send(_ body: [String: Any]) async throws -> [String: Any] {
            lock.withLock {
                bodies.append(body)
                return ["content": [["type": "text", "text": replies.removeFirst()]], "model": "m"]
            }
        }
    }

    func testAuthoringRetriesOnceWithTheReasonsAndReturnsTheTemplate() async throws {
        let root = try XCTUnwrap(DrillTestSupport.fixturesRoot())
        let valid = try String(contentsOf: root.appendingPathComponent("math/math.m2.exponent_laws.json"), encoding: .utf8)
        let wrongID = valid.replacingOccurrences(of: "\"math.m2.exponent_laws\"", with: "\"other\"")
        let transport = ScriptedTransport(["{\"template\": \(wrongID), \"reason\": \"\"}", "{\"template\": \(valid), \"reason\": \"\"}"])
        let request = DrillAuthoringRequest(skillID: "math.m2.exponent_laws", name: "指数法則", kind: "procedure",
                                            solved: [DrillSolvedExample(prompt: "次の計算をしなさい。", math: "2^{3} \\times 2^{2}", answer: "32")])
        let outcome = try await DrillAuthoringClient.author(request: request, instructions: "指示", replySchema: "{\"type\": \"object\"}",
                                                            model: TurnModel(model: "m", effort: "low"), transport: transport)
        guard case .ready = outcome else { return XCTFail("型を受け取る: \(outcome)") }
        XCTAssertEqual(transport.bodies.count, 2)
        let messages = try XCTUnwrap(transport.bodies.last?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"], "落ちた理由を同じ会話で返して書き直させる")
        XCTAssertNotNil((transport.bodies.first?["output_config"] as? [String: Any])?["format"], "返事の形は json_schema で縛る")
    }
}

/// 店(`TimelineStore`)の流れ: 戻った時に練習を挟み、終われば元のカードに戻る。
@MainActor
final class TimelineWarmupStoreTests: XCTestCase {
    private typealias F = TimelineFixture

    private final class RefusingRunner: TurnRunning, @unchecked Sendable {
        struct Refused: Error {}
        func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome { throw Refused() }
        func interrupt(planID: String) async {}
    }

    /// 解いている途中のカード c1 と、今日 3 回 × の点 exp(型あり)。
    private func setUp(template: Bool, rapid: Bool = false, minutesAgo: Double = 0) async throws -> TimelineStore {
        // 前の日になる時刻(日付が替わった直後)は、途中のカードが「今日」でなくなるので確かめられない。
        let sinceMidnight = Date().timeIntervalSince(Calendar.current.startOfDay(for: Date()))
        try XCTSkipIf(sinceMidnight < (minutesAgo + 5) * 60, "日付が替わった直後")
        let ledger = try Ledger.inMemory()
        let now = LedgerClock.iso(Date().addingTimeInterval(-minutesAgo * 60))
        try await ledger.commit { db in
            var workbook = try WorkbookMachine(loading: db)
            _ = workbook.createUnit(title: "指数関数", outcome: "", source: "consult", subunits: [.init(title: "指数法則", n: 2)], firstStage: 1)
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", F.skill("exp"))
            for i in 0..<3 {
                timeline.put("test", F.card("w\(i)", status: "answered", skills: ["exp"], createdAt: now))
                timeline.put("test", F.attempt("a\(i)", card: "w\(i)", verdict: "wrong", createdAt: now))
            }
            timeline.put("test", F.card("c1", status: "shown", position: 1, createdAt: now))
            timeline.put("test", F.card("c2", status: "unused", position: 2, createdAt: now))
            if rapid { timeline.put("test", F.card("r1", origin: "rapid", position: 3, createdAt: now)) }
            return (workbook.events + timeline.events, ())
        }
        if template {
            let root = try XCTUnwrap(DrillTestSupport.fixturesRoot())
            let text = try String(contentsOf: root.appendingPathComponent("math/math.m2.exponent_laws.json"), encoding: .utf8)
                .replacingOccurrences(of: "\"math.m2.exponent_laws\"", with: "\"exp\"")
            let json = try DrillTemplate.decode(json: text).canonicalJSON()
            try DrillTemplateStore(queue: ledger.queue).save(skillID: "exp", outcome: .ready(json: json, numericallyChecked: true, problems: 100))
        }
        let store = TimelineStore(ledger: ledger, turns: TurnCoordinator(ledger: ledger, assets: AssetCache(), runner: RefusingRunner()))
        store.newWorkDenial = { nil }
        store.drillTransport = nil
        await store.start()
        if minutesAgo == 0 { XCTAssertEqual(store.currentID, "c1") }
        return store
    }

    func testLongAwayShowsTheWarmupFirstAndReturnsToTheCardInProgress() async throws {
        let store = try await setUp(template: true)
        await store.warmupOnReturn(awaySeconds: 1900)
        let warmup = try XCTUnwrap(store.current)
        XCTAssertEqual(warmup.origin, TimelineWarmup.origin)
        XCTAssertEqual(warmup.typeName, "exp", "点の名前を型の名前にして、いつものカードと同じ形で出す")
        XCTAssertEqual(store.phase, .solving)
        // 練習を飛ばした: 練習を終えて、途中だった c1 に戻る。
        await store.skip()
        XCTAssertEqual(store.currentID, "c1")
    }

    func testShortAwayWhileSolvingWaitsForTheAnswer() async throws {
        let store = try await setUp(template: true)
        await store.warmupOnReturn(awaySeconds: 600)
        XCTAssertEqual(store.currentID, "c1", "30 分未満: 今の問題はそのまま")
        // c1 を終えた(飛ばした): 次の 1 枚の前に練習を挟み、練習の後は c2。
        await store.skip()
        let warmup = try XCTUnwrap(store.current)
        XCTAssertEqual(warmup.origin, TimelineWarmup.origin)
        await store.skip()
        XCTAssertEqual(store.currentID, "c2")
    }

    func testWithoutATemplateARapidCardStandsInOnReturnButNotOnLaunch() async throws {
        let store = try await setUp(template: false, rapid: true)
        await store.warmupOnReturn(awaySeconds: 1900, launch: true)
        XCTAssertEqual(store.currentID, "c1", "開き直した時は、型が無ければ出さない(開いた時はもともと速攻から始まる)")
        await store.warmupOnReturn(awaySeconds: 1900)
        XCTAssertEqual(store.currentID, "r1")
        XCTAssertEqual(store.current?.origin, TimelineWarmup.origin)
    }

    /// 開き直した時: 40 分前に解いている途中だった。型があれば練習を先に出し、終えたら途中の問題に戻る。
    func testRelaunchAfterALongBreakStartsWithTheWarmup() async throws {
        let store = try await setUp(template: true, minutesAgo: 40)
        XCTAssertEqual(store.current?.origin, TimelineWarmup.origin)
        await store.skip()
        XCTAssertEqual(store.currentID, "c1")
    }

    /// 開き直した時: 10 分前に解いている途中だった。今の問題はそのまま(答えを送った後に出す)。
    func testRelaunchAfterAShortBreakKeepsTheCardInProgress() async throws {
        let store = try await setUp(template: true, minutesAgo: 10)
        XCTAssertEqual(store.currentID, "c1")
    }

    func testShortAwayDoesNothing() async throws {
        let store = try await setUp(template: true)
        await store.warmupOnReturn(awaySeconds: 200)
        XCTAssertEqual(store.currentID, "c1")
    }
}
