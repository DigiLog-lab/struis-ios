import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

nonisolated private let clockLog = Logger(subsystem: "com.digiloglab.strius", category: "turn-clock")

/// 止まっていた時間を数えない時計(信頼性計画 P4-3、E2)。
///
/// `Date()` や `ContinuousClock` は、アプリが裏で止められていた間も進む。そのため裏から戻った瞬間に
/// ターンの期限や要求の時間切れが一斉に来ていた。この時計はアプリが前面にいた時間だけを数える:
/// `systemUptime`(端末が眠っている間は進まない)から、裏に回ってから戻るまで(iOS がアプリを止めうる間)を除く。
/// 心拍の間隔で止まっていたかを推し量る方式は、負荷が高く心拍が遅れると時計まで止まり、期限が効かなかった
/// (2026-10-03 の E2E で 83 分)。前面にいる間は、どれだけ遅くても実時間どおり進む。
nonisolated final class ActiveClock: @unchecked Sendable {
    static let shared: ActiveClock = {
        let clock = ActiveClock()
        clock.followApplicationLifecycle()
        return clock
    }()

    private let lock = NSLock()
    private let uptime: @Sendable () -> TimeInterval
    /// 裏にいた時間の合計と、いま裏にいるなら入った時刻。
    private var paused: TimeInterval = 0
    private var pausedSince: TimeInterval?
    private var observers: [NSObjectProtocol] = []

    /// `uptime` is replaced only by tests.
    init(uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// 前面にいた秒数(任意の起点から)。
    var now: TimeInterval {
        lock.withLock {
            let current = uptime()
            return current - paused - (pausedSince.map { current - $0 } ?? 0)
        }
    }

    /// 裏にいた時間の合計(記録用)。
    var skippedSeconds: TimeInterval {
        lock.withLock { paused + (pausedSince.map { uptime() - $0 } ?? 0) }
    }

    /// アプリが裏に回った(ここから戻るまでは数えない)。
    func pause() {
        lock.withLock { if pausedSince == nil { pausedSince = uptime() } }
    }

    /// アプリが前面に戻った。
    func resume() {
        let skipped: TimeInterval? = lock.withLock {
            guard let since = pausedSince else { return nil }
            let gap = uptime() - since
            paused += gap
            pausedSince = nil
            return gap
        }
        if let skipped, skipped > 1 { clockLog.info("not counting \(Int(skipped), privacy: .public)s in the background") }
    }

    private func followApplicationLifecycle() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in self?.pause() },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in self?.resume() },
        ]
        #endif
    }

    /// 動いていた時間で `duration` だけ待つ。途中で止められていた分は待ち足す。
    func sleep(for duration: Duration) async throws {
        let target = now + duration.timeInterval
        while true {
            let remaining = target - now
            guard remaining > 0 else { return }
            try await Task.sleep(for: .seconds(min(remaining, 30)))
        }
    }
}

/// ターンの期限(信頼性計画 P4-3)。`turn/start` を送った時を起点にし、同じプランのやり直しにも引き継ぐ
/// (どの経路でも期限が効く。C14 では turn/start の応答待ちとやり直しで 600 秒を超えた)。
nonisolated final class TurnDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: ActiveClock
    private let limit: TimeInterval
    private var startedAt: TimeInterval?

    init(limitSeconds: Int, clock: ActiveClock = .shared) {
        self.limit = TimeInterval(limitSeconds)
        self.clock = clock
    }

    /// `turn/start` を送る直前に呼ぶ。最初の 1 回だけ起点を決める。
    func start() {
        lock.withLock { if startedAt == nil { startedAt = clock.now } }
    }

    var hasStarted: Bool { lock.withLock { startedAt != nil } }

    /// 残りの秒数(まだ始まっていなければ全体)。
    var remaining: TimeInterval {
        let started = lock.withLock { startedAt }
        guard let started else { return limit }
        return limit - (clock.now - started)
    }

    var limitSeconds: Int { Int(limit) }
}

extension Duration {
    nonisolated var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// 裏に回ってもターンを続けるための iOS のバックグラウンド実行(信頼性計画 P4-5、H1)。
/// ターンが 1 つでも走っている間だけ `beginBackgroundTask` を持つ。時間切れの前に必ず返す。
///
/// 走っているターンの数は呼んだその場でロックの中で数える。iOS への開始・終了は、メインで
/// 「今の数に合わせる」だけにする。開始と終了の届く順が入れ替わっても、最後の合わせ込みが
/// 最新の数を見るので、ターンが終わった後に持ちっぱなしにならない。
nonisolated final class BackgroundTurnActivity: @unchecked Sendable {
    static let shared = BackgroundTurnActivity()

    private let lock = NSLock()
    private var running = 0
    #if canImport(UIKit)
    @MainActor private var task: UIBackgroundTaskIdentifier = .invalid
    #endif

    static func begin() { shared.change(by: 1) }

    static func end() { shared.change(by: -1) }

    /// 走っているターンの数(テスト用)。
    var runningCount: Int { lock.withLock { running } }

    private func change(by delta: Int) {
        lock.withLock { running = max(0, running + delta) }
        Task { @MainActor in self.reconcile() }
    }

    @MainActor private func reconcile() {
        #if canImport(UIKit)
        let count = runningCount
        if count > 0, task == .invalid {
            task = UIApplication.shared.beginBackgroundTask(withName: "struis-turn") { [weak self] in
                // 時間切れ: iOS に返す(返さないとアプリごと終了される)。ターンは戻った時に入り直す。
                clockLog.info("background time expired with \(self?.runningCount ?? 0, privacy: .public) turns running")
                self?.release()
            }
        } else if count == 0 {
            release()
        }
        #endif
    }

    @MainActor private func release() {
        #if canImport(UIKit)
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
        #endif
    }
}

/// ターンがどの段階まで進んだか(`startup` / `runtime_ready` / `thread_configured` / `turn_started` / `first_event`)。
/// 返らなかったターンがどこで待っていたかを台帳に残すため、ターンを走らせる側が `@TaskLocal` の受け口を置く。
nonisolated enum TurnStage {
    @TaskLocal static var sink: (@Sendable (String) -> Void)?

    static func report(_ stage: String) { sink?(stage) }
}

/// 先に終わった方の結果を 1 回だけ受け取る(ターンと時間切れの競争)。
nonisolated final class TurnRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    func finish(_ result: Value) {
        let waiting: CheckedContinuation<Value, Never>? = lock.withLock {
            guard value == nil else { return nil }
            value = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: result)
    }

    var result: Value {
        get async {
            await withCheckedContinuation { continuation in
                let ready: Value? = lock.withLock {
                    if let value { return value }
                    self.continuation = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}
