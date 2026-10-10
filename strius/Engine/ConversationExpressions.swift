import Foundation
import GRDB

/// 類題・演習の一枚が、その小単元の会話に出た式をそのまま使わないようにする(D14)。
/// - 組む前: 会話(小単元の `metadata.thread_id` の thread)に出た式を集め、一枚の生成ターンに「避ける式」として渡す。
/// - 組んだ後: できた問題が会話の式と同じなら、1 回だけ組み直させる(それでも同じなら、そのまま使う。一枚を作れなくはしない)。
/// 式の比べ方は、空白・符号の字形・上付きの書き方・`\left` などの違いをそろえた文字列の一致と包含。
nonisolated enum ConversationExpressions {
    /// 渡す式の数の上限(新しいものから)。
    static let limit = 40
    /// 比べる式の最短の長さ(そろえた後)。`x=3` のような短い式で誤って重複とみなさない。
    static let minimumLength = 6

    // MARK: - 会話から集める

    /// 一枚の小単元の会話 thread(小単元の `metadata.thread_id`)。
    static func threadID(machine: WorkbookMachine, setID: String) -> String? {
        guard let subunitID = machine.sets[setID]?.subunitId else { return nil }
        return machine.subunits[subunitID]?.metadata["thread_id"]?.stringValue
    }

    /// その会話に出た式(読める形)。新しいものから、重複を除いて `limit` 個まで。
    static func inThread(db: Database, threadID: String?) throws -> [String] {
        guard let threadID else { return [] }
        let messages = try MessageRecord
            .filter(Column("thread_id") == threadID)
            .order(Column("created_at").desc)
            .limit(200)
            .fetchAll(db)
        var seen: Set<String> = []
        var result: [String] = []
        for message in messages {
            let text = message.plainText ?? ""
            for expression in expressions(in: text) where isSpecific(normalize(expression)) && seen.insert(normalize(expression)).inserted {
                result.append(expression)
                if result.count >= limit { return result }
            }
        }
        return result
    }

    // MARK: - 式を取り出す

    private static let fenced = try! NSRegularExpression(pattern: #"\$\$(.+?)\$\$|\\\[(.+?)\\\]|\\\((.+?)\\\)|\$([^$\n]+?)\$"#, options: [.dotMatchesLineSeparators])
    /// 区切りの無い式(学習者が打った `x^2-6x+5` など)。英数字と演算子の並びで、文字と演算子を両方含むもの。
    private static let bare = try! NSRegularExpression(pattern: #"[0-9A-Za-z²³⁴^()（）+\-−*/×÷·=.]{5,}"#)

    /// 本文に出てくる式(読める形)。数式の区切りの中と、区切りの無い式の並び。等式は左右の辺も別に数える。
    static func expressions(in text: String) -> [String] {
        var found: [String] = []
        var rest = text
        let range = NSRange(text.startIndex..., in: text)
        for match in fenced.matches(in: text, range: range) {
            for group in 1...4 {
                guard let r = Range(match.range(at: group), in: text) else { continue }
                found.append(MathPlainText.convert(String(text[r])))
            }
            if let whole = Range(match.range, in: text) {
                rest = rest.replacingOccurrences(of: String(text[whole]), with: " ")
            }
        }
        let restRange = NSRange(rest.startIndex..., in: rest)
        for match in bare.matches(in: rest, range: restRange) {
            guard let r = Range(match.range, in: rest) else { continue }
            let candidate = String(rest[r])
            guard candidate.contains(where: { $0.isLetter }), candidate.contains(where: { "+-−*/×÷·=^²³⁴".contains($0) }) else { continue }
            found.append(candidate)
        }
        var result: [String] = []
        for expression in found {
            let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalize(trimmed).count >= minimumLength else { continue }
            result.append(trimmed)
            // 等式・不等式は左右の辺も比べる(会話の「x²−6x+5 = (x−3)²−4」と問題の「x²−6x+5 を平方完成」)。
            for side in trimmed.components(separatedBy: CharacterSet(charactersIn: "=<>≤≥≠")) {
                let piece = side.trimmingCharacters(in: .whitespaces)
                if normalize(piece).count >= minimumLength, piece != trimmed { result.append(piece) }
            }
        }
        return result
    }

    // MARK: - 比べる

    private static let superscriptDigits: [Character: String] = ["⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "⁻": "-", "⁺": "+", "ⁿ": "n"]

    /// 比べるための形。空白を除き、符号・掛け算の字形と上付きの書き方をそろえ、小文字にする。
    static func normalize(_ expression: String) -> String {
        var output = ""
        var inSuperscript = false
        for char in MathPlainText.convert(expression) {
            if let digit = superscriptDigits[char] {
                if !inSuperscript { output += "^" }
                output += digit
                inSuperscript = true
                continue
            }
            inSuperscript = false
            switch char {
            case " ", "\u{3000}", "\t", "\n": continue
            case "−", "–", "ー": output += "-"
            case "×", "·", "∙": output += "*"
            case "（": output += "("
            case "）": output += ")"
            case "{", "}": continue
            default: output += String(char).lowercased()
            }
        }
        return output
    }

    /// 具体的な式か。指数を除く数字が 2 つ以上ある(`x^2-6x+5`、`(x-3)^2-4`)。一般の形(`ax^2+bx+c`、`b^2-4ac`)は
    /// どの問題にも出てくるので、避ける式にしない。
    static func isSpecific(_ normalized: String) -> Bool {
        guard normalized.count >= minimumLength else { return false }
        var digits = 0
        var previous: Character?
        var inExponent = false
        for char in normalized {
            if char.isNumber {
                if previous == "^" { inExponent = true }
                if !inExponent { digits += 1 }
            } else {
                inExponent = false
            }
            previous = char
        }
        return digits >= 2
    }

    /// 問題文のうち、避ける式と同じ式を含むもの(重なった式の読める形)。
    static func overlaps(prompts: [String], avoid: [String]) -> [String] {
        let avoided = Set(avoid.map(normalize).filter(isSpecific))
        guard !avoided.isEmpty else { return [] }
        var hits: [String] = []
        for prompt in prompts {
            for expression in expressions(in: prompt) {
                let candidate = normalize(expression)
                guard candidate.count >= minimumLength else { continue }
                if avoided.contains(where: { $0 == candidate || $0.contains(candidate) || candidate.contains($0) }), !hits.contains(expression) {
                    hits.append(expression)
                }
            }
        }
        return hits
    }
}
