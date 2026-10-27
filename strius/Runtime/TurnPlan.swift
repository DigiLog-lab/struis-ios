import Foundation

/// The Engine ↔ Runtime contract (design §3.1). A plan is stored in `turns.plan`
/// so an interrupted turn can be re-run after a relaunch; it never contains
/// prompt text itself, only asset references resolved from the delivery cache.
nonisolated struct TurnPlan: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case chat
        case workbookGrading = "workbook_grading"
        case workbookSet = "workbook_set"
        case workbookUnit = "workbook_unit"
        case threadFork = "thread_fork"
        case threadInject = "thread_inject"
        case lunaLookup = "luna_lookup"
        /// 学習タイムライン(Issue #46): 次の5枚、採点、知識グラフを作る・見直す。
        case timelineBatch = "timeline_batch"
        case timelineGrading = "timeline_grading"
        case timelineGraph = "timeline_graph"
        case timelineReview = "timeline_review"
    }

    nonisolated struct AssetRef: Codable, Hashable, Sendable {
        var asset: String
        var sha256: String
        /// Appended after the asset text (e.g. the delegation instructions).
        var append: String?

        init(asset: String, sha256: String, append: String? = nil) {
            self.asset = asset
            self.sha256 = sha256
            self.append = append
        }
    }

    nonisolated struct ThreadSpec: Codable, Hashable, Sendable {
        enum Mode: String, Codable, Sendable { case start, resume, fork }
        var codexThreadID: String?
        var mode: Mode
        var cwd: String
        var model: String
        var effort: String
        var ephemeral: Bool
        var baseInstructions: AssetRef
        var developerInstructions: AssetRef?
        /// Literal developer text used when no asset is delivered (structured turns).
        var developerText: String?
        var injectDeveloperOnResume: Bool
        var config: LedgerJSON
        /// `thread/fork` source turn.
        var lastTurnID: String?
        /// 実行先。nil は OpenAI(この項目より前に保存された plan と互換)。
        var provider: ModelProvider? = nil

        enum CodingKeys: String, CodingKey {
            case mode, cwd, model, effort, ephemeral, config, provider
            case codexThreadID = "codex_thread_id"
            case baseInstructions = "base_instructions"
            case developerInstructions = "developer_instructions"
            case developerText = "developer_text"
            case injectDeveloperOnResume = "inject_developer_on_resume"
            case lastTurnID = "last_turn_id"
        }
    }

    nonisolated struct ImageRef: Codable, Hashable, Sendable {
        /// Workspace-relative path the guest reads.
        var path: String
        /// Host file to copy from.
        var hostPath: String
        /// 長い辺の上限。あれば、それを超える画像だけ縮めた JPEG にして置く(タイムラインの答案の写真)。
        var maxDimension: Int? = nil
        enum CodingKeys: String, CodingKey {
            case path
            case hostPath = "host_path"
            case maxDimension = "max_dimension"
        }
    }

    nonisolated struct TurnSpec: Codable, Hashable, Sendable {
        var text: String
        var images: [ImageRef]
        /// Full JSON schema for `outputSchema` (already patched, e.g. set counts).
        var outputSchema: LedgerJSON?
        var sandboxPolicy: String

        enum CodingKeys: String, CodingKey {
            case text, images
            case outputSchema = "output_schema"
            case sandboxPolicy = "sandbox_policy"
        }
    }

    nonisolated struct FileSpec: Codable, Hashable, Sendable {
        var path: String
        var asset: String?
        var inline: String?
        var executable: Bool

        init(path: String, asset: String? = nil, inline: String? = nil, executable: Bool = false) {
            self.path = path
            self.asset = asset
            self.inline = inline
            self.executable = executable
        }
    }

    /// A host directory tree copied into the workspace (canonical memory → `tutor_desk/`).
    nonisolated struct CopySpec: Codable, Hashable, Sendable {
        var hostPath: String
        var path: String
        enum CodingKeys: String, CodingKey {
            case path
            case hostPath = "host_path"
        }
    }

    nonisolated struct WorkspaceSpec: Codable, Hashable, Sendable {
        var files: [FileSpec]
        var dirs: [String]
        var copies: [CopySpec]?

        init(files: [FileSpec], dirs: [String], copies: [CopySpec]? = nil) {
            self.files = files
            self.dirs = dirs
            self.copies = copies
        }
    }

    nonisolated struct DelegationSpec: Codable, Hashable, Sendable {
        var enabled: Bool
        var inbox: String
        var model: String
        var effort: String
        var baseInstructions: AssetRef
        var developerText: String
        var outputSchema: LedgerJSON
        var sourceRoots: [String]
        /// The delegation contract is in the thread's developer instructions (P1-3); the turn text
        /// does not repeat it.
        var contractInDeveloper: Bool?
        /// 子の実行先。親のスレッドと同じ provider にする。
        var provider: ModelProvider? = nil

        enum CodingKeys: String, CodingKey {
            case enabled, inbox, model, effort, provider
            case baseInstructions = "base_instructions"
            case developerText = "developer_text"
            case outputSchema = "output_schema"
            case sourceRoots = "source_roots"
            case contractInDeveloper = "contract_in_developer"
        }
    }

    nonisolated struct Limits: Codable, Hashable, Sendable {
        var collectMaxFiles: Int
        var collectMaxBytes: Int
        var turnTimeoutS: Int
        enum CodingKeys: String, CodingKey {
            case collectMaxFiles = "collect_max_files"
            case collectMaxBytes = "collect_max_bytes"
            case turnTimeoutS = "turn_timeout_s"
        }
        static let structured = Limits(collectMaxFiles: 0, collectMaxBytes: 0, turnTimeoutS: 600)
        static let chat = Limits(collectMaxFiles: 8, collectMaxBytes: 262_144, turnTimeoutS: 600)
    }

    var id: String
    var kind: Kind
    var round: Int
    var thread: ThreadSpec
    var turn: TurnSpec?
    var workspace: WorkspaceSpec
    var delegation: DelegationSpec?
    var collect: [String]
    var limits: Limits
    /// `thread_inject` payload.
    var items: LedgerJSON?
    /// The working directory under the workspace root, when it is not this plan's own (P1-1): a chat
    /// turn runs in its Codex thread's directory (`thread-<codex thread id>`), the same for every turn
    /// of the conversation. Nil: the plan's own directory (structured turns, one turn per thread).
    var workspaceKey: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, round, thread, turn, workspace, delegation, collect, limits, items
        case workspaceKey = "workspace_key"
    }

    init(id: String, kind: Kind, round: Int, thread: ThreadSpec, turn: TurnSpec?, workspace: WorkspaceSpec, delegation: DelegationSpec?,
         collect: [String], limits: Limits, items: LedgerJSON?, workspaceKey: String? = nil) {
        self.id = id
        self.kind = kind
        self.round = round
        self.thread = thread
        self.turn = turn
        self.workspace = workspace
        self.delegation = delegation
        self.collect = collect
        self.limits = limits
        self.items = items
        self.workspaceKey = workspaceKey
    }

    /// The directory a Codex thread's turns share (P1-1). Nil if the id cannot name a directory.
    nonisolated static func threadWorkspaceKey(codexThreadID: String) -> String? {
        let key = "thread-" + codexThreadID
        return isSafeWorkspaceID(key) ? key : nil
    }

    /// Plans restored from an imported Ledger are untrusted input: a workspace must be one plain
    /// directory directly under the workspace root (UUIDv7 IDs pass), never `..` or a nested path.
    nonisolated static func isSafeWorkspaceID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128
            && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D || $0 == 0x5F }
    }

    /// Resolve the workspace against the current app-group container on every launch.
    nonisolated var hostWorkspace: URL {
        let key = workspaceKey.flatMap { Self.isSafeWorkspaceID($0) ? $0 : nil } ?? id
        return HyotanBoot.workspaceRoot.appendingPathComponent(key, isDirectory: true)
    }

    /// The directory is shared by the turns of one conversation (it outlives this plan).
    nonisolated var sharesWorkspace: Bool {
        workspaceKey.map(Self.isSafeWorkspaceID) ?? false
    }

    nonisolated static func guestWorkspace(id: String) -> String { HyotanBoot.workspaceRoot.appendingPathComponent(id, isDirectory: true).path }

    /// Saved plans may contain a previous iOS container UUID. Resolve owned inputs at use time.
    /// A stored source that may be staged into a workspace the model can read: learner attachments,
    /// captures and the tutor desk only. A plan restored from an imported Ledger could otherwise name
    /// the Ledger itself, canonical memory or any other file of the app.
    nonisolated static func stageableHostURL(_ path: String) throws -> URL {
        let url = try storedHostURL(path).standardizedFileURL
        let allowed = [StruisPaths.root.appendingPathComponent("attachments", isDirectory: true),
                       StruisPaths.captures, StruisPaths.memory.appendingPathComponent("tutor_desk", isDirectory: true)]
        guard !url.pathComponents.contains(".."),
              allowed.contains(where: { url.path.hasPrefix($0.standardizedFileURL.path + "/") || url.path == $0.standardizedFileURL.path })
        else { throw CocoaError(.fileReadNoPermission) }
        return url
    }

    nonisolated static func storedHostURL(_ path: String) throws -> URL {
        let marker = "/Library/Application Support/Struis/"
        guard let range = path.range(of: marker) else { return URL(fileURLWithPath: path) }
        let relative = String(path[range.upperBound...])
        guard !relative.split(separator: "/").contains("..") else { throw CocoaError(.fileReadNoPermission) }
        return StruisPaths.root.appendingPathComponent(relative)
    }

    var json: LedgerJSON { LedgerEvent.encode(self) }

    /// 台帳の行から戻す。`LedgerEvent.decode` は使わない: その `convertFromSnakeCase` は台帳の `turn_timeout_s` を
    /// `turnTimeoutS` に直してから探すので、snake_case で書いた `CodingKeys` と合わず、どの plan も戻せなかった
    /// (起動時の `resumeUnfinished` が黙って飛ばし、前のプロセスで返らなかった採点が「採点中」のまま残った)。
    static func from(_ json: LedgerJSON) throws -> TurnPlan {
        try JSONDecoder().decode(TurnPlan.self, from: JSONEncoder().encode(json))
    }
}

/// Runtime → Engine (design §3.2).
nonisolated struct TurnOutcome: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable { case completed, failed, interrupted }

    nonisolated struct CollectedFile: Codable, Hashable, Sendable {
        var path: String
        var text: String
    }

    var planID: String
    var round: Int
    var status: Status
    var codexThreadID: String?
    var codexTurnID: String?
    var finalText: String
    var executions: [LedgerJSON]
    var rateLimits: LedgerJSON?
    var files: [CollectedFile]
    var error: String?
    var elapsedMs: Int
    /// 失敗の理由(診断の文。`error` は学習者向けの一文で、こちらは `rpc 400: …`・`register HTTP 401` のような中身)。
    /// 画面では「停止しました」「AI が返事を作れませんでした」の下に小さく出す(勉強を止めない仕組み 3.5)。
    var errorDetail: String? = nil

    enum CodingKeys: String, CodingKey {
        case round, status, executions, files, error
        case errorDetail = "error_detail"
        case planID = "plan_id"
        case codexThreadID = "codex_thread_id"
        case codexTurnID = "codex_turn_id"
        case finalText = "final_text"
        case rateLimits = "rate_limits"
        case elapsedMs = "elapsed_ms"
    }

    var json: LedgerJSON { LedgerEvent.encode(self) }
}

/// Progress labels shown in the pending bubble (`codex.turn.status` equivalent).
/// One thing that really happened while a turn ran (reliability plan P2, waiting rule W11).
/// `label` stays the short learner-facing status; `kind` says what produced it so each waiting
/// screen can choose how to show it. Producers: `CodexTurnRunner` (lane B fills in the kinds);
/// consumers: `TurnCoordinator` and the waiting views. Never invent progress that did not happen.
nonisolated struct TurnProgressEvent: Sendable, Hashable {
    nonisolated enum Kind: Sendable, Hashable {
        /// A command / tool started (the existing activity label).
        case activity
        /// The model's own in-turn progress sentence (agentMessage with phase "commentary").
        case commentary
        /// Reply text grew. `itemID` is the agentMessage item; `text` is the delta.
        case replyDelta(itemID: String, text: String)
        /// A reasoning summary part arrived.
        case reasoningSummary
        /// Automatic context compaction started (`true`) or finished (`false`).
        case compaction(started: Bool)
        /// A delegated lookup started (`true`) or finished (`false`).
        case delegation(started: Bool)
        /// Nothing has arrived from the model for `seconds` (upstream latency, B7).
        case waitingForModel(seconds: Int)
        /// A structured turn produced part of its result (problems built, problems graded).
        case partialResult(done: Int, total: Int?)
    }

    var kind: Kind = .activity
    var label: String
    var progressID: String?
    var allowDuplicate: Bool
    /// `partialResult` で、書き終わった要素の学習者に見せてよい文(一枚の問題文など)。届いた順。
    var items: [String] = []

    init(kind: Kind = .activity, label: String, progressID: String?, allowDuplicate: Bool, items: [String] = []) {
        self.kind = kind
        self.label = label
        self.progressID = progressID
        self.allowDuplicate = allowDuplicate
        self.items = items
    }
}

/// Executes plans. The production runner drives the on-device app-server; the
/// mock runner (DEBUG) answers deterministically so the UI can be exercised
/// without a ChatGPT login.
protocol TurnRunning: Sendable {
    func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome
    func interrupt(planID: String) async
    /// ゲストと app-server を先に起こしておく(待ち時間の体験 §3.3: 学習者が答えている間に起動を進める)。
    func warmUp() async
    func forgetThreads(_ ids: Set<String>) async throws
    /// 時間切れのターンを置いて先へ進んだ後、接続を作り直させる(返らない接続を次のターンが使わない)。
    func resetConnection() async
}

extension TurnRunning {
    func warmUp() async {}
    func forgetThreads(_ ids: Set<String>) async throws {}
    func resetConnection() async {}
}
