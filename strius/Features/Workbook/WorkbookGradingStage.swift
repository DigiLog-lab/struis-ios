import SwiftUI
import UIKit

/// 判定の待ち(待ち時間の体験 要件 §5): 答案の読み取り → 1 問ずつなぞる → 丸をつける。
/// 結果が届くまでは「採点しています」の段を続け(W3)、丸は結果が届いてから描く。誤りの種類は採点中に出さない。
/// 状態の文言は 3 つに固定し、最後に「採点が終わりました」。
@Observable
@MainActor
final class WorkbookGradingStageModel {
    enum Phase: Equatable { case reading, grading, marking, finished }

    static let readingText = "答案を読み取っています"
    static let gradingText = "採点しています"
    static let markingText = "丸をつけています"
    static let finishedText = "採点が終わりました"

    private(set) var phase: Phase = .reading
    private(set) var status = WorkbookGradingStageModel.readingText
    /// 領域(検出が終わるまで空)。
    private(set) var regions: [WorkbookAnswerRegion] = []
    /// 走査線の位置(0〜1)。nil なら出さない。
    var scan: CGFloat?
    /// 細い実線の枠で示している領域。
    var framedRegion: Int?
    /// 今確かめている 1 問の領域(淡い面)。
    var focusRegion: Int?
    /// ペンのしるし(写真に対する 0〜1)。
    var pen: CGPoint?
    /// 右端の余白で切り替える ○・△・× の添字。
    var cycle = 0
    /// 描いた丸の進み(領域の添字 → 0〜1)と色。
    var marks: [Int: CGFloat] = [:]
    /// 出した誤りの種類(判定の添字)。
    var shownTags: [Int] = []

    /// 届いた判定(label・判定・誤りの種類)。nil の間は採点中。
    private var verdicts: [WorkbookCaptureVerdictDTO]?
    private var stopped = false
    var animates = true

    /// 判定と領域の対応(判定の添字 → 領域の添字)。
    private(set) var assignment: [Int: Int] = [:]

    func deliver(_ verdicts: [WorkbookCaptureVerdictDTO]) {
        guard self.verdicts == nil else { return }
        self.verdicts = verdicts
        assignment = WorkbookAnswerRegions.assign(verdictLabels: verdicts.map(\.label), regions: regions)
    }

    /// 失敗・中断: 演出を止める(W8)。
    func stop() {
        stopped = true
        scan = nil
        framedRegion = nil
        focusRegion = nil
        pen = nil
    }

    /// 領域に結ばれた判定(領域の添字 → 判定)。
    func verdict(forRegion region: Int) -> WorkbookCaptureVerdictDTO? {
        guard let verdicts, let index = assignment.first(where: { $0.value == region })?.key, verdicts.indices.contains(index) else { return nil }
        return verdicts[index]
    }

    var taggedVerdicts: [WorkbookCaptureVerdictDTO] {
        guard let verdicts else { return [] }
        return shownTags.compactMap { verdicts.indices.contains($0) ? verdicts[$0] : nil }
    }

    // MARK: - 進行

    func run(captureID: String, image: UIImage, onFinished: @escaping () -> Void) async {
        // §5.1 読み取り: 走査線を一度だけ通し、その間に領域を検出する。
        let detection = Task { await WorkbookAnswerRegions.detect(captureID: captureID, image: image) }
        if animates {
            scan = 0
            withAnimation(.linear(duration: 2.6)) { scan = 1 }
            await pause(2.6)
            withAnimation(.easeOut(duration: 0.25)) { scan = nil }
        }
        let found = await detection.value
        regions = found
        if let verdicts { assignment = WorkbookAnswerRegions.assign(verdictLabels: verdicts.map(\.label), regions: found) }
        if animates, !stopped {
            for index in found.indices {
                guard !stopped else { return }
                withAnimation(.easeOut(duration: 0.2)) { framedRegion = index }
                await pause(0.5)
            }
            withAnimation(.easeOut(duration: 0.3)) { framedRegion = nil }
            await pause(0.35)
        }
        guard !stopped else { return }

        // §5.2 採点中: 結果が届くまで、1 問ずつなぞって最初に戻る。
        if verdicts == nil {
            phase = .grading
            status = Self.gradingText
        }
        var index = 0
        while verdicts == nil, !stopped, !Task.isCancelled {
            guard animates, !found.isEmpty else {
                await pause(0.3)
                continue
            }
            let regionIndex = index % found.count
            withAnimation(.easeInOut(duration: 0.35)) { focusRegion = regionIndex }
            let cycling = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.35)) { self.cycle = (self.cycle + 1) % 3 }
                }
            }
            for line in found[regionIndex].lines {
                guard verdicts == nil, !stopped else { break }
                var start = Transaction()
                start.disablesAnimations = true
                withTransaction(start) { pen = CGPoint(x: line.minX, y: line.midY) }
                await pause(0.05)
                // 1 行およそ 3 秒で左から右へ。
                withAnimation(.linear(duration: 3)) { pen = CGPoint(x: line.maxX, y: line.midY) }
                await waitUnlessDelivered(3)
            }
            cycling.cancel()
            index += 1
        }
        withAnimation(.easeOut(duration: 0.25)) {
            focusRegion = nil
            if !animates { pen = nil }
        }
        guard !stopped, let verdicts else { return }

        // §5.3 丸をつける: 上の問題から順に、右端の余白へ移って記号を手書きの線で描く。
        phase = .marking
        status = Self.markingText
        let ordered = found.indices.sorted { found[$0].rect.minY < found[$1].rect.minY }
        for regionIndex in ordered {
            guard !stopped else { return }
            guard let verdictIndex = assignment.first(where: { $0.value == regionIndex })?.key else { continue }
            if animates {
                withAnimation(.easeInOut(duration: 0.45)) { pen = Self.markCenter(found[regionIndex]) }
                await pause(0.45)
                withAnimation(.easeOut(duration: 0.7)) { marks[regionIndex] = 1 }
                await pause(0.75)
            } else {
                marks[regionIndex] = 1
            }
            let verdict = verdicts[verdictIndex]
            if verdict.verdict != .correct, !verdict.errorTag.isEmpty {
                withAnimation(.easeIn(duration: animates ? 0.35 : 0)) { shownTags.append(verdictIndex) }
                if animates { await pause(0.35) }
            }
        }
        withAnimation(.easeOut(duration: 0.3)) { pen = nil }
        status = Self.finishedText
        await pause(animates ? 1.0 : 0.6)
        guard !stopped else { return }
        phase = .finished
        onFinished()
    }

    /// 丸を描く位置: 領域の右端の余白、最初の行の高さ。
    static func markCenter(_ region: WorkbookAnswerRegion) -> CGPoint {
        let y = region.lines.first?.midY ?? region.rect.midY
        // 答案のすぐ右ではなく、紙の右寄りの余白に(先生が丸をつける位置)。
        return CGPoint(x: min(max(region.rect.maxX + 0.06, 0.72), 0.92), y: y)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// 結果が届いたら待ちを切り上げる(なぞりの途中でも丸つけへ)。
    private func waitUnlessDelivered(_ seconds: Double) async {
        var waited = 0.0
        while waited < seconds, verdicts == nil, !stopped, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
    }
}

/// 答案の写真と、その上の走査線・枠・ペン・○△×・丸。判定の後の静止した表示(丸だけ)にも使う。
struct WorkbookMarkedPhoto: View {
    let image: UIImage
    let model: WorkbookGradingStageModel?
    /// 判定の後の静止した表示: 領域と判定の対応から丸だけを描く。
    var staticMarks: [(region: WorkbookAnswerRegion, verdict: WorkbookProblemTileDTO.State)] = []
    var maxHeight: CGFloat = 460

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: maxHeight)
            .overlay {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        if let model {
                            overlay(model, size: proxy.size)
                        }
                        ForEach(Array(staticMarks.enumerated()), id: \.offset) { _, item in
                            markView(item.verdict, region: item.region, size: proxy.size, progress: 1)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("答案")
    }

    @ViewBuilder
    private func overlay(_ model: WorkbookGradingStageModel, size: CGSize) -> some View {
        let regions = model.regions
        // 今確かめている 1 問だけに淡い面の色。
        if let focus = model.focusRegion, regions.indices.contains(focus) {
            let rect = scaled(regions[focus].rect, size)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.accentColor.opacity(0.14))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .transition(.opacity)
            // 右端の余白で ○・△・× を淡く切り替える(判定がまだ決まっていない)。
            let center = scaledPoint(WorkbookGradingStageModel.markCenter(regions[focus]), size)
            Text(["○", "△", "×"][model.cycle])
                .font(.system(size: markSize(regions[focus], size) * 0.8, weight: .semibold))
                .foregroundStyle(Theme.secondaryText.opacity(0.45))
                .contentTransition(.opacity)
                .position(center)
                .accessibilityHidden(true)
        }
        // 検出した領域を 1 つずつ細い実線の枠で示す。
        if let framed = model.framedRegion, regions.indices.contains(framed) {
            let rect = scaled(regions[framed].rect, size)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.accentColor, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .transition(.opacity)
        }
        // 走査線(上から下へ一度だけ)。
        if let scan = model.scan {
            LinearGradient(colors: [Theme.accentColor.opacity(0), Theme.accentColor.opacity(0.55), Theme.accentColor.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: 18)
                .offset(y: scan * size.height - 9)
                .allowsHitTesting(false)
        }
        // 丸(結果が届いてから)。
        ForEach(regions.indices, id: \.self) { index in
            if let progress = model.marks[index], let verdict = model.verdict(forRegion: index) {
                markView(verdict.verdict, region: regions[index], size: size, progress: progress)
            }
        }
        // ペンのしるし。
        if let pen = model.pen {
            Image(systemName: "pencil.tip")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accentColor)
                .rotationEffect(.degrees(-35))
                .position(x: pen.x * size.width + 5, y: pen.y * size.height - 9)
                .accessibilityHidden(true)
        }
    }

    private func markView(_ verdict: WorkbookProblemTileDTO.State, region: WorkbookAnswerRegion, size: CGSize, progress: CGFloat) -> some View {
        let side = markSize(region, size)
        let center = scaledPoint(WorkbookGradingStageModel.markCenter(region), size)
        return HandwrittenMark(kind: HandwrittenMark.Kind(verdict))
            .trim(from: 0, to: progress)
            .stroke(Self.color(verdict), style: StrokeStyle(lineWidth: max(2.5, side * 0.09), lineCap: .round, lineJoin: .round))
            .frame(width: side, height: side)
            .position(center)
            .accessibilityHidden(true)
    }

    /// 正解は成長の色、誤りは後退の色。判定できなかったものは淡い文字色。
    static func color(_ verdict: WorkbookProblemTileDTO.State) -> Color {
        switch verdict {
        case .correct: Theme.growthColor
        case .wrong: Theme.regressColor
        case .unknown, .notStarted: Theme.tertiaryText
        }
    }

    private func markSize(_ region: WorkbookAnswerRegion, _ size: CGSize) -> CGFloat {
        let byRegion = region.rect.height * size.height * 0.9
        return max(18, min(36, byRegion, size.width * 0.1))
    }

    private func scaled(_ rect: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
    }

    private func scaledPoint(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}

/// 手書きの ○・△・×。`trim` で書き順に描ける 1 本の線。
struct HandwrittenMark: Shape {
    enum Kind {
        case circle, triangle, cross
        init(_ verdict: WorkbookProblemTileDTO.State) {
            switch verdict {
            case .correct: self = .circle
            case .wrong: self = .cross
            case .unknown, .notStarted: self = .triangle
            }
        }
    }

    let kind: Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        switch kind {
        case .circle:
            // 真円を、左上から書き始めて一周で閉じる(縦横の比や揺らぎで歪ませない)。
            let radius = min(w, h) * 0.44
            let start = -Double.pi * 0.62
            path.addArc(
                center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                startAngle: .radians(start), endAngle: .radians(start + Double.pi * 2), clockwise: false
            )
        case .triangle:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + h * 0.08))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.1, y: rect.maxY - h * 0.12))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.1, y: rect.maxY - h * 0.1))
            path.addLine(to: CGPoint(x: rect.midX + w * 0.02, y: rect.minY + h * 0.1))
        case .cross:
            path.move(to: CGPoint(x: rect.minX + w * 0.14, y: rect.minY + h * 0.12))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.12, y: rect.maxY - h * 0.14))
            path.move(to: CGPoint(x: rect.maxX - w * 0.14, y: rect.minY + h * 0.14))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.12, y: rect.maxY - h * 0.12))
        }
        return path
    }
}

/// 判定を待つ間の段(§5)。写真を大きく出し、状態の文言を 1 行。「止める」は呼び手が置く。
struct WorkbookGradingStage: View {
    let captureID: String
    let image: UIImage
    let model: WorkbookGradingStageModel
    let onFinished: () -> Void
    @Environment(\.struisAnimatesWaiting) private var animates

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkbookMarkedPhoto(image: image, model: model)
            // 誤りのある問題は、答案の下に誤りの種類を静かに出す(結果が届いてから)。
            if !model.taggedVerdicts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.taggedVerdicts.enumerated()), id: \.offset) { _, verdict in
                        HStack(spacing: 8) {
                            Text(verdict.label.isEmpty ? "問" : verdict.label)
                                .font(Typography.caption)
                                .foregroundStyle(Theme.secondaryText)
                            Text(verdict.errorTag)
                                .font(Typography.caption)
                                .foregroundStyle(Theme.regressColor)
                        }
                        .transition(.opacity)
                    }
                }
                .accessibilityIdentifier("workbook-grading-error-tags")
            }
        }
        .onAppear { model.animates = animates }
        .onChange(of: animates) { _, value in model.animates = value }
        .task(id: captureID) {
            model.animates = animates
            await model.run(captureID: captureID, image: image, onFinished: onFinished)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workbook-grading-stage")
    }
}
