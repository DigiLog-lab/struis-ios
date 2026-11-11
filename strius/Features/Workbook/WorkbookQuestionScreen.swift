import SwiftUI

/// 「質問」。右上から開く子画面。今見ている一枚が文脈として乗るが、質問の範囲は縛らない。
/// `purpose == .createUnit` は単元づくり(#132): 会話ではなく、オンボーディングと同じ画面で選んで計画を作る。
/// 計画の「はじめる」の後は、この画面を閉じて作った単元を開く。
struct WorkbookQuestionScreen: View {
    let context: WorkbookQuestionContext
    /// シートで出さない時(iPad のタイムラインの右に開く欄)の閉じ方。無ければシートを閉じる。
    var onClose: (() -> Void)? = nil

    var body: some View {
        if context.purpose == .createUnit {
            UnitCreationScreen(onClose: onClose)
        } else {
            WorkbookChatQuestionScreen(context: context, onClose: onClose)
        }
    }
}

/// ホームの「単元を作る」(#132)。中高生は「ここから何をしますか」から、大学生は「何を勉強しますか」から、
/// オンボーディングと同じ画面で選ぶ。計画づくりは単元づくりとして数える(`UsageSetup.unit`)。
struct UnitCreationScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkbookStore.self) private var store
    @Environment(WorkbookCoordinator.self) private var coordinator
    @Environment(LearnerData.self) private var learnerData
    @Environment(SubscriptionStore.self) private var subscriptions
    var onClose: (() -> Void)? = nil

    var body: some View {
        OnboardingFlowView(
            learnerData: learnerData, subscriptions: subscriptions,
            unitCreation: { unitID in opened(unitID) },
            existingUnits: (store.home?.units ?? []).map(\.title),
            onFinish: { close() }
        )
        .environment(\.onboardingClose) { close() }
        // 計画づくり・確認の1問の採点が利用枠で止まったら、案内を出す。
        .usageLimitGuide([.onboardingPlan, .onboardingGrading])
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unit-creation")
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// 作った単元を開く(単元ホームの上に単元の画面を積む)。
    private func opened(_ unitID: String) {
        Task {
            await store.loadHome()
            _ = await store.loadUnit(id: unitID)
            close()
            coordinator.question = nil
            coordinator.path = [.unit(unitID)]
        }
    }
}

/// 質問の会話。
struct WorkbookChatQuestionScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkbookStore.self) private var store
    @Environment(WorkbookCoordinator.self) private var coordinator
    @Environment(LearnerData.self) private var learnerData
    @Environment(AuthStore.self) private var auth
    let context: WorkbookQuestionContext
    /// シートで出さない時(iPad のタイムラインの右に開く欄)の閉じ方。無ければシートを閉じる。
    var onClose: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ChatView(
                workbookContext: context.viewRef == nil && context.purpose == .question ? nil : context,
                embedded: false,
                onClose: { close() },
                threadBootstrap: unitCreationBootstrap,
                onProposalStarted: { started in openFirstSubunit(started) }
            )
        }
        // 質問・単元づくりが利用枠で止まったら、案内を出す(止まった返事の吹き出しにも理由が残る)。
        .usageLimitGuide([.chat])
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
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
            close()
            coordinator.question = nil
            if let first = unit?.subunits.first(where: { $0.status == .active }) ?? unit?.subunits.first {
                coordinator.path = [.subunit(first.id)]
            } else {
                coordinator.path = [.unit(unitID)]
            }
        }
    }
}
