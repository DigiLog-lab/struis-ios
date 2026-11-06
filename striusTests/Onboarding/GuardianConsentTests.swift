import XCTest
@testable import strius

/// 16 歳未満の保護者の同意(#76): 出す相手と順番、端末の控え、運営者側の記録(偽の送り先)、送れなかった時の送り直し、版の出し直し。
@MainActor
final class GuardianConsentTests: XCTestCase {
    /// 偽の送り先。recordName ごとに 1 件だけ持ち(CloudKit の公開データベースと同じく、同じ名前は増えない)、届いた回数を数える。
    private actor FakeStore: GuardianConsentStoring {
        var fails = false
        private(set) var records: [String: String] = [:]
        private(set) var attempts = 0

        func setFails(_ value: Bool) { fails = value }

        func save(recordName: String, textVersion: String) async throws {
            attempts += 1
            if fails { throw GuardianConsentStoreError.noAccount }
            if records[recordName] == nil { records[recordName] = textVersion }
        }
    }

    private func makeRecords(local: MemoryValueStore = MemoryValueStore(), cloud: MemoryValueStore = MemoryValueStore()) -> OnboardingRecords {
        OnboardingRecords(values: MirroredValues(local: local, cloud: cloud))
    }

    private func profile() -> OnboardingProfile {
        var profile = OnboardingProfile()
        profile.grade = "中1"
        return profile
    }

    private func model(band: AgeBand, records: OnboardingRecords, store: FakeStore = FakeStore(), start: OnboardingStep = .consent) -> OnboardingModel {
        records.saveAge(AgeResult(band: band, declaration: "selfDeclared", checkedAt: Date()))
        records.acceptTerms()
        return OnboardingModel(profile: profile(), records: records, consentUploader: GuardianConsentUploader(records: records, store: store),
                               hasPlan: { false }, isClaudeAvailable: { true }, start: start)
    }

    // MARK: - 出す相手と順番

    func testOnlyUnder16GetsTheGuardianScreenAfterThePhotoConsent() {
        let young = model(band: .under16, records: makeRecords())
        young.acceptPhotoConsent()
        XCTAssertEqual(young.step, .guardian, "写真の扱いの次に保護者の同意")

        for band in [AgeBand.under18, .adult] {
            let other = model(band: band, records: makeRecords())
            other.acceptPhotoConsent()
            XCTAssertEqual(other.step, .trial, "\(band) には保護者の同意を出さない")
        }
    }

    func testSwipeConsentLeavesTheReceiptAndMovesToTheTrial() throws {
        let records = makeRecords()
        let model = model(band: .under16, records: records, start: .guardian)
        let before = Date()
        model.acceptGuardianConsent()
        XCTAssertEqual(model.step, .trial)
        let consent = try XCTUnwrap(records.guardianConsent)
        XCTAssertEqual(consent.textVersion, "v1")
        XCTAssertGreaterThanOrEqual(consent.acceptedAt.timeIntervalSince1970, before.timeIntervalSince1970.rounded(.down))
        XCTAssertNotNil(UUID(uuidString: consent.number), "同意番号は UUID")
        XCTAssertFalse(model.needsGuardianConsent)
    }

    func testTrialAnswerIsNotSentToTheAIWithoutTheGuardianConsent() throws {
        let ledger = try Ledger.inMemory()
        let runner = MockTurnRunner()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(), runner: runner)
        let model = model(band: .under16, records: makeRecords(), start: .trial)
        XCTAssertNotNil(model.problem)
        model.submitAnswer(Data([0xFF, 0xD8]), fromInk: false, assets: AssetCache(), turns: turns, runner: runner)
        XCTAssertEqual(model.step, .trial, "同意の前は採点に送らない")
        XCTAssertNil(model.answerImagePath)
    }

    func testResumeReturnsToTheGuardianScreen() {
        var profile = profile()
        profile.photoConsentAt = "2026-11-06T00:00:00Z"
        profile.resumeStep = OnboardingStep.trial.rawValue
        let age = AgeResult(band: .under16, declaration: "selfDeclared", checkedAt: Date())
        XCTAssertEqual(OnboardingResume.step(profile: profile, age: age, termsAccepted: true, trialUsed: 0, hasPlan: false, hasDraft: false, needsGuardianConsent: true), .guardian)

        // 途中で閉じた: 写真の扱いまで同意して保護者の同意の前に閉じたら、次に開いた時は保護者の同意から。
        let records = makeRecords()
        records.saveAge(age)
        records.acceptTerms()
        let reopened = OnboardingModel(profile: profile, records: records, consentUploader: GuardianConsentUploader(records: records, store: FakeStore()),
                                       hasPlan: { false }, isClaudeAvailable: { true })
        XCTAssertEqual(reopened.step, .guardian)
    }

    func testReinstallWithTheReceiptDoesNotAskAgain() {
        // Keychain と iCloud の Key-Value ストアは入れ直しても残る。回答(UserDefaults)は消える。
        let local = MemoryValueStore()
        let cloud = MemoryValueStore()
        let first = makeRecords(local: local, cloud: cloud)
        first.recordGuardianConsent()
        let reinstalled = makeRecords(local: local, cloud: cloud)
        let model = model(band: .under16, records: reinstalled)
        model.acceptPhotoConsent()
        XCTAssertEqual(model.step, .trial)

        // 別の端末(Keychain は空、iCloud だけ)でも出さない。
        let otherDevice = makeRecords(local: MemoryValueStore(), cloud: cloud)
        XCTAssertFalse(otherDevice.needsGuardianConsent(band: .under16))
    }

    func testNewTextVersionAsksUnder16Again() {
        let records = makeRecords()
        records.recordGuardianConsent(textVersion: "v0")
        XCTAssertTrue(records.needsGuardianConsent(band: .under16), "版が上がったら出し直す")
        XCTAssertFalse(records.needsGuardianConsent(band: .under18))
        XCTAssertFalse(records.needsGuardianConsent(band: .adult))
        XCTAssertFalse(records.needsGuardianConsent(band: nil))
        records.recordGuardianConsent()
        XCTAssertFalse(records.needsGuardianConsent(band: .under16))
    }

    // MARK: - 運営者側の記録

    func testRecordNameIsTheSHA256OfTheConsentNumberAndOnlyTheVersionIsSent() async throws {
        XCTAssertEqual(GuardianConsent.recordName(number: "00000000-0000-0000-0000-000000000000"),
                       "12b9377cbe7e5c94e8a70d9d23929523d14afa954793130f8a3959c7b849aca8")
        XCTAssertEqual(GuardianConsent.recordName(number: "abcdef00-0000-0000-0000-000000000000"),
                       GuardianConsent.recordName(number: "ABCDEF00-0000-0000-0000-000000000000"), "読み上げの大文字・小文字で変わらない")

        let records = makeRecords()
        let store = FakeStore()
        let consent = records.recordGuardianConsent()
        let sent = await GuardianConsentUploader(records: records, store: store).sendPending()
        XCTAssertTrue(sent)
        let saved = await store.records
        XCTAssertEqual(saved, [consent.recordName: "v1"], "公開データベースには同意番号の hash と版だけ")
        XCTAssertFalse(consent.recordName.contains(consent.number.lowercased()))
        XCTAssertNil(records.pendingGuardianConsent)
    }

    func testSendingTheSameConsentAgainDoesNotAddARecord() async {
        let local = MemoryValueStore()
        let cloud = MemoryValueStore()
        let records = makeRecords(local: local, cloud: cloud)
        let store = FakeStore()
        records.recordGuardianConsent()
        await GuardianConsentUploader(records: records, store: store).sendPending()
        // 送った印が届いていない別の端末から、同じ同意番号で送り直す。
        let otherDevice = makeRecords(local: MemoryValueStore(), cloud: MemoryValueStore([OnboardingRecords.guardianConsentKey: cloud.string(OnboardingRecords.guardianConsentKey)!]))
        XCTAssertNotNil(otherDevice.pendingGuardianConsent)
        await GuardianConsentUploader(records: otherDevice, store: store).sendPending()
        let attempts = await store.attempts
        let count = await store.records.count
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(count, 1, "同じ同意番号では増えない")
        // 送れた後は、もう送らない。
        await GuardianConsentUploader(records: records, store: store).sendPending()
        let after = await store.attempts
        XCTAssertEqual(after, 2)
    }

    func testFailedSendDoesNotStopLearningAndIsRetriedLater() async throws {
        let records = makeRecords()
        let store = FakeStore()
        await store.setFails(true)
        let model = model(band: .under16, records: records, store: store, start: .guardian)
        model.acceptGuardianConsent()
        XCTAssertEqual(model.step, .trial, "送れなくても学習に進む")
        // 同意の直後の送信(失敗)が終わるのを待つ。
        var waited = 0
        while await store.attempts == 0, waited < 50 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        let firstAttempts = await store.attempts
        XCTAssertEqual(firstAttempts, 1)
        let pending = try XCTUnwrap(records.pendingGuardianConsent, "未送信の印が残る")

        // 起動時・iCloud のサインインの後に送り直す。
        let uploader = GuardianConsentUploader(records: records, store: store)
        let stillFailing = await uploader.sendPending()
        XCTAssertFalse(stillFailing)
        XCTAssertNotNil(records.pendingGuardianConsent)
        await store.setFails(false)
        let retried = await uploader.sendPending()
        XCTAssertTrue(retried)
        XCTAssertNil(records.pendingGuardianConsent)
        let saved = await store.records
        XCTAssertEqual(saved[pending.recordName], "v1")
        XCTAssertEqual(saved.count, 1)
    }
}
