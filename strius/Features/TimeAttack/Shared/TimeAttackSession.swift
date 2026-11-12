// タイムアタック(#133)は延期中。Config/Build.xcconfig の STRUIS_TIME_ATTACK が YES の時だけ本体に入る(App Clip は常に入れる)。
#if STRUIS_TIME_ATTACK
import Foundation
import Observation

/// タイムアタック1回分の流れ: 5問をそろえる → 解く → 写真を読んで採点 → 結果。本体と App Clip で同じものを使う。
@MainActor
@Observable
final class TimeAttackSession: Identifiable {
    enum Mode: Equatable {
        /// 自分で始める(本体): 今の分野の5問を作る。
        case own(unitTitle: String, context: String)
        /// 届いたリンクから解く(本体・App Clip)。
        case challenge(TimeAttack.Challenge)
    }

    enum Phase: Equatable {
        case preparing
        /// 始める前(届いた記録とルール)。
        case intro
        case running
        case grading
        /// 正答を見て本人が○×をつける。
        case selfCheck
        case result
        case failed(String)
    }

    let mode: Mode
    let transport: any TimeAttackTransport
    let local: TimeAttackLocal
    /// 採点を始める時に呼ぶ(App Clip の1日の回数を数える)。
    var onGradingStarted: () -> Void = {}
    /// 届いた5問を解き始める前に、採点まで頼めるかを確かめる(頼めない時はその理由)。
    /// 解き終えてから採点を断られないように、タイマーを動かす前に止める。
    var preflight: () -> String? = { nil }

    /// 採点のしかた。AI は写真を Anthropic に送って読む。自分で採点する時は写真を撮らず、正答を見て本人が○×をつける
    /// (App Clip で、16歳未満・年齢を共有しなかった・送ることに同意しなかった人と、その日の無料の分を使い切った人)。
    var grading: TimeAttackLocal.ClipGrading = .ai
    private(set) var phase: Phase = .preparing
    private(set) var field = ""
    private(set) var problems: [TimeAttack.Problem] = []
    private(set) var mine: TimeAttack.Entry?
    /// この記録の前の自己ベスト(初めてなら nil)。
    private(set) var previousBest: Double?
    private var laps: [Double] = []
    private var photo: Data?

    init(mode: Mode, transport: any TimeAttackTransport, local: TimeAttackLocal = TimeAttackLocal()) {
        self.mode = mode
        self.transport = transport
        self.local = local
        if case .challenge(let challenge) = mode {
            field = challenge.field
            problems = challenge.problems
            phase = .intro
        }
    }

    /// 写真を撮った後か(失敗した時に、読み取りをやり直すか、作り直すかを分ける)。
    var hasPhoto: Bool { photo != nil }

    /// 届いた記録(自分で始めた時は nil)。
    var rival: TimeAttack.Entry? {
        if case .challenge(let challenge) = mode { return challenge.latest }
        return nil
    }

    func prepare() async {
        guard case .own(let unitTitle, let context) = mode else { return }
        phase = .preparing
        do {
            let made = try await TimeAttackClaude.generate(unitTitle: unitTitle, context: context, transport: transport)
            field = made.field
            problems = made.problems
            phase = .running
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    func start() {
        if let reason = preflight() {
            phase = .failed(reason)
            return
        }
        phase = .running
    }

    /// 解き終えた。AI で採点する時は写真を読んでから、自分で採点する時は○×をつけてから結果に移る。
    func finish(laps: [Double], photo: Data?) async {
        self.laps = laps
        guard grading == .ai, let photo else {
            self.photo = nil
            phase = .selfCheck
            return
        }
        self.photo = photo
        await grade()
    }

    /// 本人がつけた○×で記録を決める。
    func submitSelfCheck(_ correct: [Bool]) {
        guard phase == .selfCheck, correct.count == problems.count else { return }
        record(correct)
    }

    private func record(_ correct: [Bool]) {
        let entry = TimeAttack.Entry(name: local.nickname, laps: laps, correct: correct, selfMarked: grading == .selfCheck ? true : nil)
        mine = entry
        previousBest = local.record(total: entry.total, field: field)
        phase = .result
    }

    func retryGrading() async {
        guard photo != nil else { return }
        await grade()
    }

    private func grade() async {
        guard let photo else { return }
        phase = .grading
        onGradingStarted()
        do {
            let correct = try await TimeAttackClaude.grade(problems: problems, photo: photo, transport: transport)
            record(correct)
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    /// 送るリンク。自分で始めた時は自分の記録だけ、届いたリンクなら届いた記録に自分の記録を足す。
    func shareURL(name: String) throws -> URL {
        let trimmed = TimeAttack.trimmedName(name)
        local.nickname = trimmed
        guard var entry = mine else { throw TimeAttackLink.Failure.unreadable }
        entry.name = trimmed
        mine = entry
        var entries: [TimeAttack.Entry] = []
        if case .challenge(let challenge) = mode { entries = challenge.entries }
        // 送り返しが続いても、リンクに載せる記録は直近の5人まで。
        entries = Array((entries + [entry]).suffix(5))
        return try TimeAttackLink.url(for: TimeAttack.Challenge(field: field, problems: problems, entries: entries))
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
#endif
