// タイムアタック(#133)は延期中。Config/Build.xcconfig の STRUIS_TIME_ATTACK が YES の時だけ本体に入る(App Clip は常に入れる)。
#if STRUIS_TIME_ATTACK
import SwiftUI

// MARK: - 解く

/// 解く画面: 問題を1問ずつ出し、紙に書いて「次へ」。5問目のあとに1枚撮る。タイマーは問題が出た時からシャッターまで。
struct TimeAttackRunView: View {
    let field: String
    let problems: [TimeAttack.Problem]
    /// 最後に紙を撮るか(自分で採点する時は撮らず、「書き終えた」でタイマーを止める)。
    var capturesPhoto = true
    var onQuit: () -> Void
    var onFinish: (_ laps: [Double], _ photo: Data?) -> Void

    @State private var index = 0
    @State private var startedAt = Date()
    @State private var lapStartedAt = Date()
    @State private var laps: [Double] = []
    @State private var stoppedAt: Date?
    @State private var isCameraPresented = false
    /// 計り始めたか。カメラを閉じると `onAppear` がもう一度呼ばれるので、時刻は最初の1回だけ決める。
    @State private var hasStarted = false

    private var isLast: Bool { index == problems.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onQuit) {
                    Label("やめる", systemImage: "xmark")
                        .font(Typography.sans(size: 14, weight: .medium))
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(Theme.card.opacity(0.8), in: Capsule())
                        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("timeattack-quit")
                Spacer()
                Text("タイムアタック").font(Typography.caption).foregroundStyle(Theme.secondaryText)
            }
            .frame(height: 44)

            HStack(alignment: .firstTextBaseline) {
                TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
                    Text(TimeAttack.clock((stoppedAt ?? context.date).timeIntervalSince(startedAt)))
                        .font(.system(size: 44, weight: .bold)).monospacedDigit()
                        .accessibilityIdentifier("timeattack-clock")
                }
                Spacer()
                Text("\(index + 1) / \(problems.count)　誤答は1問 +10秒")
                    .font(Typography.caption).monospacedDigit().foregroundStyle(Theme.secondaryText)
            }
            .padding(.top, 10)

            HStack(spacing: 6) {
                ForEach(problems.indices, id: \.self) { item in
                    Capsule()
                        .fill(item < index ? Theme.accentColor : item == index ? Theme.accentColor.opacity(0.4) : Theme.primaryText.opacity(0.09))
                        .frame(height: 6)
                }
            }
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 12) {
                Text(field)
                    .font(Typography.caption)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Theme.accentColor.opacity(0.16), in: Capsule())
                Text(problems[index].prompt)
                    .font(Typography.sans(size: 17, weight: .bold)).lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("timeattack-prompt")
                if !problems[index].math.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        TimeAttackMath(latex: problems[index].math, size: 44)
                    }
                    .accessibilityLabel(TimeAttackMath.plain(problems[index].math))
                }
            }
            .padding(.top, 28)
            .id(index)
            .transition(.opacity)

            Spacer(minLength: 16)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "pencil").foregroundStyle(Theme.accentColor)
                Text(capturesPhoto ? "答えは紙に上から順に書いてください。\(problems.count)問目のあとに、まとめて1枚撮ります。"
                                   : "答えは紙に上から順に書いてください。\(problems.count)問目のあとに、正答を見て自分で○×をつけます。")
                    .font(Typography.bodyCompact).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .struisSurface()

            Button(action: advance) {
                Label(isLast ? (capturesPhoto ? "書き終えたので撮る" : "書き終えた") : "次へ",
                      systemImage: isLast ? (capturesPhoto ? "camera" : "checkmark") : "arrow.right")
                    .font(Typography.sans(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .foregroundStyle(Theme.onAccent)
                    .background(Theme.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
            .accessibilityIdentifier("timeattack-next")
        }
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(Theme.ground.ignoresSafeArea())
        .animation(.easeInOut(duration: Theme.Duration.quick), value: index)
        .onAppear {
            guard !hasStarted else { return }
            hasStarted = true
            startedAt = Date()
            lapStartedAt = startedAt
        }
        #if DEBUG
        // Simulator の検証: `STRUIS_TIMEATTACK_AUTOPLAY` の秒数ごとに「次へ」を押し、最後は撮る(写真は `STRUIS_TIMEATTACK_PHOTO`)。
        .task {
            guard let step = ProcessInfo.processInfo.environment["STRUIS_TIMEATTACK_AUTOPLAY"].flatMap(Double.init) else { return }
            for _ in problems.indices {
                try? await Task.sleep(for: .seconds(step))
                advance()
            }
        }
        #endif
        .fullScreenCover(isPresented: $isCameraPresented) {
            TimeAttackCamera(
                onShutter: {
                    // 1回の撮影で最後の問題の時間を2回足さない(カメラ側でも2度押しは止めている)。
                    guard stoppedAt == nil else { return }
                    let now = Date()
                    laps.append(now.timeIntervalSince(lapStartedAt))
                    stoppedAt = now
                },
                onPhoto: { data in
                    guard isCameraPresented else { return }
                    isCameraPresented = false
                    onFinish(laps, data)
                },
                onCancel: {
                    // シャッターの後に失敗した時は、最後の問題の時間を戻して続ける。
                    if stoppedAt != nil, laps.count == problems.count { laps.removeLast() }
                    stoppedAt = nil
                    isCameraPresented = false
                }
            )
            .ignoresSafeArea()
        }
    }

    private func advance() {
        if isLast, !capturesPhoto {
            guard stoppedAt == nil else { return }
            let now = Date()
            laps.append(now.timeIntervalSince(lapStartedAt))
            stoppedAt = now
            onFinish(laps, nil)
            return
        }
        if isLast {
            isCameraPresented = true
            return
        }
        let now = Date()
        laps.append(now.timeIntervalSince(lapStartedAt))
        lapStartedAt = now
        index += 1
    }
}

// MARK: - 始める前(届いたリンク)

struct TimeAttackIntroView: View {
    let field: String
    let rival: TimeAttack.Entry?
    /// App Clip で今日あと何セット解けるか(本体は nil)。
    var setsLeft: Int?
    /// 最後に紙を撮るか(自分で採点すると決めている人には、撮らない流れを説明する)。
    var capturesPhoto = true
    var onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if let rival {
                    Text(rival.name.isEmpty ? "届いた記録" : "\(rival.name)さんから届いた記録")
                        .font(Typography.sans(size: 15, weight: .bold))
                    Text(TimeAttack.clock(rival.total)).font(.system(size: 56, weight: .bold)).monospacedDigit()
                }
                Text("\(field)　基礎 \(TimeAttack.problemCount)問")
                    .font(Typography.caption)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Theme.accentColor.opacity(0.16), in: Capsule())
                Text("同じ\(TimeAttack.problemCount)問を、このタイムより速く解けば勝ちです。")
                    .font(Typography.body).padding(.top, 6).multilineTextAlignment(.center)
            }
            .padding(.top, 28)

            VStack(spacing: 0) {
                rule("pencil", "紙とペンを用意して、上から順に書きます")
                Divider().overlay(Theme.hairline)
                if capturesPhoto {
                    rule("camera", "\(TimeAttack.problemCount)問解いたら、最後に1枚撮ります")
                    Divider().overlay(Theme.hairline)
                    rule("stopwatch", "問題が出てから撮るまでを計ります")
                } else {
                    rule("checkmark.circle", "\(TimeAttack.problemCount)問解いたら、正答と見比べて自分で○×をつけます")
                    Divider().overlay(Theme.hairline)
                    rule("stopwatch", "問題が出てから書き終えるまでを計ります")
                }
                Divider().overlay(Theme.hairline)
                rule("xmark", "誤答は1問につき +10秒")
                Divider().overlay(Theme.hairline)
                rule("person", "名前の入力も登録も要りません")
            }
            .padding(.horizontal, 16)
            .struisSurface(radius: Theme.Radius.cardLarge)
            .padding(.top, 24)

            Spacer(minLength: 16)

            if let setsLeft {
                Text(setsLeft > 0 ? "今日はあと\(setsLeft)回解けます" : "今日の分は使い切りました。明日また解けます")
                    .font(Typography.caption).foregroundStyle(Theme.secondaryText).padding(.bottom, 10)
            }
            Button(action: onStart) {
                Text("始める")
                    .font(Typography.sans(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .foregroundStyle(Theme.onAccent)
                    .background(Theme.accentColor.opacity((setsLeft ?? 1) > 0 ? 1 : 0.4), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled((setsLeft ?? 1) <= 0)
            .accessibilityIdentifier("timeattack-start")
        }
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        #if DEBUG
        .task {
            guard let step = ProcessInfo.processInfo.environment["STRUIS_TIMEATTACK_AUTOPLAY"].flatMap(Double.init) else { return }
            try? await Task.sleep(for: .seconds(step * 2))
            if (setsLeft ?? 1) > 0 { onStart() }
        }
        #endif
    }

    private func rule(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.accentColor).frame(width: 20)
            Text(text).font(Typography.bodyCompact)
            Spacer()
        }
        .frame(minHeight: 48)
    }
}

// MARK: - 結果

struct TimeAttackResultView: View {
    let session: TimeAttackSession
    /// 補助のボタン(本体は「もう一度」、App Clip は「似た問題を解く」)。
    let secondaryTitle: String
    var onSecondary: () -> Void
    var onClose: (() -> Void)?

    @State private var name = ""
    @State private var shareItems: ShareItems?
    @State private var shareError: String?

    private struct ShareItems: Identifiable {
        let id = UUID()
        let items: [Any]
    }

    var body: some View {
        if let mine = session.mine {
            ScrollView {
                VStack(spacing: 0) {
                    if let onClose {
                        HStack {
                            Button(action: onClose) {
                                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                                    .frame(width: 36, height: 36)
                                    .background(Theme.card.opacity(0.8), in: Circle())
                                    .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("閉じる")
                            .accessibilityIdentifier("timeattack-close")
                            Spacer()
                        }
                        .frame(height: 44)
                    }
                    hero(mine)
                    table(mine).padding(.top, 20)
                    actions(mine).padding(.top, 24)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .foregroundStyle(Theme.primaryText)
            .onAppear { name = session.local.nickname }
            .sheet(item: $shareItems) { share in
                TimeAttackShareSheet(items: share.items).presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private func hero(_ mine: TimeAttack.Entry) -> some View {
        VStack(spacing: 6) {
            Text(session.rival == nil ? "\(session.field) \(TimeAttack.problemCount)問の合計タイム" : "今回のタイム")
                .font(Typography.caption).foregroundStyle(Theme.secondaryText)
            Text(TimeAttack.clock(mine.total)).font(.system(size: 56, weight: .bold)).monospacedDigit()
                .accessibilityIdentifier("timeattack-total")
            if let rival = session.rival {
                let won = mine.total < rival.total
                badge(won ? "○ 勝ち" : "× 負け", color: won ? Theme.growthColor : Theme.regressColor)
                let gap = TimeAttack.seconds(abs(rival.total - mine.total))
                Text("\(rival.name.isEmpty ? "届いた記録" : rival.name + "さん")の \(TimeAttack.clock(rival.total)) より \(gap)\(won ? "速く" : "遅く")解きました")
                    .font(Typography.caption).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                if rival.selfMarked == true {
                    Text("\(rival.name.isEmpty ? "届いた記録" : rival.name + "さんの記録")は自分で採点したものです")
                        .font(Typography.caption).foregroundStyle(Theme.secondaryText)
                }
            } else if let best = session.previousBest {
                if mine.total < best {
                    badge("自己ベスト更新", color: Theme.growthColor)
                    Text("前回のベスト \(TimeAttack.clock(best))(\(TimeAttack.seconds(best - mine.total))短縮)")
                        .font(Typography.caption).foregroundStyle(Theme.secondaryText)
                } else {
                    Text("自己ベスト \(TimeAttack.clock(best))").font(Typography.caption).foregroundStyle(Theme.secondaryText)
                }
            } else {
                Text("初めての記録です").font(Typography.caption).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.top, 16)
        if mine.selfMarked == true {
            Text("自分で採点した記録です").font(Typography.caption).foregroundStyle(Theme.secondaryText).padding(.top, 4)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(Typography.sans(size: 12, weight: .bold))
            .foregroundStyle(Theme.ground)
            .padding(.horizontal, 12).frame(height: 28)
            .background(color, in: Capsule())
            .padding(.top, 6)
    }

    private func table(_ mine: TimeAttack.Entry) -> some View {
        let rival = session.rival
        return VStack(spacing: 0) {
            if let rival {
                HStack {
                    Spacer()
                    Text("今回").frame(width: 84, alignment: .trailing)
                    Text(rival.name.isEmpty ? "届いた記録" : rival.name).lineLimit(1).frame(width: 84, alignment: .trailing)
                }
                .font(Typography.caption).foregroundStyle(Theme.secondaryText)
                .frame(height: 36)
                Divider().overlay(Theme.hairline)
            }
            ForEach(session.problems.indices, id: \.self) { index in
                let problem = session.problems[index]
                HStack(spacing: 8) {
                    Text("\(index + 1)").foregroundStyle(Theme.secondaryText).frame(width: 18, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.math.isEmpty ? problem.prompt : TimeAttackMath.plain(problem.math)).lineLimit(1)
                        if mine.correct.indices.contains(index), !mine.correct[index] {
                            Text("正答 \(TimeAttackMath.plain(problem.answerKey))").font(Typography.micro).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Spacer()
                    cell(mine, index, primary: true)
                    if let rival { cell(rival, index, primary: false) }
                }
                .font(Typography.bodyCompact).monospacedDigit()
                .frame(minHeight: 44)
                Divider().overlay(Theme.hairline)
            }
            HStack {
                Text(rival == nil ? "解いた時間 \(TimeAttack.clock(mine.solvedSeconds))" : "× の問題は 10秒を足した時間です")
                Spacer()
                if rival == nil { Text("誤答 \(mine.wrongCount)問 +\(Int(TimeAttack.penaltySeconds) * mine.wrongCount)秒") }
            }
            .font(Typography.caption).foregroundStyle(Theme.secondaryText)
            .frame(height: 40)
        }
        .padding(.horizontal, 16)
        .struisSurface(radius: Theme.Radius.cardLarge)
    }

    private func cell(_ entry: TimeAttack.Entry, _ index: Int, primary: Bool) -> some View {
        let correct = entry.correct.indices.contains(index) && entry.correct[index]
        return HStack(spacing: 4) {
            Text(correct ? "○" : "×").fontWeight(.bold).foregroundStyle(correct ? Theme.growthColor : Theme.regressColor)
            Text(TimeAttack.seconds(session.rival == nil ? (entry.laps.indices.contains(index) ? entry.laps[index] : 0) : entry.seconds(at: index)))
                .foregroundStyle(primary ? Theme.primaryText : Theme.secondaryText)
            if session.rival == nil, !correct { Text("+10秒").font(Typography.caption).fontWeight(.bold) }
        }
        .frame(minWidth: 84, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    private func actions(_ mine: TimeAttack.Entry) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("相手に見せる名前").font(Typography.bodyCompact).foregroundStyle(Theme.secondaryText).fixedSize()
                TextField("\(TimeAttack.nicknameLimit)文字まで", text: $name)
                    .font(Typography.sans(size: 15))
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                    .onChange(of: name) { _, value in
                        if value.count > TimeAttack.nicknameLimit { name = String(value.prefix(TimeAttack.nicknameLimit)) }
                    }
                    .accessibilityIdentifier("timeattack-name")
            }
            Button(action: share) {
                Label(session.rival == nil ? "友達に送る" : "送り返す", systemImage: session.rival == nil ? "square.and.arrow.up" : "arrowshape.turn.up.left")
                    .font(Typography.sans(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .foregroundStyle(Theme.onAccent)
                    .background(Theme.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timeattack-share")
            Button(action: onSecondary) {
                Text(secondaryTitle)
                    .font(Typography.body)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Theme.accentColor.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timeattack-secondary")
            Text(shareError ?? "送るのは\(TimeAttack.problemCount)問と正答(暗号化)、タイム、この名前だけです。名前はこの端末に残し、次から自動で入ります。")
                .font(Typography.caption).foregroundStyle(shareError == nil ? Theme.secondaryText : Theme.regressColor)
                .multilineTextAlignment(.center).lineSpacing(4)
        }
    }

    private func share() {
        do {
            let url = try session.shareURL(name: name)
            let shown = TimeAttack.trimmedName(name)
            let total = session.mine?.total ?? 0
            let text = "Struis のタイムアタック(\(session.field) 基礎\(TimeAttack.problemCount)問)で \(TimeAttack.clock(total))。このタイム、抜けますか。\n\(url.absoluteString)"
            var items: [Any] = [text]
            if let image = TimeAttackShareCard.image(field: session.field, name: shown, total: total) { items.insert(image, at: 0) }
            shareError = nil
            shareItems = ShareItems(items: items)
        } catch {
            shareError = "送るリンクを作れませんでした。"
        }
    }
}

// MARK: - 自分で採点する

/// 写真を送らない時: 正答を見て、紙の答えと見比べて本人が○×をつける。
struct TimeAttackSelfCheckView: View {
    let problems: [TimeAttack.Problem]
    var onSubmit: ([Bool]) -> Void

    @State private var marks: [Bool?] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("正答と見比べて、○か×を選んでください。").font(Typography.sans(size: 17, weight: .bold))
                Text("タイムはもう止まっています。誤答は1問につき10秒を足します。").font(Typography.caption).foregroundStyle(Theme.secondaryText)
                VStack(spacing: 0) {
                    ForEach(problems.indices, id: \.self) { index in
                        row(index)
                        if index < problems.count - 1 { Divider().overlay(Theme.hairline) }
                    }
                }
                .padding(.horizontal, 16)
                .struisSurface(radius: Theme.Radius.cardLarge)
                Button {
                    onSubmit(marks.map { $0 ?? false })
                } label: {
                    Text("これで決める").font(Typography.sans(size: 17, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(Theme.onAccent)
                        .background(Theme.accentColor.opacity(isComplete ? 1 : 0.4), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!isComplete)
                .accessibilityIdentifier("timeattack-selfcheck-submit")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .foregroundStyle(Theme.primaryText)
        .onAppear { if marks.count != problems.count { marks = Array(repeating: nil, count: problems.count) } }
        #if DEBUG
        // Simulator の確認: `STRUIS_TIMEATTACK_AUTOPLAY` の時は、最後だけ × にして決める。
        .task {
            guard let step = ProcessInfo.processInfo.environment["STRUIS_TIMEATTACK_AUTOPLAY"].flatMap(Double.init) else { return }
            try? await Task.sleep(for: .seconds(step * 2))
            marks = problems.indices.map { $0 < problems.count - 1 }
            try? await Task.sleep(for: .seconds(step * 2))
            onSubmit(marks.map { $0 ?? false })
        }
        #endif
    }

    private var isComplete: Bool { marks.count == problems.count && marks.allSatisfy { $0 != nil } }

    private func row(_ index: Int) -> some View {
        let problem = problems[index]
        return HStack(spacing: 10) {
            Text("\(index + 1)").foregroundStyle(Theme.secondaryText).frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(problem.math.isEmpty ? problem.prompt : TimeAttackMath.plain(problem.math))
                    .font(Typography.bodyCompact).lineLimit(1)
                HStack(spacing: 6) {
                    Text("正答").font(Typography.caption).foregroundStyle(Theme.secondaryText)
                    TimeAttackMath(latex: problem.answerKey, size: 20)
                }
            }
            .padding(.vertical, 10)
            Spacer()
            mark(index, value: true, symbol: "○", color: Theme.growthColor)
            mark(index, value: false, symbol: "×", color: Theme.regressColor)
        }
        .frame(minHeight: 64)
    }

    private func mark(_ index: Int, value: Bool, symbol: String, color: Color) -> some View {
        let selected = marks.indices.contains(index) && marks[index] == value
        return Button {
            if marks.indices.contains(index) { marks[index] = value }
        } label: {
            Text(symbol).font(.system(size: 20, weight: .bold))
                .foregroundStyle(selected ? Theme.ground : color)
                .frame(width: 44, height: 44)
                .background(selected ? color : color.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(index + 1)問目を\(value ? "正解" : "誤答")にする")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 待ち・失敗

struct TimeAttackWaitView: View {
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(text).font(Typography.body).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("timeattack-wait")
    }
}

struct TimeAttackFailedView: View {
    let message: String
    var retryTitle: String?
    var onRetry: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(message).font(Typography.body).multilineTextAlignment(.center)
            if let retryTitle {
                Button(action: onRetry) {
                    Text(retryTitle).font(Typography.sans(size: 17, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(Theme.onAccent)
                        .background(Theme.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Button("閉じる", action: onClose).font(Typography.body)
        }
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("timeattack-failed")
    }
}
#endif
