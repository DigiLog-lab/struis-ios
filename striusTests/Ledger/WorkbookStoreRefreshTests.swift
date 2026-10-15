import Foundation
import Testing
@testable import strius

/// 問題集の画面用の覚え(`WorkbookStore`)が、台帳のイベントと画面の読み込みが重なっても古いまま・抜けたままにならないこと。
@Suite(.serialized) @MainActor
struct WorkbookStoreRefreshTests {
    private func makeStore() throws -> (Ledger, WorkbookStore) {
        let ledger = try Ledger.inMemory()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: MockTurnRunner())
        return (ledger, WorkbookStore(ledger: ledger, turns: turns))
    }

    private func insertProposal(_ ledger: Ledger) async throws -> String {
        try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let id = machine.insertProposal(request: "中2の連立方程式の文章題", threadID: nil, messageID: nil)
            return (machine.events, id)
        }
    }

    /// 読み直しが覚えている一覧を控えてから台帳を読む間に、単元づくりの待ちの画面が全体像を読み込んで覚えた。
    /// 読み直しの結果で上書きして消すと、画面は覚えている状態が「無し」のまま変わらないように見えるので見直さず、
    /// 以後の読み直しにも入らないので、全体像ができても「小単元を並べています」のまま進まなかった(Issue #22、
    /// `testOnboardingLeadsToFirstUnitAndIsNotShownAgain` が時々落ちていた)。
    @Test func proposalLoadedWhileRefreshingIsKeptAndFollowsLaterEvents() async throws {
        let (ledger, store) = try makeStore()
        let id = try await insertProposal(ledger)

        // 読み直し(ホームを読む → 覚えている一覧を控える → 一覧を読む)の間に、画面の読み込みが入る順に始める。
        let refresh = Task { await store.refreshAll() }
        let load = Task { await store.loadProposal(id: id) }
        await refresh.value
        await load.value
        #expect(store.proposals[id]?.status == .generating, "読み直しの間に覚えた全体像が消えた")

        // 全体像ができた: 覚えているので、台帳のイベントの後の読み直しで ready になる。
        try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            machine.completeProposal(id: id, overview: .object(["unit_title": .string("連立方程式")]))
            return (machine.events, ())
        }
        let deadline = Date().addingTimeInterval(5)
        while store.proposals[id]?.status != .ready, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.proposals[id]?.status == .ready, "全体像ができても覚えている状態が変わらない")
    }
}
