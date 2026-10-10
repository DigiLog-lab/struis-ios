import SwiftUI

enum ProblemCatalogTileState: String {
    case solved
    case retry
    case notStarted = "not_started"

    init(rawTileState: String) {
        self = ProblemCatalogTileState(rawValue: rawTileState) ?? .notStarted
    }

    var label: String {
        switch self {
        case .solved: "正解済み"
        case .retry: "解き直し待ち"
        case .notStarted: "未着手"
        }
    }
}

/// 正解済みマスの濃淡は装飾ではなく習熟度を運ぶ。
enum ProblemCatalogMastery {
    /// 一発正解、または繰り返し正解している
    case mastered
    /// ミスを経てから正解した
    case solved
    /// 正解はしたが、最後の挑戦から30日以上空いている
    case fading

    static let fadingInterval: TimeInterval = 30 * 24 * 60 * 60

    static func level(
        for progress: ProblemCatalogProgressDTO,
        now: Date = Date()
    ) -> ProblemCatalogMastery {
        if let lastAttempt = ProblemCatalogDateFormatting.date(fromISO: progress.lastAttemptAt),
           now.timeIntervalSince(lastAttempt) > fadingInterval {
            return .fading
        }
        if progress.correctCount >= 2 || progress.attemptCount == progress.correctCount {
            return .mastered
        }
        return .solved
    }

    var label: String {
        switch self {
        case .mastered: "定着"
        case .solved: "正解済み"
        case .fading: "忘れかけ"
        }
    }
}

enum ProblemCatalogSheetPalette {
    static let solvedDeep = Color(red: 0.03, green: 0.31, blue: 0.25)
    static let solvedStandard = Color(red: 0.11, green: 0.62, blue: 0.46)
    static let solvedFading = Color(red: 0.62, green: 0.88, blue: 0.80)

    static func solvedColor(for slot: ProblemCatalogSheetSlotDTO) -> Color {
        switch ProblemCatalogMastery.level(for: slot.progress) {
        case .mastered: solvedDeep
        case .solved: solvedStandard
        case .fading: solvedFading
        }
    }

    static let retry = Color.orange
    static let organizing = Color.yellow
    static let completed = Color.indigo
}

struct ProblemCatalogTileView: View {
    let slot: ProblemCatalogSheetSlotDTO

    private var state: ProblemCatalogTileState {
        ProblemCatalogTileState(rawTileState: slot.tileState)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fillStyle)
            .overlay {
                switch state {
                case .retry:
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(ProblemCatalogSheetPalette.retry, lineWidth: 1.5)
                case .notStarted:
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            .quaternary,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                case .solved:
                    EmptyView()
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel("\(slot.title)、\(accessibilityStateLabel)")
    }

    private var accessibilityStateLabel: String {
        state == .solved
            ? ProblemCatalogMastery.level(for: slot.progress).label
            : state.label
    }

    private var fillStyle: AnyShapeStyle {
        switch state {
        case .solved:
            AnyShapeStyle(ProblemCatalogSheetPalette.solvedColor(for: slot))
        case .retry:
            AnyShapeStyle(ProblemCatalogSheetPalette.retry.opacity(0.16))
        case .notStarted:
            AnyShapeStyle(.quaternary.opacity(0.5))
        }
    }
}

/// 長押しプレビュー(contextMenu)で見せる、その問題のちょい見せカード。
struct ProblemCatalogTilePreviewCard: View {
    let slot: ProblemCatalogSheetSlotDTO

    private var state: ProblemCatalogTileState {
        ProblemCatalogTileState(rawTileState: slot.tileState)
    }

    private var hasPrompt: Bool {
        slot.promptPreview?.nilIfBlankValue != nil
    }

    private var detailText: String {
        var parts: [String] = []
        if state == .solved {
            parts.append(ProblemCatalogMastery.level(for: slot.progress).label)
        }
        if state == .retry, let errorLabel = slot.errorLabels.first {
            parts.append("\(errorLabel)でミス")
        }
        if slot.progress.attemptCount > 0 {
            parts.append("挑戦\(slot.progress.attemptCount)回")
        }
        if let date = ProblemCatalogDateFormatting.shortDate(fromISO: slot.progress.lastAttemptAt) {
            parts.append(date)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let prompt = slot.promptPreview?.nilIfBlankValue {
                ProblemCatalogRichText(
                    text: prompt,
                    font: .title3.weight(.medium),
                    katexFontSize: 20,
                    katexFontWeight: 500,
                    lineLimit: 8,
                    maxKatexHeight: 220
                )
                .padding(.top, 2)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ProblemCatalogRichText(
                    text: slot.title,
                    font: hasPrompt ? .caption : .subheadline.weight(.semibold),
                    katexFontSize: hasPrompt ? 12 : 15,
                    katexFontWeight: 600,
                    color: hasPrompt ? .secondaryLabel : .label,
                    lineLimit: 2,
                    maxKatexHeight: 40
                )
                .foregroundStyle(hasPrompt ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Spacer(minLength: 4)
                ProblemCatalogStatusBadge(
                    state: state,
                    isOrganizing: slot.problemStatus == "unresolved"
                )
                .fixedSize(horizontal: true, vertical: false)
            }

            if !detailText.isEmpty {
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let sourceLabel = slot.sourceLabel?.nilIfBlankValue {
                Label(sourceLabel, systemImage: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }
}

struct ProblemCatalogStatusBadge: View {
    let state: ProblemCatalogTileState
    var isOrganizing = false

    var body: some View {
        Text(isOrganizing ? "整理中" : state.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.16), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        if isOrganizing { return ProblemCatalogSheetPalette.organizing }
        switch state {
        case .solved: return Color(red: 0.09, green: 0.55, blue: 0.42)
        case .retry: return ProblemCatalogSheetPalette.retry
        case .notStarted: return .secondary
        }
    }
}

enum ProblemCatalogDateFormatting {
    private static let isoParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoParserWithoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static func date(fromISO value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return isoParser.date(from: value)
            ?? isoParserWithoutFraction.date(from: value)
            ?? isoParserWithoutFraction.date(from: String(value.prefix(19)) + "Z")
    }

    static func shortDate(fromISO value: String?) -> String? {
        guard let date = date(fromISO: value) else { return nil }
        return displayFormatter.string(from: date)
    }
}

extension String {
    var containsCatalogLaTeX: Bool {
        contains("$") || contains("\\(") || contains("\\[") || contains("\\begin{")
    }

    var nilIfBlankValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// タイトル・問題文の描画。LaTeXが含まれるときだけKaTeXへ切り替える。
struct ProblemCatalogRichText: View {
    let text: String
    var font: Font = .subheadline
    var katexFontSize: CGFloat = 14
    var katexFontWeight = 500
    var color: UIColor = .label
    var lineLimit: Int? = 2
    var maxKatexHeight: CGFloat = 40

    var body: some View {
        if text.containsCatalogLaTeX {
            KaTeXMathText(
                text,
                foregroundColor: color,
                fontSize: katexFontSize,
                fontWeight: katexFontWeight
            )
            .frame(maxHeight: maxKatexHeight, alignment: .topLeading)
            .clipped()
            .allowsHitTesting(false)
        } else {
            Text(text)
                .font(font)
                .lineLimit(lineLimit)
        }
    }
}

#if DEBUG
extension ProblemCatalogSheetSlotDTO {
    static func sample(
        problemID: String,
        title: String,
        tileState: String,
        bundleID: String? = "0B000000-0000-0000-0000-000000000001",
        problemStatus: String = "resolved",
        errorLabels: [String] = [],
        sourceLabel: String? = "物理のワーク p.12",
        attemptCount: Int = 0,
        correctCount: Int = 0,
        lastAttemptAt: String? = nil,
        promptPreview: String? = nil
    ) -> ProblemCatalogSheetSlotDTO {
        ProblemCatalogSheetSlotDTO(
            problemRef: ProblemCatalogProblemRefDTO(
                problemID: problemID,
                revision: 1,
                contentHash: "sha256:\(problemID)",
                sourceLocator: "page:1#\(problemID)",
                problemBundleID: bundleID
            ),
            title: title,
            problemStatus: problemStatus,
            tileState: tileState,
            progress: ProblemCatalogProgressDTO(
                state: correctCount > 0 ? "solved" : (attemptCount > 0 ? "in_progress" : "not_started"),
                attemptCount: attemptCount,
                correctCount: correctCount,
                lastResult: correctCount > 0 ? "correct" : (attemptCount > 0 ? "incorrect" : nil),
                lastAttemptAt: lastAttemptAt
            ),
            errorLabels: errorLabels,
            sourceLabel: sourceLabel,
            promptPreview: promptPreview
        )
    }
}

extension ProblemCatalogSheetIndexDTO {
    static let preview: ProblemCatalogSheetIndexDTO = {
        let mechanics: [ProblemCatalogSheetSlotDTO] = (0..<12).map { index in
            if index == 8 {
                return .sample(
                    problemID: "mech-\(index)",
                    title: "作用・反作用とつり合い",
                    tileState: "retry",
                    errorLabels: ["力の向き"],
                    attemptCount: 2,
                    correctCount: 0,
                    lastAttemptAt: "2026-08-01T21:04:00Z",
                    promptPreview: "物体2の上に物体1がのっていて、物体2は床の上にあります。物体1にはたらく力をすべて図示し、それぞれの反作用を答えなさい。"
                )
            }
            let slopePrompt = "傾き$30^\\circ$のなめらかな斜面上に質量$m$の物体を置く。斜面に沿う方向の運動方程式を立てて、加速度の大きさを求めなさい。"
            if index == 10 {
                return .sample(
                    problemID: "mech-\(index)",
                    title: "2物体の連結と張力",
                    tileState: "not_started",
                    promptPreview: "軽い糸でつながれた2物体を水平な床の上で引く。糸の張力と全体の加速度を求めなさい。"
                )
            }
            if index == 1 || index == 5 {
                return .sample(
                    problemID: "mech-\(index)",
                    title: "斜面上の物体の運動方程式 \(index + 1)",
                    tileState: "solved",
                    attemptCount: 3,
                    correctCount: 1,
                    lastAttemptAt: "2026-07-30T20:10:00Z",
                    promptPreview: slopePrompt
                )
            }
            if index == 3 {
                return .sample(
                    problemID: "mech-\(index)",
                    title: "斜面上の物体の運動方程式 \(index + 1)",
                    tileState: "solved",
                    attemptCount: 1,
                    correctCount: 1,
                    lastAttemptAt: "2026-06-12T20:10:00Z",
                    promptPreview: slopePrompt
                )
            }
            return .sample(
                problemID: "mech-\(index)",
                title: "斜面上の物体の運動方程式 \(index + 1)",
                tileState: "solved",
                attemptCount: 1,
                correctCount: 1,
                lastAttemptAt: "2026-07-30T20:10:00Z",
                promptPreview: slopePrompt
            )
        }
        let circuits: [ProblemCatalogSheetSlotDTO] = (0..<9).map { index in
            index < 4
                ? .sample(
                    problemID: "circ-\(index)",
                    title: "オームの法則と合成抵抗 \(index + 1)",
                    tileState: "solved",
                    sourceLabel: "電磁気プリント p.3",
                    attemptCount: 1,
                    correctCount: 1,
                    promptPreview: "$R_1 = 2\\,\\Omega$、$R_2 = 3\\,\\Omega$ を並列につないだ回路の合成抵抗を求めなさい。"
                )
                : .sample(
                    problemID: "circ-\(index)",
                    title: "キルヒホッフ則 \(index + 1)",
                    tileState: "not_started",
                    sourceLabel: "電磁気プリント p.4",
                    promptPreview: "図の回路について、キルヒホッフの法則を用いて各抵抗を流れる電流を求めなさい。"
                )
        }
        let quadratic: [ProblemCatalogSheetSlotDTO] = (0..<12).map { index in
            .sample(
                problemID: "quad-\(index)",
                title: "$y=x^2-6x+11$ の最小値 \(index + 1)",
                tileState: "solved",
                sourceLabel: "6月12日の学校プリント",
                attemptCount: 1,
                correctCount: 1,
                promptPreview: "$0 \\le x \\le 4$ のとき、$y=x^2-6x+11$ の最大値と最小値を求めなさい。"
            )
        }
        let english: [ProblemCatalogSheetSlotDTO] = (0..<8).map { index in
            index < 3
                ? .sample(
                    problemID: "eng-\(index)",
                    title: "不定詞の用法 \(index + 1)",
                    tileState: "solved",
                    sourceLabel: "英文法ドリル p.24",
                    attemptCount: 1,
                    correctCount: 1,
                    promptPreview: "次の英文の下線部の不定詞が「名詞的用法・形容詞的用法・副詞的用法」のどれかを答えなさい: I have a lot of homework to do today."
                )
                : .sample(
                    problemID: "eng-\(index)",
                    title: "不定詞の書き換え \(index + 1)",
                    tileState: "not_started",
                    sourceLabel: "英文法ドリル p.25",
                    promptPreview: "It is important for us to read books. を、動名詞を使った文に書き換えなさい。"
                )
        }
        return ProblemCatalogSheetIndexDTO(
            catalogGeneration: "gen-20260801",
            createdAt: "2026-08-06T09:00:00Z",
            sheets: [
                ProblemCatalogSheetDTO(
                    sheetID: "sheet:physics:mechanics:1",
                    title: "力学:運動の法則",
                    subjectLabel: "物理",
                    slots: mechanics,
                    solvedCount: 10,
                    retryCount: 1
                ),
                ProblemCatalogSheetDTO(
                    sheetID: "sheet:physics:circuits:1",
                    title: "電磁気:回路",
                    subjectLabel: "物理",
                    slots: circuits,
                    solvedCount: 4,
                    retryCount: 0
                ),
                ProblemCatalogSheetDTO(
                    sheetID: "sheet:english:infinitive:1",
                    title: "不定詞",
                    subjectLabel: "英語",
                    slots: english,
                    solvedCount: 3,
                    retryCount: 0
                ),
                ProblemCatalogSheetDTO(
                    sheetID: "sheet:math:quadratic:1",
                    title: "二次関数",
                    subjectLabel: "数学",
                    slots: quadratic,
                    solvedCount: 12,
                    retryCount: 0
                )
            ],
            organizing: [
                .sample(
                    problemID: "org-0",
                    title: "ベクトルの内積チェック",
                    tileState: "not_started",
                    problemStatus: "unresolved",
                    sourceLabel: "数学プリント"
                ),
                .sample(
                    problemID: "org-1",
                    title: "復習:作用・反作用とつり合い",
                    tileState: "not_started",
                    problemStatus: "unresolved",
                    sourceLabel: nil
                )
            ],
            problemCount: 43,
            solvedCount: 29,
            retiredCount: 1
        )
    }()

    static let emptyPreview = ProblemCatalogSheetIndexDTO(
        catalogGeneration: "gen-20260801",
        sheets: [],
        organizing: [],
        problemCount: 0,
        solvedCount: 0
    )
}

@MainActor
struct PreviewProblemCatalogSheetService: ProblemCatalogSheetServing {
    enum Mode {
        case loaded
        case empty
        case failed
    }

    let mode: Mode

    func loadSheetIndex() async throws -> ProblemCatalogSheetIndexDTO {
        switch mode {
        case .loaded: return .preview
        case .empty: return .emptyPreview
        case .failed: throw APIError.transport(URLError(.notConnectedToInternet))
        }
    }

    func query(_ request: ProblemCatalogQueryRequest) async throws -> ProblemCatalogViewDTO {
        ProblemCatalogViewDTO(
            schemaVersion: 1,
            viewID: "preview-query",
            viewKind: "query",
            catalogGeneration: "gen-20260801",
            title: request.query,
            scopePath: [],
            interpretation: ProblemCatalogInterpretationDTO(),
            nodes: [
                ProblemCatalogNodeDTO(
                    id: "problem:mech-8",
                    parentID: nil,
                    kind: "problem",
                    title: "作用・反作用とつり合い",
                    sourceLabel: "物理のワーク p.12",
                    promptPreview: "物体2の上に物体1がのっていて…",
                    problemRef: ProblemCatalogProblemRefDTO(
                        problemID: "mech-8",
                        revision: 1,
                        contentHash: "sha256:mech-8",
                        sourceLocator: "page:1#mech-8",
                        problemBundleID: "0B000000-0000-0000-0000-000000000001"
                    ),
                    problemStatus: "resolved",
                    progress: ProblemCatalogProgressDTO(
                        state: "in_progress",
                        attemptCount: 2,
                        correctCount: 0
                    )
                )
            ],
            edges: [],
            focusNodeIDs: [],
            truncation: ProblemCatalogTruncationDTO(shownNodes: 1, totalNodes: 1),
            nextCursor: nil
        )
    }

    func loadProblem(
        ref: ProblemCatalogProblemRefDTO,
        catalogGeneration: String
    ) async throws -> ProblemCatalogProblemDetailDTO {
        ProblemCatalogProblemDetailDTO(
            catalogGeneration: catalogGeneration,
            problem: ProblemCatalogProblemDTO(
                problemRef: ref,
                status: "resolved",
                title: "作用・反作用とつり合い",
                prompt: "物体2の上に物体1がのっていて、物体2は床の上にあります。物体1にはたらく力をすべて図示し、それぞれの反作用を答えなさい。",
                difficulty: "standard",
                estimatedMinutes: 8,
                sourceKind: "material",
                sourceLabel: "物理のワーク p.12",
                sourceRefs: [],
                taxonomyPath: [
                    ProblemCatalogScopeItemDTO(kind: "subject", id: "physics", label: "物理"),
                    ProblemCatalogScopeItemDTO(kind: "unit", id: "mechanics", label: "力学:運動の法則")
                ],
                skillIDs: [],
                skillLabels: ["力のつり合い"],
                errorTags: ["force-direction"],
                errorLabels: ["力の向き"],
                progress: ProblemCatalogProgressDTO(
                    state: "in_progress",
                    attemptCount: 2,
                    correctCount: 0,
                    lastResult: "incorrect",
                    lastAttemptAt: "2026-08-01T21:04:00Z"
                )
            ),
            revisions: [ProblemCatalogRevisionDTO(revision: 1, contentHash: "sha256:mech-8", isCurrent: true)],
            recentAttempts: [
                ProblemCatalogAttemptSummaryDTO(
                    attemptID: "attempt-2",
                    result: "incorrect",
                    status: "completed",
                    createdAt: "2026-08-01T21:04:00Z",
                    completedAt: "2026-08-01T21:12:00Z"
                ),
                ProblemCatalogAttemptSummaryDTO(
                    attemptID: "attempt-1",
                    result: nil,
                    status: "in_progress",
                    createdAt: "2026-07-30T20:10:00Z",
                    completedAt: nil
                )
            ]
        )
    }
}
#endif
