import CryptoKit
import Foundation
import GRDB
import OSLog
import SwiftUI

private let workbookLog = Logger(subsystem: "com.digiloglab.strius", category: "workbook")

/// 問題集の状態。ホーム「単元」、小単元、一枚、答案(撮った紙)、相談の全体像を台帳
/// (`Ledger`) から読み、判定・生成は端末の `TurnCoordinator` が回す (design §6.3 / §6.4)。
/// 画面が使う DTO は変えない。サーバー往復もポーリングも無く、台帳のイベントで再描画する。
@Observable
@MainActor
final class WorkbookStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle
    private(set) var home: WorkbookHomeDTO?
    private(set) var subunits: [String: WorkbookSubunitDTO] = [:]
    private(set) var units: [String: WorkbookUnitDTO] = [:]
    private(set) var sets: [String: WorkbookSetDTO] = [:]
    private(set) var captures: [String: WorkbookCaptureDTO] = [:]
    private(set) var proposals: [String: WorkbookProposalDTO] = [:]
    private(set) var problems: [String: WorkbookProblemDetailDTO] = [:]
    /// 撮った直後、台帳に入る前の仮の帯。
    private(set) var uploadingCaptures: [PendingCapture] = []
    var actionError: String?
    private(set) var deletingUnitID: String?
    private(set) var deletionError: String?
    private(set) var failedDeletionUnitID: String?
    private(set) var pendingDeletion: UnitDeletion.Fact?

    func deleteUnit(id: String) async -> UnitDeletion.Fact? {
        guard deletingUnitID == nil else { return nil }
        deletingUnitID = id
        deletionError = nil
        failedDeletionUnitID = nil
        refreshTask?.cancel(); refreshTask = nil
        do {
            let fact = try await turns.deleteUnit(id: id)
            // Keep the old home visible until physical cleanup and memory updates both succeeded.
            deletingUnitID = nil
            pendingDeletion = nil
            await refreshAll()
            return fact
        } catch {
            deletingUnitID = nil
            workbookLog.error("unit deletion failed: \(String(describing: error), privacy: .private)")
            failedDeletionUnitID = id
            pendingDeletion = await ledger.pendingDeletion()
            deletionError = pendingDeletion == nil ? "単元を削除できませんでした。もう一度お試しください。" : "削除を完了できませんでした。削除を再開してください。"
            return nil
        }
    }

    struct PendingCapture: Identifiable, Hashable {
        let id: UUID
        let context: WorkbookViewRef?
        let startedAt: Date
    }

    let ledger: Ledger
    let turns: TurnCoordinator
    private var observer: UUID?
    private var refreshTask: Task<Void, Never>?
    /// 読み直しの途中で、もう一度読み直すように頼まれた(読み直しは同時に 1 つだけ)。
    private var refreshRequested = false
    /// 問題集のイベントを受け取った回数。読んでいる間に増えたら、読んだ値は古いかもしれない。
    private var ledgerRevision = 0

    init(ledger: Ledger, turns: TurnCoordinator) {
        self.ledger = ledger
        self.turns = turns
        Task { [weak self] in
            guard let self else { return }
            let id = await ledger.observe { [weak self] events in
                guard events.contains(where: { $0.entity.rawValue.hasPrefix("workbook_") }) else { return }
                Task { @MainActor [weak self] in
                    self?.ledgerRevision += 1
                    self?.scheduleRefresh()
                }
            }
            self.observer = id
        }
    }

    func dismissDeletionError() { deletionError = nil }

    func reset() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequested = false
        loadState = .idle
        home = nil
        subunits = [:]
        units = [:]
        sets = [:]
        captures = [:]
        proposals = [:]
        problems = [:]
        uploadingCaptures = []
        actionError = nil
    }

    // MARK: - Home

    var recentCaptures: [WorkbookCaptureDTO] {
        let fromHome = home?.recent ?? []
        var merged: [String: WorkbookCaptureDTO] = [:]
        for capture in fromHome { merged[capture.id] = capture }
        for (id, capture) in captures where merged[id] != nil { merged[id] = capture }
        return merged.values.sorted { $0.createdAt > $1.createdAt }
    }

    var activeSubunits: [WorkbookSubunitDTO] {
        (home?.now ?? []).map { subunits[$0.id] ?? $0 }
    }

    var hasAnyUnit: Bool { !(home?.units.isEmpty ?? true) }

    func loadHomeIfNeeded() async {
        if case .idle = loadState { await loadHome() }
    }

    func loadHome() async {
        pendingDeletion = await ledger.pendingDeletion()
        if let pendingDeletion { deletionError = "「" + pendingDeletion.title + "」の削除を再開してください" }
        if home == nil { loadState = .loading }
        await refreshHome()
    }

    func refreshHome() async {
        guard deletingUnitID == nil else { return }
        do {
            let payload = try await read { db in try WorkbookMachine(loading: db).home() }
            home = payload
            units = [:]
            subunits = [:]
            for unit in payload.units {
                units[unit.id] = unit
                for subunit in unit.subunits { subunits[subunit.id] = subunit }
            }
            for capture in payload.recent { captures[capture.id] = capture }
            loadState = .loaded
        } catch {
            workbookLog.error("home failed: \(String(describing: error), privacy: .public)")
            if home == nil { loadState = .failed(Self.message(for: error)) } else { actionError = Self.message(for: error) }
        }
    }

    /// Coalesced re-read after ledger events: the home, plus every cached set / capture / proposal / problem.
    /// 読み直しは同時に 1 つだけ。読み直しの途中で頼まれたら、終わった後にもう一度読む(先に始めた読み直しの
    /// 古い値が、後のものを上書きしないように)。
    private func scheduleRefresh() {
        guard deletingUnitID == nil else { return }
        refreshRequested = true
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            while self.refreshRequested, !Task.isCancelled {
                self.refreshRequested = false
                await self.refreshAll()
            }
            if !Task.isCancelled { self.refreshTask = nil }
        }
    }

    /// 画面用に覚える値を台帳から読む。読んでいる間に問題集のイベントが届いていたら、読んだ値は
    /// そのイベントの前のものかもしれないので、覚えた後に読み直しを頼む(呼び出し側は、待たずにすぐ覚えること)。
    /// 読み直しは覚えている全部を読むので、この値もイベントの後の値になる。
    private func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        let revision = ledgerRevision
        let value = try await ledger.read(block)
        if ledgerRevision != revision { scheduleRefresh() }
        return value
    }

    /// 覚えているものを全部読み直す(テストからも呼ぶ)。
    func refreshAll() async {
        await refreshHome()
        let setIDs = Array(sets.keys)
        let captureIDs = Array(captures.keys)
        let proposalIDs = Array(proposals.keys)
        let problemIDs = Array(problems.keys)
        do {
            let (sets, captures, proposals, problems) = try await ledger.read { db in
                let machine = try WorkbookMachine(loading: db)
                return (
                    Dictionary(uniqueKeysWithValues: setIDs.compactMap { id in machine.sets[id].map { (id, machine.setView($0)) } }),
                    Dictionary(uniqueKeysWithValues: captureIDs.compactMap { id in machine.captures[id].map { (id, machine.captureView($0)) } }),
                    Dictionary(uniqueKeysWithValues: proposalIDs.compactMap { id in machine.proposals[id].map { (id, machine.proposalView($0)) } }),
                    Dictionary(uniqueKeysWithValues: problemIDs.compactMap { id in (try? machine.problemDetail(id: id)).map { (id, $0) } })
                )
            }
            // 読んでいる間に開いた画面が覚えたもの(読んだ一覧に無いもの)は残す。消すと、画面から見て覚えている状態が
            // 「無し → 有り → 無し」と描き直しの間に戻るので画面は見直さず、以後の読み直しにも入らないので、
            // 単元づくりの待ちが全体像ができても「小単元を並べています」のまま進まなくなる(Issue #22)。
            self.sets = sets.merging(self.sets.filter { !setIDs.contains($0.key) }) { fresh, _ in fresh }
            self.captures = captures.merging(self.captures.filter { !captureIDs.contains($0.key) }) { fresh, _ in fresh }
            self.proposals = proposals.merging(self.proposals.filter { !proposalIDs.contains($0.key) }) { fresh, _ in fresh }
            self.problems = problems.merging(self.problems.filter { !problemIDs.contains($0.key) }) { fresh, _ in fresh }
        } catch {
            workbookLog.error("refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Units / subunits

    func loadUnit(id: String) async -> WorkbookUnitDTO? {
        do {
            let unit = try await read { db in try WorkbookMachine(loading: db).unitSummary(id: id) }
            units[id] = unit
            for subunit in unit.subunits { subunits[subunit.id] = subunit }
            return unit
        } catch {
            actionError = Self.message(for: error)
            units[id] = nil
            return nil
        }
    }

    @discardableResult
    func loadSubunit(id: String) async -> WorkbookSubunitDTO? {
        do {
            let subunit = try await read { db in try WorkbookMachine(loading: db).subunitSummary(id: id) }
            subunits[id] = subunit
            return subunit
        } catch {
            actionError = Self.message(for: error)
            subunits[id] = nil
            return nil
        }
    }

    /// 「先に進む」。段階 1・2 だけ。3・4 は機械が拒む。
    @discardableResult
    func advance(subunitID: String) async -> Bool {
        // 段階 1→2 で先回りの例題ができていれば、進むのと同時に例題と解説を出す(待ちが無い。§3.1)。
        if let adopted = await turns.adoptPrefetchedExample(subunitID: subunitID, advancing: true) {
            subunits[subunitID] = adopted
            await refreshHome()
            return true
        }
        do {
            let subunit = try await ledger.commit { db in
                var machine = try WorkbookMachine(loading: db)
                let summary = try machine.advance(subunitID: subunitID)
                return (machine.events, summary)
            }
            subunits[subunitID] = subunit
            await refreshHome()
            return true
        } catch {
            actionError = Self.message(for: error)
            return false
        }
    }

    /// 段階 1・2: 小単元の会話 thread を用意し、その段のモデルのターンがまだなら 1 回だけ起こす。
    @discardableResult
    func kickoff(subunitID: String) async -> (threadID: String?, result: TurnCoordinator.KickoffResult) {
        let threadID = try? await turns.subunitThread(subunitID: subunitID)
        let result = await turns.kickoffSubunit(subunitID: subunitID)
        await loadSubunit(id: subunitID)
        // 段階 1 の説明が出終わっていれば、次の例題を先回りで作る(開き直した時・起動し直した後も)。
        let turns = self.turns
        Task { await turns.prefetchExampleIfNeeded(subunitID: subunitID) }
        return (threadID, result)
    }

    /// 起こした返事が止まった / 失敗した時の「もう一度始める」。
    func restartKickoff(subunitID: String) async {
        _ = await turns.restartSubunitKickoff(subunitID: subunitID)
        await loadSubunit(id: subunitID)
    }

    /// 問題数 n。増やす方向だけ。
    @discardableResult
    func setCount(subunitID: String, n: Int) async -> Bool {
        do {
            let subunit = try await ledger.commit { db in
                var machine = try WorkbookMachine(loading: db)
                let summary = try machine.changeCount(subunitID: subunitID, n: n, reason: "learner_increase")
                return (machine.events, summary)
            }
            subunits[subunitID] = subunit
            await refreshHome()
            return true
        } catch {
            actionError = Self.message(for: error)
            return false
        }
    }

    // MARK: - Sets

    /// 現在段階の一枚を返す。開いている一枚があればそれを返し、無ければ 1 ターンで組む。
    func requestSet(subunitID: String, retryOfCapture: String? = nil) async -> WorkbookSetDTO? {
        do {
            let (set, generate) = try await ledger.commit { db -> ([LedgerEvent], (WorkbookSetDTO, Bool)) in
                var machine = try WorkbookMachine(loading: db)
                let spec = try machine.nextSetSpec(subunitID: subunitID, retryOfCapture: retryOfCapture)
                if let existing = machine.openSet(subunitID: subunitID), existing.stage == spec.stage {
                    return ([], (machine.setView(existing), false))
                }
                let id = machine.insertGeneratingSet(subunitID: subunitID, spec: spec)
                return (machine.events, (try machine.setView(id: id), true))
            }
            sets[set.id] = set
            if generate {
                await turns.startSetGeneration(setID: set.id)
            } else {
                // 先回りで組んでいた一枚を学習者が求めた: ここからは学習者が待っている処理として通す。
                await turns.promote(targetID: set.id)
            }
            await loadSubunit(id: subunitID)
            return set
        } catch {
            actionError = Self.message(for: error)
            return nil
        }
    }

    @discardableResult
    func loadSet(id: String) async -> WorkbookSetDTO? {
        do {
            let set = try await read { db in try WorkbookMachine(loading: db).setView(id: id) }
            sets[id] = set
            return set
        } catch {
            actionError = Self.message(for: error)
            sets[id] = nil
            return nil
        }
    }

    /// 「やり直す」: 同じ段のまま新しい一枚(類題 1 問 / 演習 n 問)。直前の誤答の種類を狙う。
    /// リザルトの「やり直す」。押したリザルトの答案(`captureID`)の誤りを元に、新しい一枚を作る。
    func retry(subunitID: String, captureID: String? = nil) async -> WorkbookSetDTO? {
        await requestSet(subunitID: subunitID, retryOfCapture: captureID)
    }

    /// 「例題に戻る」: 段階 2 へ。戻る前の段を記録し、例題の「先に進む」がそこへ戻す。
    @discardableResult
    func returnToExample(subunitID: String) async -> Bool {
        do {
            let subunit = try await ledger.commit { db in
                var machine = try WorkbookMachine(loading: db)
                let summary = try machine.returnToExample(subunitID: subunitID)
                return (machine.events, summary)
            }
            subunits[subunitID] = subunit
            await refreshHome()
            return true
        } catch {
            actionError = Self.message(for: error)
            return false
        }
    }

    func loadProblem(id: String) async -> WorkbookProblemDetailDTO? {
        do {
            let detail = try await read { db in try WorkbookMachine(loading: db).problemDetail(id: id) }
            problems[id] = detail
            return detail
        } catch {
            actionError = Self.message(for: error)
            problems[id] = nil
            return nil
        }
    }

    // MARK: - Captures

    /// 撮った紙を綴じる。即「最近」に入り、判定は端末の Codex で裏で走る (アップロードなし)。
    /// 何枚かをまとめて撮った時は、全ページを順に 1 つの答案にして 1 回で判定する(一括採点)。
    @discardableResult
    func submitCapture(pages: [Data], context: WorkbookViewRef?) async -> WorkbookCaptureDTO? {
        guard let first = pages.first else { return nil }
        let pending = PendingCapture(id: UUID(), context: context, startedAt: Date())
        uploadingCaptures.insert(pending, at: 0)
        defer { uploadingCaptures.removeAll { $0.id == pending.id } }
        do {
            let id = LedgerID.make()
            try StruisPaths.prepare()
            var paths: [String] = []
            for (index, data) in pages.enumerated() {
                let relative = index == 0 ? "\(id).jpg" : "\(id)-\(index + 1).jpg"
                try data.write(to: StruisPaths.captures.appendingPathComponent(relative), options: .atomic)
                paths.append(relative)
            }
            let sha = SHA256.hash(data: first).map { String(format: "%02x", $0) }.joined()
            let byteCount = first.count
            let capture = try await ledger.commit { db in
                var machine = try WorkbookMachine(loading: db)
                let view = try machine.createCapture(
                    id: id, imagePath: paths[0], contentType: "image/jpeg", sha256: sha, byteCount: byteCount,
                    subunitID: context?.subunitId, setID: context?.setId, pagePaths: paths
                )
                return (machine.events, view)
            }
            captures[capture.id] = capture
            await refreshHome()
            await turns.startGrading(captureID: capture.id)
            return capture
        } catch {
            workbookLog.error("capture failed: \(String(describing: error), privacy: .public)")
            actionError = Self.message(for: error)
            return nil
        }
    }

    @discardableResult
    func loadCapture(id: String) async -> WorkbookCaptureDTO? {
        do {
            let capture = try await read { db in try WorkbookMachine(loading: db).captureView(id: id) }
            let previous = captures[id]
            captures[id] = capture
            if previous?.status != capture.status, capture.status != .identifying {
                await refreshHome()
                if let subunitID = capture.subunitId { await loadSubunit(id: subunitID) }
                if let setID = capture.setId { await loadSet(id: setID) }
            }
            return capture
        } catch {
            actionError = Self.message(for: error)
            captures[id] = nil
            return nil
        }
    }

    /// 途中のリザルトの「見つかった k 問で結果を出す」: 判定のある問題で一枚を締める(分割採点 R3)。
    @discardableResult
    func closeSet(captureID: String) async -> Bool {
        do {
            let capture = try await ledger.commit { db in
                var machine = try WorkbookMachine(loading: db)
                let view = try machine.closeSet(captureID: captureID)
                return (machine.events, view)
            }
            captures[captureID] = capture
            if let setID = capture.setId { await loadSet(id: setID) }
            if let subunitID = capture.subunitId { await loadSubunit(id: subunitID) }
            await refreshHome()
            return true
        } catch {
            actionError = Self.message(for: error)
            return false
        }
    }

    /// 答案の写真。何枚かの答案は、全ページを縦に並べた 1 枚にする(丸は各ページの上に描く)。
    func capturePaper(id: String) async -> WorkbookCapturePaper? {
        var capture = captures[id]
        if capture == nil { capture = await loadCapture(id: id) }
        guard let capture else { return nil }
        var images: [UIImage] = []
        for path in capture.pages {
            guard let data = try? Data(contentsOf: StruisPaths.captures.appendingPathComponent(path)),
                  let image = try? await PreparedImage.decode(data, maxPixelSize: 1200) else { continue }
            images.append(image)
        }
        return WorkbookCapturePaper(pages: images)
    }

    func assign(captureID: String, request: WorkbookAssignRequest) async -> WorkbookCaptureDTO? {
        do {
            let assignment: WorkbookMachine.Assignment
            if let problemID = request.problemId {
                assignment = .problem(id: problemID)
            } else if let newProblem = request.newProblem {
                assignment = .newProblem(subunitID: newProblem.subunitId)
            } else if let newSubunit = request.newSubunit {
                assignment = .newSubunit(unitID: newSubunit.unitId, unitTitle: newSubunit.unitTitle, title: newSubunit.title, n: newSubunit.n)
            } else {
                throw LedgerError.invalid("choose exactly one of problem_id, new_problem, new_subunit")
            }
            let capture = try await ledger.commit { db in
                var machine = try WorkbookMachine(loading: db)
                let view = try machine.assign(captureID: captureID, assignment: assignment, verdictOverride: nil)
                return (machine.events, view)
            }
            captures[capture.id] = capture
            await refreshHome()
            if let subunitID = capture.subunitId { await loadSubunit(id: subunitID) }
            return capture
        } catch {
            actionError = Self.message(for: error)
            return nil
        }
    }

    /// 整理中の帯で候補を探す時に使う、全マスの平たい一覧。
    var allProblemTiles: [(subunit: WorkbookSubunitDTO, tile: WorkbookProblemTileDTO)] {
        (home?.units ?? []).flatMap { unit in
            unit.subunits.flatMap { subunit in
                (subunits[subunit.id] ?? subunit).tiles.map { (subunit: subunits[subunit.id] ?? subunit, tile: $0) }
            }
        }
    }

    // MARK: - Proposals (入口 A)

    @discardableResult
    func loadProposal(id: String) async -> WorkbookProposalDTO? {
        do {
            let proposal = try await read { db in try WorkbookMachine(loading: db).proposalView(id: id) }
            proposals[id] = proposal
            return proposal
        } catch {
            actionError = Self.message(for: error)
            proposals[id] = nil
            return nil
        }
    }

    /// 相談の全体像を作る (`POST /v1/workbook/proposals` の移植)。質問ターンの proposal ブロックからも呼ばれる。
    @discardableResult
    func createProposal(request: String, threadID: String?, messageID: String?) async -> WorkbookProposalDTO? {
        do {
            let proposal = try await ledger.commit { db in
                var machine = try WorkbookMachine(loading: db)
                let id = machine.insertProposal(request: request, threadID: threadID, messageID: messageID)
                return (machine.events, try machine.proposalView(id: id))
            }
            proposals[proposal.id] = proposal
            await turns.startUnitGeneration(proposalID: proposal.id)
            return proposal
        } catch {
            actionError = Self.message(for: error)
            return nil
        }
    }

    func startProposal(id: String) async -> WorkbookProposalDTO? {
        do {
            let proposal = try await ledger.commit { db in
                var machine = try WorkbookMachine(loading: db)
                let view = try machine.startProposal(id: id)
                return (machine.events, view)
            }
            proposals[id] = proposal
            await refreshHome()
            return proposal
        } catch {
            actionError = Self.message(for: error)
            return nil
        }
    }

    // MARK: - Helpers

    static func message(for error: Error) -> String {
        if let ledgerError = error as? LedgerError {
            if let code = ledgerError.code, let localized = localized(code: code) { return localized }
            return ledgerError.localizedDescription
        }
        if let delivery = error as? DeliveryError { return delivery.localizedDescription }
        return error.localizedDescription
    }

    private static func localized(code: String) -> String? {
        switch code {
        case "count_cannot_decrease": "問題数は減らせません"
        case "learner_stage_requires_evidence": "この段階は紙を撮って進みます"
        case "set_requires_learner_stage": "この段階では一枚を作りません"
        case "codex_connection_required": "Codex に接続してください"
        case "capture_not_in_triage": "この答案は整理済みです"
        case "return_requires_learner_stage": "類題か演習から例題に戻れます"
        default: nil
        }
    }
}
