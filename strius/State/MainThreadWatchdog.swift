#if DEBUG
import Darwin
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
            .onAppear {
                RunLoopModeProbe.start()
                UITestDiagnostics.rootDidAppear()
            }
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

/// UI テストの時だけ(シミュレータの DEBUG で固定データの時)、アプリ側から見た起動の各段階と
/// メインスレッドの止まりを時刻付きでファイルに書く。
///
/// 目的: XCUITest の操作 1 回が十数秒返ってこない場面が、アプリが本当に固まっている(操作する人にも
/// 起きる)のか、XCUITest に要素の木を作らされて止まっているだけなのかを、XCUITest の操作の時刻と
/// 突き合わせて切り分けること。UI テストの `UITestDiagnosticsObserver` がテストごとに読み、
/// xcodebuild のログへ要約を書く。アプリの動作は変えない(別スレッドから 100ms ごとに空の合図を
/// メインへ送り、返るまでの時間を測るだけ)。
///
/// 同じシミュレータで動く UI テストのプロセスも読めるよう、ホストの /tmp にシミュレータごとの
/// ファイルを置く(並列テストの複製ごとに SIMULATOR_UDID が違う)。
enum UITestDiagnostics {
    nonisolated(unsafe) private static var enabled = false
    nonisolated(unsafe) private static var stallMonitorStarted = false
    nonisolated(unsafe) private static var rootAppeared = false
    nonisolated private static let queue = DispatchQueue(label: "com.digiloglab.strius.ui-diagnostics")

    /// 起動時に一度だけ呼ぶ(striusApp.init)。
    static func start() {
        enabled = SimulatorFixtures.isEnabled
        guard enabled else { return }
        launch("init-start")
        discardMirroredSystemLog()
        startStallMonitor()
    }

    /// UI テストの時、XCTest がアプリの中で出すログ(要素の木を作るたびの属性の取得、1 プロセスで数十万行)が
    /// メインスレッドから標準エラーへそのまま書かれていた。Xcode Cloud の結果の束では、アプリの標準出力・
    /// 標準エラーが 1 プロセスあたり 25〜127MB あり(PR Gate 156・159)、要素の確認のたびに、アプリはこの書き込みを
    /// してから返事をしていた。標準エラーだけを捨てる。アプリの動作と判定は変わらない(このファイルの計測は
    /// 別のファイルに書く)。デバッガーで動かしている時と、`STRUIS_STDIO_LOG`・`STRUIS_KEEP_STDERR=1` の時は残す。
    ///
    /// 標準エラーの番号(2)は閉じずに、捨て先へ付け替える(dup2)。freopen は新しい先を開けないと元の番号を
    /// 閉じたままにし、標準エラーへの書き込み(RunLoopModeProbe)が例外で落ちた(PR Gate 162)。/dev/null を
    /// 開けない時は、読んで捨てるだけのパイプにつなぐ。どちらもできなければ何も変えない。
    private static func discardMirroredSystemLog() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["STRUIS_STDIO_LOG"] == nil, environment["STRUIS_KEEP_STDERR"] != "1", !debuggerAttached else { return }
        fflush(stderr)
        let sink: String
        let null = open("/dev/null", O_WRONLY)
        if null >= 0 {
            guard dup2(null, STDERR_FILENO) == STDERR_FILENO else { close(null); return }
            close(null)
            sink = "null"
        } else {
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else { return }
            guard dup2(ends[1], STDERR_FILENO) == STDERR_FILENO else { close(ends[0]); close(ends[1]); return }
            close(ends[1])
            let reader = ends[0]
            let drain = Thread {
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                while read(reader, &buffer, buffer.count) > 0 {}
            }
            drain.qualityOfService = .utility
            drain.start()
            sink = "pipe"
        }
        launch("stderr-discarded-\(sink)-dt-\(environment["OS_ACTIVITY_DT_MODE"] ?? "unset")")
    }

    nonisolated private static var debuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    nonisolated static var logPath: String {
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "default"
        return "/tmp/struis-ui-diagnostics-\(device).log"
    }

    nonisolated static var nowMs: Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    nonisolated static func record(_ line: String) {
        guard enabled else { return }
        let data = Data((line + "\n").utf8)
        let path = logPath
        queue.async {
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }

    /// プロセスが起動した時刻(ミリ秒)。
    nonisolated private static var processStartMs: Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Int64(start.tv_sec) * 1000 + Int64(start.tv_usec) / 1000
    }

    nonisolated static func launch(_ phase: String) {
        guard enabled else { return }
        let now = nowMs
        let since = processStartMs.map { String(now - $0) } ?? "-"
        record("LAUNCH pid=\(getpid()) phase=\(phase) at=\(now) since_exec_ms=\(since)")
    }

    /// ルートの画面が初めて出た時刻と、その後メインの run loop が最初に空いた時刻。
    static func rootDidAppear() {
        guard enabled, !rootAppeared else { return }
        rootAppeared = true
        launch("root-appear")
        DispatchQueue.main.async { UITestDiagnostics.launch("root-idle") }
    }

    nonisolated private static func startStallMonitor() {
        guard !stallMonitorStarted else { return }
        stallMonitorStarted = true
        let thread = Thread {
            while true {
                let sent = UITestDiagnostics.nowMs
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { semaphore.signal() }
                semaphore.wait()
                let answered = UITestDiagnostics.nowMs
                if answered - sent >= 250 {
                    UITestDiagnostics.record("STALL pid=\(getpid()) ms=\(answered - sent) start=\(sent) end=\(answered)")
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
#endif
