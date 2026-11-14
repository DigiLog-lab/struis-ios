import SwiftUI
import XCTest
@testable import strius

/// 送るを上に引く決まりと、液体の形を動かすバネ。
final class TimelineLiquidTests: XCTestCase {
    func testShortSlowPullDoesNotSend() {
        XCTAssertFalse(LiquidPull.commits(up: 40, velocity: -100))
        XCTAssertFalse(LiquidPull.commits(up: LiquidPull.commitDistance - 1, velocity: 0))
    }

    func testPullPastPinchSends() {
        XCTAssertTrue(LiquidPull.commits(up: LiquidPull.commitDistance + 1, velocity: 0))
    }

    func testFastFlickSendsEvenWhenShort() {
        XCTAssertTrue(LiquidPull.commits(up: 30, velocity: -900))
        // 下へはじいても送らない。
        XCTAssertFalse(LiquidPull.commits(up: 30, velocity: 900))
    }

    func testDropFollowsFingerThenGetsHeavy() {
        XCTAssertEqual(LiquidPull.travel(up: -20), 0)
        XCTAssertEqual(LiquidPull.travel(up: 100), 90, accuracy: 0.001)
        // 1:1 でついてくる長さを超えると、指の動きの 3 割だけ伸びる。
        let atFollow = LiquidPull.travel(up: LiquidPull.follow)
        XCTAssertEqual(LiquidPull.travel(up: LiquidPull.follow + 100) - atFollow, 30, accuracy: 0.001)
    }

    func testSpringSettlesOnTarget() {
        var spring = LiquidSpring(0)
        spring.aim(100, stiffness: 200, dampingRatio: 0.5)
        var overshot = false
        for _ in 0..<600 {
            spring.step(1.0 / 120)
            if spring.value > 100.5 { overshot = true }
        }
        XCTAssertTrue(overshot, "減衰比が 1 未満なら行き過ぎて揺れる")
        XCTAssertTrue(spring.isSettled)
        XCTAssertEqual(spring.value, 100, accuracy: 0.01)
    }

    func testCriticallyDampedSpringDoesNotOvershoot() {
        var spring = LiquidSpring(0)
        spring.aim(100, stiffness: 300, dampingRatio: 1)
        for _ in 0..<600 {
            spring.step(1.0 / 360)
            XCTAssertLessThanOrEqual(spring.value, 100.5)
        }
    }

    func testNeckThinsAndBreaks() {
        let button = LiquidShape(center: CGPoint(x: 0, y: 0), halfWidth: 36, halfHeight: 36)
        let near = LiquidShape(center: CGPoint(x: 0, y: -60), halfWidth: 14, halfHeight: 14)
        let far = LiquidShape(center: CGPoint(x: 0, y: -36 - TimelineLiquid.neckReach - 1), halfWidth: 14, halfHeight: 14)
        XCTAssertNotNil(TimelineLiquid.neck(from: button, to: near))
        XCTAssertNil(TimelineLiquid.neck(from: button, to: far), "離れきったら、くびれは切れる")
    }

    @MainActor
    func testReleaseDecidesSendAndStartsGrading() {
        let liquid = TimelineLiquid()
        liquid.setSlot(center: CGPoint(x: 300, y: 600), radius: 36)
        liquid.pull(up: 50)
        XCTAssertEqual(liquid.stage, .pulling)
        XCTAssertFalse(liquid.release(up: 50, velocity: 0))
        XCTAssertNotEqual(liquid.stage, .grading)

        liquid.pull(up: 140)
        XCTAssertTrue(liquid.release(up: 140, velocity: 0))
        XCTAssertEqual(liquid.stage, .grading)
        XCTAssertTrue(liquid.hasLanded)
    }

    @MainActor
    func testEmergeHidesMarkUntilLanded() async throws {
        let liquid = TimelineLiquid()
        liquid.reduceMotion = true
        liquid.setSlot(center: CGPoint(x: 300, y: 600), radius: 36)
        liquid.markCenter = CGPoint(x: 60, y: 200)
        liquid.startGrading()
        liquid.emerge(correct: true)
        XCTAssertEqual(liquid.stage, .emerging)
        XCTAssertFalse(liquid.hasLanded)
        for _ in 0..<100 where !liquid.hasLanded {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(liquid.hasLanded)
    }
}

/// 採点中のカプセルをちぎる遊び。
final class TimelineLiquidTearTests: XCTestCase {
    @MainActor
    func testPullingFarTearsOffAPieceAndResultClearsThem() {
        let liquid = TimelineLiquid()
        liquid.setSlot(center: CGPoint(x: 300, y: 600), radius: 36)
        liquid.startGrading()
        // 近くで引いている間は、まだちぎれない。
        liquid.tug(at: CGPoint(x: 300, y: 560))
        XCTAssertEqual(liquid.livePieceCount, 0)
        // 遠くまで引くとちぎれる。離した後も、もう一度引けばまたちぎれる。
        liquid.tug(at: CGPoint(x: 300, y: 400))
        liquid.letGo(velocity: .zero)
        liquid.tug(at: CGPoint(x: 300, y: 560))
        liquid.tug(at: CGPoint(x: 200, y: 420))
        liquid.letGo(velocity: CGSize(width: -300, height: 0))
        XCTAssertEqual(liquid.livePieceCount, 2)
        XCTAssertEqual(liquid.tearFeedback, 2)

        liquid.markCenter = CGPoint(x: 60, y: 200)
        liquid.emerge(correct: true)
        XCTAssertEqual(liquid.livePieceCount, 0, "結果が出たら、かけらは消える")
    }

    @MainActor
    func testTuggingOutsideGradingDoesNothing() {
        let liquid = TimelineLiquid()
        liquid.setSlot(center: CGPoint(x: 300, y: 600), radius: 36)
        liquid.tug(at: CGPoint(x: 300, y: 300))
        XCTAssertEqual(liquid.livePieceCount, 0)
        XCTAssertEqual(liquid.stage, .idle)
    }

    @MainActor
    func testOldPiecesFadeBeyondTheLimit() {
        let liquid = TimelineLiquid()
        liquid.setSlot(center: CGPoint(x: 300, y: 600), radius: 36)
        liquid.startGrading()
        for i in 0..<(TimelineLiquid.maxPieces + 3) {
            liquid.tug(at: CGPoint(x: 300, y: 560))
            liquid.tug(at: CGPoint(x: 100 + Double(i), y: 300))
            liquid.letGo(velocity: .zero)
        }
        XCTAssertLessThanOrEqual(liquid.livePieceCount, TimelineLiquid.maxPieces + 1)
    }
}

/// 質問・撮る・単元のチップを引っぱって開く決まり。
final class TimelinePullOutTests: XCTestCase {
    func testShortSlowPullDoesNotOpen() {
        XCTAssertFalse(TimelinePullRule.opens(progress: 0.2, velocity: 0.5))
        XCTAssertFalse(TimelinePullRule.opens(progress: 0.03, velocity: 5), "触れただけではじいても開かない")
    }

    func testFarOrFastPullOpens() {
        XCTAssertTrue(TimelinePullRule.opens(progress: 0.5, velocity: 0))
        XCTAssertTrue(TimelinePullRule.opens(progress: 0.15, velocity: 2.5))
        XCTAssertFalse(TimelinePullRule.opens(progress: 0.15, velocity: -2.5), "戻す方へはじいたら開かない")
    }

    func testQuestionGoesFromButtonToScreen() {
        let button = CGRect(x: 320, y: 600, width: 52, height: 52)
        let screen = TimelinePullTarget(rect: CGRect(x: 0, y: 62, width: 402, height: 812), cornerRadius: 38, bottomRadius: 55)
        let start = TimelinePullOut.shape(.ask, origin: button, target: screen, t: 0)
        XCTAssertEqual(start.rect, button)
        XCTAssertEqual(start.topRadius, 26, accuracy: 0.001, "始まりはボタンの円")
        let end = TimelinePullOut.shape(.ask, origin: button, target: screen, t: 1)
        XCTAssertEqual(end.rect.minY, 62, accuracy: 0.001)
        XCTAssertEqual(end.rect.width, 402, accuracy: 0.001)
        XCTAssertEqual(end.bottomRadius, 55, accuracy: 0.001)
    }

    func testScopeListDropsDownFromTheChip() {
        let chip = CGRect(x: 20, y: 70, width: 110, height: 40)
        let list = TimelinePullTarget(rect: CGRect(x: 20, y: 70, width: 362, height: 500), cornerRadius: 24)
        for t in [0.2, 0.5, 0.9] {
            let shape = TimelinePullOut.shape(.scope, origin: chip, target: list, t: t)
            XCTAssertEqual(shape.rect.minX, 20, accuracy: 0.001, "左上はチップに留まる")
            XCTAssertEqual(shape.rect.minY, 70, accuracy: 0.001, "左上はチップに留まる")
        }
    }

    func testCameraRunsAlongTheDisplayBottom() {
        let button = CGRect(x: 310, y: 640, width: 72, height: 72)
        let frame = TimelinePullTarget(rect: CGRect(x: 8, y: 306, width: 386, height: 568), cornerRadius: 34, bottomRadius: 47)
        for t in [0.3, 0.6, 1.0] {
            let shape = TimelinePullOut.shape(.camera, origin: button, target: frame, t: t)
            XCTAssertEqual(shape.rect.maxY, 874, accuracy: 0.001, "引き始めてすぐ、下端はディスプレイの下端に付く")
        }
    }

    @MainActor
    func testPhoneTargetsMatchMeasuredScreens() {
        let t = TimelinePullTargets.targets(bounds: CGRect(x: 0, y: 0, width: 402, height: 874), safeTop: 62, isPad: false, displayCorner: 55,
                                            chip: CGRect(x: 96, y: 70, width: 110, height: 40))
        XCTAssertEqual(t[.camera]?.rect.minY ?? 0, 306, accuracy: 1)
        XCTAssertEqual(t[.camera]?.rect.maxY ?? 0, 874, accuracy: 1)
        XCTAssertEqual(t[.ask]?.rect.minY ?? 0, 62, accuracy: 1)
        XCTAssertEqual(t[.scope]?.rect.minX ?? 0, 96, accuracy: 1)
        XCTAssertEqual(t[.scope]?.rect.minY ?? 0, 70, accuracy: 1)
    }
}

/// 引っぱって開く動きが、描く層が無くても止まらないこと(Codex のレビューの指摘)。
final class TimelinePullOutSettleTests: XCTestCase {
    @MainActor
    private func makePullOut() -> TimelinePullOut {
        let pullOut = TimelinePullOut()
        pullOut.origins = [.ask: CGRect(x: 320, y: 600, width: 52, height: 52), .camera: CGRect(x: 310, y: 680, width: 72, height: 72)]
        pullOut.targets = TimelinePullTargets.targets(bounds: CGRect(x: 0, y: 0, width: 402, height: 874), safeTop: 62, isPad: false,
                                                      displayCorner: 55, chip: nil)
        return pullOut
    }

    @MainActor
    func testPeekSettlesEvenWhenNothingDrawsIt() async throws {
        let pullOut = makePullOut()
        pullOut.peek(.ask)
        XCTAssertEqual(pullOut.active, .ask)
        for _ in 0..<150 where pullOut.active != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(pullOut.active, "タップで顔を出した後、戻りきらずに残った")
        pullOut.pull(.camera, translation: CGSize(width: -20, height: -30))
        XCTAssertEqual(pullOut.active, .camera, "質問をタップした後に、撮るを引けない")
    }

    @MainActor
    func testClosingFinishesEvenIfTheButtonDisappears() async throws {
        let pullOut = makePullOut()
        pullOut.open(.ask)
        for _ in 0..<150 where !pullOut.isOpen { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(pullOut.isOpen)
        pullOut.origins[.ask] = nil
        pullOut.close(.ask)
        for _ in 0..<150 where pullOut.active != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(pullOut.active, "ボタンが消えると、閉じきらずに残った")
    }
}

/// 開ききった単元の一覧・質問は、途中の大きさで止まらない(Codex のレビューの指摘)。
final class TimelinePullOutRestTests: XCTestCase {
    @MainActor
    private func openedFrame(reduceMotion: Bool) async throws -> TimelinePullOut.Frame? {
        let pullOut = TimelinePullOut()
        pullOut.reduceMotion = reduceMotion
        pullOut.origins = [.ask: CGRect(x: 320, y: 600, width: 52, height: 52)]
        pullOut.targets = TimelinePullTargets.targets(bounds: CGRect(x: 0, y: 0, width: 402, height: 874), safeTop: 62, isPad: false,
                                                      displayCorner: 55, chip: nil)
        pullOut.open(.ask)
        for _ in 0..<150 where !pullOut.isOpen { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(pullOut.isOpen)
        return pullOut.frame(at: Date())
    }

    @MainActor
    func testOpenRestsAtFullSize() async throws {
        let frame = try await openedFrame(reduceMotion: false)
        XCTAssertEqual(frame?.progress ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(frame?.body.rect.minY ?? 0, 62, accuracy: 0.5)
    }

    @MainActor
    func testOpenWithReduceMotionRestsAtFullSize() async throws {
        let frame = try await openedFrame(reduceMotion: true)
        XCTAssertEqual(frame?.progress ?? 0, 1, accuracy: 0.001)
    }
}
