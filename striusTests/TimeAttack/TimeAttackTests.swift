import XCTest
@testable import strius

/// タイムアタック(#133)の決まり: 合計の数え方、リンクの往復、読み取った答えの割り当て。
final class TimeAttackTests: XCTestCase {
    private let problems: [TimeAttack.Problem] = [
        .init(prompt: "次の値を求めなさい。", math: "\\sin 30^\\circ", answerKey: "\\frac{1}{2}", answerExpr: "1/2"),
        .init(prompt: "次の値を求めなさい。", math: "\\cos 45^\\circ", answerKey: "\\frac{\\sqrt{2}}{2}", answerExpr: "sqrt(2)/2"),
        .init(prompt: "次の値を求めなさい。", math: "\\tan 60^\\circ", answerKey: "\\sqrt{3}", answerExpr: "sqrt(3)"),
        .init(prompt: "次の値を求めなさい。", math: "\\sin 150^\\circ", answerKey: "\\frac{1}{2}", answerExpr: "1/2"),
        .init(prompt: "次の値を求めなさい。", math: "\\cos 120^\\circ", answerKey: "-\\frac{1}{2}", answerExpr: "-1/2"),
    ]

    func testTotalAddsTenSecondsPerWrongAnswer() {
        let entry = TimeAttack.Entry(name: "ゆう", laps: [6.2, 7.9, 5.4, 9.8, 12.1], correct: [true, true, true, true, false])
        XCTAssertEqual(entry.solvedSeconds, 41.4, accuracy: 1e-9)
        XCTAssertEqual(entry.total, 51.4, accuracy: 1e-9)
        XCTAssertEqual(entry.seconds(at: 4), 22.1, accuracy: 1e-9)
        XCTAssertEqual(TimeAttack.clock(entry.total), "0:51.4")
        XCTAssertEqual(TimeAttack.clock(70.44), "1:10.4")
    }

    func testLinkRoundTripsAndHidesTheAnswers() throws {
        let challenge = TimeAttack.Challenge(field: "三角関数", problems: problems,
                                             entries: [.init(name: "ゆう", laps: [6.2, 7.9, 5.4, 9.8, 12.1], correct: [true, true, true, true, false])])
        let url = try TimeAttackLink.url(for: challenge, bundleID: "com.digiloglab.strius.Clip")
        XCTAssertEqual(url.host, "appclip.apple.com")
        XCTAssertTrue(url.absoluteString.contains("p=com.digiloglab.strius.Clip"))
        XCTAssertFalse(url.absoluteString.contains("sqrt"), "正答の式が URL にそのまま出ている")
        XCTAssertLessThan(url.absoluteString.count, 2_000)
        XCTAssertEqual(try TimeAttackLink.challenge(from: url), challenge)
    }

    func testBrokenOrForeignLinksAreRejected() {
        XCTAssertThrowsError(try TimeAttackLink.challenge(from: URL(string: "https://appclip.apple.com/id?p=com.digiloglab.strius.Clip")!)) {
            XCTAssertEqual($0 as? TimeAttackLink.Failure, .notALink)
        }
        XCTAssertThrowsError(try TimeAttackLink.challenge(from: URL(string: "https://appclip.apple.com/id?c=AAAA")!)) {
            XCTAssertEqual($0 as? TimeAttackLink.Failure, .unreadable)
        }
    }

    func testLinksWithImpossibleRecordsAreRejected() throws {
        // 鍵は公開リポジトリにあるので、誰でも復号できるリンクを作れる。範囲外の秒数でアプリを落とさない。
        for laps in [[1e20, 1, 1, 1, 1], [-1, 1, 1, 1, 1], [1, 1, 1]] {
            let challenge = TimeAttack.Challenge(field: "三角関数", problems: problems,
                                                 entries: [.init(name: "x", laps: laps, correct: Array(repeating: true, count: laps.count))])
            let url = try TimeAttackLink.url(for: challenge, bundleID: "com.digiloglab.strius.Clip")
            XCTAssertThrowsError(try TimeAttackLink.challenge(from: url)) { XCTAssertEqual($0 as? TimeAttackLink.Failure, .unreadable) }
        }
        // NaN は JSON に書けない(作る側で落ちる)ので、確かめは直接。
        let nan = TimeAttack.Challenge(field: "三角関数", problems: problems,
                                       entries: [.init(name: "x", laps: [.nan, 1, 1, 1, 1], correct: Array(repeating: true, count: 5))])
        XCTAssertFalse(TimeAttackLink.isSane(nan))
        XCTAssertEqual(TimeAttack.clock(1e20), TimeAttack.clock(TimeAttack.maxLapSeconds * 10))
        XCTAssertEqual(TimeAttack.clock(.nan), "0:00.0")
    }

    func testAnswersGoToNumberedProblemsThenTopToBottom() {
        // 3 番だけ番号つきで先に書き、残りは番号なしで上から。5 問目は書いていない。
        let answers: [(number: Int?, readable: Bool, text: String)] = [
            (3, true, "\\sqrt{3}"), (nil, true, "\\frac{1}{2}"), (nil, true, "\\frac{1}{\\sqrt{2}}"), (nil, true, "\\frac{1}{2}"),
        ]
        XCTAssertEqual(TimeAttackClaude.judge(problems: problems, answers: answers), [true, true, true, true, false])
    }

    func testWrongSignAndUnreadableAnswersAreWrong() {
        let answers: [(number: Int?, readable: Bool, text: String)] = [
            (1, true, "0.5"), (2, false, ""), (3, true, "x = \\sqrt{3}"), (4, true, "1/2"), (5, true, "\\frac{1}{2}"),
        ]
        XCTAssertEqual(TimeAttackClaude.judge(problems: problems, answers: answers), [true, false, true, true, false])
    }

    func testReplyJSONIsReadEvenWithSurroundingText() throws {
        struct Reply: Decodable { var field: String }
        let response: [String: Any] = ["content": [["type": "text", "text": "```json\n{\"field\": \"三角関数\"}\n```"]]]
        XCTAssertEqual(try TimeAttackClaude.decode(Reply.self, from: response).field, "三角関数")
    }

    func testClipAllowsThreeSetsADay() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "timeattack-tests-\(UUID().uuidString)"))
        let local = TimeAttackLocal(defaults: defaults)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(local.clipSetsLeft(now: day), 3)
        for _ in 0..<3 { local.useClipSet(now: day) }
        XCTAssertEqual(local.clipSetsLeft(now: day), 0)
        XCTAssertEqual(local.clipSetsLeft(now: day.addingTimeInterval(86_400)), 3)
    }

    func testBestIsKeptPerField() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "timeattack-tests-\(UUID().uuidString)"))
        let local = TimeAttackLocal(defaults: defaults)
        XCTAssertNil(local.record(total: 58.3, field: "三角関数"))
        XCTAssertEqual(local.record(total: 51.4, field: "三角関数"), 58.3)
        XCTAssertEqual(local.best(field: "三角関数"), 51.4)
        local.record(total: 60, field: "三角関数")
        XCTAssertEqual(local.best(field: "三角関数"), 51.4)
        XCTAssertNil(local.best(field: "二次関数"))
    }

    func testPlainMathForTheResultRows() {
        XCTAssertEqual(TimeAttackMath.plain("\\frac{\\sqrt{2}}{2}"), "√2/2")
        XCTAssertEqual(TimeAttackMath.plain("\\sin\\frac{\\pi}{6}"), "sin π/6")
        XCTAssertEqual(TimeAttackMath.plain("\\cos 45^\\circ"), "cos 45°")
        XCTAssertEqual(TimeAttackMath.plain("-\\frac{1}{2}"), "-1/2")
        XCTAssertEqual(TimeAttackMath.plain("x^{2}+1"), "x^2+1")
        XCTAssertEqual(TimeAttackMath.plain("\\frac{x+1}{2}"), "(x+1)/2")
    }

    private struct NoTransport: TimeAttackTransport {
        func send(_ body: [String: Any], purpose: TimeAttackClaude.Purpose) async throws -> [String: Any] { [:] }
    }

    @MainActor
    func testAReceivedChallengeDoesNotStartWhenItCannotBeGraded() {
        let challenge = TimeAttack.Challenge(field: "三角関数", problems: problems, entries: [])
        let session = TimeAttackSession(mode: .challenge(challenge), transport: NoTransport())
        XCTAssertEqual(session.phase, .intro)
        session.preflight = { "今週の利用枠を使い切りました。" }
        session.start()
        XCTAssertEqual(session.phase, .failed("今週の利用枠を使い切りました。"))
        session.preflight = { nil }
        session.start()
        XCTAssertEqual(session.phase, .running)
    }

    @MainActor
    func testSelfCheckRecordsTheLearnersMarksWithoutSendingAPhoto() async {
        let challenge = TimeAttack.Challenge(field: "三角関数", problems: problems, entries: [])
        let defaults = UserDefaults(suiteName: "timeattack-tests-\(UUID().uuidString)")!
        let session = TimeAttackSession(mode: .challenge(challenge), transport: NoTransport(), local: TimeAttackLocal(defaults: defaults))
        var graded = false
        session.onGradingStarted = { graded = true }
        session.grading = .selfCheck
        session.start()
        await session.finish(laps: [6, 7, 5, 9, 12], photo: nil)
        XCTAssertEqual(session.phase, .selfCheck)
        session.submitSelfCheck([true, true, true, true, false])
        XCTAssertEqual(session.phase, .result)
        XCTAssertEqual(session.mine?.total ?? 0, 49, accuracy: 1e-9)
        XCTAssertFalse(graded, "自分で採点する時は AI に頼まない(App Clip の回数も数えない)")
    }

    func testOnlySixteenAndOverSendThePhotoFromTheAppClip() {
        XCTAssertEqual(TimeAttackLocal.clipGrading(for: .adult), .ai)
        XCTAssertEqual(TimeAttackLocal.clipGrading(for: .under18), .ai)
        XCTAssertEqual(TimeAttackLocal.clipGrading(for: .under16), .selfMarked)
        XCTAssertEqual(TimeAttackLocal.clipGrading(for: nil), .selfMarked, "年齢を共有しなかった時は送らない")
    }

    func testTheAppClipAsksAgainWhenTheTermsChange() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "timeattack-tests-\(UUID().uuidString)"))
        let local = TimeAttackLocal(defaults: defaults)
        XCTAssertNil(local.clipGrading(termsVersion: "2026-11-06"))
        local.recordClipGrading(.ai, termsVersion: "2026-11-06")
        XCTAssertEqual(local.clipGrading(termsVersion: "2026-11-06"), .ai)
        XCTAssertNil(local.clipGrading(termsVersion: "2026-12-01"), "規約が新しくなったら聞き直す")
    }

    @MainActor
    func testSelfMarkingFinishesWithoutAPhoto() {
        let challenge = TimeAttack.Challenge(field: "三角関数", problems: problems, entries: [])
        let session = TimeAttackSession(mode: .challenge(challenge), transport: NoTransport(),
                                        local: TimeAttackLocal(defaults: UserDefaults(suiteName: "timeattack-tests-\(UUID().uuidString)")!))
        session.start()
        session.finishWithoutPhoto(laps: [3, 3, 3, 3, 3])
        XCTAssertEqual(session.phase, .marking)
        XCTAssertFalse(session.hasPhoto)
        session.submitMarks([true, true, false, true, true])
        XCTAssertEqual(session.phase, .result)
        XCTAssertEqual(session.mine?.selfMarked, true)
        XCTAssertEqual(session.mine?.total ?? 0, 25, accuracy: 1e-9)
    }

    func testNicknameIsTrimmedToTenCharacters() {
        XCTAssertEqual(TimeAttack.trimmedName("  とてもながいなまえのひとです  "), "とてもながいなまえの")
    }
}
