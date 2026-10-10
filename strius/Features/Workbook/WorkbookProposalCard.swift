import SwiftUI

/// 入口 A: 相談の返答に添える全体像カードと「はじめる」。
struct WorkbookProposalCard: View {
    @Environment(WorkbookStore.self) private var store
    @Environment(LearnerData.self) private var learnerData
    @Environment(\.colorScheme) private var scheme
    let proposalID: String
    var onStarted: ((WorkbookProposalDTO) -> Void)?
    /// 単元づくりの待ち(§4)で、候補から行へ移す時の結び目。
    var rowGeometry: RowGeometry? = nil
    @State private var isStarting = false

    struct RowGeometry {
        let namespace: Namespace.ID
    }

    private var proposal: WorkbookProposalDTO? { store.proposals[proposalID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let proposal {
                switch proposal.status {
                case .generating:
                    HStack(spacing: 8) {
                        // W10: 読み込みのアイコンはアプリアイコン。
                        StruisLoadingIndicator().controlSize(.small)
                        Text("全体像を組んでいます")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    // 全体像を組むターンで実際に起きた出来事(A12・信頼性計画 P2)。
                    TurnLiveLine(keys: [TurnActivityKey.target(proposal.id)] + (proposal.messageId.map { [TurnActivityKey.unitPrefetch(messageID: $0)] } ?? []), onStop: {
                        Task { await learnerData.turns.interrupt(targetID: proposal.id) }
                    })
                    .accessibilityIdentifier("workbook-proposal-live")
                case .failed:
                    Text(proposal.error ?? "全体像を組めませんでした")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.regress(scheme))
                case .ready, .started:
                    if let overview = proposal.overview {
                        Text(overview.unitTitle)
                            .font(Typography.title)
                        if !overview.outcome.isEmpty {
                            Text(overview.outcome)
                                .font(Typography.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(overview.subunits.enumerated()), id: \.offset) { index, subunit in
                                if index > 0 {
                                    Rectangle().fill(Theme.hairline).frame(height: 1)
                                }
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(Typography.ordinal)
                                        .foregroundStyle(Theme.accentColor)
                                        .frame(width: 16, alignment: .trailing)
                                    Text(subunit.title)
                                        .font(Typography.body)
                                    Spacer()
                                    Text("\(subunit.n)問")
                                        .font(Typography.micro.monospacedDigit())
                                        .foregroundStyle(Theme.tertiaryText)
                                }
                                .padding(.vertical, 9)
                                .modifier(RowGeometryModifier(geometry: rowGeometry, title: subunit.title))
                            }
                        }
                        if proposal.status == .started {
                            Label("はじめました", systemImage: "checkmark")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.secondaryText)
                        } else {
                            Button {
                                guard !isStarting else { return }
                                isStarting = true
                                Task {
                                    if let started = await store.startProposal(id: proposal.id) {
                                        onStarted?(started)
                                    }
                                    isStarting = false
                                }
                            } label: {
                                Text("はじめる")
                                    .font(Typography.bodyEmphasized)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isStarting)
                            .accessibilityIdentifier("workbook-proposal-start")
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .struisSurface(radius: Theme.Radius.card)
        .task(id: proposalID) { await store.loadProposal(id: proposalID) }
        // `.contain` keeps the children's own identifiers (e.g. workbook-proposal-start).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workbook-proposal-card")
    }
}

private struct RowGeometryModifier: ViewModifier {
    let geometry: WorkbookProposalCard.RowGeometry?
    let title: String

    func body(content: Content) -> some View {
        if let geometry {
            content.matchedGeometryEffect(id: UnitSieveModel.rowID(title), in: geometry.namespace)
        } else {
            content
        }
    }
}
