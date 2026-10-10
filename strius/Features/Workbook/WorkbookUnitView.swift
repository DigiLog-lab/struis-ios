import SwiftUI

/// 単元。小単元の並び。各行に名前・マス・段階または合格。
struct WorkbookUnitView: View {
    @Environment(WorkbookStore.self) private var store
    @Environment(WorkbookCoordinator.self) private var coordinator
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
