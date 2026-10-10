import SwiftUI

/// シートを開いたときの素の問題リスト。メタファーはここで終わり、実務のデータに触れる層。
struct ProblemCatalogSheetDetailView: View {
    let sheet: ProblemCatalogSheetDTO

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(sheet.subjectLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("·")
                    Text("\(sheet.solvedCount) / \(sheet.slots.count)問")
                        .layoutPriority(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(sheet.slots) { slot in
                        NavigationLink(
                            value: ProblemCatalogDestination.problem(
                                ProblemCatalogProblemContext(
                                    slot: slot,
                                    breadcrumb: "\(sheet.subjectLabel) · \(sheet.displayTitle)"
                                )
                            )
                        ) {
                            ProblemCatalogSlotRow(slot: slot)
                        }
                        .buttonStyle(.plain)
                        if slot.id != sheet.slots.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(sheet.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 整理中(科目の判定待ち)の問題リスト。
struct ProblemCatalogOrganizingListView: View {
    let slots: [ProblemCatalogSheetSlotDTO]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("取り込み時に科目を確定できなかった問題です。問題を開くと内容を確認できます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(slots) { slot in
                        NavigationLink(
                            value: ProblemCatalogDestination.problem(
                                ProblemCatalogProblemContext(slot: slot, breadcrumb: "整理中")
                            )
                        ) {
                            ProblemCatalogSlotRow(slot: slot, isOrganizing: true)
                        }
                        .buttonStyle(.plain)
                        if slot.id != slots.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle("整理中")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ProblemCatalogSlotRow: View {
    let slot: ProblemCatalogSheetSlotDTO
    var isOrganizing = false

    private var state: ProblemCatalogTileState {
        ProblemCatalogTileState(rawTileState: slot.tileState)
    }

    private var subtitleText: String {
        var parts: [String] = []
        if state == .retry, let errorLabel = slot.errorLabels.first {
            parts.append("\(errorLabel)でミス")
        }
        if let date = ProblemCatalogDateFormatting.shortDate(
            fromISO: slot.progress.lastAttemptAt
        ) {
            parts.append(date)
        }
        if let sourceLabel = slot.sourceLabel?.nilIfBlankValue {
            parts.append(sourceLabel)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                ProblemCatalogRichText(
                    text: slot.title,
                    font: .subheadline,
                    katexFontSize: 14,
                    katexFontWeight: 600,
                    lineLimit: 2,
                    maxKatexHeight: 40
                )
                if !subtitleText.isEmpty {
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            ProblemCatalogStatusBadge(state: state, isOrganizing: isOrganizing)
                .layoutPriority(1)
                .fixedSize(horizontal: true, vertical: false)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(slot.title)、\(isOrganizing ? "整理中" : state.label)"
        )
    }
}

/// 検索結果などで使う、コンテキスト由来の問題行。
struct ProblemCatalogProblemRow: View {
    let context: ProblemCatalogProblemContext

    private var state: ProblemCatalogTileState {
        ProblemCatalogTileState(rawTileState: context.tileState)
    }

    private var subtitleText: String {
        var parts: [String] = []
        if let breadcrumb = context.breadcrumb?.nilIfBlankValue {
            parts.append(breadcrumb)
        }
        if let sourceLabel = context.sourceLabel?.nilIfBlankValue {
            parts.append(sourceLabel)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                ProblemCatalogRichText(
                    text: context.title,
                    font: .subheadline,
                    katexFontSize: 14,
                    katexFontWeight: 600,
                    lineLimit: 2,
                    maxKatexHeight: 40
                )
                if !subtitleText.isEmpty {
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            ProblemCatalogStatusBadge(
                state: state,
                isOrganizing: context.problemStatus == "unresolved"
            )
            .layoutPriority(1)
            .fixedSize(horizontal: true, vertical: false)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(context.title)、\(state.label)")
    }
}

#if DEBUG
#Preview("通常") {
    NavigationStack {
        ProblemCatalogSheetDetailView(sheet: ProblemCatalogSheetIndexDTO.preview.sheets[0])
    }
}

#Preview("ダーク") {
    NavigationStack {
        ProblemCatalogSheetDetailView(sheet: ProblemCatalogSheetIndexDTO.preview.sheets[0])
    }
    .preferredColorScheme(.dark)
}

#Preview("整理中 / 小型端末") {
    NavigationStack {
        ProblemCatalogOrganizingListView(slots: ProblemCatalogSheetIndexDTO.preview.organizing)
    }
    .frame(width: 320)
}

#Preview("大文字") {
    NavigationStack {
        ProblemCatalogSheetDetailView(sheet: ProblemCatalogSheetIndexDTO.preview.sheets[0])
    }
    .environment(\.dynamicTypeSize, .accessibility5)
}
#endif
