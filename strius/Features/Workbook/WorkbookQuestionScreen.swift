import SwiftUI

/// 「質問」。右上から開く子画面。今見ている一枚が文脈として乗るが、質問の範囲は縛らない。
/// `purpose == .createUnit` は単元づくり: 学習者が打つ前にモデルが問いを出し、全体像の提案まで導く(§13.12)。
/// 全体像カードの「はじめる」の後は、この画面を閉じて小単元 1 の要点を開く。
struct WorkbookQuestionScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkbookStore.self) private var store
    @Environment(WorkbookCoordinator.self) private var coordinator
    @Environment(LearnerData.self) private var learnerData
    @Environment(AuthStore.self) private var auth
    let context: WorkbookQuestionContext
    /// シートで出さない時(iPad のタイムラインの右に開く質問)の閉じ方。無ければシートを閉じる。
    var onClose: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ChatView(
                workbookContext: context.viewRef == nil && context.purpose == .question ? nil : context,
                embedded: false,
                onClose: { if let onClose { onClose() } else { dismiss() } },
                threadBootstrap: unitCreationBootstrap,
                onProposalStarted: { started in openFirstSubunit(started) }
            )
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// 単元づくりの時だけ、学習者が打つ前にモデルのターンを起こす。
    private var unitCreationBootstrap: ((ChatStore) async -> Void)? {
        guard context.purpose == .createUnit else { return nil }
        return { chat in await startUnitCreation(chat) }
    }

    private func startUnitCreation(_ chat: ChatStore) async {
        let defaults = UserDefaults.standard
        let pendingAttachments = coordinator.unitCreationAttachments
        coordinator.unitCreationAttachments = []
        // 教材の保存を待っている間にサインアウトされたら、前の学習者の教材で単元づくりを始めない。
        let generation = auth.sessionGeneration
        do {
            // 選んだ教材は端末に保存し、起動が成功するまで保存したままにしておく。「再試行」でも、
            // アプリを閉じて開き直した後の「単元を作る」でも、同じ写しを使う(写しを溜めない・失わない)。
            var stored = OnboardingProfile.pendingUnitCreationAttachments(defaults)
            if !pendingAttachments.isEmpty {
                let fresh = try await ChatStore.storeAttachmentsInBackground(pendingAttachments)
                guard generation == auth.sessionGeneration, auth.canUseApp else {
                    ChatStore.removeStoredAttachments(fresh)
                    return
                }
                ChatStore.removeStoredAttachments(stored)
                stored = fresh
                OnboardingProfile.setPendingUnitCreationAttachments(stored, defaults)
            }
            let threadID = try await learnerData.turns.startUnitCreation(
                existingThreadID: defaults.string(forKey: OnboardingProfile.unitCreationThreadKey),
                profile: OnboardingProfile.load(), attachments: stored
            )
            // 起動を待っている間にサインアウトされた: 前の学習者の単元づくりを止め、会話の記録も残さない。
            guard generation == auth.sessionGeneration, auth.canUseApp else {
                await learnerData.turns.interruptChat(threadID: threadID)
                return
            }
            defaults.set(threadID, forKey: OnboardingProfile.unitCreationThreadKey)
            // 起動メッセージが教材を指したので、保留は解く(ファイルはその会話が使う)。
            OnboardingProfile.setPendingUnitCreationAttachments([], defaults)
            if let id = UUID(uuidString: threadID) { await chat.adoptThread(id: id) }
        } catch {
            guard generation == auth.sessionGeneration, auth.canUseApp else { return }
            // 作った会話は覚えておき、「再試行」でその会話を使い直す(会話を増やさない)。
            if let started = error as? TurnCoordinator.UnitCreationStartError {
                defaults.set(started.threadID, forKey: OnboardingProfile.unitCreationThreadKey)
            }
            // 「再試行」で同じ起動をやり直せるようにする(空の会話で待たせない)。教材の写しは保留のまま残る。
            chat.failBootstrap(error)
        }
    }

    private func openFirstSubunit(_ started: WorkbookProposalDTO) {
        guard let unitID = started.unitId else { return }
        UserDefaults.standard.removeObject(forKey: OnboardingProfile.unitCreationThreadKey)
        let origin = coordinator.question
        Task {
            let unit = await store.loadUnit(id: unitID)
            // 待っている間に学習者がこの画面を閉じた(か別の質問を開いた)なら、画面を移さない。単元はホームに出ている。
            guard origin != nil, coordinator.question == origin else { return }
            dismiss()
            coordinator.question = nil
            if let first = unit?.subunits.first(where: { $0.status == .active }) ?? unit?.subunits.first {
                coordinator.path = [.subunit(first.id)]
            } else {
                coordinator.path = [.unit(unitID)]
            }
        }
    }
}
