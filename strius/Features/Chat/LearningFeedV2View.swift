import SwiftUI

struct LearningFeedV2EntryCard: View {
    let onCanvasContextChange: (UUID?) -> Void

    init(onCanvasContextChange: @escaping (UUID?) -> Void = { _ in }) {
        self.onCanvasContextChange = onCanvasContextChange
    }
    @Environment(APIClient.self) private var api
    @Environment(BootstrapStore.self) private var bootstrap
    @Environment(ChatStore.self) private var chat
    @Environment(LearningFeedRuntimeServices.self) private var runtime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var reservation: LearningFeedV2PrefetchResponse?
    @State private var resumableReservation: LearningFeedV2PrefetchResponse?
    @State private var sessionThreadID: UUID?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var launchedUserID: String?
    @State private var launchDecisionID: UUID?

    var body: some View {
        Group {
            if let reservation,
               let userID = bootstrap.user?.id.uuidString ?? runtime.cachedUserID {
                LearningFeedV2SessionView(
                    reservation: reservation,
                    userID: userID,
                    deviceID: Self.deviceID,
                    chatThreadID: sessionThreadID,
                    api: api,
                    runtime: runtime,
                    launchDecisionID: launchDecisionID,
                    onClose: {
                        self.reservation = nil
                        onCanvasContextChange(nil)
                    }
                )
                .frame(minHeight: 560)
                .accessibilityIdentifier("learning-canvas-shell")
            } else if isLoading {
                ProgressView("学習内容を確認しています").progressViewStyle(StruisProgressViewStyle())
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("learning-feed-entry-error")
            }
        }
        .task(id: effectiveUserID) {
            guard let userID = effectiveUserID,
                  launchedUserID != userID else { return }
            launchedUserID = userID
            await start(userID: userID)
        }
    }

    private func start(userID: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        if let cached = await runtime.resumableReservation(userID: userID) {
            let snapshot = try? await runtime.persistence.loadSnapshot(
                userID: userID,
                sessionID: cached.sessionID
            )
            sessionThreadID = snapshot?.chatThreadID ?? chat.threadID
            runtime.start(userID: userID)
            reservation = cached
            onCanvasContextChange(cached.sessionID)
            return
        }

        do {
            sessionThreadID = chat.threadID
            let request = ExperienceLaunchRequest(
                clientIntentID: UUID(),
                routeEpoch: 0,
                deviceID: Self.deviceID,
                appSessionID: Self.appSessionID,
                launchSource: "app_icon",
                explicitIntent: "unspecified",
                availableSeconds: 180,
                studyContextID: nil,
                threadID: chat.threadID,
                requestedSubject: nil,
                requestedRepresentation: nil,
                clientCapabilities: ExperienceClientCapabilities(
                    artifactVersions: [LearningFeedArtifactVersion.v2.rawValue, LearningFeedArtifactVersion.v21.rawValue],
                    renderers: runtime.registry.advertisedVersions,
                    accessibility: ExperienceAccessibilityCapabilities(
                        reduceMotion: reduceMotion,
                        screenReader: UIAccessibility.isVoiceOverRunning,
                        dynamicTypeCategory: UIApplication.shared.preferredContentSizeCategory.rawValue
                    )
                )
            )
            let response: ExperienceLaunchResponse = try await api.send(.experienceLaunch, body: request)
            launchDecisionID = response.decisionID
            guard let reservationPayload = response.learningReservation else {
                errorMessage = nil
                return
            }
            guard response.clientIntentID == request.clientIntentID, response.routeEpoch == request.routeEpoch else {
                return
            }
            let rawReservation = try Self.encodeReservation(reservationPayload)
            let decoded = try runtime.artifactRouter.decodePrefetch(rawReservation, registry: runtime.registry)
            try await runtime.persistence.cacheReservation(
                userID: userID,
                response: decoded,
                rawData: rawReservation
            )
            runtime.start(userID: userID)
            reservation = decoded
            onCanvasContextChange(decoded.sessionID)
        } catch APIError.transport(_) {
            await openCachedReservation(userID: userID)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func openCachedReservation(userID: String) async {
        do {
            guard let data = try await runtime.persistence.latestCachedReservationData(userID: userID) else {
                throw LearningFeedArtifactValidationError.expired
            }
            let cached = try runtime.artifactRouter.decodePrefetch(data, registry: runtime.registry)
            let snapshot = try await runtime.persistence.loadSnapshot(
                userID: userID,
                sessionID: cached.sessionID
            )
            sessionThreadID = snapshot?.chatThreadID ?? chat.threadID
            runtime.start(userID: userID)
            reservation = cached
            onCanvasContextChange(cached.sessionID)
        } catch {
            errorMessage = "今すぐ出せる問題を準備できませんでした。ここで一緒に続けられます。"
        }
    }

    private func refreshResumableReservation() async {
        guard let userID = effectiveUserID else {
            resumableReservation = nil
            return
        }
        resumableReservation = await runtime.resumableReservation(userID: userID)
    }

    private var effectiveUserID: String? {
        bootstrap.user?.id.uuidString ?? runtime.cachedUserID
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "今すぐ出せる問題を準備できませんでした。ここで一緒に続けられます。"
    }

    private static var deviceID: String {
        let key = "learning-feed-device-id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    private static let appSessionID = UUID()

    private static func encodeReservation(_ reservation: LearningFeedV2PrefetchResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(reservation)
    }
}

struct LearningFeedV2SessionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ChatStore.self) private var chat
    @AccessibilityFocusState private var isStageFocused: Bool

    @State private var store: LearningEpisodeStore
    @State private var isDeepDiveSending = false
    private let onClose: () -> Void

    init(
        reservation: LearningFeedV2PrefetchResponse,
        userID: String,
        deviceID: String,
        chatThreadID: UUID?,
        api: APIClient,
        runtime: LearningFeedRuntimeServices,
        launchDecisionID: UUID? = nil,
        onClose: @escaping () -> Void = {}
    ) {
        self.onClose = onClose
        _store = State(initialValue: LearningEpisodeStore(
            reservation: reservation,
            userID: userID,
            deviceID: deviceID,
            chatThreadID: chatThreadID,
            api: api,
            runtime: runtime,
            launchDecisionID: launchDecisionID
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sessionHeader
                Divider()
                if store.isStarting {
                    ProgressView("学習内容を開いています").progressViewStyle(StruisProgressViewStyle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let runtimeError = store.runtimeError, !store.state.didStart {
                    startupFailure(runtimeError)
                } else {
                    ScrollView {
                        EpisodeStageHost(store: store)
                            .padding(20)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    Divider()
                    interactionShelf
                }
            }
            .background(Theme.ground)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        Task {
                            if await store.close() {
                                onClose()
                            }
                        }
                    }
                    .accessibilityIdentifier("learning-feed-close")
                }
            }
        }
        .interactiveDismissDisabled()
        .task { await store.start() }
        .onChange(of: store.state.stepIndex) {
            isStageFocused = true
        }
        .onChange(of: store.state.episodeIndex) {
            isStageFocused = true
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task { await store.resumeAfterForeground() }
            }
        }
    }

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.pack.title)
                .font(Typography.caption)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Text(store.currentEpisode.title)
                .font(Typography.title)
                .accessibilityFocused($isStageFocused)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var interactionShelf: some View {
        VStack(spacing: 10) {
            if let error = store.deepDiveError ?? store.runtimeError {
                Text(error)
                    .font(Typography.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    actionButtons
                }
                VStack(spacing: 10) {
                    actionButtons
                }
            }
        }
        .padding(16)
        .background(.bar)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if store.currentStep.stage == .consequence, store.state.chatThreadID != nil {
            Button("なぜ？") {
                Task { await openDeepDive() }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(isDeepDiveSending)
            .accessibilityLabel("この結果をコーチに質問")
            .accessibilityIdentifier("learning-feed-deep-dive")
        }
        if store.currentStep.stage == .boundary {
            boundaryButtons
        } else {
            Button(primaryActionTitle) {
                Task { await store.advance() }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(!store.canAdvance || isDeepDiveSending)
            .accessibilityIdentifier("learning-feed-next")
        }
    }

    private var primaryActionTitle: String {
        switch store.currentStep.stage {
        case .hook: "触ってみる"
        case .committed: "予想を置く"
        case .exploring: "試してみる"
        case .consequence: "違いを確かめる"
        case .invariantCheck: "関係を確かめる"
        case .variationCheck: "条件を変えて試す"
        case .schoolTransfer: "自力で使ってみる"
        default: "確かめる"
        }
    }

    @ViewBuilder
    private var boundaryButtons: some View {
        if hasNextEpisode {
            Button("もう少し続ける") {
                Task {
                    _ = await store.chooseBoundary("next")
                }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        Button("今日はここまで") {
            Task {
                if await store.chooseBoundary("close") {
                    onClose()
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityIdentifier("learning-feed-boundary-close")
    }

    private func openDeepDive() async {
        guard !isDeepDiveSending,
              let expectedThreadID = store.state.chatThreadID,
              chat.threadID == expectedThreadID
        else {
            store.setDeepDiveError("チャットを開けませんでした")
            return
        }
        isDeepDiveSending = true
        store.setDeepDiveError(nil)
        guard await store.prepareDeepDive() else {
            isDeepDiveSending = false
            store.setDeepDiveError("保存を確認できませんでした。接続後にもう一度お試しください。")
            return
        }
        let sent = await chat.send(
            text: "この結果になる理由を教えてください。",
            learningFeedSessionID: store.reservation.sessionID
        )
        isDeepDiveSending = false
        if !sent {
            chat.clearSendError()
            store.setDeepDiveError("質問を送れませんでした。もう一度お試しください。")
        }
    }

    private var hasNextEpisode: Bool {
        store.state.episodeIndex + 1 < store.pack.episodes.count
    }

    private func startupFailure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(Theme.secondaryText)
            Text(message)
                .font(Typography.body)
                .multilineTextAlignment(.center)
            Button("チャットに戻る") { onClose() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(24)
    }
}

private struct EpisodeStageHost: View {
    @Bindable var store: LearningEpisodeStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            KaTeXMathText(
                store.currentStep.prompt,
                foregroundColor: promptColor,
                fontSize: 22,
                fontWeight: 700
            )
            if store.currentStep.stage != .boundary {
                SemanticOrderAccessibilityView(
                    elements: store.currentEpisode.semanticElements,
                    order: store.currentStep.accessibility.semanticOrder
                )
                EpisodeRendererHost(store: store)
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, minHeight: 480, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(store.currentStep.accessibility.summary)
    }

    private var promptColor: UIColor {
        scheme == .dark
            ? UIColor(red: 0.953, green: 0.910, blue: 0.831, alpha: 1)
            : UIColor(red: 0.122, green: 0.102, blue: 0.078, alpha: 1)
    }
}

private struct SemanticOrderAccessibilityView: View {
    let elements: [LearningFeedSemanticElement]
    let order: [String]

    var body: some View {
        Color.clear
            .frame(height: 0)
            .accessibilityChildren {
                ForEach(orderedElements, id: \.id) { element in
                    Text(element.meaning)
                        .accessibilityLabel(element.meaning)
                }
            }
    }

    private var orderedElements: [LearningFeedSemanticElement] {
        order.compactMap { id in elements.first { $0.id == id } }
    }
}

private struct EpisodeRendererHost: View {
    @Bindable var store: LearningEpisodeStore

    var body: some View {
        switch EpisodeRendererKind(rawValue: store.currentStep.rendererKind) {
        case .binaryPrediction:
            BinaryPredictionRenderer(store: store)
        case .directManipulation:
            DirectManipulationRenderer(store: store)
        case .graphParameter:
            GraphParameterRenderer(store: store)
        case .dragOrder:
            DragOrderRenderer(store: store)
        case .selectEvidence:
            SelectEvidenceRenderer(store: store)
        case .numericInput:
            TextAnswerRenderer(store: store, keyboardType: .decimalPad, multiline: false)
        case .equationInput:
            TextAnswerRenderer(store: store, keyboardType: .default, multiline: false)
        case .shortResponse:
            TextAnswerRenderer(store: store, keyboardType: .default, multiline: true)
        case .annotateText:
            SemanticSelectionRenderer(store: store, itemKey: "segments", introductoryTextKey: "text")
        case .relationshipMap:
            SemanticSelectionRenderer(store: store, itemKey: "nodes")
        case .spatialArrangement:
            SpatialArrangementRenderer(store: store)
        case .timelineCause:
            SemanticOrderRenderer(store: store, itemKey: "events")
        case .dataFilter:
            SemanticSelectionRenderer(store: store, itemKey: "columns")
        case .codeTrace:
            CodeTraceRenderer(store: store)
        case .proofRepair:
            SemanticOrderRenderer(store: store, itemKey: "lines")
        case .audioPrediction:
            SemanticSelectionRenderer(store: store, itemKey: "choices", introductoryTextKey: "transcript_fallback", singleSelection: true)
        case .artifactCompare:
            SemanticSelectionRenderer(store: store, itemKey: "criteria")
        case nil:
            Text("この問題の表示にはアプリの更新が必要です")
                .foregroundStyle(.red)
        }
    }
}

private struct SemanticSelectionRenderer: View {
    @Bindable var store: LearningEpisodeStore
    let itemKey: String
    var introductoryTextKey: String? = nil
    var singleSelection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let introductoryTextKey,
               let text = store.currentStep.interactionConfig[introductoryTextKey]?.stringValue,
               !text.isEmpty {
                Text(text).font(Typography.body)
            }
            ForEach(store.currentStep.choices(for: itemKey)) { choice in
                Button {
                    if singleSelection {
                        store.selectChoice(choice.id)
                    } else {
                        store.toggleEvidence(choice.id)
                    }
                } label: {
                    HStack {
                        Text(choice.label)
                        Spacer()
                        let selected = singleSelection
                            ? store.state.input.selectedChoiceID == choice.id
                            : store.state.input.selectedEvidenceIDs.contains(choice.id)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct SemanticOrderRenderer: View {
    @Bindable var store: LearningEpisodeStore
    let itemKey: String

    var body: some View {
        let labels = Dictionary(uniqueKeysWithValues: store.currentStep.choices(for: itemKey).map { ($0.id, $0.label) })
        VStack(spacing: 8) {
            ForEach(Array(store.state.input.orderedIDs.enumerated()), id: \.element) { index, id in
                HStack {
                    Text(labels[id] ?? id).frame(maxWidth: .infinity, alignment: .leading)
                    Button("上へ", systemImage: "chevron.up") {
                        store.moveOrderedItem(from: index, to: max(0, index - 1))
                    }.labelStyle(.iconOnly).disabled(index == 0)
                    Button("下へ", systemImage: "chevron.down") {
                        store.moveOrderedItem(from: index, to: min(store.state.input.orderedIDs.count - 1, index + 1))
                    }.labelStyle(.iconOnly).disabled(index == store.state.input.orderedIDs.count - 1)
                }
                .frame(minHeight: 52)
                .padding(.horizontal, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

private struct SpatialArrangementRenderer: View {
    @Bindable var store: LearningEpisodeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.currentStep.choices(for: "items")) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.label).font(Typography.bodyEmphasized)
                    ForEach(store.currentStep.choices(for: "zones")) { zone in
                        let value = "\(item.id):\(zone.id)"
                        Button(zone.label) { store.toggleEvidence(value) }
                            .buttonStyle(.bordered)
                            .tint(store.state.input.selectedEvidenceIDs.contains(value) ? .accentColor : .secondary)
                    }
                }
            }
        }
    }
}

private struct CodeTraceRenderer: View {
    @Bindable var store: LearningEpisodeStore

    var body: some View {
        let lines: [String] = {
            guard case .array(let values)? = store.currentStep.interactionConfig["source_lines"] else { return [] }
            return values.compactMap(\.stringValue)
        }()
        let current = min(max(0, Int(store.state.input.parameterValue)), max(0, lines.count - 1))
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text("\(index == current ? "▶" : " ") \(line)")
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel(index == current ? "現在、\(line)" : line)
            }
            HStack {
                Button("前の状態") { store.setParameter(Double(max(0, current - 1))) }.disabled(current == 0)
                Button("次の状態") { store.setParameter(Double(min(max(0, lines.count - 1), current + 1))) }
                    .disabled(lines.isEmpty || current >= lines.count - 1)
            }.buttonStyle(.bordered)
        }
    }
}

private struct BinaryPredictionRenderer: View {
    @Bindable var store: LearningEpisodeStore

    var body: some View {
        VStack(spacing: 10) {
            ForEach(store.currentStep.choices) { choice in
                Button {
                    store.selectChoice(choice.id)
                } label: {
                    HStack {
                        Text(choice.label)
                        Spacer()
                        Image(systemName: store.state.input.selectedChoiceID == choice.id ? "checkmark.circle.fill" : "circle")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityValue(store.state.input.selectedChoiceID == choice.id ? "選択中" : "未選択")
            }
        }
    }
}

private struct GraphParameterRenderer: View {
    @Bindable var store: LearningEpisodeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 16) {
            Canvas { context, size in
                let inset: CGFloat = 12
                let drawingSize = CGSize(width: max(1, size.width - inset * 2), height: max(1, size.height - inset * 2))
                var redLine = Path()
                redLine.move(to: point(x: parameterRange.lowerBound, y: redValue(at: parameterRange.lowerBound), size: drawingSize, inset: inset))
                redLine.addLine(to: point(x: parameterRange.upperBound, y: redValue(at: parameterRange.upperBound), size: drawingSize, inset: inset))
                context.stroke(redLine, with: .color(.red), lineWidth: 5)

                var blueLine = Path()
                blueLine.move(to: point(x: parameterRange.lowerBound, y: blueValue(at: parameterRange.lowerBound), size: drawingSize, inset: inset))
                blueLine.addLine(to: point(x: parameterRange.upperBound, y: blueValue(at: parameterRange.upperBound), size: drawingSize, inset: inset))
                context.stroke(blueLine, with: .color(.blue), lineWidth: 5)

                let selectedX = store.state.input.parameterValue
                let redPoint = point(x: selectedX, y: redValue(at: selectedX), size: drawingSize, inset: inset)
                let bluePoint = point(x: selectedX, y: blueValue(at: selectedX), size: drawingSize, inset: inset)
                context.fill(Path(ellipseIn: CGRect(x: redPoint.x - 7, y: redPoint.y - 7, width: 14, height: 14)), with: .color(.red))
                context.fill(Path(ellipseIn: CGRect(x: bluePoint.x - 7, y: bluePoint.y - 7, width: 14, height: 14)), with: .color(.blue))
            }
            .frame(height: 220)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: store.state.input.parameterValue)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(store.currentStep.accessibility.summary)
            .accessibilityValue(accessibilityValue)

            Slider(
                value: parameterBinding,
                in: parameterRange,
                step: stepValue
            )
            .accessibilityLabel(parameterLabel)
            VStack(alignment: .leading, spacing: 4) {
                Stepper(
                    "\(parameterLabel) \(formatted(store.state.input.parameterValue))",
                    value: parameterBinding,
                    in: parameterRange,
                    step: stepValue
                )
                .frame(minHeight: 44)
                Text("赤 \(formatted(redValue(at: store.state.input.parameterValue)))、青 \(formatted(blueValue(at: store.state.input.parameterValue)))")
                    .foregroundStyle(Theme.secondaryText)
            }
                .font(Typography.title)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var parameterBinding: Binding<Double> {
        Binding(
            get: { store.state.input.parameterValue },
            set: { store.setParameter($0) }
        )
    }

    private var parameterRange: ClosedRange<Double> {
        let configuration = store.currentStep.interactionConfig
        let minimum = configuration["min"]?.numberValue ?? 0
        let maximum = configuration["max"]?.numberValue ?? 10
        return minimum...max(minimum + 1, maximum)
    }

    private var stepValue: Double {
        max(0.001, store.currentStep.interactionConfig["step"]?.numberValue ?? 1)
    }

    private var parameterLabel: String {
        store.currentStep.interactionConfig["label"]?.stringValue.learningFeedViewNonEmpty ?? "変える量"
    }

    private var model: [String: JSONValue] {
        guard case .object(let value)? = store.currentStep.interactionConfig["model"] else { return [:] }
        return value
    }

    private func redValue(at x: Double) -> Double {
        (model["red_intercept"]?.numberValue ?? 0) + (model["red_slope"]?.numberValue ?? 0) * x
    }

    private func blueValue(at x: Double) -> Double {
        (model["blue_intercept"]?.numberValue ?? 0) + (model["blue_slope"]?.numberValue ?? 0) * x
    }

    private var graphYRange: ClosedRange<Double> {
        let values = [
            redValue(at: parameterRange.lowerBound), redValue(at: parameterRange.upperBound),
            blueValue(at: parameterRange.lowerBound), blueValue(at: parameterRange.upperBound),
        ]
        let lower = values.min() ?? 0
        let upper = values.max() ?? 1
        return min(0, lower)...max(lower + 1, upper)
    }

    private func point(x: Double, y: Double, size: CGSize, inset: CGFloat) -> CGPoint {
        let xSpan = max(0.001, parameterRange.upperBound - parameterRange.lowerBound)
        let ySpan = max(0.001, graphYRange.upperBound - graphYRange.lowerBound)
        let normalizedX = (x - parameterRange.lowerBound) / xSpan
        let normalizedY = (y - graphYRange.lowerBound) / ySpan
        return CGPoint(
            x: inset + size.width * normalizedX,
            y: inset + size.height * (1 - normalizedY)
        )
    }

    private var accessibilityValue: String {
        "\(parameterLabel) \(formatted(store.state.input.parameterValue))、赤 \(formatted(redValue(at: store.state.input.parameterValue)))、青 \(formatted(blueValue(at: store.state.input.parameterValue)))"
    }

    private func formatted(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.2f", value)
    }
}

private struct DirectManipulationRenderer: View {
    @Bindable var store: LearningEpisodeStore

    var body: some View {
        VStack(spacing: 18) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 18)
                    .fill(.blue.opacity(0.18))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(.blue)
                            .frame(width: max(24, proxy.size.width * normalizedValue))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                .frame(height: 88)
                .accessibilityLabel(store.currentStep.accessibility.summary)
                .accessibilityValue(formattedValue)
            Slider(
                value: Binding(
                    get: { store.state.input.parameterValue },
                    set: { store.setParameter($0) }
                ),
                in: parameterRange,
                step: stepValue
            )
            .accessibilityLabel(parameterLabel)
            Stepper(
                "\(parameterLabel) \(formattedValue)",
                value: Binding(
                    get: { store.state.input.parameterValue },
                    set: { store.setParameter($0) }
                ),
                in: parameterRange,
                step: stepValue
            )
            .frame(minHeight: 44)
        }
    }

    private var parameterLabel: String {
        store.currentStep.interactionConfig["label"]?.stringValue.learningFeedViewNonEmpty ?? "動かす量"
    }

    private var parameterRange: ClosedRange<Double> {
        let minimum = store.currentStep.interactionConfig["min"]?.numberValue ?? 0
        let maximum = store.currentStep.interactionConfig["max"]?.numberValue ?? 10
        return minimum...max(minimum + 1, maximum)
    }

    private var stepValue: Double {
        max(0.001, store.currentStep.interactionConfig["step"]?.numberValue ?? 1)
    }

    private var normalizedValue: Double {
        let span = max(0.001, parameterRange.upperBound - parameterRange.lowerBound)
        return (store.state.input.parameterValue - parameterRange.lowerBound) / span
    }

    private var formattedValue: String {
        let value = store.state.input.parameterValue
        return value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.2f", value)
    }
}

private struct DragOrderRenderer: View {
    @Bindable var store: LearningEpisodeStore

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(store.state.input.orderedIDs.enumerated()), id: \.element) { index, item in
                HStack {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityHidden(true)
                    Text(label(for: item))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("上へ", systemImage: "chevron.up") {
                        store.moveOrderedItem(from: index, to: max(0, index - 1))
                    }
                    .labelStyle(.iconOnly)
                    .disabled(index == 0)
                    Button("下へ", systemImage: "chevron.down") {
                        store.moveOrderedItem(from: index, to: min(store.state.input.orderedIDs.count - 1, index + 1))
                    }
                    .labelStyle(.iconOnly)
                    .disabled(index == store.state.input.orderedIDs.count - 1)
                }
                .frame(minHeight: 56)
                .padding(.horizontal, 14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .draggable(item)
                .dropDestination(for: String.self) { identifiers, _ in
                    guard let draggedID = identifiers.first,
                          let source = store.state.input.orderedIDs.firstIndex(of: draggedID),
                          source != index
                    else {
                        return false
                    }
                    store.moveOrderedItem(from: source, to: index)
                    return true
                }
            }
        }
    }

    private func label(for id: String) -> String {
        guard case .array(let values)? = store.currentStep.interactionConfig["items"] else { return id }
        for value in values {
            if case .object(let object) = value,
               object["id"]?.stringValue == id
            {
                return object["label"]?.stringValue.learningFeedViewNonEmpty
                    ?? object["text"]?.stringValue.learningFeedViewNonEmpty
                    ?? id
            }
        }
        return id
    }
}

private struct SelectEvidenceRenderer: View {
    @Bindable var store: LearningEpisodeStore

    var body: some View {
        VStack(spacing: 8) {
            ForEach(items, id: \.id) { item in
                Button {
                    store.toggleEvidence(item.id)
                } label: {
                    HStack(alignment: .top) {
                        Text(item.label)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: store.state.input.selectedEvidenceIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var items: [LearningFeedV2Choice] {
        guard case .array(let values)? = store.currentStep.interactionConfig["choices"] else { return [] }
        return values.compactMap { value in
            guard case .object(let object) = value,
                  let id = object["id"]?.stringValue.learningFeedViewNonEmpty,
                  let label = (object["label"] ?? object["text"])?.stringValue.learningFeedViewNonEmpty
            else { return nil }
            return LearningFeedV2Choice(id: id, label: label)
        }
    }
}

private struct TextAnswerRenderer: View {
    @Bindable var store: LearningEpisodeStore
    let keyboardType: UIKeyboardType
    let multiline: Bool

    var body: some View {
        Group {
            if multiline {
                TextEditor(text: textBinding)
                    .frame(minHeight: 140)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                TextField(placeholder, text: textBinding)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(keyboardType)
                    .frame(minHeight: 44)
            }
        }
        .accessibilityLabel(placeholder)
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { store.state.input.text },
            set: { store.setText($0) }
        )
    }

    private var placeholder: String {
        store.currentStep.interactionConfig["placeholder"]?.stringValue.learningFeedViewNonEmpty
            ?? "答え"
    }
}

private extension String {
    var learningFeedViewNonEmpty: String? { isEmpty ? nil : self }
}
