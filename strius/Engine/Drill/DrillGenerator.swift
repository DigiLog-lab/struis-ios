import Foundation

/// 種を外から渡せる乱数(SplitMix64)。同じ種からは同じ並びが出るので、テストで結果を固定できる。
nonisolated struct DrillSeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z: UInt64 = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 生成器。条件を満たす変数の組を乱数で選んで、問題文と答えを作る。AI も通信も使わない。
nonisolated struct DrillGenerator: Sendable {
    /// 条件を満たす組が出るまで選び直す回数の上限。点検器が「満たす組の割合」を確かめているので、普通はすぐ見つかる。
    static let maxDraws: Int = 4000

    let compiled: DrillCompiledTemplate

    init(compiled: DrillCompiledTemplate) {
        self.compiled = compiled
    }

    init(template: DrillTemplate) throws {
        self.compiled = try DrillCompiledTemplate(template)
    }

    /// 変数の値の組を 1 つ、乱数で選ぶ。
    func draw<G: RandomNumberGenerator>(using generator: inout G) -> [DrillValue] {
        compiled.variables.map { (variable: DrillCompiledTemplate.Variable) -> DrillValue in
            variable.domain[Int.random(in: 0..<variable.domain.count, using: &generator)]
        }
    }

    /// 次の 1 問。`previous`(直前に出した問題)と同じ問題は避ける。
    func next<G: RandomNumberGenerator>(using generator: inout G, avoiding previous: DrillProblem? = nil) throws -> DrillProblem {
        var repeated: DrillProblem? = nil
        for _ in 0..<DrillGenerator.maxDraws {
            // 値が定まらない組は選び直す(点検で見つけきれなかった組があっても、出題は止めない)。
            guard let instance: DrillCompiledTemplate.Instance = try? compiled.instance(values: draw(using: &generator)) else { continue }
            if let previous: DrillProblem = previous, instance.problem.key == previous.key {
                repeated = instance.problem
                continue
            }
            return instance.problem
        }
        // 1 通りしか作れない型でも、出題は止めない。
        if let repeated: DrillProblem = repeated { return repeated }
        throw DrillFailure(message: "条件を満たす変数の組が見つかりませんでした")
    }
}
