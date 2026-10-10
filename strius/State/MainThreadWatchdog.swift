#if DEBUG
import Foundation
import SwiftUI
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

struct MainThreadWatchdogProbe: View {
    @State private var watchdog = MainThreadWatchdog.shared

    var body: some View {
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
