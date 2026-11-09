import SwiftUI

/// 単元。小単元の並び。各行に名前・マス・段階または合格。
struct WorkbookUnitView: View {
    @Environment(WorkbookStore.self) private var store
    @Environment(WorkbookCoordinator.self) private var coordinator
    @Environment(\.solveUnitInTimeline) private var solveInTimeline
    let unitID: String

    var body: some View {
        let unit = store.units[unitID]
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let unit {
                    HStack {
                        Text("\(unit.passedCount) / \(unit.subunitCount)")
                            .font(Typography.caption.monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                        if unit.status == .passed {
                            Text("合格")
                                .font(Typography.micro.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(WorkbookPalette.passed, in: Capsule())
                                .foregroundStyle(Theme.ground)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    if let solveInTimeline {
                        Button { solveInTimeline(unitID) } label: {
                            Label("タイムラインで解く", systemImage: "rectangle.stack")
                                .font(Typography.sans(size: 16, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .foregroundStyle(Theme.onAccent)
                                .background(Theme.accentColor, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("workbook-unit-solve-in-timeline")
                    }
                    ForEach(unit.subunits) { row in
                        let subunit = store.subunits[row.id] ?? row
                        Button {
                            coordinator.open(.subunit(subunit.id))
                        } label: {
                            WorkbookSubunitRow(subunit: subunit)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                    }
                } else {
                    ProgressView().padding(.top, 40).frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 96)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle(unit?.title ?? "単元")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                WorkbookQuestionPill { coordinator.ask() }
            }
        }
        .workbookCaptureInset(context: nil) { coordinator.capture(context: $0) }
        .task(id: unitID) { _ = await store.loadUnit(id: unitID) }
        .struisRefreshable { _ = await store.loadUnit(id: unitID) }
    }
}

extension EnvironmentValues {
    /// 単元の画面の「タイムラインで解く」(タイムラインの上に単元ホームを重ねている時だけ。単元の ID を渡す)。
    @Entry var solveUnitInTimeline: (@MainActor (String) -> Void)? = nil
}
