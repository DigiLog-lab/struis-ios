// タイムアタック(#133)は延期中。Config/Build.xcconfig の STRUIS_TIME_ATTACK が YES の時だけ本体に入る(App Clip は常に入れる)。
#if STRUIS_TIME_ATTACK
import CryptoKit
import Foundation

/// タイムアタック(#133): 今の分野の一番基礎の5問を紙に上から順に解き、最後に1枚撮るまでの時間を競う。誤答は1問 +10秒。
/// 自前のサーバーは置かない。友達との対戦は、5問・正答・記録を App Clip のリンクに入れて渡す。
/// このフォルダ(`Shared`)は本体と App Clip の両方でコンパイルする。
nonisolated enum TimeAttack {
    static let problemCount = 5
    static let penaltySeconds: Double = 10
    static let nicknameLimit = 10
    /// 1問にかけられる秒数の上限(リンクで受け取る記録の確かめと、時間の書き方の上限)。
    static let maxLapSeconds: Double = 3_600
    /// App Clip で無料で解ける1日のセット数(受け取った人の採点は運営の負担)。
    static let clipDailySets = 3
    /// 読み取りと出題に使うモデル。
    static let model = "claude-haiku-5-5"

    nonisolated struct Problem: Codable, Sendable, Equatable, Hashable {
        /// 問題文(式を含めない日本語の文)。
        var prompt: String
        /// 式(区切りの無い LaTeX)。無ければ空。
        var math: String
        /// 正しい答え(区切りの無い LaTeX)。
        var answerKey: String
        /// プログラムで評価できる答えの式(`TimelineExpression` が読む)。
        var answerExpr: String

        enum CodingKeys: String, CodingKey {
            case prompt = "p", math = "m", answerKey = "k", answerExpr = "e"
        }
    }

    /// 1人分の記録。
    nonisolated struct Entry: Codable, Sendable, Equatable {
        var name: String
        /// 1問ごとにかかった秒数(問題が出てから「次へ」まで。最後の問題は撮るまで)。
        var laps: [Double]
        var correct: [Bool]
        /// 自分で○×をつけた記録(App Clip で写真を送らなかった時)。AI の採点なら nil。
        var selfMarked: Bool?

        enum CodingKeys: String, CodingKey { case name = "n", laps = "l", correct = "c", selfMarked = "s" }

        init(name: String, laps: [Double], correct: [Bool], selfMarked: Bool? = nil) {
            self.name = name
            self.laps = laps
            self.correct = correct
            self.selfMarked = selfMarked
        }

        var solvedSeconds: Double { laps.reduce(0, +) }
        var wrongCount: Int { correct.filter { !$0 }.count }
        var total: Double { solvedSeconds + Double(wrongCount) * TimeAttack.penaltySeconds }

        /// 誤答の10秒を足した、その問題の秒数。
        func seconds(at index: Int) -> Double {
            guard laps.indices.contains(index) else { return 0 }
            return laps[index] + (correct.indices.contains(index) && !correct[index] ? TimeAttack.penaltySeconds : 0)
        }
    }

    /// リンクで渡すもの: 分野・5問・届いた記録(送り返しで増える)。
    nonisolated struct Challenge: Codable, Sendable, Equatable {
        var version: Int = 1
        var field: String
        var problems: [Problem]
        var entries: [Entry]

        enum CodingKeys: String, CodingKey { case version = "v", field = "f", problems = "q", entries = "r" }

        /// 送ってきた人(最後に記録を足した人)。
        var latest: Entry? { entries.last }
    }

    // MARK: - 時間の書き方

    /// `0:51.4` の形。
    static func clock(_ seconds: Double) -> String {
        let bounded = seconds.isFinite ? min(max(0, seconds), maxLapSeconds * Double(problemCount * 2)) : 0
        let tenths = Int((bounded * 10).rounded())
        let minutes = tenths / 600
        let rest = tenths % 600
        return String(format: "%d:%02d.%d", minutes, rest / 10, rest % 10)
    }

    /// `11.2秒` の形。
    static func seconds(_ value: Double) -> String {
        String(format: "%.1f秒", value.isFinite ? min(max(0, value), maxLapSeconds) : 0)
    }

    /// ニックネームを10文字までに切り詰め、前後の空白を落とす。
    static func trimmedName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nicknameLimit))
    }
}

// MARK: - リンク

/// App Clip のリンク。Apple が発行する既定のリンク(appclip.apple.com)に、暗号化した中身を `c` で付ける。
/// 鍵はアプリに埋め込む(公開リポジトリなので、URL を見ただけで正答が分からないようにする程度の隠し方)。
nonisolated enum TimeAttackLink {
    static let host = "appclip.apple.com"
    static let parameter = "c"

    /// App Clip の bundle ID(本体の bundle ID + `.Clip`)。
    static var clipBundleID: String {
        let id = Bundle.main.bundleIdentifier ?? "com.digiloglab.strius"
        return id.hasSuffix(".Clip") ? id : id + ".Clip"
    }

    private static let key = SymmetricKey(data: Data([
        0x53, 0x74, 0x72, 0x75, 0x69, 0x73, 0x2d, 0x54, 0x69, 0x6d, 0x65, 0x41, 0x74, 0x74, 0x61, 0x63,
        0x6b, 0x2d, 0x31, 0x33, 0x33, 0x2d, 0x6c, 0x69, 0x6e, 0x6b, 0x2d, 0x6b, 0x65, 0x79, 0x2d, 0x31,
    ]))

    enum Failure: Error, Equatable { case notALink, unreadable }

    static func url(for challenge: TimeAttack.Challenge, bundleID: String = clipBundleID) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/id"
        components.queryItems = [URLQueryItem(name: "p", value: bundleID), URLQueryItem(name: parameter, value: try encode(challenge))]
        guard let url = components.url else { throw Failure.unreadable }
        return url
    }

    static func encode(_ challenge: TimeAttack.Challenge) throws -> String {
        let json = try JSONEncoder().encode(challenge)
        let packed = try (json as NSData).compressed(using: .zlib) as Data
        let sealed = try AES.GCM.seal(packed, using: key)
        guard let combined = sealed.combined else { throw Failure.unreadable }
        return combined.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ token: String) throws -> TimeAttack.Challenge {
        var base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let combined = Data(base64Encoded: base64) else { throw Failure.unreadable }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let packed = try AES.GCM.open(box, using: key)
            let json = try (packed as NSData).decompressed(using: .zlib) as Data
            let challenge = try JSONDecoder().decode(TimeAttack.Challenge.self, from: json)
            guard isSane(challenge) else { throw Failure.unreadable }
            return challenge
        } catch {
            throw Failure.unreadable
        }
    }

    /// 鍵はアプリに埋め込んであり誰でも中身を作れるので、復号できても値は信じない: 数や長さが決まりの範囲かを確かめる
    /// (範囲外の秒数は、時間の書き方で整数に直す時にアプリを落とす)。
    static func isSane(_ challenge: TimeAttack.Challenge) -> Bool {
        let count = TimeAttack.problemCount
        guard challenge.problems.count == count, challenge.entries.count <= 5, challenge.field.count <= 40 else { return false }
        for problem in challenge.problems {
            guard problem.prompt.count <= 400, problem.math.count <= 400, problem.answerKey.count <= 200, problem.answerExpr.count <= 200 else { return false }
        }
        for entry in challenge.entries {
            guard entry.name.count <= TimeAttack.nicknameLimit, entry.laps.count == count, entry.correct.count == count,
                  entry.laps.allSatisfy({ $0.isFinite && (0...TimeAttack.maxLapSeconds).contains($0) }) else { return false }
        }
        return true
    }

    /// 開かれたリンクから中身を読む(タイムアタックのリンクでなければ `notALink`)。
    static func challenge(from url: URL) throws -> TimeAttack.Challenge {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == parameter })?.value, !token.isEmpty else {
            throw Failure.notALink
        }
        return try decode(token)
    }
}

// MARK: - 端末に残すもの

/// ニックネーム・自己ベスト・App Clip の1日の回数。サーバーには送らない。
nonisolated struct TimeAttackLocal: @unchecked Sendable {
    var defaults: UserDefaults = .standard

    private static let nameKey = "timeattack.nickname"
    private static let bestKey = "timeattack.best"
    private static let clipConsentKey = "timeattack.clip.consent"
    private static let clipDayKey = "timeattack.clip.day"
    private static let clipCountKey = "timeattack.clip.count"

    var nickname: String {
        get { defaults.string(forKey: Self.nameKey) ?? "" }
        nonmutating set { defaults.set(TimeAttack.trimmedName(newValue), forKey: Self.nameKey) }
    }

    /// その分野の自己ベスト(合計秒)。
    func best(field: String) -> Double? {
        (defaults.dictionary(forKey: Self.bestKey) as? [String: Double])?[field]
    }

    /// 記録を残し、前のベスト(あれば)を返す。
    @discardableResult
    func record(total: Double, field: String) -> Double? {
        var bests = (defaults.dictionary(forKey: Self.bestKey) as? [String: Double]) ?? [:]
        let previous = bests[field]
        if previous.map({ total < $0 }) ?? true { bests[field] = total }
        defaults.set(bests, forKey: Self.bestKey)
        return previous
    }

    // App Clip の同意(#133): 今の規約の版に同意し、年齢の確認で16歳以上と分かった時だけ、答案の写真を AI に送る。
    // 16歳未満・年齢を共有しなかった・同意しなかった時は、写真を送らず自分で○×をつける。

    nonisolated enum ClipGrading: String, Codable, Sendable { case ai, selfCheck }

    nonisolated struct ClipConsent: Codable, Sendable, Equatable {
        var termsVersion: String
        var grading: ClipGrading
        var decidedAt: Date
    }

    /// 今の規約の版で決めた採点の仕方(まだ決めていない・規約が新しくなった時は nil)。
    func clipGrading(termsVersion: String) -> ClipGrading? {
        guard let data = defaults.data(forKey: Self.clipConsentKey),
              let consent = try? JSONDecoder().decode(ClipConsent.self, from: data), consent.termsVersion == termsVersion else { return nil }
        return consent.grading
    }

    func recordClipGrading(_ grading: ClipGrading, termsVersion: String, at date: Date = Date()) {
        if let data = try? JSONEncoder().encode(ClipConsent(termsVersion: termsVersion, grading: grading, decidedAt: date)) {
            defaults.set(data, forKey: Self.clipConsentKey)
        }
    }

    /// 年齢の区分から採点の仕方を決める: 16歳以上(16〜17歳・18歳以上)だけ AI。
    static func clipGrading(for band: AgeBand?) -> ClipGrading {
        switch band {
        case .under18, .adult: .ai
        case .under16, nil: .selfCheck
        }
    }

    // App Clip の無料の回数(端末の日付で数える。App Clip のデータは iOS に消されることがあるので厳密な上限ではない)。

    func clipSetsLeft(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let today = Self.day(now, calendar: calendar)
        let used = defaults.string(forKey: Self.clipDayKey) == today ? defaults.integer(forKey: Self.clipCountKey) : 0
        return max(0, TimeAttack.clipDailySets - used)
    }

    func useClipSet(now: Date = Date(), calendar: Calendar = .current) {
        let today = Self.day(now, calendar: calendar)
        let used = defaults.string(forKey: Self.clipDayKey) == today ? defaults.integer(forKey: Self.clipCountKey) : 0
        defaults.set(today, forKey: Self.clipDayKey)
        defaults.set(used + 1, forKey: Self.clipCountKey)
    }

    private static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
#endif
