import CloudKit
import CryptoKit
import Foundation
import OSLog
import StoreKit

nonisolated private let consentLog = Logger(subsystem: "com.digiloglab.strius", category: "guardian-consent")

/// 16 歳未満の保護者の同意の文面(#76)。版を上げると、保存した版と違う `under16` の利用者に同意の画面を出し直す。
/// 規約の版(`LegalVersion.terms`)とは別の値。
nonisolated enum GuardianConsentText {
    static let version = "v1"
    static let title = "保護者の方へ"
    static let lead = "お子さまが Struis を使うには、保護者の方の同意が必要です。この画面は保護者の方が読んで操作してください。"
    static let renewalTitle = "保護者の同意の内容を新しくしました"
    static let renewalLead = "続けて使うには、保護者の方の同意がもう一度必要です。今の内容は次のとおりです。"
    static let badge = "保護者の方が操作します"
    static let swipe = "保護者として同意する"
    static let swiped = "同意しました"
    static let note = "スワイプすると、保護者として利用規約・プライバシーポリシーと上の内容に同意したことになります。同意した日時は運営者にも記録されます(お名前などは記録しません)。"
    static let afterNote = "同意しました。お試しの1問に進みます。"
}

/// 端末に残す同意の控え(`OnboardingRecords`)。同意番号は問い合わせの時に利用者が読み上げる。
nonisolated struct GuardianConsent: Codable, Hashable, Sendable {
    var id: UUID
    var acceptedAt: Date
    var textVersion: String

    /// 設定に出す同意番号(大文字の UUID)。購入の `appAccountToken` にも同じ値を付ける。
    var number: String { id.uuidString }

    /// 公開データベースの recordName: 同意番号(大文字の UUID の文字列)の SHA-256 の 16 進。
    /// 公開データベースに同意番号そのものは置かない。
    var recordName: String { Self.recordName(number: number) }

    static func recordName(number: String) -> String {
        SHA256.hash(data: Data(number.uppercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 運営者側に残す同意の記録の送り先。
nonisolated protocol GuardianConsentStoring: Sendable {
    /// 同じ recordName の記録が既にあるか。
    func exists(recordName: String) async throws -> Bool
    /// 新しく作る(本人に書き換えの権限は無いので、既にある記録には使わない)。
    func create(recordName: String, textVersion: String, acceptedAt: Date) async throws
}

nonisolated enum GuardianConsentStoreError: Error {
    /// iCloud が使えない(サインインしていない・制限されている・一時的に使えない)。公開データベースに書けない。
    case accountUnavailable
}

/// CloudKit の公開データベース(`iCloud.com.digiloglab.strius`)の `GuardianConsent`。
/// フィールドは `textVersion` と、端末で同意した時刻の `acceptedAt`。送れた時刻は CloudKit の `creationDate` に残る。
/// 権限: Authenticated は作るだけ、Creator は読むだけ、World は何もできない(他の利用者からは読めない)。
nonisolated struct CloudKitGuardianConsentStore: GuardianConsentStoring {
    static let recordType = "GuardianConsent"

    private var database: CKDatabase { CKContainer(identifier: CloudKitSyncTransport.containerIdentifier).publicCloudDatabase }

    private func requireAccount() async throws {
        let status = try await CKContainer(identifier: CloudKitSyncTransport.containerIdentifier).accountStatus()
        guard status == .available else { throw GuardianConsentStoreError.accountUnavailable }
    }

    func exists(recordName: String) async throws -> Bool {
        try await requireAccount()
        do {
            _ = try await database.record(for: CKRecord.ID(recordName: recordName))
            return true
        } catch let error as CKError where error.code == .unknownItem {
            return false
        }
    }

    func create(recordName: String, textVersion: String, acceptedAt: Date) async throws {
        try await requireAccount()
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: recordName))
        record["textVersion"] = textVersion as CKRecordValue
        record["acceptedAt"] = acceptedAt as CKRecordValue
        let (results, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
        guard let result = results[record.recordID] else { return }
        do {
            _ = try result.get()
        } catch let error as CKError where error.code == .serverRecordChanged {
            // 読んだ後に別の端末が先に作った(同じ控えを iCloud で共有している)。記録は 1 件のまま。
            consentLog.info("guardian consent already recorded")
        }
    }
}

#if DEBUG
/// 画面の確認用(`STRUIS_GUARDIAN_CONSENT_STORE=ok|fail`): CloudKit に送らず、成功か失敗を返す。
nonisolated struct DebugGuardianConsentStore: GuardianConsentStoring {
    let succeeds: Bool

    func exists(recordName: String) async throws -> Bool {
        if !succeeds { throw GuardianConsentStoreError.accountUnavailable }
        return false
    }

    func create(recordName: String, textVersion: String, acceptedAt: Date) async throws {
        consentLog.info("debug guardian consent \(recordName, privacy: .public) \(textVersion, privacy: .public) ok=\(succeeds)")
        if !succeeds { throw GuardianConsentStoreError.accountUnavailable }
    }
}
#endif

/// 未送信の同意の記録を送る。同意の直後・タイムラインを開いた時・iCloud のアカウントが変わった後に呼ぶ。
/// 送れなければ未送信の印を残したまま、次に送り直す。
actor GuardianConsentUploader {
    static let shared = GuardianConsentUploader(records: .shared, store: GuardianConsentUploader.defaultStore())

    private let records: OnboardingRecords
    private let store: any GuardianConsentStoring
    private var isSending = false

    init(records: OnboardingRecords, store: any GuardianConsentStoring) {
        self.records = records
        self.store = store
    }

    private static func defaultStore() -> any GuardianConsentStoring {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["STRUIS_GUARDIAN_CONSENT_STORE"] { return DebugGuardianConsentStore(succeeds: mode == "ok") }
        #endif
        return CloudKitGuardianConsentStore()
    }

    /// 送れた(か、送る物が無い)なら true。
    @discardableResult
    func sendPending() async -> Bool {
        guard let consent = records.pendingGuardianConsent else { return true }
        guard !isSending else { return false }
        isSending = true
        defer { isSending = false }
        do {
            // 先に読む: 入れ直した端末や別の端末から、同じ同意番号で送り直した時に増やさない。
            if try await !store.exists(recordName: consent.recordName) {
                try await store.create(recordName: consent.recordName, textVersion: consent.textVersion, acceptedAt: consent.acceptedAt)
            }
            records.markGuardianConsentSent(consent)
            await MainActor.run { NotificationCenter.default.post(name: .guardianConsentChanged, object: nil) }
            return true
        } catch {
            consentLog.error("guardian consent not sent: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

extension Notification.Name {
    /// 同意の控えか、送った印が変わった(設定の表示を読み直す)。
    nonisolated static let guardianConsentChanged = Notification.Name("struis.guardianConsentChanged")
}

extension OnboardingRecords {
    /// 購入に付ける項目: 16 歳未満で同意の控えがあれば、同意番号を `appAccountToken` にする
    /// (iCloud が使えない利用者でも、Apple の購入記録に同意番号が残る)。
    var purchaseOptions: Set<Product.PurchaseOption> {
        guard age?.band == .under16, let consent = guardianConsent else { return [] }
        return [.appAccountToken(consent.id)]
    }
}
