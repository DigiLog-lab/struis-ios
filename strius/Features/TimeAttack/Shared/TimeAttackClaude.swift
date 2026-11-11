import Foundation
import UIKit

/// Messages API に1回だけ送る口。本体は利用枠を数える経路、App Clip は App Attest の token で直接送る。
nonisolated protocol TimeAttackTransport: Sendable {
    /// 送って、応答の JSON(`content` を持つ Messages API の応答)を返す。
    func send(_ body: [String: Any], purpose: TimeAttackClaude.Purpose) async throws -> [String: Any]
}

/// タイムアタックの AI の仕事: 5問を作る(本体だけ)と、紙の写真から5問の答えを読む(本体と App Clip)。
/// 正誤はアプリが正答の式と突き合わせて決める(読み取りには正答を渡さない)。
nonisolated enum TimeAttackClaude {
    enum Purpose: String, Sendable { case generate, read }

    enum Failure: Error, LocalizedError, Equatable {
        case malformed(String)
        case tooFewProblems(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .malformed: "AI の返事を読めませんでした。もう一度試してください。"
            case .tooFewProblems: "問題を作れませんでした。もう一度試してください。"
            case .unreadable: "答案の写真を読めませんでした。紙全体が入るように撮り直してください。"
            }
        }
    }

    // MARK: 出題

    static let generateInstructions = """
    # Struis タイムアタックの出題

    指定の分野で、いちばん基礎の問題を6問作ってください(アプリが答えを検算し、そのうち5問を使います)。生徒は紙に答えだけを上から順に書き、解く速さを友達と競います。

    - 1問は、その分野を習った人なら5〜15秒で答えが出る大きさにする。証明・説明・答えが2つ以上ある問題・場合分けが要る問題は出さない。
    - 答えは数か短い式1つ。6問とも違う問題にし、易しい順に並べる。
    - `prompt`: 問題文。です・ます調ではなく問題集の書き方(「〜を求めなさい。」)。式・記号は入れず、式はすべて `math` に入れる。
    - `math`: 式(区切りの無い LaTeX)。式が無い問題は空。
    - `answer_key`: 正しい答え(区切りの無い LaTeX)。
    - `answer_expr`: プログラムで評価できる答えの式(`*` を省かない、べき乗は `^`、関数は sqrt sin cos tan exp log abs、`pi`)。角度の答えは度ではなく数で書く。
    - `field`: 分野の短い名前(例: 三角関数)。

    出力は次の JSON だけにしてください。

    {"field": "...", "problems": [{"prompt": "...", "math": "...", "answer_key": "...", "answer_expr": "..."}]}
    """

    static func generateBody(unitTitle: String, context: String, repair: String? = nil) -> [String: Any] {
        var request: [String: Any] = ["unit": unitTitle, "context": context]
        if let repair { request["fix"] = repair }
        let text = (try? String(data: JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), encoding: .utf8)) ?? ""
        return [
            "model": TimeAttack.model, "max_tokens": 2_000,
            "system": generateInstructions,
            "messages": [["role": "user", "content": [["type": "text", "text": text]]]],
        ]
    }

    private struct GeneratedProblem: Decodable {
        var prompt: String?
        var math: String?
        var answerKey: String?
        var answerExpr: String?
        enum CodingKeys: String, CodingKey {
            case prompt, math
            case answerKey = "answer_key"
            case answerExpr = "answer_expr"
        }
    }

    private struct Generated: Decodable {
        var field: String?
        var problems: [GeneratedProblem]?
    }

    /// 5問を作る。答えの式が読めない・正答と答えの式が合わない問題は受け取らず、足りなければ1回だけ作り直させる。
    static func generate(unitTitle: String, context: String, transport: any TimeAttackTransport) async throws -> (field: String, problems: [TimeAttack.Problem]) {
        var repair: String?
        var lastCount = 0
        for _ in 0..<2 {
            let response = try await transport.send(generateBody(unitTitle: unitTitle, context: context, repair: repair), purpose: .generate)
            let generated: Generated = try decode(Generated.self, from: response)
            let problems = (generated.problems ?? []).compactMap(validated)
            if problems.count >= TimeAttack.problemCount {
                let field = generated.field?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (field.isEmpty ? unitTitle : field, Array(problems.prefix(TimeAttack.problemCount)))
            }
            lastCount = problems.count
            repair = "前の返事では、答えの式が読めない・正答と合わない問題があり、使える問題が\(problems.count)問しかありませんでした。5問とも answer_expr をプログラムで評価できる形にしてください。"
        }
        throw Failure.tooFewProblems(lastCount)
    }

    private static func validated(_ item: GeneratedProblem) -> TimeAttack.Problem? {
        let prompt = (item.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (item.answerKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let expr = (item.answerExpr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !key.isEmpty, !expr.isEmpty, (try? TimelineExpression.parse(prepared(expr))) != nil else { return nil }
        // 正答の LaTeX が式として読める時は、答えの式と一致することを確かめる(読めない時は答えの式を信じる)。
        if TimelineExpression.equivalent(prepared(expr), prepared(key)) == false { return nil }
        return TimeAttack.Problem(prompt: prompt, math: (item.math ?? "").trimmingCharacters(in: .whitespacesAndNewlines), answerKey: key, answerExpr: expr)
    }

    // MARK: 読み取り

    static let readInstructions = """
    # Struis タイムアタックの答えの読み取り

    生徒が5問の答えを1枚の紙に上から順に書き、写真を撮りました。問題は依頼の `problems` に、番号順に並んでいます。
    写真から、それぞれの問題の答えを読み取ってください。

    採点はしません。答えを直したり、計算し直したりせず、生徒が書いたとおりに書き写してください。間違っていてもそのまま書き写すのが仕事です。

    - 生徒が答えに番号を振っていれば、その番号の問題の答えとします。番号が無ければ、上から順に1問目・2問目…とします。
    - 書かれていない問題・読めない答えは `readable` を false、`learner_answer` を空にします。
    - `learner_answer` は区切りの無い LaTeX(例: `\\frac{\\sqrt{3}}{2}`)。

    出力は次の JSON だけにしてください。

    {"answers": [{"number": 1, "readable": true, "learner_answer": "..."}]}
    """

    /// 写真は長辺 1600px の JPEG に縮めて送る。
    static let photoMaxDimension: CGFloat = 1_600

    static func readBody(problems: [TimeAttack.Problem], jpeg: Data) -> [String: Any] {
        let list: [[String: Any]] = problems.enumerated().map { index, problem in
            ["number": index + 1, "problem": problem.prompt, "math": problem.math]
        }
        let text = (try? String(data: JSONSerialization.data(withJSONObject: ["problems": list], options: [.sortedKeys]), encoding: .utf8)) ?? ""
        return [
            "model": TimeAttack.model, "max_tokens": 1_000,
            "system": readInstructions,
            "messages": [["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                ["type": "text", "text": text],
            ]]],
        ]
    }

    private struct ReadAnswer: Decodable {
        var number: Int?
        var readable: Bool?
        var learnerAnswer: String?
        enum CodingKeys: String, CodingKey {
            case number, readable
            case learnerAnswer = "learner_answer"
        }
    }

    private struct Read: Decodable { var answers: [ReadAnswer]? }

    /// 写真から5問の答えを読み、正答と突き合わせた正誤を返す(読めない・無い答えは誤答)。
    static func grade(problems: [TimeAttack.Problem], photo: Data, transport: any TimeAttackTransport) async throws -> [Bool] {
        guard let jpeg = shrunkJPEG(photo) else { throw Failure.unreadable }
        let response = try await transport.send(readBody(problems: problems, jpeg: jpeg), purpose: .read)
        let read: Read = try decode(Read.self, from: response)
        return judge(problems: problems, answers: (read.answers ?? []).map { ($0.number, $0.readable ?? false, $0.learnerAnswer ?? "") })
    }

    /// 読み取った答えを問題に割り当てて正誤を決める。番号が無い・範囲外の答えは、空いている問題に上から順に入れる。
    static func judge(problems: [TimeAttack.Problem], answers: [(number: Int?, readable: Bool, text: String)]) -> [Bool] {
        var assigned = [String?](repeating: nil, count: problems.count)
        var unnumbered: [(Bool, String)] = []
        for answer in answers {
            if let number = answer.number, (1...problems.count).contains(number), assigned[number - 1] == nil {
                assigned[number - 1] = answer.readable ? answer.text : ""
            } else {
                unnumbered.append((answer.readable, answer.text))
            }
        }
        for (readable, text) in unnumbered {
            guard let slot = assigned.firstIndex(where: { $0 == nil }) else { break }
            assigned[slot] = readable ? text : ""
        }
        return problems.enumerated().map { index, problem in
            guard let written = assigned[index]?.trimmingCharacters(in: .whitespacesAndNewlines), !written.isEmpty else { return false }
            return matches(written, problem: problem)
        }
    }

    /// 書いた答えが正答と同じか。式として比べられる時は値で、比べられない時は文字で比べる。
    static func matches(_ written: String, problem: TimeAttack.Problem) -> Bool {
        let rhs = written.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) ?? written
        if let same = TimelineExpression.equivalent(prepared(problem.answerExpr), prepared(rhs)) { return same }
        return normalized(rhs) == normalized(problem.answerKey)
    }

    /// `TimelineExpression` に渡す前の下ごしらえ: `\sqrt{2}` を `sqrt(2)` にして(`\frac` の中に入れ子の `{}` があると
    /// 読めないため)、角度の記号(`^\circ`・`°`)を落とす。
    static func prepared(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "^{\\circ}", with: "").replacingOccurrences(of: "^\\circ", with: "")
            .replacingOccurrences(of: "\\circ", with: "").replacingOccurrences(of: "°", with: "")
        let sqrt = try! NSRegularExpression(pattern: #"\\sqrt\{([^{}]*)\}"#)
        while let match = sqrt.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) {
            let replacement = sqrt.replacementString(for: match, in: result, offset: 0, template: "sqrt($1)")
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\\left", with: "").replacingOccurrences(of: "\\right", with: "")
            .replacingOccurrences(of: "\\dfrac", with: "\\frac").lowercased()
    }

    // MARK: 共通

    /// 応答の本文(`content` の text)から、最初の `{` から最後の `}` までを JSON として読む。
    static func decode<T: Decodable>(_ type: T.Type, from response: [String: Any]) throws -> T {
        let text = ((response["content"] as? [[String: Any]]) ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8) else { throw Failure.malformed(String(text.prefix(200))) }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw Failure.malformed(String(text.prefix(200))) }
    }

    static func shrunkJPEG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = longest > photoMaxDimension ? photoMaxDimension / longest : 1
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}
