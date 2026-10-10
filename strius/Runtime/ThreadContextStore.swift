import CryptoKit
import Foundation
import OSLog

nonisolated private let contextStoreLog = Logger(subsystem: "com.digiloglab.strius", category: "thread-context")

/// Codex のスレッドに何を渡し済みかの控え(信頼性計画 P1)。
///
/// Codex の rollout(スレッドの履歴)はアプリ内の Codex home にあり、台帳の書き出しには入らない。
/// この控えも同じく Codex 側の状態の写しなので、Codex home の隣に置く(台帳には入れない)。
/// - `developer`: そのスレッドの履歴に入っている developer 指示のハッシュ。版が変わった時だけ渡し直す。
/// - `memory`: 直近のターンの入力に載せた記憶の根拠のハッシュ。変わらなければ次のターンでは載せない。
/// - `notices`: 次のターンの前にスレッドへ入れる Struis からの注記(期限で止めた、など)。
nonisolated final class ThreadContextStore: @unchecked Sendable {
    static let shared = ThreadContextStore(url: HyotanBoot.root.appendingPathComponent("thread-context.json"))

    nonisolated struct Entry: Codable, Equatable, Sendable {
        var developer: String?
        var memory: String?
        var notices: [String]?
        var updatedAt: Date?
    }

    private let url: URL?
    private let lock = NSLock()
    private var entries: [String: Entry]
    /// 古い控えは捨てる(終わった単元の会話などが溜まり続けないように)。
    static let limit = 400

    /// `url` が nil なら書き出さない(テスト)。
    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func remove(_ ids: Set<String>) {
        let snapshot = lock.withLock {
            for id in ids { entries[id] = nil }
            // Every existing conversation must receive the changed memory on its next turn.
            for id in entries.keys { entries[id]?.memory = nil }
            return entries
        }
        persist(snapshot)
    }

    func entry(_ threadID: String) -> Entry? {
        lock.withLock { entries[threadID] }
    }

    func update(_ threadID: String, _ change: (inout Entry) -> Void) {
        let snapshot: [String: Entry] = lock.withLock {
            var entry = entries[threadID] ?? Entry()
            change(&entry)
            entry.updatedAt = Date()
            entries[threadID] = entry
            if entries.count > Self.limit {
                let oldest = entries.sorted { ($0.value.updatedAt ?? .distantPast) < ($1.value.updatedAt ?? .distantPast) }
                for (key, _) in oldest.prefix(entries.count - Self.limit) { entries[key] = nil }
            }
            return entries
        }
        persist(snapshot)
    }

    /// 次のターンの前に入れる注記を取り出す(取り出したら消える。入れられなかったら `addNotice` で戻す)。
    func takeNotices(_ threadID: String) -> [String] {
        var taken: [String] = []
        update(threadID) { entry in
            taken = entry.notices ?? []
            entry.notices = nil
        }
        return taken
    }

    func addNotice(_ threadID: String, _ notice: String) {
        update(threadID) { entry in
            var notices = entry.notices ?? []
            if !notices.contains(notice) { notices.append(notice) }
            entry.notices = Array(notices.suffix(4))
        }
    }

    private func persist(_ snapshot: [String: Entry]) {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {
            contextStoreLog.error("thread context store not saved: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated static func hash(_ parts: String...) -> String {
        var hasher = SHA256()
        for part in parts {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
