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
