import Foundation

/// 点検の結果。
nonisolated struct DrillInspection: Equatable, Sendable {
    /// 見つけた問題(空なら合格)。
    let issues: [DrillIssue]
    /// 調べた変数の組の数。
    let examined: Int
    /// そのうち条件を満たした組の数。
    let satisfying: Int
    /// 作れた、互いに違う問題の数。
    let distinct: Int
    /// 変数の組を総当たりしたか(多すぎる時は抽出)。
    let exhaustive: Bool
    /// 数値の点検をしたか(型に `checks` があり、すべて合った)。
    let numericallyChecked: Bool

    var passed: Bool { issues.isEmpty }

    /// AI に返す、落ちた理由(1 行に 1 つ)。
    var feedback: String {
        issues.map { (issue: DrillIssue) -> String in "- \(issue.message)" }.joined(separator: "\n")
    }
}

/// 点検器(docs/offline-drill/format.md「点検」)。AI が書いた型を保存する前に、端末の中で確かめる。
/// 変数の組を総当たり(多すぎる時は抽出)し、問題が十分作れるか、答えが必ず定まるか、表示が崩れないか、
/// 数値で確かめられる型は答えの公式が正しいかを見る。
nonisolated struct DrillValidator: Sendable {
    /// 作れる問題の数の下限。
    static let minimumProblems: Int = 20
    /// これ以下なら変数の組を総当たりする。
    static let enumerationLimit: Double = 4_000
    /// 総当たりしない時に抽出する組の数。
    static let sampleCount: Int = 2_000
    /// 表示の点検をする問題の数の上限。
    static let lintLimit: Int = 400
    /// 条件を満たす組の割合の下限(これより低いと、出題のたびに選び直しが続く)。
    static let minimumAcceptance: Double = 0.01
    /// 数値の点検をする問題の数の上限。
    static let numericLimit: Int = 48
    /// 画面の数式描画で読めるかを確かめる問題の数の上限。
    static let renderLimit: Int = 24
    /// 丸めの境目で値が定まらない組を許す割合(生成器が選び直す)。
    static let roundingAllowance: Double = 0.05

    /// 画面の数式描画で読めるかを確かめる関数(LaTeX を渡し、読めなければ理由を返す)。端末では SwiftMath を当てる。
    var renderProbe: (@Sendable (String) -> String?)?

    init(renderProbe: (@Sendable (String) -> String?)? = nil) {
        self.renderProbe = renderProbe
    }

    /// JSON の文字列を読んで点検する。
    func inspect(json text: String) -> (template: DrillTemplate?, inspection: DrillInspection) {
        do {
            let template: DrillTemplate = try DrillTemplate.decode(json: text)
            return (template, inspect(template))
        } catch let error as DrillTemplate.DecodeError {
            return (nil, DrillValidator.failed([DrillIssue(code: "decode", message: error.message)]))
        } catch {
            return (nil, DrillValidator.failed([DrillIssue(code: "decode", message: "JSON として読めません")]))
        }
    }

    private static func failed(_ issues: [DrillIssue]) -> DrillInspection {
        DrillInspection(issues: issues, examined: 0, satisfying: 0, distinct: 0, exhaustive: false, numericallyChecked: false)
    }

    func inspect(_ template: DrillTemplate) -> DrillInspection {
        var issues: [DrillIssue] = []
        func add(_ code: String, _ message: String) {
            let issue: DrillIssue = DrillIssue(code: code, message: message)
            if !issues.contains(issue) { issues.append(issue) }
        }

        // 型そのものの形。
        if template.skillId.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty { add("shape", "skill_id が空です") }
        if template.title.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty { add("shape", "title が空です") }
        if !["math", "physics", "chemistry", "other"].contains(template.subject) { add("shape", "subject は math・physics・chemistry・other のどれかです") }
        let reason: String = (template.noNumericCheck ?? "").trimmingCharacters(in: CharacterSet.whitespaces)
        if template.checks.isEmpty, reason.isEmpty {
            add("shape", "checks が空です。数値で確かめる点検を書くか、確かめられない理由を no_numeric_check に書いてください")
        }
        if !template.checks.isEmpty, !reason.isEmpty {
            add("shape", "checks があるのに no_numeric_check も書かれています。どちらか一方にしてください")
        }

        let compiled: DrillCompiledTemplate
        var checks: [DrillCompiledCheck] = []
        do {
            compiled = try DrillCompiledTemplate(template)
            for (index, check): (Int, DrillCheck) in template.checks.enumerated() {
                checks.append(try DrillCompiledCheck(check, index: index, compiled: compiled))
            }
        } catch let error as DrillFailure {
            add("compile", error.message)
            return DrillValidator.failed(issues)
        } catch {
            add("compile", "型を読めませんでした")
            return DrillValidator.failed(issues)
        }
        // 変数を 1 つも使っていない問題は、数字が入れ替わらない。
        let used: Set<String> = compiled.prompt.names.union(compiled.math.names)
        if used.isEmpty { add("shape", "問題文(prompt・math)に差し込みが 1 つもありません。数字が入れ替わりません") }

        // 変数の組を総当たり(多すぎる時は抽出)する。
        let exhaustive: Bool = compiled.combinationCount <= DrillValidator.enumerationLimit
        var examined: Int = 0
        var satisfying: Int = 0
        var roundingFailures: Int = 0
        var keys: Set<String> = []
        var kept: [[DrillValue]] = []
        var failures: [String: String] = [:]
        var lintFound: [String] = []

        func examine(_ values: [DrillValue]) {
            examined += 1
            do {
                guard let instance: DrillCompiledTemplate.Instance = try compiled.instance(values: values) else { return }
                satisfying += 1
                if keys.insert(instance.problem.key).inserted {
                    kept.append(values)
                    if lintFound.count < 12, keys.count <= DrillValidator.lintLimit || keys.count % 16 == 0 {
                        for issue: String in DrillLint.issues(in: instance.problem) where !lintFound.contains(where: { (known: String) -> Bool in DrillValidator.sameKind(known, issue) }) {
                            lintFound.append(issue)
                        }
                    }
                }
            } catch let error as DrillFailure {
                satisfying += 1
                if error.message.contains("丸めの境目") {
                    roundingFailures += 1
                } else if failures.count < 6, failures[error.message] == nil {
                    failures[error.message] = describe(values, compiled)
                }
            } catch {
                satisfying += 1
                failures["値を計算できませんでした"] = describe(values, compiled)
            }
        }

        if exhaustive {
            var indices: [Int] = Array(repeating: 0, count: compiled.variables.count)
            var finished: Bool = false
            while !finished {
                examine(zip(compiled.variables, indices).map { (variable: DrillCompiledTemplate.Variable, index: Int) -> DrillValue in variable.domain[index] })
                var position: Int = indices.count - 1
                while position >= 0 {
                    indices[position] += 1
                    if indices[position] < compiled.variables[position].domain.count { break }
                    indices[position] = 0
                    position -= 1
                }
                finished = position < 0
            }
        } else {
            var random: DrillSeededRandom = DrillSeededRandom(seed: 0x5EED_D211)
            let generator: DrillGenerator = DrillGenerator(compiled: compiled)
            for _ in 0..<DrillValidator.sampleCount {
                examine(generator.draw(using: &random))
            }
        }

        for (message, example): (String, String) in failures.sorted(by: { (a: (key: String, value: String), b: (key: String, value: String)) -> Bool in a.key < b.key }) {
            add("undefined", "条件を満たすのに、問題を作れない変数の組があります(\(example)): \(message)。constraints でその組を外してください")
        }
        if satisfying > 0, Double(roundingFailures) > DrillValidator.roundingAllowance * Double(satisfying) {
            add("undefined", "丸めの境目(…5)にちょうど乗って表示が定まらない組が多すぎます(\(roundingFailures) / \(satisfying))。sin(pi/6) のような実数の計算は sind(30) のように誤差のない関数にしてください")
        }
        let acceptance: Double = examined == 0 ? 0 : Double(satisfying) / Double(examined)
        if satisfying == 0 {
            add("count", "条件を満たす変数の組が 1 つもありません")
        } else {
            if keys.count < DrillValidator.minimumProblems {
                let total: String = exhaustive ? "全部で" : "抽出した \(examined) 組のうち"
                add("count", "作れる問題が少なすぎます(\(total) \(keys.count) 通り。\(DrillValidator.minimumProblems) 通り以上にしてください)。変数の範囲を広げてください")
            }
            if acceptance < DrillValidator.minimumAcceptance {
                add("count", "条件を満たす組の割合が低すぎます(\(String(format: "%.2f", acceptance * 100))%)。答えから逆算して変数を決める形にしてください(例: 解を先に選んで、係数を lets で計算する)")
            }
        }
        for issue: String in lintFound {
            add("display", issue)
        }

        // 画面の数式描画で読めるか(端末で確かめる)。
        if let probe: (@Sendable (String) -> String?) = renderProbe {
            for values: [DrillValue] in DrillValidator.spread(kept, limit: DrillValidator.renderLimit) {
                guard let instance: DrillCompiledTemplate.Instance = try? compiled.instance(values: values) else { continue }
                var maths: [String] = instance.problem.math.isEmpty ? [] : [instance.problem.math]
                maths += DrillLint.split(instance.problem.prompt)?.maths ?? []
                maths += DrillLint.split(instance.problem.answer)?.maths ?? []
                for math: String in maths {
                    if let problem: String = probe(math) { add("display", "画面で式を描けません(\(problem)): \(math)") }
                }
                if issues.contains(where: { (issue: DrillIssue) -> Bool in issue.code == "display" }) { break }
            }
        }

        // 数値の点検。
        var numericFailed: Bool = false
        if !checks.isEmpty {
            var reported: Set<String> = []
            for values: [DrillValue] in DrillValidator.spread(kept, limit: DrillValidator.numericLimit) {
                guard let instance: DrillCompiledTemplate.Instance = try? compiled.instance(values: values) else { continue }
                for check: DrillCompiledCheck in checks where !reported.contains(check.place) {
                    if let failure: String = check.failure(for: instance, compiled: compiled) {
                        reported.insert(check.place)
                        numericFailed = true
                        add("numeric", "数値の点検に落ちました(\(describe(values, compiled))): \(failure)")
                    }
                }
                if reported.count == checks.count { break }
            }
        }

        return DrillInspection(issues: issues, examined: examined, satisfying: satisfying, distinct: keys.count, exhaustive: exhaustive,
                               numericallyChecked: !checks.isEmpty && !numericFailed && satisfying > 0)
    }

    /// 同じ種類の指摘か(例の式だけが違うものは 1 つにまとめる)。
    private static func sameKind(_ a: String, _ b: String) -> Bool {
        func head(_ text: String) -> String {
            let pieces: [Substring] = text.split(separator: ":", maxSplits: 2)
            return pieces.prefix(2).joined(separator: ":")
        }
        return head(a) == head(b)
    }

    /// 全体からまんべんなく `limit` 個を選ぶ。
    private static func spread(_ items: [[DrillValue]], limit: Int) -> [[DrillValue]] {
        guard items.count > limit else { return items }
        return (0..<limit).map { (index: Int) -> [DrillValue] in items[index * items.count / limit] }
    }

    /// 変数の組を読める形にする(a = 2, b = -3)。
    private func describe(_ values: [DrillValue], _ compiled: DrillCompiledTemplate) -> String {
        zip(compiled.variables, values).map { (variable: DrillCompiledTemplate.Variable, value: DrillValue) -> String in
            "\(variable.name) = \(DrillValidator.text(of: value))"
        }.joined(separator: ", ")
    }

    private static func text(of value: DrillValue) -> String {
        switch value {
        case DrillValue.quantity(let quantity):
            if let rational: DrillRational = quantity.number.rational {
                return rational.isInteger ? "\(rational.numerator)" : "\(rational.numerator)/\(rational.denominator)"
            }
            return quantity.number.doubleValue.map { (double: Double) -> String in "\(double)" } ?? "(複素数)"
        case DrillValue.text(let text): return "'\(text)'"
        case DrillValue.bool(let flag): return flag ? "true" : "false"
        case DrillValue.record(let fields):
            let first: String = fields.sorted { (a: (key: String, value: DrillValue), b: (key: String, value: DrillValue)) -> Bool in a.key < b.key }
                .first.map { (field: (key: String, value: DrillValue)) -> String in "\(field.key): \(text(of: field.value))" } ?? ""
            return "{\(first), …}"
        }
    }
}
