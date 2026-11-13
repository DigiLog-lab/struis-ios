import XCTest
@testable import strius

/// Issue #46「タイムラインに混ぜるカード10種」: 受け取る前の点検と、材料からの組み替え・端末の中の採点。
final class TimelineCardsTests: XCTestCase {
    typealias F = TimelineFixture

    private func draft(_ json: [String: Any]) throws -> TimelineCards.Draft {
        try F.batch(cards: [json]).cards[0]
    }

    func testDefects() throws {
        XCTAssertTrue(TimelineCards.defects(try draft(F.draftJSON(skills: ["a"])), allowedSkills: ["a"], levelCap: nil).isEmpty)
        XCTAssertFalse(TimelineCards.defects(try draft(F.draftJSON(skills: ["zzz"])), allowedSkills: ["a"], levelCap: nil).isEmpty)
        XCTAssertFalse(TimelineCards.defects(try draft(F.draftJSON(level: 3)), allowedSkills: [], levelCap: 2).isEmpty)
        // 検算: 答えが合わないカードは受け取らない。
        let wrong = F.draftJSON(checks: [["left": "2*x^2-8*x+3", "right": "2*(x-2)^2+5"]])
        XCTAssertTrue(TimelineCards.defects(try draft(wrong), allowedSkills: [], levelCap: nil).contains { $0.hasPrefix("check failed") })
        XCTAssertFalse(TimelineCards.defects(try draft(F.draftJSON(kind: "sort", facts: [:])), allowedSkills: [], levelCap: nil).isEmpty)
    }

    private func base() throws -> TimelineCardRecord {
        var machine = F.machine()
        let id = machine.insertCard(from: try draft(F.draftJSON()), batchID: "b", position: 1, chain: nil)
        return machine.cards[id]!
    }

    func testEveryTemplateKindCanBeBuiltFromOneProblem() throws {
        let card = try base()
        for kind in [TimelineCards.Kind.order, .findError, .nextStep, .fillLine, .graphMatch, .sort, .predict, .inverse, .reason] {
            XCTAssertNotNil(TimelineCards.derive(kind, from: card), "\(kind) を組み替えられない")
        }
        // 03 は AI が作った文が無ければ作らない。
        XCTAssertNil(TimelineCards.derive(.compare, from: card))
    }

    func testOnDeviceGrading() throws {
        let card = try base()
        func make(_ kind: TimelineCards.Kind) -> TimelineCardRecord {
            var copy = card
            copy.kind = kind.rawValue
            copy.payload = .object((card.payload.objectValue ?? [:]).merging(TimelineCards.derive(kind, from: card)!.payload) { _, new in new })
            return copy
        }
        let order = make(.order)
        XCTAssertTrue(TimelineCards.grade(order, answer: .array([0, 1, 2, 3].map { .number($0) })))
        XCTAssertFalse(TimelineCards.grade(order, answer: .array([1, 0, 2, 3].map { .number($0) })))
        let findError = make(.findError)
        XCTAssertEqual(findError.payload["answer_index"]?.intValue, 2)
        XCTAssertTrue(TimelineCards.grade(findError, answer: .number(2)))
        let sort = make(.sort)
        let truth = sort.payload["items"]!.arrayValue!.map { LedgerJSON.bool($0["right"]!.boolValue!) }
        XCTAssertTrue(TimelineCards.grade(sort, answer: .array(truth)))
        let predict = make(.predict)
        XCTAssertTrue(TimelineCards.grade(predict, answer: .number(1)))  // 答えは −5(負)
        let graph = make(.graphMatch)
        XCTAssertTrue(TimelineCards.grade(graph, answer: graph.payload["graph_order"]!))
    }

    /// 端末の中で採点するカードを間違えた時は、出題の時に作った手順を「解き方」として結果に出す(モデルを呼ばない)。
    func testWrongChoiceCardsShowTheSolutionStepsOnTheResult() throws {
        let card: TimelineCardRecord = try base()
        let steps: [String] = ["y = 2x^2 - 8x + 3", "= 2(x^2 - 4x) + 3", "= 2(x - 2)^2 - 5", "最小値 -5"]
        func make(_ kind: TimelineCards.Kind) -> TimelineCardRecord {
            var copy: TimelineCardRecord = card
            copy.kind = kind.rawValue
            copy.payload = .object((card.payload.objectValue ?? [:]).merging(TimelineCards.derive(kind, from: card)!.payload) { _, new in new })
            return copy
        }
        for kind in [TimelineCards.Kind.findError, .nextStep, .predict, .reason] {
            XCTAssertEqual(TimelineCards.solutionSteps(make(kind)), steps, "\(kind) の結果に解き方が出ない")
        }
        // 仕分けとグラフは、アプリが元の問題から作った別の問い。元の問題の手順ではなく、その問いの説明を出す。
        XCTAssertEqual(TimelineCards.solutionSteps(make(.sort)), ["軸 x = 2 が、範囲の左端と右端の間(端も入ります)にあれば「含む」、なければ「含まない」です。"])
        XCTAssertEqual(TimelineCards.solutionSteps(make(.graphMatch)), [
            "頂点の位置と、グラフが上と下のどちらに開くかで見分けます。",
            "式 1: 頂点は (2, -5)、下に凸(上に開く)",
            "式 2: 頂点は (2, 5)、上に凸(下に開く)",
            "式 3: 頂点は (2, -2)、下に凸(上に開く)",
        ])
        // 並べ替えは、手順そのものが「正しい答え」として出るので重ねない。
        XCTAssertTrue(TimelineCards.solutionSteps(make(.order)).isEmpty)
        // 読み取って採点するカードは、採点のコメントが説明になる。
        XCTAssertTrue(TimelineCards.solutionSteps(card).isEmpty)
        XCTAssertTrue(TimelineCards.solutionSteps(make(.fillLine)).isEmpty)
        XCTAssertTrue(TimelineCards.solutionSteps(make(.inverse)).isEmpty)
        // 手順を持たないカード(空の行だけ)は、何も出さない。
        var bare: TimelineCardRecord = make(.reason)
        bare.payload = .object((bare.payload.objectValue ?? [:]).merging(["steps": .array([.string(" "), .string("")])]) { _, new in new })
        XCTAssertTrue(TimelineCards.solutionSteps(bare).isEmpty)
    }

    /// グラフと式を組にするカード: 結果と解説には、元の問題の答えではなく、グラフごとの正しい式を出す。質問・解説には式の一覧を添える。
    func testGraphMatchShowsThePairingAndListsTheExpressions() throws {
        let card: TimelineCardRecord = try base()
        var graph: TimelineCardRecord = card
        graph.kind = TimelineCards.Kind.graphMatch.rawValue
        graph.payload = .object((card.payload.objectValue ?? [:]).merging(TimelineCards.derive(.graphMatch, from: card)!.payload) { _, new in new })
        let order: [Int] = graph.payload["graph_order"]!.arrayValue!.compactMap(\.intValue)
        let right = try XCTUnwrap(TimelineCards.shownAnswers(graph, chosen: graph.payload["graph_order"]))
        XCTAssertEqual(right.correct, order.enumerated().map { "左から\($0.offset + 1)番目のグラフ: 式 \($0.element + 1)" }.joined(separator: "\n"))
        XCTAssertEqual(right.learner, right.correct)
        let wrong = try XCTUnwrap(TimelineCards.shownAnswers(graph, chosen: .array([0, 0, 0].map { .number($0) })))
        XCTAssertEqual(wrong.learner, "左から1番目のグラフ: 式 1\n左から2番目のグラフ: 式 1\n左から3番目のグラフ: 式 1")
        XCTAssertNotEqual(wrong.learner, wrong.correct)
        let lines: [String] = TimelineCards.optionLines(graph)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].contains("グラフが3つ"))
        XCTAssertTrue(lines[1].hasPrefix("式 1: "))
        // 選ぶカードは番号付きの選択肢。読み取って採点するカードには付けない。
        var reason: TimelineCardRecord = card
        reason.kind = TimelineCards.Kind.reason.rawValue
        reason.payload = .object((card.payload.objectValue ?? [:]).merging(TimelineCards.derive(.reason, from: card)!.payload) { _, new in new })
        XCTAssertEqual(TimelineCards.optionLines(reason), ["選択肢:", "1. a", "2. b", "3. c"])
        XCTAssertTrue(TimelineCards.optionLines(card).isEmpty)
        // 比べるカードは、画面に並ぶ 2 つの解き方も添える(添えないと、何を比べているのかが伝わらない)。
        let compare: TimelineCardRecord = F.card("c", kind: TimelineCards.Kind.compare.rawValue, payload: [
            "a_title": .string("平方完成"), "a_lines": .array([.string("y = 2(x - 2)^2 - 5"), .string("最小値 -5")]),
            "b_title": .string(""), "b_lines": .array([.string("y' = 4x - 8 = 0"), .string("x = 2")]),
            "options": .array([.string("どちらも最小値を求めている"), .string("求めているものが違う")]), "answer_index": .number(0),
        ])
        XCTAssertEqual(TimelineCards.optionLines(compare), [
            "平方完成:", "y = 2(x - 2)^2 - 5", "最小値 -5", "解き方 B:", "y' = 4x - 8 = 0", "x = 2",
            "選択肢:", "1. どちらも最小値を求めている", "2. 求めているものが違う",
        ])
    }

    /// 質問・解説に添える問題文: 選ぶカードは「何を答える問いか」の文を落とさない。次の一手は、そこまでの手順も添える。
    func testProblemLinesKeepTheInstructionAndTheShownSteps() throws {
        var machine = F.machine()
        let nextID: String = machine.insertCard(from: try draft(F.draftJSON(kind: "next_step")), batchID: "b", position: 1, chain: nil)
        let next: TimelineCardRecord = machine.cards[nextID]!
        let shown: [String] = next.payload["shown"]!.arrayValue!.compactMap(\.stringValue)
        XCTAssertFalse(shown.isEmpty)
        let lines: [String] = TimelineCards.problemLines(next)
        XCTAssertTrue(lines.contains("次の一手を選びなさい。"), "何を答える問いかが渡っていない: \(lines)")
        let start: Int = try XCTUnwrap(lines.firstIndex(of: "ここまでの手順:"))
        XCTAssertEqual(Array(lines[(start + 1)...(start + shown.count)]), shown)
        XCTAssertEqual(lines[start + shown.count + 1], "選択肢:")
        // 正負を予想するカードも、問いの文が入る。
        let predictID: String = machine.insertCard(from: try draft(F.draftJSON(kind: "predict")), batchID: "b", position: 2, chain: nil)
        let predict: TimelineCardRecord = machine.cards[predictID]!
        XCTAssertTrue(TimelineCards.problemLines(predict).contains(predict.prompt))
        // 解いて書くカードは今までどおり(問いかけを重ねない、手順も選択肢も付けない)。
        let solve: TimelineCardRecord = try base()
        let solveLines: [String] = TimelineCards.problemLines(solve)
        XCTAssertFalse(solveLines.contains("ここまでの手順:"))
        XCTAssertFalse(solveLines.contains("選択肢:"))
        XCTAssertEqual(solveLines.filter { $0 == solve.prompt }.count, (solve.payload["problem"]?.stringValue ?? "").isEmpty ? 1 : 0)
    }

    func testWrittenAnswersAreCheckedWithMath() throws {
        let card = try base()
        var inverse = card
        inverse.kind = "inverse"
        inverse.payload = .object((card.payload.objectValue ?? [:]).merging(TimelineCards.derive(.inverse, from: card)!.payload) { _, new in new })
        // 答えは何通りもある: 頂点が (2, −5) なら ○。
        XCTAssertEqual(TimelineCards.gradeWritten(inverse, learnerExpr: "3(x - 2)^2 - 5"), true)
        XCTAssertEqual(TimelineCards.gradeWritten(inverse, learnerExpr: "-(x-2)^2-5"), true)
        XCTAssertEqual(TimelineCards.gradeWritten(inverse, learnerExpr: "(x+2)^2-5"), false)
        var fill = card
        fill.kind = "fill_line"
        fill.payload = .object((card.payload.objectValue ?? [:]).merging(TimelineCards.derive(.fillLine, from: card)!.payload) { _, new in new })
        // 隠した行は 3 行目(= 2(x − 2)^2 − 5)。
        XCTAssertEqual(TimelineCards.gradeWritten(fill, learnerExpr: "2(x-2)^2-5"), true)
        XCTAssertEqual(TimelineCards.gradeWritten(fill, learnerExpr: "2(x-2)^2+5"), false)
    }
}
