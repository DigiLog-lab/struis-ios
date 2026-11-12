#if DEBUG
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import strius

/// 画面のプロトタイプ(`OfflineDrillLabView`)に入れた型と、端末での数式の描画。
/// SwiftMath とアプリのコードを使うので、iOS のテストだけで流す(`striusTests/Drill/` は Linux でも流す)。
final class OfflineDrillLabTests: XCTestCase {
    private func fixturesRoot() throws -> URL {
        try XCTUnwrap(DrillTestSupport.fixturesRoot(), "drill-templates が見つかりません")
    }

    private func catalogTemplates() throws -> [(path: String, template: DrillTemplate)] {
        let root: URL = try fixturesRoot()
        let entries: [DrillCatalogEntry] = try JSONDecoder().decode(DrillCatalogFile.self, from: try Data(contentsOf: root.appendingPathComponent("catalog.json"))).entries
        return try entries.compactMap { (entry: DrillCatalogEntry) -> (path: String, template: DrillTemplate)? in
            guard let path: String = entry.template else { return nil }
            let text: String = try String(contentsOf: root.appendingPathComponent(path), encoding: String.Encoding.utf8)
            return (path: path, template: try DrillTemplate.decode(json: text))
        }
    }

    /// プロトタイプで見せる型は、実際に書いた型の写しで、端末の点検(SwiftMath での描画を含む)を通る。
    func testLabSamplesAreTheWrittenTemplatesAndPassTheDeviceInspection() throws {
        let root: URL = try fixturesRoot()
        XCTAssertGreaterThanOrEqual(OfflineDrillLabSamples.sources.count, 8)
        for source: (path: String, json: String) in OfflineDrillLabSamples.sources {
            let embedded: DrillTemplate = try DrillTemplate.decode(json: source.json)
            let original: DrillTemplate = try DrillTemplate.decode(json: try String(contentsOf: root.appendingPathComponent(source.path), encoding: String.Encoding.utf8))
            XCTAssertEqual(embedded, original, "\(source.path) の写しが正本と違う(scripts/offline-drill/make_lab_samples.py で作り直す)")
            let inspection: DrillInspection = DrillRenderProbe.validator.inspect(embedded)
            XCTAssertTrue(inspection.passed, "\(source.path): \(inspection.feedback)")
        }
    }

    /// 一覧のすべての型について、作った問題文・式・答えの数式を、アプリの数式描画(SwiftMath)が読める。
    func testEveryTemplateRendersWithSwiftMath() throws {
        let templates: [(path: String, template: DrillTemplate)] = try catalogTemplates()
        XCTAssertGreaterThan(templates.count, 400)
        var failures: [String] = []
        var checked: Int = 0
        for entry: (path: String, template: DrillTemplate) in templates {
            let generator: DrillGenerator = try DrillGenerator(template: entry.template)
            var random: DrillSeededRandom = DrillSeededRandom(seed: 20261112)
            var previous: DrillProblem? = nil
            for _: Int in 0..<12 {
                let problem: DrillProblem = try generator.next(using: &random, avoiding: previous)
                previous = problem
                var maths: [String] = problem.math.isEmpty ? [] : [problem.math]
                maths += try XCTUnwrap(DrillLint.split(problem.prompt), entry.path).maths
                maths += try XCTUnwrap(DrillLint.split(problem.answer), entry.path).maths
                for math: String in maths {
                    checked += 1
                    if let reason: String = DrillRenderProbe.swiftMath(math) { failures.append("\(entry.path): \(reason): \(math)") }
                }
            }
        }
        XCTAssertGreaterThan(checked, 5_000)
        XCTAssertEqual(failures.prefix(20).map { (line: String) -> String in line }, [], "SwiftMath で読めない式が \(failures.count) 個")
    }

    func testProbeReportsWhatSwiftMathCannotRead() {
        XCTAssertNil(DrillRenderProbe.swiftMath("\\frac{1}{2}x^{2} + \\sqrt{3}"))
        XCTAssertNotNil(DrillRenderProbe.swiftMath("\\rightleftarrows"), "平衡の矢印は SwiftMath に無い(型では式の外に ⇄ と書く)")
        XCTAssertNotNil(DrillRenderProbe.swiftMath("\\frac{1}{2"))
    }

    // MARK: - 書く面

    private func canvas(in view: UIView) -> TimelinePassThroughCanvas? {
        if let found: TimelinePassThroughCanvas = view as? TimelinePassThroughCanvas { return found }
        for child: UIView in view.subviews {
            if let found: TimelinePassThroughCanvas = canvas(in: child) { return found }
        }
        return nil
    }

    private func isCanvas(_ view: UIView?, _ canvas: TimelinePassThroughCanvas) -> Bool {
        guard let view: UIView = view else { return false }
        return view === canvas || view.isDescendant(of: canvas)
    }

    /// 余白は指で書ける状態で画面を覆い、ボタンの上だけ指をボタンに通す(画面を実際に組んで、指が届く先を確かめる)。
    @MainActor
    func testMarginIsWritableWithAFingerAndTheButtonsStayTappable() throws {
        let scene: UIWindowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { (scene: UIScene) -> UIWindowScene? in scene as? UIWindowScene }.first)
        let window: UIWindow = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host: UIHostingController<OfflineDrillLabView> = UIHostingController(rootView: OfflineDrillLabView())
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        let ink: TimelinePassThroughCanvas = try XCTUnwrap(canvas(in: window), "書く面が画面に無い")
        XCTAssertEqual(ink.drawingPolicy, PKCanvasViewDrawingPolicy.anyInput, "指で書ける")
        XCTAssertTrue(ink.isDrawingAllowed)
        XCTAssertTrue(ink.drawingGestureRecognizer.isEnabled)
        let frame: CGRect = ink.convert(ink.bounds, to: window)
        XCTAssertGreaterThanOrEqual(frame.width, 400, "端から端まで")
        XCTAssertGreaterThanOrEqual(frame.height, 700)

        // 余白(問題文の下の空いた所)と問題文の上の指は、書く面に届く。
        for point: CGPoint in [CGPoint(x: 120, y: 560), CGPoint(x: 200, y: 220), CGPoint(x: 30, y: 800)] {
            XCTAssertTrue(isCanvas(window.hitTest(point, with: nil), ink), "\(point) の指が書く面に届かない")
        }
        // ボタン(左上の「オフライン」、右下の「答え」「次へ」)の上の指は、書く面を通り抜ける。
        XCTAssertGreaterThanOrEqual(ink.passThrough.count, 2)
        for area: CGRect in ink.passThrough {
            let point: CGPoint = ink.convert(CGPoint(x: area.midX, y: area.midY), to: window)
            XCTAssertFalse(isCanvas(window.hitTest(point, with: nil), ink), "\(area) のボタンに指が届かない")
        }

        // 線を書くと「1つ戻す」「全部消す」が出て、その上も指を通す。
        let before: Int = ink.passThrough.count
        let points: [PKStrokePoint] = stride(from: 0, through: 120, by: 12).map { (offset: Int) -> PKStrokePoint in
            PKStrokePoint(location: CGPoint(x: ink.contentOffset.x + 80 + CGFloat(offset), y: ink.contentOffset.y + 500 + CGFloat(offset) / 3),
                          timeOffset: TimeInterval(offset) / 100, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: 0)
        }
        ink.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(PKInkingTool.InkType.monoline, color: UIColor.black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        ink.delegate?.canvasViewDrawingDidChange?(ink)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(ink.passThrough.count, before + 1, "書いた後は、戻す・消すのボタンが出る")
    }

    // MARK: - プロトタイプの状態

    @MainActor
    private func model(_ arguments: [String]) -> OfflineDrillLabModel {
        OfflineDrillLabModel.launch(arguments: ["strius", "-offline-drill-lab"] + arguments)
    }

    @MainActor
    func testAnswerIsHiddenUntilAskedAndHiddenAgainOnTheNextProblem() throws {
        let lab: OfflineDrillLabModel = model(["-offline-drill-seed", "5"])
        XCTAssertEqual(lab.variant, OfflineDrillLabModel.Variant.answer)
        XCTAssertEqual(lab.count, 1)
        XCTAssertFalse(lab.isAnswerShown)
        let first: DrillProblem = try XCTUnwrap(lab.problem)
        lab.toggleAnswer()
        XCTAssertTrue(lab.isAnswerShown)
        lab.next()
        XCTAssertFalse(lab.isAnswerShown, "次の問題では答えを隠す")
        XCTAssertEqual(lab.count, 2)
        XCTAssertNotEqual(try XCTUnwrap(lab.problem), first, "直前と同じ問題は出さない")
    }

    @MainActor
    func testNextOnlyVariantNeverShowsTheAnswer() {
        let lab: OfflineDrillLabModel = model(["-offline-drill-variant", "next", "-offline-drill-reveal"])
        XCTAssertEqual(lab.variant, OfflineDrillLabModel.Variant.next)
        XCTAssertFalse(lab.isAnswerShown)
        lab.toggleAnswer()
        XCTAssertFalse(lab.isAnswerShown)
    }

    @MainActor
    func testLaunchArgumentsChooseTheTemplateAndTheSeedRepeatsTheProblems() throws {
        let arguments: [String] = ["-offline-drill-skill", "physics.mech.velocity_time", "-offline-drill-seed", "42", "-offline-drill-reveal"]
        let a: OfflineDrillLabModel = model(arguments)
        let b: OfflineDrillLabModel = model(arguments)
        XCTAssertEqual(a.template.skillId, "physics.mech.velocity_time")
        XCTAssertTrue(a.isAnswerShown)
        var seen: [DrillProblem] = []
        for _: Int in 0..<5 {
            XCTAssertEqual(a.problem, b.problem, "同じ種からは同じ問題の並び")
            seen.append(try XCTUnwrap(a.problem))
            a.next()
            b.next()
        }
        XCTAssertEqual(Set(seen.map(\.key)).count, 5)

        a.select(0)
        XCTAssertEqual(a.template.skillId, "math.m1.complete_square_vertex")
        XCTAssertEqual(a.count, 1)
        a.setVariant(OfflineDrillLabModel.Variant.next)
        XCTAssertFalse(a.isAnswerShown)
    }
}
#endif
