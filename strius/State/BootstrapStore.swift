import Foundation
import OSLog

private let bootstrapLog = Logger(subsystem: "com.digiloglab.strius", category: "bootstrap")

/// Single-source bootstrap state shared between Chat and Settings tabs.
/// Mirrors the Web PWA's `useAppShell().bootstrap` payload — only the fields
/// that are actually consumed by Chat or Settings are surfaced here.
@Observable
@MainActor
final class BootstrapStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle
    private(set) var user: BootstrapResponse.User?
    private(set) var threads: [ThreadSummary] = []

    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private let fixtureOverride: Bool?
    private let client: APIClient
    private let ledger: Ledger?

    init(client: APIClient, ledger: Ledger? = nil, useFixtures: Bool? = nil) {
        fixtureOverride = useFixtures
        self.client = client
        self.ledger = ledger
    }

    /// 会話一覧は台帳から読む (design §4.2 `threads`)。
    func refreshThreads() async {
        guard let ledger else { return }
        let rows = (try? await ledger.read { db in try ChatRepository.threads(db) }) ?? []
        // 「質問」は自由質問の会話だけ。小単元・単元づくりの会話はそれぞれの画面から開く
        // (混ざると自由質問や添付が教える会話の文脈に入る)。単元づくりの会話は source=user のまま
        // (過去の会話の文脈には使う)なので、作る時の題名と作りかけの記録で見分ける。
        // 自由質問の中でモデルが単元の提案を出しても、その会話は自由質問のまま一覧に残す。
        let pendingUnitCreation = UserDefaults.standard.string(forKey: OnboardingProfile.unitCreationThreadKey)
        let questions = rows.filter {
            $0.source != "branch" && $0.source != "subunit"
                && $0.title != TurnCoordinator.unitCreationThreadTitle && $0.id != pendingUnitCreation
        }
        let visible = Self.visibleThreads(questions.map(ChatRepository.summary))
        if threads != visible { threads = visible }
    }

    func reset() {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        user = nil
        threads = []
        loadState = .idle
    }

    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        let generation = generation
        let task = Task { await performRefresh(generation: generation) }
        refreshTask = task
        await task.value
        if self.generation == generation { refreshTask = nil }
    }

    private func performRefresh(generation: UUID) async {
        if !Auth0Config.authenticationRequired {
            await refreshThreads()
            guard self.generation == generation else { return }
            user = nil
            loadState = .loaded
            return
        }

        if usesSimulatorFixtures {
            user = BootstrapResponse.User(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                displayName: "Tomo",
                email: "simulator@struis.local"
            )
            await refreshThreads()
            loadState = .loaded
            return
        }

        if user == nil { loadState = .loading }
        do {
            let response: BootstrapResponse = try await client.send(.bootstrap)
            guard self.generation == generation, !Task.isCancelled else { return }
            user = response.user
            await refreshThreads()
            loadState = .loaded
        } catch {
            guard self.generation == generation, !Task.isCancelled else { return }
            bootstrapLog.error("bootstrap failed: \(String(describing: error))")
            if user == nil { loadState = .failed(Self.message(for: error)) }
        }
    }

    private static func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized: return "もう一度ログインしてください"
            case .transport: return "ネットワークに接続できません"
            case .server(let status, _): return "サーバーエラー (\(status))"
            case .decoding, .invalidResponse: return "サーバー応答の解釈に失敗しました"
            }
        }
        return error.localizedDescription
    }

    private func loadThreadHistory(fallback: [ThreadSummary]) async throws -> [ThreadSummary] {
        do {
            let fullHistory: [ThreadSummary] = try await client.send(.listThreads)
            return Self.visibleThreads(fullHistory)
        } catch {
            bootstrapLog.error("thread history refresh failed: \(String(describing: error))")
            return Self.visibleThreads(fallback)
        }
    }

    private static func visibleThreads(_ items: [ThreadSummary]) -> [ThreadSummary] {
        items
            .filter { !isInternalThreadSource($0.source) }
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastMessageAt ?? lhs.createdAt ?? .distantPast
                let rhsDate = rhs.lastMessageAt ?? rhs.createdAt ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    private static func isInternalThreadSource(_ source: String?) -> Bool {
        guard let normalized = source?
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty
        else {
            return false
        }
        return ["codex-qa", "internal-auth", "smoke", "web-bypass"].contains(normalized)
    }

    private static var simulatorThreads: [ThreadSummary] {
        [
            ThreadSummary(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                title: "二次関数の頂点",
                source: "simulator",
                latestPreview: "平方完成の途中式を確認しました。",
                lastMessageAt: Date().addingTimeInterval(-60 * 18),
                createdAt: Date().addingTimeInterval(-60 * 40)
            ),
            ThreadSummary(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                title: "英作文の言い換え",
                source: "simulator",
                latestPreview: "because以外の理由表現を整理しました。",
                lastMessageAt: Date().addingTimeInterval(-60 * 60 * 5),
                createdAt: Date().addingTimeInterval(-60 * 60 * 6)
            ),
            ThreadSummary(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                title: "化学反応式の係数",
                source: "simulator",
                latestPreview: "酸素原子の数から合わせ直しました。",
                lastMessageAt: Date().addingTimeInterval(-60 * 60 * 25),
                createdAt: Date().addingTimeInterval(-60 * 60 * 26)
            )
        ]
    }

    private var usesSimulatorFixtures: Bool {
        if let fixtureOverride { return fixtureOverride }
        return SimulatorFixtures.isEnabled
    }
}
