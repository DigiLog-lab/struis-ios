import UIKit
import XCTest
@testable import strius

/// Anthropic に送る学習者の ID(#78): 全利用者で同じ固定の値を送り、端末の ID(`ledger.deviceID`)は送らない。
/// 前の版の学習メモと、iCloud で届いた古い版のメモに残った端末ごとの値は、固定の値に書き換える。
final class LearnerIDTests: XCTestCase {
    /// 届いたプランを残してから、模擬の返事を返す。
    private final class CapturingRunner: TurnRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [TurnPlan] = []
        private let mock = MockTurnRunner()
        var plans: [TurnPlan] { lock.withLock { seen } }
        func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome {
            lock.withLock { seen.append(plan) }
            return try await mock.run(plan, progress: progress)
        }
        func interrupt(planID: String) async {}
    }

    func testChatTurnSendsTheFixedLearnerIDAndNeverTheDeviceID() async throws {
        let ledger = try Ledger.inMemory()
        let runner = CapturingRunner()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(), runner: runner)
        let threadID = LedgerID.make()
        try await ledger.append([ChatRepository.createThread(id: threadID, title: "learner id").1])
        _ = try await turns.sendChat(.init(threadID: threadID, text: "二次関数の頂点は？", attachments: [], workbookView: nil))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while runner.plans.isEmpty, clock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        let plan = try XCTUnwrap(runner.plans.first)
        let text = try XCTUnwrap(plan.turn?.text)
        XCTAssertTrue(text.contains("learner_id: \(TutorMemory.modelLearnerID)"), "ターンの本文に固定の ID: \(text.prefix(400))")
        XCTAssertFalse(text.contains(ledger.deviceID), "ターンの本文に端末の ID を入れない")
        for file in plan.workspace.files {
            XCTAssertFalse(file.inline?.contains(ledger.deviceID) ?? false, "\(file.path) に端末の ID を入れない")
        }
        let session = try String(contentsOf: ChatTurns.desk.appendingPathComponent("current/session.yaml"), encoding: .utf8)
        XCTAssertTrue(session.contains("learner_id: \(TutorMemory.modelLearnerID)"), "学習メモの確かめ(session.yaml)も固定の ID")
        XCTAssertFalse(session.contains(ledger.deviceID))
    }

    func testAttachmentManifestCarriesTheGivenLearnerID() throws {
        let relative = "learner-id-\(UUID().uuidString).png"
        try FileManager.default.createDirectory(at: ChatTurns.attachmentsRoot, withIntermediateDirectories: true)
        let url = ChatTurns.attachmentsRoot.appendingPathComponent(relative)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let attachment = ChatTurns.Attachment(filename: "page.png", contentType: "image/png", bytes: png.count, relativePath: relative,
                                              sha256: SyncNames.sha256(png), kind: "image")
        let result = try AttachmentStaging.stage([attachment], learnerID: TutorMemory.modelLearnerID, threadID: "t", messageID: "m")
        XCTAssertTrue(result.manifest?.contains("- learner_id: `\(TutorMemory.modelLearnerID)`") == true, result.manifest ?? "")
    }

    func testLearnerIDsInMemoryTextAreReplacedAndOtherValuesKept() {
        let yaml = """
        schema_version: 1
        learner_id: 7f1c0a9e-2b33-4c55-9d11-0123456789ab
        prototype_user_id: '7f1c0a9e-2b33-4c55-9d11-0123456789ab'
        claims:
          - id: c1
            source:
              learner_id: "7f1c0a9e-2b33-4c55-9d11-0123456789ab"
              thread_id: th-1
        """
        let replaced = TutorMemory.replacingLearnerIDs(in: yaml)
        XCTAssertEqual(replaced, """
        schema_version: 1
        learner_id: learner
        prototype_user_id: learner
        claims:
          - id: c1
            source:
              learner_id: learner
              thread_id: th-1
        """)
        XCTAssertNil(TutorMemory.replacingLearnerIDs(in: replaced ?? ""), "2 回目は変えない")
        XCTAssertEqual(TutorMemory.replacingLearnerIDs(in: #"{"learner_id": "abc", "x": 1, "prototype_user_id":"abc"}"#),
                       #"{"learner_id": "learner", "x": 1, "prototype_user_id":"learner"}"#)
        XCTAssertNil(TutorMemory.replacingLearnerIDs(in: "thread_id: th-1\n"), "学習者の ID が無ければ変えない")
    }

    func testOldMemoryFilesAreRewrittenOnlyWhenTheyHoldAnotherID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("learner-id-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = "0c8d4e6f-1111-4222-8333-444455556666"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("evidence/model/2026-10"), withIntermediateDirectories: true)
        try "learner_id: \(device)\nclaims: []\n".write(to: root.appendingPathComponent("learner/profile.yaml").creatingParent(), atomically: true, encoding: .utf8)
        try "source:\n  learner_id: \(device)\n".write(to: root.appendingPathComponent("evidence/model/2026-10/e1.yaml"), atomically: true, encoding: .utf8)
        try "learner_id: learner\n".write(to: root.appendingPathComponent("goals/current.yaml").creatingParent(), atomically: true, encoding: .utf8)
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        try image.write(to: root.appendingPathComponent("evidence/photo.png"))

        XCTAssertEqual(try TutorMemory.replaceLearnerIDs(at: root), 2, "端末の ID の入った 2 つだけを書き換える")
        let all = try FileManager.default.subpathsOfDirectory(atPath: root.path).compactMap { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
        XCTAssertFalse(all.contains { $0.contains(device) }, "端末の ID が残らない")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("evidence/photo.png")), image, "メモ以外のファイルは触らない")
        XCTAssertEqual(try TutorMemory.replaceLearnerIDs(at: root), 0, "何度呼んでも同じ")
    }

    /// iCloud で届いた古い版のメモは、固定の ID にして置く。同期の記録は届いた内容のままなので、送り直さない。
    func testMemoryFromAnOlderDeviceIsStoredWithTheFixedIDAndNotSentBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("learner-id-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try Ledger(path: directory.appendingPathComponent("ledger.sqlite"))
        let device = "0c8d4e6f-1111-4222-8333-444455556666"
        let body = Data("learner_id: \(device)\nclaims: []\n".utf8)
        let downloaded = directory.appendingPathComponent("download.yaml")
        try body.write(to: downloaded)
        let record = SyncFileRecord(path: "memory/tutor_desk/learner/profile.yaml", sha256: SyncNames.sha256(body),
                                    modifiedAt: LedgerClock.now(), fileURL: downloaded, systemFields: nil)
        let changed = try await ledger.ingestFiles([record], deletions: [])
        XCTAssertEqual(changed, 1)
        let stored = try String(contentsOf: directory.appendingPathComponent(record.path), encoding: .utf8)
        XCTAssertEqual(stored, "learner_id: learner\nclaims: []\n")
        let outbox = try ledger.scanSyncFiles()
        XCTAssertTrue(outbox.saves.isEmpty, "書き換えたメモを iCloud へ送り直さない")
    }
}

private extension URL {
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
