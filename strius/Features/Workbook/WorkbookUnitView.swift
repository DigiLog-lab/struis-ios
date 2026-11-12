import SwiftUI

/// 単元。小単元の並び。各行に名前・マス・段階または合格。
struct WorkbookUnitView: View {
    @Environment(WorkbookStore.self) private var store
    @Environment(WorkbookCoordinator.self) private var coordinator
    @Environment(\.solveUnitInTimeline) private var solveInTimeline
    @Environment(LearnerData.self) private var learnerData
    @State private var attacher = UnitMaterialAttacher()
    @State private var isMaterialCameraPresented = false
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
                        materialButton(unit)
                    }
                    .padding(.horizontal, 20)
                    if let error = attacher.error(unitID) {
                        Text(error)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.regressColor)
                            .padding(.horizontal, 20)
                            .accessibilityIdentifier("workbook-unit-material-error")
                    }
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
        .background {
            ChatCameraPresentation(isPresented: $isMaterialCameraPresented, batch: ChatCameraBatch(limit: 8, doneTitle: "終える") { photos in
                attacher.attach(unitID: unitID, photos: photos, learnerData: learnerData) { _ = await store.loadUnit(id: unitID) }
            })
        }
        .task(id: unitID) { _ = await store.loadUnit(id: unitID) }
        .struisRefreshable { _ = await store.loadUnit(id: unitID) }
    }

    /// 進みの右の「教科書を撮る」(大学の授業は「資料を撮る」、ページや回が付いた後は「撮り足す」)。#132
    @ViewBuilder
    private func materialButton(_ unit: WorkbookUnitDTO) -> some View {
        if attacher.isRunning(unitID) {
            HStack(spacing: 8) {
                StruisLoadingIndicator().controlSize(.small)
                Text("読み取り中").font(Typography.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workbook-unit-material-reading")
        } else {
            let hasRefs = unit.subunits.contains { (store.subunits[$0.id] ?? $0).ref != nil }
            let course = OnboardingProfile.load()?.isUniversity ?? false
            Button { isMaterialCameraPresented = true } label: {
                Label(hasRefs ? "撮り足す" : (course ? "資料を撮る" : "教科書を撮る"), systemImage: "camera")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workbook-unit-add-material")
        }
    }
}

extension EnvironmentValues {
    /// 単元の画面の「タイムラインで解く」(タイムラインの上に単元ホームを重ねている時だけ。単元の ID を渡す)。
    @Entry var solveUnitInTimeline: (@MainActor (String) -> Void)? = nil
}
