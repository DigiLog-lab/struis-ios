import SwiftUI

/// 1 枚の問題(画面 1・3・4・8)。単元・問題文・式の順に、画面の上に寄せて並べる。
struct TimelineProblemView: View {
    let card: TimelineCardRecord
    let store: TimelineStore
    var compact = false

    private var chain: (position: Int, total: Int)? { TimelineRules.chainPosition(card) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
            if !compact { chips }
            if let problem = card.payload["problem"]?.stringValue, card.kind != "solve", card.kind != "predict" {
                Text(problem).font(Typography.sans(size: 15, weight: .medium)).foregroundStyle(Theme.secondaryText)
            }
            if !card.prompt.isEmpty {
                Text(card.prompt)
                    .font(Typography.sans(size: compact ? 15 : 22, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("timeline-prompt")
            }
            if !card.math.isEmpty, card.kind == "solve" || card.kind == "predict" {
                TimelineMath(latex: card.math, size: compact ? 20 : 34)
            }
            if !card.question.isEmpty {
                TimelineQuestionText(text: card.question, changed: card.chain?["changed"]?.stringValue, size: compact ? 15 : 20)
            }
            if !compact, let previous = card.chain?["previous"]?.stringValue, !previous.isEmpty {
                Label("前は \(previous)", systemImage: TimelineSymbol.past)
                    .font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
            }
            if !compact, card.kind == "solve" {
                if card.level >= 3, card.skills.count > 1 { TimelineProcedureList(card: card, store: store) }
                Label(card.level <= 1 || card.origin == "rapid" ? "答えだけでOK" : (card.level >= 3 ? "途中まででOK" : "書いて撮る"), systemImage: TimelineSymbol.pencil)
                    .font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
            }
        }
        .opacity(compact ? 0.55 : 1)
    }

    @ViewBuilder
    private var chips: some View {
        HStack(spacing: 8) {
            if store.badge == .resume, store.currentID == card.id {
                TimelineChip(text: "昨日", symbol: TimelineSymbol.past, tinted: true)
            } else if let chain, chain.position > 1 {
                TimelineChip(text: "続き", symbol: TimelineSymbol.chain, tinted: true)
            } else if card.origin == "easier" {
                TimelineChip(text: "一段戻す", symbol: TimelineSymbol.past, tinted: true)
            } else if let unit = store.unitChip(for: card) {
                TimelineChip(text: unit, tinted: true).accessibilityIdentifier("timeline-unit-chip")
            }
            if card.level <= 1 || card.origin == "rapid" || card.origin == "history" {
                TimelineChip(text: "\(card.estimatedSeconds)秒", symbol: TimelineSymbol.clock)
            }
            if let number = TimelineCards.Kind(rawValue: card.kind)?.number {
                TimelineChip(text: TimelineCards.Kind(rawValue: card.kind)?.title, symbol: nil).accessibilityLabel("カード \(number)")
            }
            Spacer(minLength: 0)
            if let chain { TimelineChainBar(position: chain.position, total: chain.total) }
        }
    }
}

/// 難しそうな問題に並べる、使う手順。今日もう解いた手順は ○ の数、新しい手順だけ縁取り。
struct TimelineProcedureList: View {
    let card: TimelineCardRecord
    let store: TimelineStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(card.skills, id: \.self) { skill in
                if store.isNewSkill(skill) {
                    Button { store.openHowto() } label: {
                        HStack {
                            Text(store.skillName(skill)).font(Typography.sans(size: 15, weight: .bold))
                            Spacer()
                            Label("見る", systemImage: TimelineSymbol.new).font(Typography.sans(size: 13, weight: .bold))
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(Theme.primaryText)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(Theme.accentColor.opacity(0.14), in: Capsule())
                        .overlay(Capsule().stroke(Theme.accentColor, lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("timeline-howto-open")
                    // 書く面の上にあっても押せるようにする。
                    .timelineInkPassThrough()
                } else {
                    HStack {
                        Text(store.skillName(skill)).font(Typography.sans(size: 15, weight: .medium))
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(0..<min(3, store.solvedToday(skill)), id: \.self) { _ in TimelineMark(correct: true, size: 11) }
                        }
                    }
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(Theme.hairline, in: Capsule())
                }
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
    }
}

/// 新しい手順のときだけの「やり方の確認」(画面 5)。できる手順は1行にたたみ、新しい手順は図で見せる。
struct TimelineHowtoView: View {
    let card: TimelineCardRecord
    let store: TimelineStore
    let onAsk: () -> Void

    private var cases: [LedgerJSON] { card.payload["howto"]?["diagram"]?["cases"]?.arrayValue ?? [] }
    private var steps: [String] { card.payload["steps"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                TimelineChip(text: "確認", symbol: TimelineSymbol.book, tinted: true)
                ZStack {
                    Image(systemName: TimelineSymbol.camera)
                    Rectangle().frame(width: 22, height: 2).rotationEffect(.degrees(-35))
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.hairline, in: Capsule())
                .accessibilityLabel("撮らなくてよい")
            }
            Text([TimelineMath.plain(card.math), card.question].filter { !$0.isEmpty }.joined(separator: "  "))
                .font(Typography.sans(size: 17, weight: .bold)).foregroundStyle(Theme.primaryText)
            ForEach(Array(card.skills.enumerated()), id: \.offset) { index, skill in
                if store.isNewSkill(skill) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("\(index + 1)").font(Typography.ordinal).foregroundStyle(Theme.secondaryText)
                            Text(store.skillName(skill)).font(Typography.sans(size: 17, weight: .bold))
                            Spacer()
                            Label("新しい", systemImage: TimelineSymbol.new).font(Typography.sans(size: 13, weight: .bold))
                        }
                        if cases.isEmpty {
                            Text(card.payload["howto"]?["note"]?.stringValue ?? steps.joined(separator: "\n"))
                                .font(Typography.sans(size: 15, weight: .medium)).foregroundStyle(Theme.secondaryText)
                        } else {
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(Array(cases.enumerated()), id: \.offset) { _, item in
                                    VStack(spacing: 6) {
                                        TimelineRangeDiagram(position: item["position"]?.stringValue ?? "straddle", minAt: item["min_at"]?.stringValue ?? "vertex")
                                        Text(item["label"]?.stringValue ?? "").font(Typography.sans(size: 13, weight: .medium)).multilineTextAlignment(.center)
                                    }
                                }
                            }
                            HStack(spacing: 6) {
                                Circle().fill(Theme.primaryText).frame(width: 9, height: 9)
                                Text("が最小").font(Typography.sans(size: 13, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(16)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.accentColor, lineWidth: 1.2))
                } else {
                    HStack {
                        Text("\(index + 1)").font(Typography.ordinal).foregroundStyle(Theme.secondaryText)
                        Text(store.skillName(skill)).font(Typography.sans(size: 15, weight: .medium))
                        Spacer()
                        TimelineMark(correct: true)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Theme.hairline, in: Capsule())
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 12) {
                Button { Task { await store.solveSameForm() } } label: {
                    Label("同じ形を 1 問解く", systemImage: TimelineSymbol.next)
                        .font(Typography.sans(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .foregroundStyle(Theme.onAccent)
                        .background(Theme.accentColor, in: Capsule())
                }
                .accessibilityIdentifier("timeline-howto-solve")
                Button(action: onAsk) {
                    Label("質問", systemImage: TimelineSymbol.ask)
                        .font(Typography.sans(size: 16, weight: .bold))
                        .padding(.horizontal, 20).padding(.vertical, 16)
                        .foregroundStyle(Theme.primaryText)
                        .background(Theme.accentColor.opacity(0.16), in: Capsule())
                }
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-howto")
    }
}

/// 結果の画面(画面 2・6・9)。問題は薄く小さくして上に残し、区切り線の下に正誤と秒数、答え。
struct TimelineResultView: View {
    let card: TimelineCardRecord
    let attempt: TimelineAttemptRecord
    let store: TimelineStore

    private var correct: Bool { attempt.verdict == "correct" }
    private var checkpoints: [LedgerJSON] { attempt.checkpointResults.arrayValue?.filter { $0["text"] != nil } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TimelineProblemView(card: card, store: store, compact: true)
            Divider()
            HStack(spacing: 10) {
                TimelineMark(correct: correct, size: 22)
                Text(correct ? "正解" : "誤答").font(Typography.sans(size: 24, weight: .bold))
                Text("\(Int(attempt.seconds.rounded()))秒").font(Typography.sans(size: 15, weight: .medium)).foregroundStyle(Theme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(correct ? "timeline-result-correct" : "timeline-result-wrong")
            if attempt.keySuspect {
                Text("この問題の答えが間違っていました。正解にしました。")
                    .font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
            }
            if !card.answerKey.isEmpty, TimelineCards.Kind(rawValue: card.kind)?.needsReading ?? false {
                Text(card.answerKey).font(Typography.sans(size: 18, weight: .bold)).foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !correct, !checkpoints.isEmpty {
                // どの場合が抜けたか(書けた場合に ○、抜けた場合に ×。地の色も変える)。
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(checkpoints.enumerated()), id: \.offset) { _, item in
                        let ok = item["result"]?.stringValue == "correct"
                        HStack(alignment: .top, spacing: 8) {
                            TimelineMark(correct: ok)
                            Text(item["text"]?.stringValue ?? "").font(Typography.sans(size: 13, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(ok ? Theme.growthColor.opacity(0.10) : Theme.regressColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-checkpoints")
            }
            if !attempt.feedback.isEmpty {
                Text(attempt.feedback).font(Typography.sans(size: 14, weight: .medium)).foregroundStyle(Theme.secondaryText)
            }
            if let predicted = prediction {
                HStack(spacing: 6) {
                    Text("予想").font(Typography.sans(size: 13, weight: .bold))
                    TimelineMark(correct: predicted)
                }
            }
            if store.reveals { reveal }
        }
    }

    /// 08 解く前に予想: 解いた後に、予想と答え合わせ。
    private var prediction: Bool? {
        guard card.kind == "solve" else { return nil }
        let predicts = store.machine.cards.values.filter { $0.kind == "predict" && $0.payload["base_card_id"]?.stringValue == card.id }
        guard let predict = predicts.first, let answer = store.machine.attempts(cardID: predict.id).last else { return nil }
        return answer.verdict == "correct"
    }

    /// 解き終わったら、難しさを明かす: 角帽と「入試の形」、単元の進み(ゴールが近いときだけ「あと 1」)。
    private var reveal: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: TimelineSymbol.exam).font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("入試の形").font(Typography.sans(size: 20, weight: .bold))
                    if !card.typeName.isEmpty { Text(card.typeName).font(Typography.sans(size: 14, weight: .medium)).foregroundStyle(Theme.secondaryText) }
                }
            }
            if let progress = store.unitProgress(for: card) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(progress.title).font(Typography.sans(size: 13, weight: .medium))
                        Spacer()
                        Text("\(progress.passed) / \(progress.total)").font(Typography.sans(size: 13, weight: .bold)).monospacedDigit()
                    }
                    ProgressView(value: Double(progress.passed), total: Double(max(1, progress.total))).tint(Theme.accentColor)
                    if progress.total - progress.passed == 1 {
                        Label("あと 1", systemImage: TimelineSymbol.stairs).font(Typography.sans(size: 13, weight: .bold))
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-reveal")
    }
}

/// 10 種のうち、端末の中で採点するカード(タップ・ドラッグ・払う)。
struct TimelineInteractiveCard: View {
    let card: TimelineCardRecord
    let store: TimelineStore
    @State private var order: [Int] = []
    @State private var sorted: [Bool] = []
    @State private var sortOffset: CGFloat = 0
    @State private var pairs: [Int: Int] = [:]
    @State private var pickedGraph: Int?
    @State private var chosen: Int?

    private var kind: TimelineCards.Kind? { TimelineCards.Kind(rawValue: card.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch kind {
            case .order: orderCard
            case .findError: choices(lines: strings("lines"), header: nil)
            case .nextStep:
                ForEach(Array(strings("shown").enumerated()), id: \.offset) { _, line in
                    Text(line).font(Typography.sans(size: 16, weight: .medium)).foregroundStyle(Theme.secondaryText)
                }
                choices(lines: strings("options"), header: nil)
            case .compare: compareCard
            case .reason, .predict: choices(lines: strings("options"), header: nil)
            case .sort: sortCard
            case .graphMatch: graphCard
            default: EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-card-\(card.kind)")
        .onAppear {
            order = card.payload["shuffled"]?.arrayValue?.compactMap(\.intValue) ?? []
        }
    }

    private func strings(_ key: String) -> [String] { card.payload[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    private func choices(lines: [String], header: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Button {
                    chosen = index
                    Task { await store.answer(.number(Double(index))) }
                } label: {
                    Text(line)
                        .font(Typography.sans(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 13)
                        .foregroundStyle(Theme.primaryText)
                        .background(chosen == index ? Theme.accentColor.opacity(0.18) : Theme.card, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(chosen == index ? Theme.accentColor : Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(chosen != nil)
                .accessibilityIdentifier("timeline-choice-\(index)")
            }
        }
    }

    /// 01 手順の並び替え(指でドラッグ)。
    private var orderCard: some View {
        let steps = strings("steps")
        return VStack(alignment: .leading, spacing: 10) {
            List {
                ForEach(order, id: \.self) { index in
                    Text(steps.indices.contains(index) ? steps[index] : "")
                        .font(Typography.sans(size: 15, weight: .medium))
                        .listRowBackground(Theme.card)
                }
                .onMove { from, to in order.move(fromOffsets: from, toOffset: to) }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .frame(height: CGFloat(max(1, steps.count)) * 52)
            .accessibilityIdentifier("timeline-order-list")
            Button("この順で決める") {
                Task { await store.answer(.array(order.map { .number(Double($0)) })) }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("timeline-order-submit")
        }
    }

    /// 03 2つの解き方を比べる。
    private var compareCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(["a", "b"], id: \.self) { side in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.payload["\(side)_title"]?.stringValue ?? "").font(Typography.sans(size: 12, weight: .bold))
                        ForEach(strings("\(side)_lines"), id: \.self) { Text($0).font(Typography.sans(size: 14, weight: .medium)) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            choices(lines: strings("options"), header: nil)
        }
    }

    /// 07 左右に仕分け(左右に払う)。
    private var sortCard: some View {
        let items = card.payload["items"]?.arrayValue ?? []
        let index = sorted.count
        return VStack(spacing: 16) {
            if index < items.count {
                Text(items[index]["text"]?.stringValue ?? "")
                    .font(Typography.sans(size: 26, weight: .medium))
                    .frame(width: 240, height: 140)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 6)
                    .rotationEffect(.degrees(Double(sortOffset / 20)))
                    .offset(x: sortOffset)
                    .gesture(DragGesture().onChanged { sortOffset = $0.translation.width }.onEnded { value in
                        if abs(value.translation.width) > 80 { place(value.translation.width > 0, count: items.count) }
                        withAnimation { sortOffset = 0 }
                    })
                    .accessibilityIdentifier("timeline-sort-item")
                HStack {
                    Button { place(false, count: items.count) } label: { Label(card.payload["left_label"]?.stringValue ?? "左", systemImage: "arrow.left") }
                        .accessibilityIdentifier("timeline-sort-left")
                    Spacer()
                    Button { place(true, count: items.count) } label: { Label(card.payload["right_label"]?.stringValue ?? "右", systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle()) }
                        .accessibilityIdentifier("timeline-sort-right")
                }
                .font(Typography.sans(size: 15, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                Text("\(index + 1) / \(items.count)").font(Typography.caption).foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func place(_ right: Bool, count: Int) {
        sorted.append(right)
        if sorted.count == count { Task { await store.answer(.array(sorted.map(LedgerJSON.bool))) } }
    }

    /// 06 グラフと式を結ぶ(グラフを押してから式を押す)。
    private var graphCard: some View {
        let exprs = strings("exprs")
        let graphs = card.payload["graph_order"]?.arrayValue?.compactMap(\.intValue) ?? []
        return VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Array(graphs.enumerated()), id: \.offset) { slot, expression in
                    Button { pickedGraph = slot } label: {
                        VStack {
                            TimelineFunctionPlot(expression: exprs.indices.contains(expression) ? exprs[expression] : "", highlighted: pickedGraph == slot)
                            Text(pairs[slot].map { "式 \($0 + 1)" } ?? "?").font(Typography.caption)
                        }
                        .padding(6)
                        .background(pickedGraph == slot ? Theme.accentColor.opacity(0.12) : Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("timeline-graph-\(slot)")
                }
            }
            ForEach(Array(exprs.enumerated()), id: \.offset) { index, expression in
                Button {
                    guard let slot = pickedGraph else { return }
                    pairs[slot] = index
                    pickedGraph = nil
                    if pairs.count == graphs.count { Task { await store.answer(.array((0..<graphs.count).map { .number(Double(pairs[$0] ?? -1)) })) } }
                } label: {
                    Text("式 \(index + 1):  y = \(expression)")
                        .font(Typography.sans(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("timeline-expr-\(index)")
            }
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon }
    }
}

/// 04 1行だけ穴埋め・09 逆に作る(指で書いて送る)。
struct TimelineWritingPrompt: View {
    let card: TimelineCardRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if card.kind == "fill_line" {
                let lines = card.payload["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let hidden = card.payload["hidden"]?.intValue ?? -1
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    if index == hidden {
                        RoundedRectangle(cornerRadius: 10).fill(Theme.accentColor.opacity(0.14)).frame(height: 40)
                            .overlay(Text("?").font(Typography.sans(size: 17, weight: .bold)))
                    } else {
                        Text(line).font(Typography.sans(size: 17, weight: .medium))
                    }
                }
            } else if let note = card.payload["note"]?.stringValue {
                Text(note).font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}
