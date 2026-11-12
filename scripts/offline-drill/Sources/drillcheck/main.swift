import Foundation
@testable import strius

// 型の JSON を点検する道具(Linux でも macOS でも動く)。
//   swift run drillcheck check <ファイルかフォルダ>... [--show 3]

func templateFiles(_ path: String) -> [URL] {
    let url: URL = URL(fileURLWithPath: path)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return [] }
    guard isDirectory.boolValue else { return [url] }
    let enumerator: FileManager.DirectoryEnumerator? = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
    var found: [URL] = []
    while let next: URL = enumerator?.nextObject() as? URL {
        if next.pathExtension == "json", next.lastPathComponent != "catalog.json" { found.append(next) }
    }
    return found.sorted { (a: URL, b: URL) -> Bool in a.path < b.path }
}

func check(_ arguments: [String]) -> Int32 {
    var show: Int = 0
    var paths: [String] = []
    var index: Int = 0
    while index < arguments.count {
        if arguments[index] == "--show", index + 1 < arguments.count {
            show = Int(arguments[index + 1]) ?? 0
            index += 2
        } else {
            paths.append(arguments[index])
            index += 1
        }
    }
    var failed: Int = 0
    var total: Int = 0
    let validator: DrillValidator = DrillValidator()
    for file: URL in paths.flatMap(templateFiles) {
        total += 1
        guard let text: String = try? String(contentsOf: file, encoding: String.Encoding.utf8) else {
            print("FAIL \(file.lastPathComponent): 読めません")
            failed += 1
            continue
        }
        let result: (template: DrillTemplate?, inspection: DrillInspection) = validator.inspect(json: text)
        let inspection: DrillInspection = result.inspection
        let status: String = inspection.passed ? "PASS" : "FAIL"
        print("\(status) \(file.lastPathComponent) 問題 \(inspection.distinct) 通り(\(inspection.exhaustive ? "総当たり" : "抽出") \(inspection.satisfying)/\(inspection.examined)) 数値点検\(inspection.numericallyChecked ? "あり" : "なし")")
        if !inspection.passed {
            failed += 1
            print(inspection.feedback)
        }
        if show > 0, let template: DrillTemplate = result.template, let generator: DrillGenerator = try? DrillGenerator(template: template) {
            var random: DrillSeededRandom = DrillSeededRandom(seed: 20261112)
            var previous: DrillProblem? = nil
            for _ in 0..<show {
                guard let problem: DrillProblem = try? generator.next(using: &random, avoiding: previous) else { break }
                print("   Q: \(problem.prompt)\(problem.math.isEmpty ? "" : "  [\(problem.math)]")")
                print("   A: \(problem.answer)")
                previous = problem
            }
        }
    }
    print("\(total) 件中 \(total - failed) 件が合格")
    return failed == 0 ? 0 : 1
}

let arguments: [String] = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "check": exit(check(Array(arguments.dropFirst())))
default:
    print("使い方: drillcheck check <ファイルかフォルダ>... [--show 3]")
    exit(2)
}
