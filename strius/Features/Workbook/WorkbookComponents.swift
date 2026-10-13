import SwiftUI

/// 問題集の共通部品。ガラスは操作系(質問ピル・撮影ボタン)だけ。コンテンツは不透明、背景は無地。
enum WorkbookPalette {
    // 銅と生成りの中に収まる色だけを使う。システムの緑・橙・藍は面から浮く。
    static let correct = Theme.accentColor
    static let wrong = Theme.regressColor
    static let unknown = Theme.tertiaryText
    static let passed = Theme.growthColor

}

/// マス。破線は使わない(小さいと汚れに見える)。状態は面の濃さと色だけで分ける。
/// 未着手=地に沈む薄い面 / 正解=銅の面 / 誤答=赤みの縁(小さいときは薄い面) / 判定不能=灰の薄い面。
struct WorkbookTile: View {
    let state: WorkbookProblemTileDTO.State
    var assisted = false
    var size: CGFloat = 22

    private var isSmall: Bool { size < 12 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(2, size * 0.24), style: .continuous)
        shape
            .fill(fill)
            .overlay {
                if state == .wrong, !isSmall {
                    shape.strokeBorder(WorkbookPalette.wrong, lineWidth: 1.5)
                }
                if state == .correct, assisted, !isSmall {
                    // ヒントあり。面の中に小さな抜きを置く。
                    Circle().fill(Theme.card).frame(width: size * 0.28, height: size * 0.28)
                }
            }
            .frame(width: size, height: size)
            .accessibilityLabel(label)
    }

    private var fill: Color {
        switch state {
        case .correct: WorkbookPalette.correct
        case .wrong: WorkbookPalette.wrong.opacity(isSmall ? 0.55 : 0.16)
        case .unknown: WorkbookPalette.unknown.opacity(0.35)
        case .notStarted: Theme.primaryText.opacity(0.09)
        }
    }

    private var label: String {
        switch state {
        case .correct: assisted ? "正解 ヒントあり" : "正解"
        case .wrong: "誤答"
        case .unknown: "判定不能"
        case .notStarted: "未着手"
        }
    }
}

/// 小単元のマスの並び。n 個で、合格の窓に入った演習の答え(古い順)だけを並べ、残りは未着手。
/// 新しい答えで古いものが押し出される。行は 5 列でそろえる(10 は 5×2、15 は 5×3)。
struct WorkbookTileRow: View {
    let tiles: [WorkbookProblemTileDTO]
    let n: Int
    var size: CGFloat = 22

    var body: some View {
        WorkbookWindowGrid(
            states: tiles.suffix(n).map(\.state), assisted: tiles.suffix(n).map(\.assisted), current: [], n: n, size: size
        )
    }
}

/// マスの格子。列数は min(n, 5)。`current` が true のマスは今回の一枚で埋まったもの(下線で示す)。
struct WorkbookWindowGrid: View {
    let states: [WorkbookProblemTileDTO.State]
    var assisted: [Bool] = []
    let current: [Bool]
    let n: Int
    var size: CGFloat = 22

    static func columns(n: Int) -> Int { max(1, min(n, 5)) }

    var body: some View {
        let count = max(n, states.count)
        let columns = Self.columns(n: n)
        let spacing = max(3, size * 0.22)
        Grid(alignment: .leading, horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(0..<((count + columns - 1) / columns), id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if index < count {
                            cell(index)
                        } else {
                            Color.clear.frame(width: size, height: size)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("workbook-window-grid")
    }

    private func cell(_ index: Int) -> some View {
        let state = index < states.count ? states[index] : .notStarted
        let isCurrent = index < current.count && current[index]
        return WorkbookTile(state: state, assisted: index < assisted.count && assisted[index], size: size)
            .overlay(alignment: .bottom) {
                if isCurrent, size >= 12 {
                    Capsule().fill(Theme.primaryText.opacity(0.55)).frame(width: size * 0.5, height: 2).offset(y: size * 0.18 + 3)
                }
            }
    }

    private var accessibilitySummary: String {
        let correct = states.filter { $0 == .correct }.count
        return "マス \(n) 個中 正解 \(correct)"
    }
}

/// 合格ライン。直近 n 問の 8 割。
struct WorkbookPassLine: View {
    let window: WorkbookWindowDTO

    var body: some View {
        HStack(spacing: 8) {
            Text("直近\(window.n)問で\(window.requiredCorrect)問")
                .font(Typography.caption)
                .foregroundStyle(Theme.secondaryText)
            Text("\(window.correct) / \(window.count)")
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(window.passed ? WorkbookPalette.passed : .primary)
            if window.passed {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(WorkbookPalette.passed)
                    .font(.caption)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 常設の撮影ボタン。全画面で同じ位置(下中央)。ガラスの tinted。
struct WorkbookCaptureButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("撮る", systemImage: "camera.fill")
                .labelStyle(.iconOnly)
                .padding(.horizontal, 14)
                .foregroundStyle(Theme.onAccent)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.Palette.accentLight)
        .accessibilityLabel("撮る")
        .accessibilityIdentifier("workbook-capture-button")
    }
}

/// 右上の「質問」。ツールバー自身のガラス面を使う。
struct WorkbookQuestionPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 13, weight: .semibold))
                Text("質問")
                    .font(Typography.bodyEmphasized)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // 長いタイトルと並ぶとツールバーが幅を詰め、文字がガラス面の外へはみ出す。本来の幅を譲らない。
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("質問")
        .accessibilityIdentifier("workbook-question-pill")
    }
}

/// 一言(○×と一緒に出す短い判定)。
struct WorkbookVerdictMark: View {
    let verdict: WorkbookProblemTileDTO.State

    var body: some View {
        Group {
            switch verdict {
            case .correct:
                Image(systemName: "circle")
                    .foregroundStyle(WorkbookPalette.correct)
            case .wrong:
                Image(systemName: "xmark")
                    .foregroundStyle(WorkbookPalette.wrong)
            case .unknown, .notStarted:
                Image(systemName: "questionmark")
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .font(.system(size: 18, weight: .bold))
        .frame(width: 28, height: 28)
        .accessibilityLabel(verdict == .correct ? "正解" : verdict == .wrong ? "誤答" : "判定不能")
    }
}

struct WorkbookPromptText: View {
    let text: String
    var lineLimit: Int? = 3

    var body: some View {
        // 一枚の紙カードでは問題文を切らない。行数制限がある一覧だけ高さを抑える。
        ProblemCatalogRichText(
            text: WorkbookMathSource.withInlineMath(text), font: Typography.body, katexFontSize: 15, lineLimit: lineLimit,
            maxKatexHeight: lineLimit == nil ? 400 : CGFloat(24 * (lineLimit ?? 3))
        )
    }
}

enum WorkbookMathSource {
    private static let equation = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9\\$])([A-Za-z][A-Za-z0-9^_{}()]*[ \t]*=[ \t]*[A-Za-z0-9πΠα-ωΑ-Ω\\{}+\-−×÷*/^_().][A-Za-z0-9πΠα-ωΑ-Ω\\{}+\-−×÷*/^_(). \t]*)"#
    )

    static func withInlineMath(_ text: String) -> String {
        // 既に数式区切りがある本文は、その指定をそのまま使う。
        guard !text.containsCatalogLaTeX else { return text }
        let matches = equation.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: result) else { continue }
            let source = String(result[range])
            let formula = source.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"(?<![A-Za-z\\])(sin|cos|tan|log|ln)(?=\()"#, with: #"\\$1"#, options: .regularExpression)
            let trailing = source.dropFirst(source.trimmingCharacters(in: .whitespaces).count)
            result.replaceSubrange(range, with: "$\(formula)$\(trailing)")
        }
        return result
    }
}

enum WorkbookFormatting {
    /// 相対時刻はここだけで作る。未来(端末の時計のずれ)と 1 分未満は「たった今」。
    static func relative(_ iso: String, now: Date = Date()) -> String {
        guard let date = ProblemCatalogDateFormatting.date(fromISO: iso) ?? LedgerClock.parse(iso) else { return "" }
        return relative(date, now: now)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "たった今" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// 学習者に見せるエラーは日本語の一言だけ。内部の言葉(メソッド名・イベント名)は出さない。
    static func learnerFacingError(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksInternal = trimmed.isEmpty || trimmed.range(of: #"[A-Za-z_]+/[A-Za-z_]+|Error|error|\(|\{"#, options: .regularExpression) != nil
        return looksInternal ? "うまくいきませんでした。もう一度試してください。" : trimmed
    }
}

/// 相対時刻。画面を開いている間も 30 秒ごとに進める。
struct WorkbookRelativeTime: View {
    let iso: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(WorkbookFormatting.relative(iso, now: context.date))
        }
    }
}

/// 撮影ボタンを下中央に常設する修飾子。
struct WorkbookCaptureInset: ViewModifier {
    let context: WorkbookViewRef?
    let onCapture: (WorkbookViewRef?) -> Void

    // 内容の上に面を被せない。撮るは OS の下部ツールバーに置き、スクロールの縁の処理は OS に任せる。
    func body(content: Content) -> some View {
        // 撮るボタンの下を通る行が透けて重ならないように、下端は OS の硬い縁(D13)にする。
        content
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .toolbar {
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                WorkbookCaptureButton { onCapture(context) }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
        }
    }
}

extension View {
    func workbookCaptureInset(context: WorkbookViewRef?, onCapture: @escaping (WorkbookViewRef?) -> Void) -> some View {
        modifier(WorkbookCaptureInset(context: context, onCapture: onCapture))
    }
}

// MARK: - 段階

extension WorkbookStage {
    /// 段階の記号。前 2 つは読む・聞く側、後 2 つは書く側。
    var symbol: String {
        switch self {
        case .introduction: "text.book.closed.fill"
        case .jointExample: "bubble.left.and.bubble.right.fill"
        case .soloExample: "pencil"
        case .practice: "square.grid.2x2.fill"
        }
    }
}

/// 段階の輪。4 つの弧がそのまま 4 段階。済=銅、いま=銅(明るい)、先=沈む。中央にいまの段階の記号。
/// 合格すると輪が閉じて印に替わる。一覧ではこれだけを出し、4 語は小単元の画面で見せる。
struct WorkbookStageRing: View {
    let stage: Int
    let passed: Bool
    var size: CGFloat = 34

    var body: some View {
        let line = size * 0.13
        ZStack {
            if passed {
                Circle().fill(WorkbookPalette.passed)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(Theme.ground)
            } else {
                ForEach(1...4, id: \.self) { index in
                    let gap = 0.045
                    Circle()
                        .trim(from: Double(index - 1) / 4 + gap / 2, to: Double(index) / 4 - gap / 2)
                        .stroke(color(index), style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .padding(line / 2)
                if let item = WorkbookStage(rawValue: stage) {
                    Image(systemName: item.symbol)
                        .font(.system(size: size * 0.34, weight: .semibold))
                        .foregroundStyle(Theme.accentColor)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(passed ? "合格" : "段階 \(WorkbookStage(rawValue: stage)?.label ?? "") 4 段階中 \(stage)")
    }

    private func color(_ index: Int) -> Color {
        if index < stage { return Theme.accentColor.opacity(0.45) }
        if index == stage { return Theme.accentColor }
        return Theme.primaryText.opacity(0.10)
    }
}

/// 段階の道のり。小単元の画面用。注文の追跡と同じ形: 点と線、済みは印、いまは輪。
struct WorkbookStageSteps: View {
    let stage: Int
    let passed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(WorkbookStage.allCases, id: \.rawValue) { item in
                let done = passed || item.rawValue < stage
                let now = !passed && item.rawValue == stage
                VStack(spacing: 7) {
                    HStack(spacing: 0) {
                        bar(filled: done || now, hidden: item.rawValue == 1)
                        node(done: done, now: now)
                        bar(filled: done, hidden: item.rawValue == 4)
                    }
                    Text(item.label)
                        .font(now ? Typography.caption.weight(.bold) : Typography.caption)
                        .foregroundStyle(now ? Theme.primaryText : done ? Theme.secondaryText : Theme.tertiaryText)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func bar(filled: Bool, hidden: Bool) -> some View {
        Rectangle()
            .fill(filled ? Theme.accentColor.opacity(0.5) : Theme.primaryText.opacity(0.10))
            .frame(height: 2)
            .opacity(hidden ? 0 : 1)
    }

    @ViewBuilder
    private func node(done: Bool, now: Bool) -> some View {
        ZStack {
            if done {
                Circle().fill(Theme.accentColor)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.card)
            } else if now {
                Circle().strokeBorder(Theme.accentColor, lineWidth: 2)
                Circle().fill(Theme.accentColor).padding(5.5)
            } else {
                Circle().strokeBorder(Theme.primaryText.opacity(0.16), lineWidth: 1.5)
            }
        }
        .frame(width: 20, height: 20)
        .padding(.horizontal, 4)
    }
}
