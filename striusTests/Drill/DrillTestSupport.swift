import Foundation
import XCTest
@testable import strius

/// オフライン反復のテストで使う道具。
enum DrillTestSupport {
    static func rational(_ numerator: Int, _ denominator: Int = 1) -> DrillRational {
        DrillRational(numerator, denominator)!
    }

    static func number(_ numerator: Int, _ denominator: Int = 1) -> DrillValue {
        DrillValue.number(DrillNumber(rational: rational(numerator, denominator)))
    }

    /// 式を評価する。
    static func evaluate(_ source: String, _ scope: [String: DrillValue] = [:]) throws -> DrillValue {
        try DrillExpression.parse(source).evaluate(scope)
    }

    /// 式を評価して LaTeX にする(名前の宣言なし)。
    static func tex(_ source: String, _ modifiers: [String] = [], _ scope: [String: DrillValue] = [:]) throws -> String {
        let quantity: DrillQuantity = try DrillExpression.quantity(try evaluate(source, scope))
        return try DrillFormat.text(of: quantity, spec: try DrillFormatSpec.parse(modifiers), display: DrillDisplay.none)
    }

    /// 型から、種を固定して 1 問作る。
    static func problem(_ template: DrillTemplate, seed: UInt64 = 1) throws -> DrillProblem {
        var random: DrillSeededRandom = DrillSeededRandom(seed: seed)
        return try DrillGenerator(template: template).next(using: &random)
    }

    /// 変数の値を決めて 1 問作る(`values` は変数の順)。
    static func problem(_ template: DrillTemplate, values: [DrillValue]) throws -> DrillProblem? {
        try DrillCompiledTemplate(template).instance(values: values)?.problem
    }

    /// テスト用の型(数学、点検は value 1 つ)。
    static func template(variables: [DrillVariable], lets: [DrillLet] = [], constraints: [String] = [], parts: [DrillPart] = [], prompt: String = "次の計算をしなさい。",
                         math: String, answer: String, checks: [DrillCheck] = [], noNumericCheck: String? = nil, subject: String = "math") -> DrillTemplate {
        DrillTemplate(skillId: "test.skill", title: "テスト", subject: subject, variables: variables, lets: lets, constraints: constraints, parts: parts,
                      prompt: prompt, math: math, answer: answer, checks: checks, noNumericCheck: checks.isEmpty ? (noNumericCheck ?? "テスト用") : noNumericCheck)
    }

    static func integer(_ name: String, _ min: Int, _ max: Int, exclude: [Double]? = nil) -> DrillVariable {
        DrillVariable(name: name, kind: "integer", min: Double(min), max: Double(max), exclude: exclude)
    }

    /// 型の置き場(striusTests/Fixtures/drill-templates)。テストのバンドルに入っていればそこから、無ければソースの隣から読む。
    static func fixturesRoot(file: String = #filePath) -> URL? {
        if let bundled: URL = Bundle(for: DrillFixtureLocator.self).url(forResource: "drill-templates", withExtension: nil) { return bundled }
        let local: URL = URL(fileURLWithPath: file).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/drill-templates")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// リポジトリの直下(Linux と、ソースが手元にある Mac で使える)。
    static func repositoryRoot(file: String = #filePath) -> URL? {
        let root: URL = URL(fileURLWithPath: file).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/offline-drill").path) ? root : nil
    }
}

final class DrillFixtureLocator {}
