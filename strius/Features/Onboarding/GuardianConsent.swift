import CloudKit
import CryptoKit
import Foundation
import OSLog

nonisolated private let consentLog = Logger(subsystem: "com.digiloglab.strius", category: "guardian-consent")

/// 16 歳未満の保護者の同意の文面(#76)。版を上げると、保存した版と違う `under16` の利用者に同意の画面を出し直す。
/// 規約の版(#78)とは別の値。
nonisolated enum GuardianConsentText {
    static let version = "v1"
    static let title = "保護者の方へ"
    static let lead = "お子さまが Struis を使うには、保護者の方の同意が必要です。次の内容をお読みください。"
    static let points = [
        "答案や写真、質問などは、採点と説明のために米国の Anthropic に送られます。",
        "学習の記録は端末と iCloud に保存され、運営者は読めません。",
        "採点と説明は AI が行うため、間違えることがあります。",
    ]
    static let swipe = "保護者として同意する"
}

/// 端末に残す同意の控え(`OnboardingRecords`)。同意番号は問い合わせの時に利用者が読み上げる。
nonisolated struct GuardianConsent: Codable, Hashable, Sendable {
    var id: UUID
    var acceptedAt: Date
    var textVersion: String

    /// 設定に出す同意番号(大文字の UUID)。
    var number: String { id.uuidString }

    /// 公開データベースの recordName: 同意番号(大文字の UUID の文字列)の SHA-256 の 16 進。
    /// 公開データベースは全利用者が読めるので、同意番号そのものは置かない。
    var recordName: String { Self.recordName(number: number) }

    static func recordName(number: String) -> String {
        SHA256.hash(data: Data(number.uppercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 運営者側に残す同意の記録の送り先。
nonisolated protocol GuardianConsentStoring: Sendable {
    /// 同じ recordName で 2 回送っても、記録は 1 件のまま(既にあれば成功として返す)。
    func save(recordName: String, textVersion: String) async throws
}

nonisolated enum GuardianConsentStoreError: Error {
    /// iCloud にサインインしていない(公開データベースに書けない)。
    case noAccount
}

/// CloudKit の公開データベース(`iCloud.com.digiloglab.strius`)の `GuardianConsent`。フィールドは `textVersion` だけで、
/// 同意の日時は CloudKit が保存時に付ける `creationDate`。
nonisolated struct CloudKitGuardianConsentStore: GuardianConsentStoring {
    static let recordType = "GuardianConsent"

    func save(recordName: String, textVersion: String) async throws {
        let container = CKContainer(identifier: CloudKitSyncTransport.containerIdentifier)
        guard try await container.accountStatus() == .available else { throw GuardianConsentStoreError.noAccount }
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: recordName))
        record["textVersion"] = textVersion as CKRecordValue
        // 既にある記録は書き換えない(`ifServerRecordUnchanged` で同じ recordName は serverRecordChanged になる)。
        let (results, _) = try await container.publicCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
        guard let result = results[record.recordID] else { return }
        do {
            _ = try result.get()
        } catch let error as CKError where error.code == .serverRecordChanged {
            consentLog.info("guardian consent already recorded")
        }
    }
}

#if DEBUG
/// 画面の確認用(`STRUIS_GUARDIAN_CONSENT_STORE=ok|fail`): CloudKit に送らず、成功か失敗を返す。
nonisolated struct DebugGuardianConsentStore: GuardianConsentStoring {
    let succeeds: Bool

    func save(recordName: String, textVersion: String) async throws {
        consentLog.info("debug guardian consent save \(recordName, privacy: .public) \(textVersion, privacy: .public) ok=\(succeeds)")
        if !succeeds { throw GuardianConsentStoreError.noAccount }
    }
}
#endif

/// 未送信の同意の記録を送る。同意の直後・起動時・iCloud のサインインの後に呼ぶ。送れなければ未送信の印を残したまま、次に送り直す。
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
            try await store.save(recordName: consent.recordName, textVersion: consent.textVersion)
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
