import Foundation
import XCTest

/// テストごとに、アプリが書いた起動の各段階とメインスレッドの止まり(アプリ側の `UITestDiagnostics`)を
/// 読み、xcodebuild のログへ要約を書く。テストの操作・判定・待ち時間には一切触れない(読むだけ)。
///
/// テストバンドルの主クラス(Info.plist の NSPrincipalClass)として、テストの前に XCTest が作る。
/// ログの `t=` はテストの開始からの秒で、XCUITest の操作の記録(`t = 12.34s Checking …`)と同じ物差し。
@objc(UITestDiagnosticsObserver)
final class UITestDiagnosticsObserver: NSObject, XCTestObservation {
    private var startedAt: [String: Int64] = [:]

    override init() {
        super.init()
        try? FileManager.default.removeItem(atPath: Self.logPath)
        MainActor.assumeIsolated {
            XCTestObservationCenter.shared.addTestObserver(self)
        }
    }

    /// アプリの `UITestDiagnostics.logPath` と同じ場所(同じシミュレータなら SIMULATOR_UDID が同じ)。
    static var logPath: String {
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "default"
        return "/tmp/struis-ui-diagnostics-\(device).log"
    }

    private static var nowMs: Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    func testCaseWillStart(_ testCase: XCTestCase) {
        startedAt[testCase.name] = Self.nowMs
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        guard let start = startedAt.removeValue(forKey: testCase.name) else { return }
        let end = Self.nowMs
        let name = testCase.name.trimmingCharacters(in: CharacterSet(charactersIn: "-[]"))
            .replacingOccurrences(of: " ", with: "/")
        let lines = ((try? String(contentsOfFile: Self.logPath, encoding: .utf8)) ?? "").split(separator: "\n")
        var launches: [String] = []
        var stalls: [(start: Int64, ms: Int64)] = []
        for line in lines {
            let fields = Self.fields(line)
            if line.hasPrefix("LAUNCH "), let at = fields["at"].flatMap({ Int64($0) }), at >= start, at <= end {
                let offset = String(format: "%.2f", Double(at - start) / 1000)
                launches.append("\(fields["phase"] ?? "?")@t=\(offset)s(exec+\(fields["since_exec_ms"] ?? "-")ms)")
            } else if line.hasPrefix("STALL "), let from = fields["start"].flatMap({ Int64($0) }),
                      let ms = fields["ms"].flatMap({ Int64($0) }), from >= start, from <= end {
                stalls.append((from, ms))
            }
        }
        let longest = stalls.map { $0.ms }.max() ?? 0
        let total = stalls.map { $0.ms }.reduce(0, +)
        print("UI_DIAGNOSTICS test=\(name) max_stall_ms=\(longest) stalls_over_1s=\(stalls.filter { $0.ms >= 1000 }.count) "
              + "stall_total_ms=\(total) launch=\(launches.joined(separator: ","))")
        for stall in stalls where stall.ms >= 1000 {
            print("UI_DIAGNOSTICS_STALL test=\(name) t=\(String(format: "%.2f", Double(stall.start - start) / 1000))s ms=\(stall.ms)")
        }
    }

    private static func fields(_ line: Substring) -> [String: String] {
        var result: [String: String] = [:]
        for part in line.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        return result
    }
}
