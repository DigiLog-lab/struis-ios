import XCTest
@testable import strius

/// 計算操作の一覧(`Fixtures/drill-templates/catalog.json`)の 1 行。
struct DrillCatalogEntry: Codable, Equatable {
    var id: String
    /// math | physics | chemistry
    var subject: String
    /// 学年・科目(中学1年、高校 数学I、大学初年 など)。
    var level: String
    /// 分野。
    var field: String
    /// 操作の名前。
    var name: String
    /// 型のファイル(`math/….json`)。書式で表せない操作には無い。
    var template: String?
    /// 数値の点検があるか(型がある行だけ)。
    var numericCheck: Bool?
    /// 例題(型が無い行だけ。型がある行の例題は、型から作る)。
    var example: String?
    /// 書式で表せない理由(型が無い行だけ)。
    var unrepresentable: String?

    enum CodingKeys: String, CodingKey {
        case id, subject, level, field, name, template, example, unrepresentable
        case numericCheck = "numeric_check"
    }
}

struct DrillCatalogFile: Codable {
    var entries: [DrillCatalogEntry]
}

/// 並べて点検した結果を、順番どおりに受け取る入れ物。
final class DrillResultBox: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var results: [(template: DrillTemplate?, inspection: DrillInspection)?]

    init(count: Int) {
        self.results = Array(repeating: nil, count: count)
    }

    func set(_ index: Int, _ result: (template: DrillTemplate?, inspection: DrillInspection)) {
        lock.lock()
        results[index] = result
        lock.unlock()
    }

    func get(_ index: Int) -> (template: DrillTemplate?, inspection: DrillInspection)? {
        lock.lock()
        defer { lock.unlock() }
        return results[index]
    }
}

/// 書いた型をそのまま単体テストの材料にする。一覧のすべての型が点検を通ることを固定する。
final class DrillCatalogTests: XCTestCase {
    typealias S = DrillTestSupport

    private func catalog() throws -> (root: URL, entries: [DrillCatalogEntry]) {
        let root: URL = try XCTUnwrap(S.fixturesRoot(), "drill-templates が見つかりません")
        let data: Data = try Data(contentsOf: root.appendingPathComponent("catalog.json"))
        return (root, try JSONDecoder().decode(DrillCatalogFile.self, from: data).entries)
    }

    private func source(_ entry: DrillCatalogEntry, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(try XCTUnwrap(entry.template)), encoding: String.Encoding.utf8)
    }

    func testEveryTemplatePassesInspection() throws {
        let loaded: (root: URL, entries: [DrillCatalogEntry]) = try catalog()
        let validator: DrillValidator = DrillValidator()
        let templated: [DrillCatalogEntry] = loaded.entries.filter { (entry: DrillCatalogEntry) -> Bool in entry.template != nil }
        let sources: [String] = try templated.map { (entry: DrillCatalogEntry) -> String in try source(entry, root: loaded.root) }
        XCTAssertGreaterThan(templated.count, 0)
        // 型は数百あるので、コアの数だけ並べて点検する(点検器は状態を持たない)。
        let results: DrillResultBox = DrillResultBox(count: templated.count)
        DispatchQueue.concurrentPerform(iterations: templated.count) { (index: Int) -> Void in
            results.set(index, validator.inspect(json: sources[index]))
        }
        for (index, entry): (Int, DrillCatalogEntry) in templated.enumerated() {
            guard let result: (template: DrillTemplate?, inspection: DrillInspection) = results.get(index) else { return XCTFail("\(entry.id): 点検の結果がありません") }
            XCTAssertTrue(result.inspection.passed, "\(entry.id): \(result.inspection.feedback)")
            XCTAssertEqual(result.template?.skillId, entry.id, entry.id)
            XCTAssertEqual(result.template?.title, entry.name, entry.id)
            XCTAssertEqual(result.template?.subject, entry.subject, entry.id)
            XCTAssertEqual(result.inspection.numericallyChecked, entry.numericCheck, "\(entry.id): 一覧の「数値点検」と型が合いません")
            XCTAssertGreaterThanOrEqual(result.inspection.distinct, DrillValidator.minimumProblems, entry.id)
        }
    }

    func testCatalogIsConsistent() throws {
        let loaded: (root: URL, entries: [DrillCatalogEntry]) = try catalog()
        XCTAssertEqual(Set(loaded.entries.map(\.id)).count, loaded.entries.count, "ID が重なっています")
        var listed: Set<String> = []
        for entry: DrillCatalogEntry in loaded.entries {
            XCTAssertTrue(["math", "physics", "chemistry"].contains(entry.subject), entry.id)
            XCTAssertTrue(entry.id.hasPrefix(entry.subject + "."), entry.id)
            XCTAssertFalse(entry.level.isEmpty || entry.field.isEmpty || entry.name.isEmpty, entry.id)
            if let template: String = entry.template {
                listed.insert(template)
                XCTAssertEqual(template, "\(entry.subject)/\(entry.id).json", entry.id)
                XCTAssertNotNil(entry.numericCheck, "\(entry.id): 数値点検の有無がありません")
                XCTAssertNil(entry.unrepresentable, entry.id)
            } else {
                // 書式で表せない操作は、例題と理由を付けて一覧に残す。
                XCTAssertFalse((entry.example ?? "").isEmpty, "\(entry.id): 例題がありません")
                XCTAssertFalse((entry.unrepresentable ?? "").isEmpty, "\(entry.id): 表せない理由がありません")
            }
        }
        // 一覧に無い型のファイルが残っていない。
        var files: Set<String> = []
        for subject: String in ["math", "physics", "chemistry"] {
            let directory: URL = loaded.root.appendingPathComponent(subject)
            for name: String in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".json") {
                files.insert("\(subject)/\(name)")
            }
        }
        XCTAssertEqual(files.subtracting(listed), [], "一覧に無い型があります")
        XCTAssertEqual(listed.subtracting(files), [], "型のファイルがありません")
    }

    func testGeneratorProducesFromEveryTemplate() throws {
        // 生成器が、どの型からも続けて問題を作れる(直前と同じ問題は出さない)。
        let loaded: (root: URL, entries: [DrillCatalogEntry]) = try catalog()
        for entry: DrillCatalogEntry in loaded.entries where entry.template != nil {
            let generator: DrillGenerator = try DrillGenerator(template: try DrillTemplate.decode(json: try source(entry, root: loaded.root)))
            var random: DrillSeededRandom = DrillSeededRandom(seed: 7)
            var previous: DrillProblem? = nil
            for _ in 0..<5 {
                let problem: DrillProblem = try generator.next(using: &random, avoiding: previous)
                XCTAssertNotEqual(problem.key, previous?.key, entry.id)
                XCTAssertEqual(DrillLint.issues(in: problem), [], entry.id)
                previous = problem
            }
        }
    }

    // MARK: 一覧の文書

    /// 一覧の例題。型がある行は、型から種を固定して作る。
    private func example(_ entry: DrillCatalogEntry, root: URL) throws -> String {
        guard entry.template != nil else { return entry.example ?? "" }
        var random: DrillSeededRandom = DrillSeededRandom(seed: 20261112)
        let problem: DrillProblem = try DrillGenerator(template: try DrillTemplate.decode(json: try source(entry, root: root))).next(using: &random)
        return problem.math.isEmpty ? problem.prompt : "\(problem.prompt) $\(problem.math)$"
    }

    private func markdown(_ entries: [DrillCatalogEntry], root: URL) throws -> String {
        let subjects: [(key: String, name: String)] = [("math", "数学"), ("physics", "物理"), ("chemistry", "化学")]
        var lines: [String] = [
            "# オフライン反復モード 計算操作の一覧",
            "",
            "この文書は `striusTests/Fixtures/drill-templates/catalog.json` から単体テスト(`DrillCatalogTests`)が作ります。手で直さず、`catalog.json` と型を直してから作り直してください",
            "(`cd scripts/offline-drill && DRILL_WRITE_CATALOG=1 swift test --filter DrillCatalogTests`)。",
            "",
            "- 1 行は、知識グラフの `procedure` の点と同じくらいの細かさ(1 つの手順で解ける計算操作)です。概念の理解・証明・暗記だけの事項は対象外です。",
            "- 「例題」は、型がある行では型から実際に作った 1 問です。",
            "- 「数値点検」は、型の `checks` で答えの公式を数値で確かめているかです。「なし」の型は、型の `no_numeric_check` に理由があります。",
            "- 「表せない理由」は、書式(`docs/offline-drill/format.md`)で表せない操作に付けます。",
            "",
            "## 集計",
            "",
            "| 教科 | 行 | 型あり | 数値点検あり | 数値点検なし | 表せない |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
        for subject: (key: String, name: String) in subjects {
            let rows: [DrillCatalogEntry] = entries.filter { (entry: DrillCatalogEntry) -> Bool in entry.subject == subject.key }
            let withTemplate: [DrillCatalogEntry] = rows.filter { (entry: DrillCatalogEntry) -> Bool in entry.template != nil }
            let checked: Int = withTemplate.filter { (entry: DrillCatalogEntry) -> Bool in entry.numericCheck == true }.count
            lines.append("| \(subject.name) | \(rows.count) | \(withTemplate.count) | \(checked) | \(withTemplate.count - checked) | \(rows.count - withTemplate.count) |")
        }
        let allTemplates: [DrillCatalogEntry] = entries.filter { (entry: DrillCatalogEntry) -> Bool in entry.template != nil }
        let allChecked: Int = allTemplates.filter { (entry: DrillCatalogEntry) -> Bool in entry.numericCheck == true }.count
        lines.append("| 合計 | \(entries.count) | \(allTemplates.count) | \(allChecked) | \(allTemplates.count - allChecked) | \(entries.count - allTemplates.count) |")
        for subject: (key: String, name: String) in subjects {
            var level: String = ""
            for entry: DrillCatalogEntry in entries where entry.subject == subject.key {
                if entry.level != level {
                    level = entry.level
                    lines += ["", "## \(subject.name) \(level)", "", "| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |", "| --- | --- | --- | --- | --- | --- | --- |"]
                }
                // 表の区切りと重なる「|」は \vert に、改行は空白にする。
                let shown: String = try example(entry, root: root).replacingOccurrences(of: "|", with: "\\vert ").replacingOccurrences(of: "\n", with: " ")
                let template: String = entry.template.map { (path: String) -> String in "[あり](../../striusTests/Fixtures/drill-templates/\(path))" } ?? "なし"
                let numeric: String = entry.numericCheck.map { (flag: Bool) -> String in flag ? "あり" : "なし" } ?? "—"
                lines.append("| \(subject.name) | \(entry.field) | \(entry.name) | \(shown) | \(template) | \(numeric) | \(entry.unrepresentable ?? "") |")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func testCatalogDocumentIsCurrent() throws {
        let loaded: (root: URL, entries: [DrillCatalogEntry]) = try catalog()
        let text: String = try markdown(loaded.entries, root: loaded.root)
        // 文書はソースの隣にある時だけ比べる(テストのバンドルには入れていない)。
        guard let repository: URL = S.repositoryRoot() else { throw XCTSkip("docs/offline-drill がこの環境から読めません") }
        let document: URL = repository.appendingPathComponent("docs/offline-drill/catalog.md")
        if ProcessInfo.processInfo.environment["DRILL_WRITE_CATALOG"] == "1" {
            try text.write(to: document, atomically: true, encoding: String.Encoding.utf8)
        }
        let current: String = (try? String(contentsOf: document, encoding: String.Encoding.utf8)) ?? ""
        XCTAssertEqual(current, text, "docs/offline-drill/catalog.md が古くなっています。DRILL_WRITE_CATALOG=1 で作り直してください")
    }
}
