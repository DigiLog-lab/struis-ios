import XCTest

/// Verify the mode before spending time on UI actions. No app is launched.
final class CIBenchmarkModeUITests: XCTestCase {
    func testBaselineVariantInjection() throws {
        let value = ProcessInfo.processInfo.environment["STRUIS_CI_BENCH_VARIANT"]
        XCTAssertEqual(value, "baseline")
    }

    func testOptimizedVariantInjection() throws {
        let value = ProcessInfo.processInfo.environment["STRUIS_CI_BENCH_VARIANT"]
        XCTAssertEqual(value, "optimized")
    }
}

