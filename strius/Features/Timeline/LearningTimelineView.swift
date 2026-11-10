import SwiftUI

/// 起動したら最初に出る、1問ずつの全画面の「タイムライン」(Issue #46)。ブランド名は出さない。
/// 操作は右下の縦並び(上から 質問・飛ばす・撮る)、下の帯に次の問題の1行目を常に見せ、上に送ると次へ進む。
/// 上の帯と下の帯の間は、問題文の上も含めて画面の端から端まで指で書ける。次へ進むのは、下の帯を上に送ったときだけ。
/// iPad で横幅が広い時(Issue #55)は、書く道具を右上に、「送る」を右下に常に置き(書くまで押せない)、結果でも送った手書きを残す。
/// ペンの太さと消しゴムは、書ける間だけ出す標準の道具パレット(ペン1本と消しゴムだけ)で選ぶ。
/// 横向きは問題を左の列に置いて右を全部紙にし、下の帯を問題の列の下だけにして右下まで書けるようにする。
struct LearningTimelineView: View {
    let store: TimelineStore
    let onOpenUnits: () -> Void
    var layout: TimelineLayout = .compact
    @Environment(WorkbookCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasInk = false
    @State private var ink = TimelineInkController()
    @State private var inkGeneration = 0
    @State private var isDrawing = false
    @State private var isInkZoomed = false
    @State private var inkPassThrough: [CGRect] = []
    /// 書く面の左上(`TimelineInkSpace.name` の座標)。iPad は画面の上端から置くので、安全域の分だけマイナスになる。
    @State private var inkOrigin: CGPoint = .zero
    /// 上の帯と下の帯の間(`TimelineInkSpace.name` の座標)。iPhone の並びの書く面はここに置く。
    @State private var inkArea: CGRect = .zero
    @State private var isCameraPresented = false
    @State private var dragOffset: CGFloat = 0
    @State private var isResultAskPresented = false
    @State private var isDisputePresented = false
    @State private var disputeDraft = ""

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Theme.card, Theme.ground], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, layout.isPad ? 24 : 20)
                    .padding(.top, 8)
                if let focus = store.pinnedFocus {
                    // 押せない1行なので、書く面の指は通さない(iPad は書く面がこの行の上にも乗る)。前は指を通していて、
                    // この行は Spacer で画面の幅いっぱいに広がるため、固定中は画面の端から端までの帯で書き始められなかった。
                    TimelineScopeFocus(title: focus.title, marks: focus.marks)
                        .padding(.horizontal, layout.isPad ? 24 : 20)
                        .padding(.top, 10)
                }
                ZStack(alignment: .bottomTrailing) {
                    content
                        .padding(.leading, layout.isPad ? TimelineLayout.columnLeading : 24)
                        .padding(.trailing, layout == .padLandscape ? 0 : 24)
                        .padding(.top, 16)
                        // 横向きは下の帯が問題の列の下に重なるので、その分を空ける。
                        .padding(.bottom, layout == .padLandscape ? 132 : 0)
                        .frame(width: layout == .padLandscape ? TimelineLayout.columnLeading + TimelineLayout.columnWidth : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if showsInkHint { inkHint }
                    actions
                        .timelineInkPassThrough()
                        .padding(.trailing, layout.isPad ? 28 : 20)
                        .padding(.bottom, layout == .padLandscape ? 32 : 16)
                        // 書いている間はボタンを薄くして、下に書いた字を透かす。
                        .opacity(isDrawing ? 0.35 : 1)
                }
                .offset(y: min(0, dragOffset) * 0.35)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TimelineInkSpace.name)) } action: { inkArea = $0 }
                if layout != .padLandscape { nextStrip }
            }
            // iPad 横向きの下の帯(問題の列の下だけ)。外の ZStack に直接置く。前は問題の欄の overlay に置いていて、
            // 面が画面の下端まで伸びず、帯の下にホームインジケータの高さの隙間が残っていた。
            if layout == .padLandscape {
                nextStrip
                    .frame(width: TimelineLayout.stripWidth)
                    .padding(.leading, TimelineLayout.stripLeading)
                    .offset(y: min(0, dragOffset) * 0.35)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            if showsInk { placedInkLayer }
            if store.skipBannerAttemptID != nil { skipBanner.transition(.move(edge: .top).combined(with: .opacity)) }
            if let error = store.actionError {
                Text(error)
                    .font(Typography.sans(size: 14, weight: .medium))
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 60)
                    .onTapGesture { store.dismissError() }
                    .accessibilityIdentifier("timeline-error")
            }
        }
        // 指を通す区画は、画面全体(この ZStack)の座標で集め、書く面の位置を引いて書く面の座標に直す。
        .coordinateSpace(name: TimelineInkSpace.name)
        .onPreferenceChange(TimelineInkPassThroughKey.self) { inkPassThrough = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-screen")
        .animation(.easeInOut(duration: Theme.Duration.standard), value: store.phase)
        .animation(.easeInOut(duration: Theme.Duration.standard), value: store.currentID)
        .task { await store.start() }
        .onChange(of: scenePhase) { _, phase in Task { await store.scenePhaseChanged(phase) } }
        .onChange(of: store.currentID) { _, _ in clearInk() }
        .background {
            ChatCameraPresentation(isPresented: $isCameraPresented) { data in
                Task { await store.submit(image: data) }
            }
        }
        .sheet(isPresented: Binding(get: { store.isScopeSheetPresented }, set: { store.isScopeSheetPresented = $0 })) {
            TimelineScopeSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.card)
        }
        .sheet(isPresented: Binding(get: { store.isStopSheetPresented }, set: { store.isStopSheetPresented = $0 })) {
            TimelineStopSheet(store: store)
                .presentationDetents([.medium])
                .presentationBackground(Theme.card)
        }
    }

    // MARK: 上端

    private var topBar: some View {
        HStack {
            Button(action: onOpenUnits) {
                Label("単元", systemImage: TimelineSymbol.units)
                    .font(Typography.sans(size: 16, weight: .bold))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .foregroundStyle(Theme.primaryText)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .timelineInkPassThrough()
            .accessibilityIdentifier("timeline-units-button")
            scopeChip
            if layout.isPad {
                // iPad: 「今日」は「単元」の隣に置き、右上は書く道具にする。
                todayCount.padding(.leading, 16)
                Spacer()
                if showsInkTools { inkTools }
            } else {
                Spacer()
                todayCount
            }
        }
        // iPad: 書く道具(44pt)が出入りしても、上の帯の高さを変えない。
        .frame(minHeight: layout.isPad ? 44 : nil)
        .padding(.top, layout.isPad ? 8 : 0)
        // 下に引いたら、やめようとしたとみなしてシートを出す。
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.height > 80 { store.isStopSheetPresented = true }
        })
    }

    /// 解く範囲のチップ: 「おまかせ ⌄」、固定中は銅の「微分積分 ✕」(✕ でおまかせに戻す)。
    @ViewBuilder
    private var scopeChip: some View {
        if let unit = store.pinnedUnit {
            HStack(spacing: 0) {
                Button { store.isScopeSheetPresented = true } label: {
                    Text(unit.title)
                        .font(Typography.sans(size: 15, weight: .bold))
                        .lineLimit(1)
                        .foregroundStyle(Theme.primaryText)
                        .padding(.leading, 14).padding(.trailing, 4)
                        .frame(height: 40)
                }
                .accessibilityLabel("解く範囲: \(unit.title)")
                .accessibilityIdentifier("timeline-scope-chip")
                Button { Task { await store.setScope(nil) } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 36, height: 40)
                }
                .accessibilityLabel("固定を外す")
                .accessibilityIdentifier("timeline-scope-clear")
            }
            .buttonStyle(.plain)
            .background(Theme.accentColor.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(Theme.accentColor.opacity(0.35), lineWidth: 1))
            .timelineInkPassThrough()
        } else {
            Button { store.isScopeSheetPresented = true } label: {
                HStack(spacing: 4) {
                    Text("おまかせ")
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                }
                .font(Typography.sans(size: 15, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .timelineInkPassThrough()
            .accessibilityLabel("解く範囲: おまかせ")
            .accessibilityIdentifier("timeline-scope-chip")
        }
    }

    private var todayCount: some View {
        Button { store.isStopSheetPresented = true } label: {
            Text("今日 \(store.answeredToday)問").font(Typography.sans(size: 15, weight: .medium)).foregroundStyle(Theme.secondaryText).monospacedDigit()
        }
        .buttonStyle(.plain)
        .timelineInkPassThrough()
        .accessibilityIdentifier("timeline-today-count")
    }

    /// iPad の右上の書く道具は、書ける間だけ出す(採点中・結果では書き足せない)。
    private var showsInkTools: Bool {
        guard showsInk else { return false }
        return store.phase == .solving || isRapid
    }

    /// iPad の右上の書く道具: 「1つ戻す」・「全部消す」(書くまでは薄く押せない)。縮めた時は「元の大きさ」。
    /// ペンの太さと消しゴムは、標準の道具パレット(`TimelineInkCanvas` の `showsToolPicker`)で選ぶ。
    private var inkTools: some View {
        HStack(spacing: 10) {
            if isInkZoomed {
                Button("元の大きさ") { ink.resetZoom() }
                    .font(Typography.sans(size: 13, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                    .accessibilityIdentifier("timeline-ink-zoom-reset")
            }
            inkToolButton(symbol: TimelineSymbol.undo, label: "1つ戻す", identifier: "timeline-ink-undo") { ink.undo() }
            inkToolButton(symbol: TimelineSymbol.clear, label: "全部消す", identifier: "timeline-ink-clear") { ink.clear() }
        }
        .buttonStyle(.plain)
        .timelineInkPassThrough()
        .opacity(isDrawing ? 0.35 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-ink-tools")
    }

    private func inkToolButton(symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 44, height: 44)
                .background(Theme.card, in: Circle())
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                .opacity(hasInk ? 1 : 0.4)
        }
        .disabled(!hasInk)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// iPad: まだ何も書いていない時、紙の真ん中に ✎「どこにでも書けます」(押せない飾り)。
    private var showsInkHint: Bool {
        layout.isPad && showsInkTools && !hasInk && !isInkZoomed
    }

    private var inkHint: some View {
        let hint = VStack(spacing: 8) {
            Image(systemName: TimelineSymbol.pencil).font(.system(size: 26, weight: .medium))
            Text("どこにでも書けます").font(Typography.sans(size: 15, weight: .medium))
        }
        .foregroundStyle(Theme.tertiaryText)
        return VStack(spacing: 0) {
            // 縦向きは問題の下の紙(下半分)の真ん中、横向きは問題の列の右の紙の真ん中。
            if layout == .padPortrait { Color.clear }
            hint.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.leading, layout == .padLandscape ? TimelineLayout.columnLeading + TimelineLayout.columnWidth : 0)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("timeline-ink-hint")
    }

    // MARK: 中身

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .guide:
            guide
        case .waiting:
            VStack(alignment: .leading, spacing: 12) {
                ProgressView()
                Text("問題を用意しています").font(Typography.sans(size: 17, weight: .bold)).foregroundStyle(Theme.primaryText)
                // AI が今していること(実際に届いた出来事)と、出来事が来ない時の事実。1 分を超えたら「止める」を出す。
                if let batchID = store.awaitedBatchID {
                    TurnLiveLine(keys: [TurnActivityKey.target(batchID)], onStop: { Task { await store.stopBatch() } })
                        .frame(maxWidth: 320, alignment: .leading)
                        .accessibilityIdentifier("timeline-waiting-live")
                }
            }
            .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-waiting")
        case .batchFailed(let reason):
            VStack(alignment: .leading, spacing: 12) {
                Text(TimelineTurns.batchFailure).font(Typography.sans(size: 17, weight: .bold)).foregroundStyle(Theme.primaryText)
                let shown: String = TimelineTurns.batchFailureReason(reason)
                if !shown.isEmpty { Text(shown).font(Typography.micro).foregroundStyle(Theme.secondaryText).lineLimit(3) }
                Button("もう一度") { Task { await store.retryBatch() } }.buttonStyle(.bordered).accessibilityIdentifier("timeline-batch-retry")
            }
            .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-batch-failed")
        case .limitReached(let denial):
            // 利用枠で止まった(#78): 新しいカードは出さず、案内のシートへ。閉じた後もここから開き直せる。
            VStack(alignment: .leading, spacing: 12) {
                Text(denial == .noPlan ? "お試しの3問を使い切りました" : "今週の利用枠を使い切りました")
                    .font(Typography.sans(size: 17, weight: .bold)).foregroundStyle(Theme.primaryText)
                Text(denial == .noPlan ? "続けるには、プランを選んでください。" : "枠が戻るか、プランを上げると、次の問題を出します。")
                    .font(Typography.micro).foregroundStyle(Theme.secondaryText)
                Button(denial == .noPlan ? "プランを選ぶ" : "利用枠を見る") { store.openUsageLimit() }
                    .buttonStyle(.bordered).accessibilityIdentifier("timeline-usage-limit-open")
            }
            .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-usage-limit")
        case .finished:
            VStack(alignment: .leading, spacing: 16) {
                Text("今日はここまで").font(Typography.sans(size: 26, weight: .bold))
                Text("✓ \(store.answeredToday) 問").font(Typography.sans(size: 17, weight: .medium)).foregroundStyle(Theme.secondaryText)
                Button("続ける") { store.resumeAfterFinish() }.buttonStyle(.bordered).accessibilityIdentifier("timeline-resume")
            }
            .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-finished")
        case .dip(_, let trigger):
            TimelineDipChoiceView(store: store, trigger: trigger)
        case .rapidDone:
            TimelineRapidDoneView(store: store)
        case .toy:
            TimelineToyView(store: store)
        case .howto:
            if let card = store.current { TimelineHowtoView(card: card, store: store) { ask(card) } }
        case .rapid(let index):
            if let card = store.current {
                VStack(alignment: .leading, spacing: 18) {
                    TimelineRapidHeader(store: store, index: index)
                    // 式が無い速攻は問題文だけ(問題文を式として組んで二度出さない)。
                    if !card.math.isEmpty { TimelineMath(latex: card.math, size: 30) }
                    TimelineRichText(text: card.prompt, size: card.math.isEmpty ? 24 : 17, weight: .bold)
                    Spacer(minLength: 0)
                }
            }
        case .result:
            if let card = store.current, let attempt = store.lastAttempt {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        TimelineResultView(card: card, attempt: attempt, store: store)
                        // iPhone は結果の画面で書く面を出さないので、送った手書きに赤ペンを重ねてここに出す。
                        if !layout.isPad, let answer = store.inkAnswer(attempt.id) {
                            let marks = store.redPen(attempt.id)
                            if !marks.isEmpty { TimelineRedPenPaper(answer: answer, marks: marks) }
                        }
                        if attempt.verdict == "wrong", store.isStuck(card) {
                            // 2日続けて同じ所で止まった: 直近の答案をすべて渡して、質問(チューターとの会話)で一緒に考える。
                            Button { askWithHistory(card) } label: {
                                Label("質問で一緒に考える", systemImage: TimelineSymbol.ask)
                                    .font(Typography.sans(size: 15, weight: .bold))
                                    .padding(.horizontal, 18).padding(.vertical, 12)
                                    .foregroundStyle(Theme.primaryText)
                                    .background(Theme.accentColor.opacity(0.16), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            // iPad は結果の画面でも書く面が上に乗る(スクロールできる)ので、ボタンには指を通す。
                            .timelineInkPassThrough()
                            .accessibilityIdentifier("timeline-stuck-ask")
                        }
                    }
                    .padding(.trailing, layout == .padLandscape ? 0 : 60).padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        case .solving, .grading:
            if let card = store.current {
                VStack(alignment: .leading, spacing: 14) {
                    TimelineProblemView(card: card, store: store)
                    if TimelineCards.Kind(rawValue: card.kind)?.needsReading ?? true {
                        if card.kind != "solve" { TimelineWritingPrompt(card: card) }
                        Spacer(minLength: 0)
                        footnote(card)
                    } else {
                        TimelineInteractiveCard(card: card, store: store).id(card.id).padding(.trailing, layout == .padLandscape ? 0 : 64)
                        Spacer(minLength: 0)
                    }
                }
                .overlay {
                    if case .grading = store.phase {
                        Color.clear.contentShape(Rectangle())
                    }
                }
            }
        }
    }

    /// 左下: 前に解いた印(「↺ 2日前 ○」)と通し番号。
    private func footnote(_ card: TimelineCardRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch store.badge {
            case .resume?:
                Label("昨日", systemImage: TimelineSymbol.past)
            case .history(let days)?:
                HStack(spacing: 6) {
                    Label(days <= 1 ? "昨日" : "\(days)日前", systemImage: TimelineSymbol.past)
                    TimelineMark(correct: true, size: 11)
                }
            default:
                EmptyView()
            }
            Text("No. \(store.problemNumber)").font(Typography.ordinal).foregroundStyle(Theme.tertiaryText)
        }
        .font(Typography.sans(size: 14, weight: .medium))
        .foregroundStyle(Theme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, layout == .padLandscape ? 0 : 90)
        // 書いた後は、同じ場所に「1つ戻す」「全部消す」を出す(iPad は右上に出すので消さない)。
        .opacity(!layout.isPad && (hasInk || isInkZoomed) ? 0 : 1)
    }

    /// 指で書く面を出すか(読み取りで採点するカードを解いている間と、速攻)。
    private var showsInk: Bool {
        switch store.phase {
        case .solving, .grading:
            guard let card = store.current else { return false }
            return TimelineCards.Kind(rawValue: card.kind)?.needsReading ?? true
        case .rapid:
            return store.current != nil
        case .result:
            // iPad は、送った手書きを結果の右にそのまま残す(書き足しはできない)。撮って送った時は書いた線が無いので出さない。
            guard layout.isPad, hasInk, let card = store.current else { return false }
            return TimelineCards.Kind(rawValue: card.kind)?.needsReading ?? true
        default:
            return false
        }
    }

    /// 書く面を置く。iPad は画面の上端から下端まで、端から端まで覆う(上の帯の横の余白やホームインジケータの所にも書ける)。
    /// iPhone の並びは、上の帯と下の帯の間(`inkArea`)。上の帯・右下の縦並び・下の帯のボタンと、問題の中のボタンには
    /// 指を通す(`timelineInkPassThrough`)。
    /// 並びで置き場所(ビューの木の位置)を変えない。Split View で幅を変えて iPad と iPhone の並びが入れ替わっても、
    /// 同じ書く面のまま大きさだけ変わるので、書いた答案が消えない(置き場所を分けると書く面が作り直され、線が消える)。
    /// GeometryReader で包み、書く面の大きさが画面の並びを押し広げないようにする(iPad から狭めた直後は `inkArea` に
    /// 前の幅が残っていて、そのまま置くと画面全体がウィンドウより広がり、その広さで測り直して戻らなくなった)。
    private var placedInkLayer: some View {
        GeometryReader { proxy in
            let area: CGRect = layout.isPad ? CGRect(origin: .zero, size: proxy.size) : inkArea
            inkLayer
                .frame(width: area.width, height: area.height)
                .position(x: area.midX, y: area.midY)
        }
        .ignoresSafeArea(edges: layout.isPad ? .all : [])
    }

    /// 書く面(枠は置かない)。iPhone は左下に鉛筆と「1つ戻す」「全部消す」。
    private var inkLayer: some View {
        ZStack(alignment: .bottomLeading) {
            TimelineInkCanvas(hasInk: $hasInk, isDrawing: $isDrawing, isZoomed: $isInkZoomed, controller: ink,
                              passThrough: inkPassThrough.map { $0.offsetBy(dx: -inkOrigin.x, dy: -inkOrigin.y) },
                              showsToolPicker: layout.isPad && showsInkTools, isReadOnly: isResult)
                .id(inkGeneration)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 結果の画面では、書き足しはできないがスクロールと拡大縮小はできる(採点中は触らせない)。
                .allowsHitTesting(!isGrading)
            // 結果の画面: 書く面の上に赤ペンの層(生徒の線とは別の層)。
            if isResult, let attempt = store.lastAttempt {
                TimelineRedPenLayer(marks: store.redPen(attempt.id), viewport: ink.viewport)
            }
            if !layout.isPad, hasInk || isInkZoomed {
                HStack(spacing: 14) {
                    Image(systemName: TimelineSymbol.pencil).foregroundStyle(Theme.tertiaryText)
                    if hasInk {
                        Button("1つ戻す") { ink.undo() }.accessibilityIdentifier("timeline-ink-undo")
                        Button("全部消す") { ink.clear() }.accessibilityIdentifier("timeline-ink-clear")
                    }
                    if isInkZoomed {
                        Button("元の大きさ") { ink.resetZoom() }.accessibilityIdentifier("timeline-ink-zoom-reset")
                    }
                }
                .font(Typography.sans(size: 13, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.card.opacity(0.92), in: Capsule())
                .padding(.leading, 16).padding(.bottom, 16)
                .opacity(isDrawing ? 0.35 : 1)
            }
        }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(TimelineInkSpace.name)).origin } action: { inkOrigin = $0 }
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 16) {
            TimelineChip(text: "はじめに", symbol: TimelineSymbol.new, tinted: true)
            Text("まず、勉強する単元を作りましょう").font(Typography.sans(size: 24, weight: .bold)).foregroundStyle(Theme.primaryText)
            Text("教科書のページや、いま習っている所を教えてください。そこから1問ずつ、タイムラインに出していきます。")
                .font(Typography.sans(size: 15, weight: .medium)).foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button { coordinator.createUnit() } label: {
                Label("単元を作る", systemImage: "plus")
                    .font(Typography.sans(size: 16, weight: .bold))
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .foregroundStyle(Theme.onAccent)
                    .background(Theme.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timeline-guide-create-unit")
        }
        .padding(.trailing, 40)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-guide")
    }

    // MARK: 右下の縦並び

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 22) {
            switch store.phase {
            case .solving:
                if let card = store.current {
                    if TimelineCards.Kind(rawValue: card.kind)?.needsReading ?? true, layout.isPad {
                        // iPad は書くのが先: 「送る」を同じ場所に置いておき、書くまでは押せない。書いた後は 撮る・送る。
                        if !hasInk {
                            TimelineActionButton(symbol: TimelineSymbol.ask, label: "質問", identifier: "timeline-ask") { ask(card) }
                            TimelineActionButton(symbol: TimelineSymbol.skip, label: "飛ばす", identifier: "timeline-skip") { Task { await store.skip() } }
                        }
                        TimelineActionButton(symbol: TimelineSymbol.camera, label: "撮る", identifier: "timeline-capture") { isCameraPresented = true }
                        TimelineActionButton(symbol: TimelineSymbol.send, label: "送る", prominent: true, isEnabled: hasInk,
                                             diameter: TimelineLayout.sendDiameter, identifier: "timeline-send") { sendInk() }
                    } else if TimelineCards.Kind(rawValue: card.kind)?.needsReading ?? true {
                        TimelineActionButton(symbol: TimelineSymbol.ask, label: "質問", identifier: "timeline-ask") { ask(card) }
                        if hasInk {
                            TimelineActionButton(symbol: TimelineSymbol.camera, label: "撮る", identifier: "timeline-capture") { isCameraPresented = true }
                            TimelineActionButton(symbol: TimelineSymbol.send, label: "送る", prominent: true, identifier: "timeline-send") { sendInk() }
                        } else {
                            TimelineActionButton(symbol: TimelineSymbol.skip, label: "飛ばす", identifier: "timeline-skip") { Task { await store.skip() } }
                            TimelineActionButton(symbol: TimelineSymbol.camera, label: "撮る", prominent: true, identifier: "timeline-capture") { isCameraPresented = true }
                        }
                    } else {
                        TimelineActionButton(symbol: TimelineSymbol.ask, label: "質問", identifier: "timeline-ask") { ask(card) }
                        TimelineActionButton(symbol: TimelineSymbol.skip, label: "飛ばす", identifier: "timeline-skip") { Task { await store.skip() } }
                    }
                }
            case .rapid:
                if layout.isPad {
                    TimelineActionButton(symbol: TimelineSymbol.send, label: "送る", prominent: true, isEnabled: hasInk,
                                         diameter: TimelineLayout.sendDiameter, identifier: "timeline-send") { sendRapid() }
                } else {
                    TimelineActionButton(symbol: TimelineSymbol.send, label: "送る", prominent: true, identifier: "timeline-send") { sendRapid() }
                }
            case .grading:
                VStack(alignment: .trailing, spacing: 6) {
                    ProgressView().controlSize(.large).frame(width: 72, height: 72)
                    Text("採点中").font(Typography.sans(size: 12, weight: .bold)).foregroundStyle(Theme.secondaryText).frame(width: 72)
                    // AI が今考えていることの見出し(チャットと同じ仕組み)。高さを決めておき、見出しの長さで上の印が動かないようにする。
                    if let attemptID = store.lastAttemptID {
                        TurnLiveLine(keys: [TurnActivityKey.target(attemptID)], font: Typography.micro)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 168, height: 44, alignment: .topTrailing)
                    }
                }
                .accessibilityIdentifier("timeline-grading")
            case .result:
                if let card = store.current {
                    // 結果の画面の「質問」: 問題について質問するか、判定に納得できないと伝えるか(後者は見直しに回す)。
                    TimelineActionButton(symbol: TimelineSymbol.ask, label: "質問", identifier: "timeline-ask") { isResultAskPresented = true }
                        .confirmationDialog("質問", isPresented: $isResultAskPresented, titleVisibility: .hidden) {
                            Button("この問題について質問する") { ask(card) }
                            if store.lastAttempt?.capturePath != nil {
                                Button("判定に納得できない") { disputeDraft = ""; isDisputePresented = true }
                            }
                            Button("やめる", role: .cancel) {}
                        }
                        .alert("判定に納得できない", isPresented: $isDisputePresented) {
                            TextField("どこが違うと思うか(書かなくてもよい)", text: $disputeDraft)
                            Button("見直してもらう") { let text = disputeDraft; Task { await store.dispute(text) } }
                            Button("やめる", role: .cancel) {}
                        } message: {
                            Text("この答案を見直します。見直した結果は、区切りのよいところでお知らせします。")
                        }
                    if TimelineCards.Kind(rawValue: card.kind)?.needsReading ?? false {
                        TimelineActionButton(symbol: TimelineSymbol.explain, label: "解説", identifier: "timeline-explain") { explain(card) }
                    }
                    TimelineActionButton(symbol: TimelineSymbol.next, label: "次へ", prominent: true, identifier: "timeline-next") { Task { await store.goNext() } }
                }
            case .rapidDone:
                TimelineActionButton(symbol: TimelineSymbol.next, label: "次へ", prominent: true, identifier: "timeline-next") { store.finishRapid() }
            default:
                EmptyView()
            }
        }
    }

    // MARK: 下の帯

    private var nextStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if hasInk, store.phase == .solving || isRapid {
                    Label("ここを上へ", systemImage: "arrow.up").font(Typography.sans(size: 13, weight: .bold))
                } else if let next = store.upcoming {
                    Label(stripLabel(next), systemImage: stripSymbol(next)).font(Typography.sans(size: 13, weight: .bold))
                }
                Spacer()
                Text("Next").font(Typography.ordinal).foregroundStyle(Theme.tertiaryText)
            }
            .foregroundStyle(Theme.secondaryText)
            // 高さは決めておく(上下に高い式で帯の高さが変わらないように)。積分の上下の端まで入る高さにする(前は 26pt で下が切れた)。
            ProblemCatalogRichText(text: stripLine, font: Typography.sans(size: 16, weight: .medium), katexFontSize: 15,
                                   color: UIColor(Theme.primaryText), lineLimit: 1, maxKatexHeight: 44)
                .foregroundStyle(Theme.primaryText)
                .frame(height: 44, alignment: .leading)
                .clipped()
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 面はホームインジケータの下(画面の下端)まで伸ばす。前の「高さ 40 の面を下へずらす」形は描かれず、帯の下に地の色の隙間が残っていた。
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(Theme.card)
                .ignoresSafeArea(edges: .bottom)
        }
        .shadow(color: .black.opacity(0.06), radius: 8, y: -2)
        .contentShape(Rectangle())
        .gesture(swipeUp)
        // iPad は書く面が帯の上にも重なるので、帯(ホームインジケータの下の面まで)には指を通す。
        .timelineInkPassThrough(toScreenBottom: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("timeline-next-strip")
        .accessibilityAction(named: "次へ") { Task { await advance() } }
    }

    private var isRapid: Bool { if case .rapid = store.phase { true } else { false } }
    private var isGrading: Bool { if case .grading = store.phase { true } else { false } }
    private var isResult: Bool { if case .result = store.phase { true } else { false } }

    private var stripLine: String {
        guard let next = store.upcoming else { return store.phase == .waiting ? "用意しています" : "" }
        // 式は数式として描く(LaTeX を文字のまま出さない)。式がある時は式だけ(問いの文まで並べると 1 行に入らず、2 行目が切れる)。
        if next.kind == "solve", !next.math.isEmpty { return "$" + next.math + "$" }
        let text = next.kind == "solve" && !next.question.isEmpty ? next.question : next.prompt
        return TimelineRichText.source(text)
    }

    private func stripLabel(_ next: TimelineCardRecord) -> String {
        if next.origin == "easier" { return "一段戻す" }
        if next.origin == "variant" { return "数値を変えて" }
        if next.kind == TimelineCards.Kind.ask.rawValue || next.kind == TimelineCards.Kind.notice.rawValue { return TimelineCards.Kind(rawValue: next.kind)?.title ?? "" }
        if let current = store.current, let chain = TimelineRules.chainID(next), chain == TimelineRules.chainID(current) { return "続き" }
        if next.origin == "rapid" || next.level <= 1 { return "\(next.estimatedSeconds)秒" }
        if let kind = TimelineCards.Kind(rawValue: next.kind), kind != .solve { return kind.title }
        return TimelineRules.chainPosition(next) != nil ? "続き" : "次"
    }

    private func stripSymbol(_ next: TimelineCardRecord) -> String {
        if next.origin == "easier" { return TimelineSymbol.back }
        if next.origin == "variant" { return TimelineSymbol.variant }
        if next.origin == "rapid" || next.level <= 1 { return TimelineSymbol.clock }
        return TimelineSymbol.chain
    }

    private var swipeUp: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in dragOffset = value.translation.height }
            .onEnded { value in
                defer { withAnimation(.spring) { dragOffset = 0 } }
                guard value.translation.height < -70 else { return }
                Task { await advance() }
            }
    }

    // MARK: 動作

    private func advance() async {
        switch store.phase {
        case .solving:
            // 書いている間は、下の帯を上に送ったら書いたものを送る(紙に切り替えた人は飛ばす)。
            if hasInk { sendInk() } else { await store.skip() }
        case .result:
            await store.goNext()
        case .rapid:
            if hasInk { sendRapid() }
        case .rapidDone:
            store.finishRapid()
        default:
            break
        }
    }

    private func sendInk() {
        guard let answer = ink.answer() else { return }
        Task { await store.submit(image: answer.data, ink: answer) }
    }

    private func sendRapid() {
        guard let data = ink.image() else { return }
        clearInk()
        Task { await store.submitRapid(image: data) }
    }

    private func clearInk() {
        ink.clear()
        hasInk = false
        isDrawing = false
        isInkZoomed = false
        inkGeneration += 1
    }

    private func problemText(_ card: TimelineCardRecord) -> String {
        [card.payload["problem"]?.stringValue ?? card.prompt, card.math, card.question].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func ask(_ card: TimelineCardRecord) {
        coordinator.ask(WorkbookQuestionContext(subunitId: card.subunitId, setId: nil, title: "タイムライン", stageLabel: nil,
                                                initialDraft: "この問題について質問です。\n" + problemText(card)))
    }

    private func askWithHistory(_ card: TimelineCardRecord) {
        coordinator.ask(WorkbookQuestionContext(subunitId: card.subunitId, setId: nil, title: "タイムライン", stageLabel: nil,
                                                initialDraft: "同じところで2日続けて止まっています。一緒に考えてください。\n" + problemText(card) + "\n\nこれまでの答案:\n" + store.recentAnswers(for: card)))
    }

    private func explain(_ card: TimelineCardRecord) {
        coordinator.ask(WorkbookQuestionContext(subunitId: card.subunitId, setId: nil, title: "タイムライン", stageLabel: nil,
                                                initialDraft: "この問題の解き方を説明してください。\n" + problemText(card) + "\n答え: " + card.answerKey))
    }

    private var skipBanner: some View {
        VStack(spacing: 10) {
            Text("飛ばしました").font(Typography.sans(size: 15, weight: .bold))
            HStack(spacing: 10) {
                Button("難しそう") { Task { await store.setSkipReason("too_hard") } }
                    .accessibilityIdentifier("timeline-skip-too-hard")
                Button("簡単すぎる") { Task { await store.setSkipReason("too_easy") } }
                    .accessibilityIdentifier("timeline-skip-too-easy")
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-skip-banner")
    }
}

/// やめようとしたとき(画面 7)。「あと 1 つ」と「今日はここまで」を同じ大きさで並べる。
struct TimelineStopSheet: View {
    let store: TimelineStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let summary = store.stopSummary
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                Label("\(summary.count) 問", systemImage: "checkmark").accessibilityIdentifier("timeline-stop-count")
                Label("\(summary.minutes)分", systemImage: TimelineSymbol.clock)
            }
            .font(Typography.sans(size: 20, weight: .bold))
            if let next = summary.next {
                VStack(alignment: .leading, spacing: 8) {
                    Label(TimelineRules.chainPosition(next) != nil ? "続き" : "次の1問", systemImage: TimelineSymbol.chain).font(Typography.sans(size: 13, weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                    Text(TimelineMath.previewLine(next))
                        .font(Typography.sans(size: 16, weight: .medium)).lineLimit(2)
                    if summary.total > 0 {
                        HStack(spacing: 8) {
                            TimelineMark(correct: true, size: 11)
                            Text("\(summary.done) / \(summary.total)").font(Typography.sans(size: 14, weight: .bold)).monospacedDigit()
                            ProgressView(value: Double(summary.done), total: Double(summary.total)).tint(Theme.accentColor)
                        }
                    }
                }
                .padding(14)
                .background(Theme.ground, in: RoundedRectangle(cornerRadius: 16))
            }
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Text("あと 1 つ").frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("timeline-one-more")
                Button { store.stopForToday() } label: {
                    Text("今日はここまで").frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("timeline-stop-today")
            }
            .font(Typography.sans(size: 16, weight: .bold))
        }
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-stop-sheet")
    }
}
