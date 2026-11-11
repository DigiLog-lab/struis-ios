import Foundation
import Observation
import OSLog

private let attachLog = Logger(subsystem: "com.digiloglab.strius", category: "workbook")

/// 単元の画面の「教科書を撮る」「資料を撮る」「撮り足す」(#132)。撮った写真を AI に渡し、
/// ページや授業の回を小単元に付ける。大学の授業の単元なら、授業が進んだ回の小単元を足す。確認の画面は挟まない。
@MainActor
@Observable
final class UnitMaterialAttacher {
    private(set) var runningUnitIDs: Set<String> = []
    private(set) var errors: [String: String] = [:]

    func isRunning(_ unitID: String) -> Bool { runningUnitIDs.contains(unitID) }
    func error(_ unitID: String) -> String? { errors[unitID] }

    /// 撮った写真を割り当てる。終わったら `onDone` で単元を読み直す。
    func attach(unitID: String, photos: [Data], learnerData: LearnerData, onDone: @escaping @MainActor () async -> Void) {
        guard !photos.isEmpty, !runningUnitIDs.contains(unitID) else { return }
        runningUnitIDs.insert(unitID)
        errors[unitID] = nil
        let universityLearner = OnboardingProfile.load()?.isUniversity ?? false
        Task {
            defer { runningUnitIDs.remove(unitID) }
            var paths: [String] = []
            // 写真は割り当てに使うだけで単元に残さない(残すと単元を消しても消えない)。終わったら、失敗しても消す。
            defer { Self.removePhotos(paths) }
            do {
                for photo in photos.prefix(8) { paths.append(try OnboardingModel.store(photo, folder: "workbook/materials")) }
                let ledger = learnerData.ledger
                guard let request = try await ledger.read({ db in
                    Self.request(machine: try WorkbookMachine(loading: db), unitID: unitID, universityLearner: universityLearner)
                }) else { return }
                let plan = try await OnboardingTurns.attachPlan(assets: learnerData.assets, planID: LedgerID.make(), request: request.json, imagePaths: paths)
                let text = try await OnboardingTurns.run(plan, turns: learnerData.turns, runner: learnerData.runner, limit: OnboardingTurns.gradingTimeLimit)
                guard let attachment = OnboardingTurns.parseAttachment(text, subunitIDs: request.subunitIDs, isCourse: request.isCourse) else {
                    throw OnboardingTurns.Failure.malformed
                }
                guard attachment.readable, !attachment.assignments.isEmpty || !attachment.newSubunits.isEmpty else {
                    errors[unitID] = "この単元のページや回を読み取れませんでした"
                    return
                }
                try await ledger.commit { db in
                    var workbook = try WorkbookMachine(loading: db)
                    Self.apply(attachment, unitID: unitID, to: &workbook)
                    return (workbook.events, ())
                }
                await onDone()
            } catch {
                attachLog.error("attach material failed: \(String(describing: error), privacy: .public)")
                errors[unitID] = (error as? LocalizedError)?.errorDescription ?? "読み取れませんでした。もう一度撮ってください。"
            }
        }
    }

    nonisolated static func removePhotos(_ paths: [String]) {
        for path in paths { try? FileManager.default.removeItem(at: StruisPaths.captures.appendingPathComponent(path)) }
    }

    nonisolated struct Request: Sendable {
        var json: LedgerJSON
        var subunitIDs: Set<String>
        var isCourse: Bool
    }

    /// AI に渡す単元と小単元(今付いているページや回も)。大学の授業の単元か(計画の道筋、無ければ学習者が大学生か)も渡す。
    nonisolated static func request(machine: WorkbookMachine, unitID: String, universityLearner: Bool) -> Request? {
        guard let unit = machine.units[unitID] else { return nil }
        let rows = machine.orderedSubunits(unitID: unitID)
        let route = unit.overview["route"]?.stringValue ?? ""
        let isCourse = route.isEmpty ? universityLearner : route == OnboardingProfile.Route.university.rawValue
        let subunits: [LedgerJSON] = rows.map { row in
            .object([
                "id": .string(row.id), "title": .string(row.title), "outcome": .string(row.outcome),
                "ref": .string(row.metadata["ref"]?.stringValue ?? ""),
            ])
        }
        let json: LedgerJSON = .object([
            "task": .string("attach_material"), "unit_title": .string(unit.title), "is_course": .bool(isCourse), "subunits": .array(subunits),
        ])
        return Request(json: json, subunitIDs: Set(rows.map(\.id)), isCourse: isCourse)
    }

    /// 割り当てを単元に書く。
    nonisolated static func apply(_ attachment: MaterialAttachment, unitID: String, to workbook: inout WorkbookMachine) {
        for assignment in attachment.assignments {
            workbook.setSubunitRef(subunitID: assignment.subunitID, ref: assignment.ref)
        }
        for subunit in attachment.newSubunits {
            workbook.appendSubunit(unitID: unitID, spec: WorkbookMachine.SubunitSpec(
                title: subunit.title, outcome: subunit.outcome, n: subunit.n, scoringUnit: subunit.scoringUnit, ref: subunit.ref))
        }
    }
}
