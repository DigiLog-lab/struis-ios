import XCTest
@testable import strius

/// 2026-11-15 の検証用(一時。マージしない): クーロンの法則の型から問題を作り、点検が通るかを見る。
final class DrillVerify1115Tests: XCTestCase {
    func testCoulombTemplateGenerates() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/drill-templates/physics/physics.em.coulomb_law.json")
        let template = try DrillTemplate.decode(json: try String(contentsOf: url, encoding: .utf8))
        let generator = try DrillGenerator(template: template)
        var random = DrillSeededRandom(seed: 1115)
        var previous: DrillProblem? = nil
        for i in 0..<8 {
            let problem = try generator.next(using: &random, avoiding: previous)
            XCTAssertEqual(DrillLint.issues(in: problem), [])
            print("DRILL\(i + 1): \(problem.prompt) \(problem.math) => \(problem.answer)")
            previous = problem
        }
    }
}
