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

    func testNicknameIsTrimmedToTenCharacters() {
        XCTAssertEqual(TimeAttack.trimmedName("  とてもながいなまえのひとです  "), "とてもながいなまえの")
    }
}
