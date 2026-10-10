import SwiftUI
import UIKit

/// 整理中(候補あり: はい / 別の問題。候補なし: 問題を選ぶ) と
/// どの問題？(候補 3 件、検索、新しい問題として綴じる、新しい小単元に)。
struct WorkbookTriageView: View {
    @Environment(WorkbookStore.self) private var store
    @Environment(WorkbookCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    let captureID: String
    @State private var image: UIImage?
    @State private var isChoosing = false
    @State private var isAssigning = false
    /// 綴じる先を関係の深い順に並べ、先頭の数件だけ出す。残りは「ほかの小単元」で開く。
    @State private var showsAllDestinations = false

    private var capture: WorkbookCaptureDTO? { store.captures[captureID] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let capture {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                    paperItems(capture)
                    if let error = store.actionError {
                        Text(error)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.regress(scheme))
                            .onTapGesture { store.actionError = nil }
                    }
                    if capture.status != .triage {
                        Button("判定を見る") { coordinator.path.removeLast(); coordinator.open(.capture(capture.id)) }
                            .buttonStyle(.bordered)
                    } else if isChoosing || capture.candidates.isEmpty {
                        chooser(capture)
                    } else {
                        candidateQuestion(capture)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle(isChoosing || capture?.candidates.isEmpty == true ? "どの問題？" : "整理中")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: captureID) {
            await store.loadCapture(id: captureID)
            image = await store.captureImage(id: captureID)
        }
        .accessibilityIdentifier("workbook-triage")
    }

    /// 紙から読み取った問題をすべて出す(D12: 1 枚に複数の問題があっても問 1 だけにしない)。
    @ViewBuilder
    private func paperItems(_ capture: WorkbookCaptureDTO) -> some View {
        let items = capture.verdicts.filter { !$0.promptText.isEmpty }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if items.count > 1 {
                    Text("この紙の問題 \(items.count) 問")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if items.count > 1, !item.label.isEmpty {
                            Text(item.label)
                                .font(Typography.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        WorkbookPromptText(text: item.promptText, lineLimit: 3)
                    }
                }
            }
            .accessibilityIdentifier("workbook-triage-items")
        }
    }

    /// 2 問目以降の扱い(既存の問題を選んだ時)。
    @ViewBuilder
    private func restNote(_ capture: WorkbookCaptureDTO) -> some View {
        let count = capture.verdicts.count
        if count > 1 {
            Text("ほかの \(count - 1) 問は、同じ小単元に新しい問題として綴じます。")
                .font(Typography.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func candidateQuestion(_ capture: WorkbookCaptureDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let top = capture.candidates.first {
                candidateCard(top)
                restNote(capture)
                HStack(spacing: 12) {
                    Button {
                        assign(WorkbookAssignRequest(problemId: top.problemId))
                    } label: {
                        Text("はい").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAssigning)
                    .accessibilityIdentifier("workbook-triage-yes")
                    Button {
                        isChoosing = true
                    } label: {
                        Text("別の問題").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isAssigning)
                    .accessibilityIdentifier("workbook-triage-other")
                }
            }
        }
    }

    private func chooser(_ capture: WorkbookCaptureDTO) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !capture.candidates.isEmpty {
                Text("候補")
                    .font(Typography.eyebrow)
                    .foregroundStyle(Theme.secondaryText)
                ForEach(capture.candidates) { candidate in
                    Button {
                        assign(WorkbookAssignRequest(problemId: candidate.problemId))
                    } label: {
                        candidateCard(candidate)
                    }
                    .buttonStyle(.plain)
                    .disabled(isAssigning)
                }
            }
            WorkbookProblemPicker(excluding: Set(capture.candidates.map(\.problemId))) { tile in
                assign(WorkbookAssignRequest(problemId: tile.id))
            }
            restNote(capture)
            Text("綴じる先")
                .font(Typography.eyebrow)
                .foregroundStyle(Theme.secondaryText)
            let ranked = rankedDestinations(capture)
            ForEach(showsAllDestinations ? ranked : Array(ranked.prefix(Self.visibleDestinations))) { subunit in
                Button {
                    assign(WorkbookAssignRequest(newProblem: .init(subunitId: subunit.id)))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("新しい問題として綴じる")
                                .font(Typography.bodyEmphasized)
                            Text("\(subunit.unitTitle) · \(subunit.title)")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "plus.square").foregroundStyle(Theme.secondaryText)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .struisSurface(radius: Theme.Radius.stat)
                }
                .buttonStyle(.plain)
                .disabled(isAssigning)
                .accessibilityIdentifier("workbook-triage-destination-\(subunit.id)")
            }
            if !showsAllDestinations, ranked.count > Self.visibleDestinations {
                Button("ほかの小単元(\(ranked.count - Self.visibleDestinations))") { showsAllDestinations = true }
                    .font(Typography.caption)
                    .accessibilityIdentifier("workbook-triage-more-destinations")
            }
            NewSubunitForm(units: store.home?.units ?? [], isBusy: isAssigning) { request in
                assign(WorkbookAssignRequest(newSubunit: request))
            }
        }
    }

    private static let visibleDestinations = 4

    /// 綴じる先の小単元を、この紙との関係の深い順に(D12)。すべての単元の小単元から選べる。
    private func rankedDestinations(_ capture: WorkbookCaptureDTO) -> [WorkbookSubunitDTO] {
        let all = (store.home?.units ?? []).flatMap(\.subunits)
        let subunits = all.isEmpty ? store.activeSubunits : all
        return WorkbookTriageRanking.rank(
            subunits: subunits,
            paperText: capture.verdicts.map(\.promptText).joined(separator: "\n"),
            candidateSubunitIDs: capture.candidates.map(\.subunitId)
        )
    }

    private func candidateCard(_ candidate: WorkbookCaptureCandidateDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(candidate.subunitTitle)
                .font(Typography.micro)
                .foregroundStyle(Theme.secondaryText)
            // 同じ書き出し(「次の式の括弧を外し…」)の問題が並んでも区別できるように、式を先に出す(D12)。
            WorkbookPromptText(text: WorkbookTriageRanking.distinguishing(candidate.prompt), lineLimit: 3)
            if !candidate.reason.isEmpty {
                Text(candidate.reason)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .struisSurface(radius: Theme.Radius.stat)
    }

    private func assign(_ request: WorkbookAssignRequest) {
        guard !isAssigning else { return }
        isAssigning = true
        Task {
            if let assigned = await store.assign(captureID: captureID, request: request) {
                coordinator.path.removeLast()
                coordinator.open(.capture(assigned.id))
            }
            isAssigning = false
        }
    }
}

/// 全マスから検索して選ぶ。
struct WorkbookProblemPicker: View {
    @Environment(WorkbookStore.self) private var store
    let excluding: Set<String>
    let onPick: (WorkbookProblemTileDTO) -> Void
    @State private var query = ""

    private var matches: [(subunit: WorkbookSubunitDTO, tile: WorkbookProblemTileDTO)] {
        let all = store.allProblemTiles.filter { !excluding.contains($0.tile.id) }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(all.prefix(6)) }
        return all.filter { $0.tile.prompt.localizedCaseInsensitiveContains(trimmed) || $0.subunit.title.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("問題を探す", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workbook-problem-search")
            ForEach(matches, id: \.tile.id) { item in
                Button {
                    onPick(item.tile)
                } label: {
                    HStack(spacing: 10) {
                        WorkbookTile(state: item.tile.state, assisted: item.tile.assisted, size: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            WorkbookPromptText(text: WorkbookTriageRanking.distinguishing(item.tile.prompt), lineLimit: 1)
                            Text(item.subunit.title)
                                .font(Typography.micro)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .struisSurface(radius: Theme.Radius.stat)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 新しい小単元に綴じる。単元は既存から選ぶか、新しく立てる。
struct NewSubunitForm: View {
    let units: [WorkbookUnitDTO]
    let isBusy: Bool
    let onSubmit: (WorkbookAssignRequest.NewSubunit) -> Void
    @State private var title = ""
    @State private var unitTitle = ""
    @State private var unitID: String?
    @State private var n = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("新しい小単元に")
                .font(Typography.eyebrow)
                .foregroundStyle(Theme.secondaryText)
            TextField("小単元の名前", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workbook-new-subunit-title")
            if !units.isEmpty {
                Picker("単元", selection: $unitID) {
                    Text("新しい単元").tag(String?.none)
                    ForEach(units) { unit in
                        Text(unit.title).tag(String?.some(unit.id))
                    }
                }
                .pickerStyle(.menu)
            }
            if unitID == nil {
                TextField("単元の名前", text: $unitTitle)
                    .textFieldStyle(.roundedBorder)
            }
            Stepper("問題数 \(n)", value: $n, in: 1...100)
                .font(Typography.body)
            Button {
                onSubmit(.init(unitId: unitID, unitTitle: unitTitle, title: title, n: n))
            } label: {
                Text("綴じる").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy || title.trimmingCharacters(in: .whitespaces).isEmpty || (unitID == nil && unitTitle.trimmingCharacters(in: .whitespaces).isEmpty))
        }
    }
}

/// 整理中の画面の並べ方と見せ方(D12)。
enum WorkbookTriageRanking {
    /// 小単元を、この紙との関係の深い順に。紙の文と小単元の名前・到達目標・
    /// 単元名で共通する語(漢字・カタカナ・英数字の 2 文字ずつ)の多い順。同じなら判定が候補に挙げた問題の小単元、学習中の順に先に、
    /// 元の順を保つ(候補は外れていることがあるので、語の重なりより優先しない。E2E s9)。
    static func rank(subunits: [WorkbookSubunitDTO], paperText: String, candidateSubunitIDs: [String]) -> [WorkbookSubunitDTO] {
        let paper = bigrams(MathPlainText.readable(paperText))
        let candidates = Set(candidateSubunitIDs)
        let scored = subunits.enumerated().map { index, subunit -> (score: Int, index: Int, subunit: WorkbookSubunitDTO) in
            let words = bigrams([subunit.title, subunit.outcome, subunit.unitTitle].joined(separator: " "))
            var score = paper.intersection(words).count * 10
            if candidates.contains(subunit.id) { score += 5 }
            if subunit.status == .active { score += 1 }
            return (score, index, subunit)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map(\.subunit)
    }

    /// 区別に使う語。漢字・カタカナ・英数字の続きを 2 文字ずつに切る(ひらがなは助詞や送り仮名なので使わない)。
    static func bigrams(_ text: String) -> Set<String> {
        var result: Set<String> = []
        var run: [Character] = []
        func flush() {
            if run.count >= 2 {
                for index in 0..<(run.count - 1) { result.insert(String(run[index...index + 1]).lowercased()) }
            }
            run.removeAll()
        }
        for char in text {
            if isContentCharacter(char) { run.append(char) } else { flush() }
        }
        flush()
        return result
    }

    private static func isContentCharacter(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x30A0...0x30FF: return true  // 漢字・カタカナ
        default: return char.isASCII && (char.isLetter || char.isNumber)
        }
    }

    private static let mathSegment = try! NSRegularExpression(
        pattern: #"\$\$(.+?)\$\$|\\\[(.+?)\\\]|\\\((.+?)\\\)|\$([^$\n]+?)\$"#, options: [.dotMatchesLineSeparators]
    )

    /// 問題文を、式を先に出す形にする(同じ書き出しの問題を区別できるように)。式が無ければそのまま。
    static func distinguishing(_ prompt: String) -> String {
        let source = WorkbookMathSource.withInlineMath(prompt)
        let range = NSRange(source.startIndex..., in: source)
        let formulas = mathSegment.matches(in: source, range: range).compactMap { match in
            Range(match.range, in: source).map { String(source[$0]) }
        }
        guard !formulas.isEmpty else { return prompt }
        var rest = source
        for formula in formulas { rest = rest.replacingOccurrences(of: formula, with: "…") }
        let instruction = rest.replacingOccurrences(of: #"(…\s*)+"#, with: "… ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return formulas.joined(separator: "　") + (instruction.isEmpty ? "" : "\n" + instruction)
    }
}
