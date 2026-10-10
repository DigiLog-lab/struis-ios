import SwiftUI
import UIKit
import GRDB

struct LearningProgressSelection: Identifiable {
    let threadID: UUID
    let messageID: UUID
    var id: UUID { messageID }
}

struct LearningProgressRecord: Codable, Sendable {
    let schemaVersion: Int
    let messageId: String
    let revision: Int
    let saveStatus: String
    let summary: Summary
    let ancestors: [Ancestor]
    let evidence: [Evidence]
    let trials: [Trial]
    let before: Position
    let after: Position
    let conditions: [String]
    let issues: [String]

    struct Summary: Codable, Sendable {
        let currentGoal: String?
        let currentStage: String?
        let completedActions: [String]
        let nextAction: String?
        let waitReason: String?
    }
    struct Position: Codable, Sendable {
        let currentGoal: String?
        let currentStage: String?
        let nextAction: String?
        let waitReason: String?
    }
    struct Ancestor: Codable, Sendable {
        let id: String
        let title: String
        let status: String
    }
    struct Evidence: Codable, Sendable {
        let messageId: String
        let summary: String
    }
    struct Trial: Codable, Sendable {
        let problemId: String
        let submissionId: String
        let score: Double
        let assisted: Bool
        let feedback: String
    }

    func verificationText() throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

struct LearningProgressSheet: View {
    let selection: LearningProgressSelection
    @Environment(LearnerData.self) private var learnerData
    @Environment(\.dismiss) private var dismiss
    @State private var record: LearningProgressRecord?
    @State private var isLoading = true
    @State private var copied = false
    @State private var copyFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("進行を読み込んでいます")
                } else if let record {
                    content(record)
                } else {
                    ContentUnavailableView {
                        Label("進行を取得できませんでした", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("通信状態を確認して、もう一度お試しください。")
                    } actions: {
                        Button("再読み込み") { Task { await load() } }
                    }
                }
            }
            .navigationTitle("学習の進行")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func content(_ record: LearningProgressRecord) -> some View {
        List {
            if record.saveStatus == "not_recorded" {
                Section {
                    Text("この返信には進行の記録がありません。")
                }
            } else {
                if record.saveStatus != "saved" {
                    Section {
                        Label("今回の進行更新は保存されていません", systemImage: "exclamationmark.circle")
                    }
                }
                Section("今の取り組み") {
                    row("目標", record.summary.currentGoal)
                    row("段階", record.summary.currentStage)
                }
                Section("今回の完了") {
                    if record.summary.completedActions.isEmpty {
                        Text("完了した作業の記録はありません。")
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        strings(record.summary.completedActions)
                    }
                }
                Section("次の行動") {
                    row("次にすること", record.summary.nextAction)
                    if let reason = record.summary.waitReason, !reason.isEmpty {
                        row("待っていること", reason)
                    }
                }
                Section("評価の根拠") {
                    if record.evidence.isEmpty {
                        Text("習得を確認する新しい証拠はありません。")
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        ForEach(Array(record.evidence.suffix(2).enumerated()), id: \.offset) { _, evidence in
                            Text(evidence.summary)
                        }
                        if record.evidence.count > 2 {
                            DisclosureGroup("ほかの根拠") {
                                ForEach(Array(record.evidence.dropLast(2).enumerated()), id: \.offset) { _, evidence in
                                    Text(evidence.summary)
                                }
                            }
                        }
                    }
                }
                Section {
                    DisclosureGroup("親ゴール") {
                        if record.ancestors.isEmpty { Text("親ゴールはありません。") }
                        ForEach(Array(record.ancestors.enumerated()), id: \.offset) { _, goal in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(goal.title)
                                Text(statusTitle(goal.status)).font(.caption).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                    DisclosureGroup("試行履歴") {
                        if record.trials.isEmpty { Text("試行の記録はありません。") }
                        ForEach(Array(record.trials.enumerated()), id: \.offset) { index, trial in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("試行 \(index + 1)・\(trial.assisted ? "支援あり" : "自力解答")")
                                    .font(.subheadline.weight(.medium))
                                Text("得点：\(trial.score.formatted(.number.precision(.fractionLength(0...2))))")
                                if !trial.feedback.isEmpty { Text(trial.feedback) }
                            }
                        }
                    }
                    DisclosureGroup("判定条件と更新内容") {
                        if !record.conditions.isEmpty { strings(record.conditions) }
                        Text("更新前").font(.subheadline.weight(.medium))
                        position(record.before)
                        Text("更新後").font(.subheadline.weight(.medium))
                        position(record.after)
                        Text(record.saveStatus == "saved" ? "保存済み" : "未保存")
                        strings(record.issues)
                    }
                }
            }
            Section {
                Button(copied ? "コピーしました" : "この返信の検証情報をコピー", systemImage: "doc.on.doc") {
                    do {
                        UIPasteboard.general.string = try record.verificationText()
                        copied = true
                        copyFailed = false
                    } catch { copyFailed = true }
                }
                .accessibilityIdentifier("learning-progress-copy")
                if copyFailed { Text("コピーできませんでした。もう一度お試しください。") }
            }
        }
        .accessibilityIdentifier("learning-progress-details")
    }

    private func row(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.secondaryText)
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "記録なし")
        }
    }

    private func strings(_ values: [String]) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { _, value in Text(value) }
    }

    private func position(_ value: LearningProgressRecord.Position) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row("目標", value.currentGoal)
            row("段階", value.currentStage)
            row("次にすること", value.nextAction)
            if let reason = value.waitReason { row("待っていること", reason) }
        }
    }

    private func statusTitle(_ value: String) -> String {
        switch value {
        case "completed": "完了"
        case "active", "in_progress": "進行中"
        case "waiting", "waiting_input": "入力待ち"
        case "paused": "中断中"
        case "pending", "planned": "未着手"
        case "blocked", "stalled": "見直し中"
        default: "未達"
        }
    }

    private func load() async {
        isLoading = true
        copied = false
        do {
            let messageID = selection.messageID.uuidString.lowercased()
            let trace: LedgerJSON? = try await learnerData.ledger.read { db in
                guard let message = try MessageRecord.fetchOne(db, key: messageID), message.role == "assistant" else { return nil }
                return message.metadata["learning_progress"] ?? .emptyObject
            }
            guard !Task.isCancelled, let trace else { record = nil; isLoading = false; return }
            let publicTrace = try LearningProgress.publicTrace(trace: trace.any as? JSONObject ?? [:], messageID: messageID)
            let data = try JSONSerialization.data(withJSONObject: publicTrace)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(LearningProgressRecord.self, from: data)
            guard result.schemaVersion == 1,
                  result.messageId.lowercased() == messageID,
                  ["saved", "rejected", "not_recorded"].contains(result.saveStatus) else {
                record = nil
                isLoading = false
                return
            }
            record = result
        } catch {
            guard !Task.isCancelled else { return }
            record = nil
        }
        isLoading = false
    }
}
