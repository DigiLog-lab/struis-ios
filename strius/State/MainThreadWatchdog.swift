#if DEBUG
import Foundation
import SwiftUI
import UIKit
import OSLog

private let watchdogLog = Logger(subsystem: "com.digiloglab.strius", category: "hang-watchdog")

/// DEBUG の `-hang-watchdog` 起動引数でだけ動く、メインスレッドの止まりの記録(E2E H2 の検証用)。
/// 別スレッドから 100ms ごとにメインへ合図を送り、返ってくるまでの最長時間を覚える。UI テストは
/// `debug-hang-watchdog` の value(ミリ秒)を読む。XCUITest のツリー取得の遅さに左右されない。
@Observable
@MainActor
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-hang-watchdog") }

    private(set) var maxStallMs = 0
    private var started = false

    /// 計測の始まりを揃える(画面を開くまでの止まりを数えない)。
    func reset() { maxStallMs = 0 }

    func start() {
        guard Self.isEnabled, !started else { return }
        started = true
        let thread = Thread { [weak self] in
            while true {
                let sent = Date()
                let semaphore = DispatchSemaphore(value: 0)
                var stall = 0
                DispatchQueue.main.async {
                    stall = Int(Date().timeIntervalSince(sent) * 1000)
                    semaphore.signal()
                }
                semaphore.wait()
                let measured = stall
                if measured > 300 { watchdogLog.error("main thread stall \(measured, privacy: .public) ms") }
                if measured > 50 {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if measured > self.maxStallMs { self.maxStallMs = measured }
                    }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}

/// UI テストで XCUITest の「アプリが落ち着いた」合図(event loop idle)が 60 秒来ず、アプリは暇なまま操作ごとに
/// 60 秒待たされてテストが時間切れになる件の調査用(Simulator の DEBUG で固定データの時だけ)。
/// 1 秒ごとにメインの run loop の今のモードと、指で追っている・慣性で動いているスクロールの数を調べ、
/// default 以外のモードやスクロールの追跡・慣性が 3 秒以上続いている時だけ標準エラーに `RUNLOOP_PROBE` を書く
/// (XCUITest はアプリの標準エラーを xcresult に残す)。モードが UITracking のまま止まっていれば、
/// XCUITest の合図の要求がメインで処理されない(アプリ側の原因)ことが分かる。
enum RunLoopModeProbe {
    private static var started = false

    @MainActor static func start() {
        guard SimulatorFixtures.isEnabled, !started else { return }
        started = true
        let thread = Thread {
            var anomalySince: Date?
            var lastReport = ""
            while true {
                Thread.sleep(forTimeInterval: 1)
                let sent = Date()
                let semaphore = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var report = ""
                DispatchQueue.main.async {
                    let mode = RunLoop.main.currentMode?.rawValue ?? "none"
                    // 慣性のスクロールは default のモードでも続くので、モードに関係なく数える。
                    let busy = MainActor.assumeIsolated { RunLoopModeProbe.movingScrollViews() }
                    if mode != RunLoop.Mode.default.rawValue || busy > 0 {
                        report = "mode=\(mode) moving_scroll_views=\(busy)"
                    }
                    semaphore.signal()
                }
                // メインが 1 回だけ 0.5〜5 秒止まった時は、止まっていた長さがそのまま分かるので、すぐ書く。
                let answered = semaphore.wait(timeout: .now() + 5)
                let delayMs = Int(Date().timeIntervalSince(sent) * 1000)
                if answered == .success, delayMs > 500 {
                    FileHandle.standardError.write(Data("RUNLOOP_PROBE main thread answered after \(delayMs) ms\n".utf8))
                }
                if answered == .timedOut {
                    FileHandle.standardError.write(Data("RUNLOOP_PROBE main thread did not answer within 5 s\n".utf8))
                    semaphore.wait()
                    continue
                }
                if report.isEmpty {
                    if let since = anomalySince, !lastReport.isEmpty {
                        let seconds = Int(Date().timeIntervalSince(since))
                        FileHandle.standardError.write(Data("RUNLOOP_PROBE back to default after \(seconds) s\n".utf8))
                    }
                    anomalySince = nil
                    lastReport = ""
                    continue
                }
                let since = anomalySince ?? Date()
                anomalySince = since
                let seconds = Int(Date().timeIntervalSince(since))
                // ふつうのスクロール(1〜2 秒の慣性)は書かない。3 秒以上続いたら、状態が変わった時と 10 秒ごとに書く。
                if seconds >= 3, report != lastReport || seconds % 10 == 0 {
                    FileHandle.standardError.write(Data("RUNLOOP_PROBE \(report) for_s=\(seconds)\n".utf8))
                    lastReport = report
                }
            }
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    /// 指で追っている・ドラッグ中・慣性で動いているスクロールの数。
    @MainActor private static func movingScrollViews() -> Int {
        var count = 0
        func visit(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.isTracking || scroll.isDragging || scroll.isDecelerating { count += 1 }
            view.subviews.forEach(visit)
        }
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] { visit(window) }
        }
        return count
    }
}

struct MainThreadWatchdogProbe: View {
    @State private var watchdog = MainThreadWatchdog.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { RunLoopModeProbe.start() }
        if MainThreadWatchdog.isEnabled {
            Button("reset") { watchdog.reset() }
                .font(.system(size: 8))
                .frame(width: 24, height: 24)
                .opacity(0.02)
                .accessibilityIdentifier("debug-hang-watchdog-reset")
            Text(String(watchdog.maxStallMs))
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("debug-hang-watchdog")
                .accessibilityValue(String(watchdog.maxStallMs))
                .onAppear { watchdog.start() }
                .allowsHitTesting(false)
        }
    }
}
#endif
