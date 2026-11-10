import StoreKit
import XCTest
@testable import strius

/// 16 歳未満の保護者の同意(#76): 出す相手と順番、端末の控え、AI へ送る前の門、運営者側の記録(偽の送り先)、
/// 送れなかった時の送り直し、版の出し直し。
@MainActor
final class GuardianConsentTests: XCTestCase {
    /// 偽の送り先。recordName ごとに 1 件だけ持ち(公開データベースと同じく、同じ名前は増えない)、作った回数を数える。
    private actor FakeStore: GuardianConsentStoring {
        struct Saved: Equatable {
            var textVersion: String
            var acceptedAt: Date
        }

        var fails = false
        private(set) var records: [String: Saved] = [:]
        private(set) var creates = 0
        private(set) var reads = 0

        func setFails(_ value: Bool) { fails = value }

        func exists(recordName: String) async throws -> Bool {
            reads += 1
            if fails { throw GuardianConsentStoreError.accountUnavailable }
            return records[recordName] != nil
        }

        func create(recordName: String, textVersion: String, acceptedAt: Date) async throws {
            creates += 1
            if fails { throw GuardianConsentStoreError.accountUnavailable }
            if records[recordName] == nil { records[recordName] = Saved(textVersion: textVersion, acceptedAt: acceptedAt) }
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

    /// 年齢の確認を終え、規約の画面にいる(規約にはまだ同意していない)。
    private func model(band: AgeBand, records: OnboardingRecords, store: FakeStore = FakeStore(), start: OnboardingStep = .terms,
                       reconsent: Bool = false) -> OnboardingModel {
        records.saveAge(AgeResult(band: band, declaration: "selfDeclared", checkedAt: Date()))
        var profile = profile()
        profile.ageBand = band
        return OnboardingModel(profile: profile, records: records, consentUploader: GuardianConsentUploader(records: records, store: store),
                               hasPlan: { false }, isClaudeAvailable: { true }, start: reconsent ? nil : start, reconsent: reconsent)
    }

    // MARK: - 出す相手と順番

    func testUnder16GoesFromTheTermsToTheGuardianScreenInsteadOfWhatIsSent() {
        let young = model(band: .under16, records: makeRecords())
        young.acceptTerms()
        XCTAssertEqual(young.step, .guardian, "16 歳未満は規約の次に保護者の同意(「AI に送る内容」は出さない)")

        for band in [AgeBand.under18, .adult] {
            let other = model(band: band, records: makeRecords())
            other.acceptTerms()
            XCTAssertEqual(other.step, .consent, "\(band) には保護者の同意を出さない")
        }
    }

    func testSwipeConsentLeavesTheReceiptRecordsWhatIsSentAndMovesToTheTrial() throws {
        let records = makeRecords()
        let model = model(band: .under16, records: records, start: .guardian)
        records.acceptTerms()
        let before = Date()
        model.acceptGuardianConsent()
        XCTAssertEqual(model.step, .trial)
        let consent = try XCTUnwrap(records.guardianConsent)
        XCTAssertEqual(consent.textVersion, GuardianConsentText.version)
        XCTAssertGreaterThanOrEqual(consent.acceptedAt.timeIntervalSince1970, before.timeIntervalSince1970.rounded(.down))
        XCTAssertNotNil(UUID(uuidString: consent.number), "同意番号は UUID")
        XCTAssertNotNil(model.profile.photoConsentAt, "保護者が送る内容に同意したので、送る内容への同意も記録する")
        XCTAssertFalse(model.needsGuardianConsent)
        XCTAssertTrue(records.allowsAI)
    }

    func testAIIsNotAllowedForUnder16WithoutTheGuardianConsent() {
        let records = makeRecords()
        records.saveAge(AgeResult(band: .under16, declaration: "selfDeclared", checkedAt: Date()))
        records.acceptTerms()
        XCTAssertFalse(records.allowsAI, "規約に同意していても、保護者の同意が無ければ AI へ送らない")
        records.recordGuardianConsent()
        XCTAssertTrue(records.allowsAI)

        let older = makeRecords()
        older.saveAge(AgeResult(band: .under18, declaration: "selfDeclared", checkedAt: Date()))
        older.acceptTerms()
        XCTAssertTrue(older.allowsAI, "16 歳以上は保護者の同意を要らない")
    }

    func testTrialAnswerIsNotSentToTheAIWithoutTheGuardianConsent() throws {
        let ledger = try Ledger.inMemory()
        let runner = MockTurnRunner()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(), runner: runner)
        let model = model(band: .under16, records: makeRecords(), start: .trial)
        model.startTrial()
        XCTAssertNotNil(model.problem)
        model.submitAnswer(Data([0xFF, 0xD8]), fromInk: false, assets: AssetCache(), turns: turns, runner: runner)
        XCTAssertEqual(model.step, .trial, "同意の前は採点に送らない")
        XCTAssertNil(model.answerImagePath)
    }

    func testResumeReturnsToTheGuardianScreen() {
        let age = AgeResult(band: .under16, declaration: "selfDeclared", checkedAt: Date())
        var profile = profile()
        profile.resumeStep = OnboardingStep.trial.rawValue
        XCTAssertEqual(OnboardingResume.step(profile: profile, age: age, termsAccepted: true, trialUsed: 0, hasPlan: false, hasDraft: false,
                                             needsGuardianConsent: true), .guardian)
        // 送る内容への同意(保護者の同意で記録する)が無ければ、保護者の同意から。
        XCTAssertEqual(OnboardingResume.step(profile: profile, age: age, termsAccepted: true, trialUsed: 0, hasPlan: false, hasDraft: false), .guardian)

        // 規約まで同意して閉じたら、次に開いた時は保護者の同意から。
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
        first.saveAge(AgeResult(band: .under16, declaration: "selfDeclared", checkedAt: Date()))
        first.acceptTerms()
        first.recordGuardianConsent()
        let reinstalled = makeRecords(local: local, cloud: cloud)
        XCTAssertFalse(reinstalled.needsGuardianConsent(band: .under16))
        var profile = profile()
        profile.photoConsentAt = "2026-11-10T00:00:00Z"
        let reopened = OnboardingModel(profile: profile, records: reinstalled,
                                       consentUploader: GuardianConsentUploader(records: reinstalled, store: FakeStore()),
                                       hasPlan: { false }, isClaudeAvailable: { true })
        XCTAssertEqual(reopened.step, .trial)

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

    func testTermsReconsentForUnder16AsksTheGuardianInsteadOfWhatIsSent() {
        let records = makeRecords()
        records.recordGuardianConsent()
        let model = model(band: .under16, records: records, reconsent: true)
        var finished = false
        model.onReconsented = { finished = true }
        XCTAssertEqual(model.step, .terms)
        model.acceptTerms()
        XCTAssertEqual(model.step, .guardian, "規約が変わったので、保護者にも同意し直してもらう")
        model.acceptGuardianConsent()
        XCTAssertTrue(finished)
    }

    // MARK: - 運営者側の記録

    func testRecordNameIsTheSHA256OfTheConsentNumberAndOnlyTheVersionAndTimeAreSent() async throws {
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
        XCTAssertEqual(saved, [consent.recordName: FakeStore.Saved(textVersion: GuardianConsentText.version, acceptedAt: consent.acceptedAt)],
                       "公開データベースには同意番号の hash と、版と、端末で同意した時刻だけ")
        XCTAssertFalse(consent.recordName.contains(consent.number.lowercased()))
        XCTAssertNil(records.pendingGuardianConsent)
    }

    func testSendingTheSameConsentAgainReadsFirstAndDoesNotCreateIt() async {
        let cloud = MemoryValueStore()
        let records = makeRecords(cloud: cloud)
        let store = FakeStore()
        records.recordGuardianConsent()
        await GuardianConsentUploader(records: records, store: store).sendPending()
        // 送った印が届いていない別の端末から、同じ同意番号で送り直す。
        let otherDevice = makeRecords(cloud: MemoryValueStore([OnboardingRecords.guardianConsentKey: cloud.string(OnboardingRecords.guardianConsentKey)!]))
        XCTAssertNotNil(otherDevice.pendingGuardianConsent)
        let sent = await GuardianConsentUploader(records: otherDevice, store: store).sendPending()
        XCTAssertTrue(sent, "既にあれば送信済みにする")
        XCTAssertNil(otherDevice.pendingGuardianConsent)
        let creates = await store.creates
        let count = await store.records.count
        XCTAssertEqual(creates, 1, "既にある記録は作り直さない(本人に書き換えの権限は無い)")
        XCTAssertEqual(count, 1)
        // 送れた後は、もう送らない。
        await GuardianConsentUploader(records: records, store: store).sendPending()
        let reads = await store.reads
        XCTAssertEqual(reads, 2)
    }

    func testFailedSendDoesNotStopLearningAndIsRetriedLater() async throws {
        let records = makeRecords()
        let store = FakeStore()
        await store.setFails(true)
        let model = model(band: .under16, records: records, store: store, start: .guardian)
        records.acceptTerms()
        model.acceptGuardianConsent()
        XCTAssertEqual(model.step, .trial, "送れなくても学習に進む")
        // 同意の直後の送信(失敗)が終わるのを待つ。
        var waited = 0
        while await store.reads == 0, waited < 50 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        let pending = try XCTUnwrap(records.pendingGuardianConsent, "未送信の印が残る")

        // タイムラインを開いた時・iCloud のアカウントが変わった後に送り直す。
        let uploader = GuardianConsentUploader(records: records, store: store)
        let stillFailing = await uploader.sendPending()
        XCTAssertFalse(stillFailing)
        XCTAssertNotNil(records.pendingGuardianConsent)
        await store.setFails(false)
        let retried = await uploader.sendPending()
        XCTAssertTrue(retried)
        XCTAssertNil(records.pendingGuardianConsent)
        let saved = await store.records
        XCTAssertEqual(saved[pending.recordName]?.textVersion, GuardianConsentText.version)
        XCTAssertEqual(saved[pending.recordName]?.acceptedAt, pending.acceptedAt, "送れた時刻ではなく、端末で同意した時刻を残す")
        XCTAssertEqual(saved.count, 1)
    }

    // MARK: - 購入の記録

    func testUnder16WithTheReceiptPurchasesWithTheConsentNumber() throws {
        let records = makeRecords()
        XCTAssertTrue(records.purchaseOptions.isEmpty)
        records.saveAge(AgeResult(band: .under16, declaration: "selfDeclared", checkedAt: Date()))
        XCTAssertTrue(records.purchaseOptions.isEmpty, "同意の控えが無ければ付けない")
        let consent = records.recordGuardianConsent()
        XCTAssertEqual(records.purchaseOptions, [.appAccountToken(consent.id)])
    }
}
