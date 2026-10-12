#if DEBUG
import SwiftUI
import UIKit

/// Issue #6「一括採点」の画面案(静止したモック)。`-batch-capture-lab <画面>` で起動すると、その画面だけを出す。
/// 写真は `STRUIS_MOCK_PAPER`(答案の画像のパス)。動きと保存は持たない。
struct BatchCaptureLabView: View {
    let screen: String

    static var requestedScreen: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-batch-capture-lab") else { return nil }
        return arguments.indices.contains(index + 1) ? arguments[index + 1] : "a1"
    }

    var body: some View {
        switch screen {
        case "a2": BatchMockA2()
        case "b1": BatchMockB1()
        case "c1": BatchMockC1()
        case "r0": BatchMockR0()
        case "r1": BatchMockR1()
        default: BatchMockA1()
        }
    }
}

private enum BatchMockPaper {
    static let image: UIImage? = ProcessInfo.processInfo.environment["STRUIS_MOCK_PAPER"].flatMap { UIImage(contentsOfFile: $0) }

    @ViewBuilder
    static func view(fill: Bool = true) -> some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
        } else {
            Rectangle().fill(Color(white: 0.93))
        }
    }
}

/// 撮った一枚の小さな写真(番号つき)。
private struct BatchMockThumb: View {
    let number: Int
    var size: CGFloat = 52
    var selected = false
    var removable = false

    var body: some View {
        BatchMockPaper.view()
            .frame(width: size, height: size * 1.3)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Theme.Palette.accentDark : .white.opacity(0.35), lineWidth: selected ? 2.5 : 1)
            }
            .overlay(alignment: .bottomLeading) {
                Text("\(number)")
                    .font(Typography.micro.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if removable {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.65))
                        .padding(4)
                }
            }
    }
}

/// 背景に置く小単元の画面(カメラの下に透ける)。
private struct BatchMockSubunitBackdrop: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("二次関数").font(Typography.caption).foregroundStyle(Theme.secondaryText)
            Text("頂点の座標が求められる").font(Typography.heading1).foregroundStyle(Theme.primaryText)
            HStack(spacing: 6) {
                ForEach(0..<10, id: \.self) { _ in WorkbookTile(state: .notStarted, size: 22) }
            }
            Text("演習の一枚 10 問").font(Typography.caption).foregroundStyle(Theme.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ground)
    }
}

// MARK: - 案A 連続で撮る(カメラを閉じずに束ねる)

private struct BatchMockA1: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            BatchMockSubunitBackdrop().ignoresSafeArea()
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 10) {
                BatchMockPaper.view()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay(alignment: .top) {
                        Text("3枚目を撮る")
                            .font(Typography.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.top, 10)
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 4)
                HStack(spacing: 8) {
                    BatchMockThumb(number: 1, size: 40)
                    BatchMockThumb(number: 2, size: 40)
                    Spacer()
                }
                .padding(.horizontal, 16)
                ZStack {
                    HStack {
                        Text("キャンセル").font(Typography.body).foregroundStyle(.white)
                        Spacer()
                        Text("採点する 2")
                            .font(Typography.bodyEmphasized)
                            .foregroundStyle(Theme.Palette.textOnAccentLight)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Theme.Palette.accentLight, in: Capsule())
                    }
                    BatchMockShutter()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .frame(height: 620)
            .background(.black, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
            .padding(.horizontal, 8)
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

private struct BatchMockShutter: View {
    var body: some View {
        Circle()
            .strokeBorder(.white, lineWidth: 3)
            .frame(width: 64, height: 64)
            .overlay { Circle().fill(.white).frame(width: 50, height: 50) }
    }
}

private struct BatchMockA2: View {
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("演習の一枚 · 頂点の座標が求められる")
                            .font(Typography.caption).foregroundStyle(Theme.secondaryText)
                        Text("3 枚をまとめて採点します")
                            .font(Typography.heading2).foregroundStyle(Theme.primaryText)
                        Text("並べた順に 1 つの答案として読みます。長押しで並べ替え。")
                            .font(Typography.caption).foregroundStyle(Theme.secondaryText)
                    }
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(1...3, id: \.self) { index in
                            BatchMockThumb(number: index, size: 160, removable: true)
                        }
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                            .frame(width: 160, height: 208)
                            .overlay {
                                VStack(spacing: 6) {
                                    Image(systemName: "camera.fill").font(.system(size: 22))
                                    Text("撮り足す").font(Typography.bodyEmphasized)
                                }
                                .foregroundStyle(Theme.accentColor)
                            }
                    }
                }
                .padding(20)
            }
            .background(Theme.ground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Text("戻る").foregroundStyle(Theme.accentColor) }
            }
            .safeAreaInset(edge: .bottom) {
                Text("3 枚をまとめて採点する")
                    .font(Typography.bodyEmphasized)
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.accentColor, in: Capsule())
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - 案B 確認画面に「もう 1 枚」

private struct BatchMockB1: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Text("2 枚目")
                    .font(Typography.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.top, 8)
                BatchMockPaper.view(fill: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 16)
                HStack(spacing: 10) {
                    BatchMockThumb(number: 1, size: 44)
                    BatchMockThumb(number: 2, size: 44, selected: true)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .frame(width: 44, height: 57)
                        .overlay { Image(systemName: "plus").foregroundStyle(.white) }
                }
                HStack(spacing: 12) {
                    BatchMockOutlined(text: "撮り直す")
                    BatchMockOutlined(text: "もう 1 枚撮る", icon: "camera")
                }
                .padding(.horizontal, 20)
                Text("2 枚で採点する")
                    .font(Typography.bodyEmphasized)
                    .foregroundStyle(Theme.Palette.textOnAccentLight)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.Palette.accentLight, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
    }
}

private struct BatchMockOutlined: View {
    let text: String
    var icon: String?

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(Typography.bodyEmphasized)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 案C 未送信の束を小単元に残す

private struct BatchMockC1: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("二次関数").font(Typography.caption).foregroundStyle(Theme.secondaryText)
                        Text("頂点の座標が求められる").font(Typography.heading1).foregroundStyle(Theme.primaryText)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("まだ送っていない答案").font(Typography.title).foregroundStyle(Theme.primaryText)
                            Spacer()
                            Text("3 枚").font(Typography.bodyEmphasized).foregroundStyle(Theme.accentColor)
                        }
                        Text("演習の一枚 10 問のうち、撮った分をまとめて採点します")
                            .font(Typography.caption).foregroundStyle(Theme.secondaryText)
                        HStack(spacing: 10) {
                            ForEach(1...3, id: \.self) { BatchMockThumb(number: $0, size: 64) }
                        }
                        HStack(spacing: 10) {
                            Label("撮り足す", systemImage: "camera")
                                .font(Typography.bodyEmphasized)
                                .foregroundStyle(Theme.accentColor)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Theme.accentColor.opacity(0.12), in: Capsule())
                            Text("まとめて採点")
                                .font(Typography.bodyEmphasized)
                                .foregroundStyle(Theme.onAccent)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Theme.accentColor, in: Capsule())
                        }
                    }
                    .padding(16)
                    .struisSurface(radius: Theme.Radius.card)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("演習の一枚").font(Typography.title).foregroundStyle(Theme.primaryText)
                        HStack(spacing: 6) {
                            ForEach(0..<10, id: \.self) { _ in WorkbookTile(state: .notStarted, size: 24) }
                        }
                        Text("撮った紙は採点するまで端末に置いておきます。あとから撮り足せます。")
                            .font(Typography.caption).foregroundStyle(Theme.secondaryText)
                    }
                    .padding(16)
                    .struisSurface(radius: Theme.Radius.card)
                }
                .padding(20)
            }
            .background(Theme.ground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Image(systemName: "chevron.left").foregroundStyle(Theme.accentColor) }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    WorkbookCaptureButton {}
                        .overlay(alignment: .topTrailing) {
                            Text("3")
                                .font(Typography.micro.monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(Theme.Palette.regressLight, in: Circle())
                                .offset(x: 6, y: -6)
                        }
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
            }
        }
    }
}

// MARK: - 共通 まとめた答案の採点中・結果

private struct BatchMockR0: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("答案を読み取っています")
                        .font(Typography.heading2).foregroundStyle(Theme.primaryText)
                    BatchMockPaper.view(fill: false)
                        .frame(maxWidth: .infinity)
                        .frame(height: 380)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(LinearGradient(colors: [Theme.Palette.accentLight.opacity(0), Theme.Palette.accentLight.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                                .frame(height: 40)
                                .offset(y: 150)
                        }
                    VStack(spacing: 0) {
                        BatchMockPageRow(number: 1, text: "問1〜問4 を見つけました", state: .done)
                        Divider()
                        BatchMockPageRow(number: 2, text: "読み取っています", state: .running)
                        Divider()
                        BatchMockPageRow(number: 3, text: "待っています", state: .waiting)
                    }
                    .padding(.horizontal, 16)
                    .struisSurface(radius: Theme.Radius.card)
                    Text("3 枚を 1 つの答案として採点します。ほかの画面に移っても続きます。")
                        .font(Typography.caption).foregroundStyle(Theme.secondaryText)
                }
                .padding(20)
            }
            .background(Theme.ground)
            .navigationTitle("結果")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct BatchMockPageRow: View {
    enum State { case done, running, waiting }
    let number: Int
    let text: String
    let state: State

    var body: some View {
        HStack(spacing: 12) {
            BatchMockThumb(number: number, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(number) 枚目").font(Typography.bodyEmphasized).foregroundStyle(Theme.primaryText)
                Text(text).font(Typography.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            switch state {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.growthColor)
            case .running: ProgressView()
            case .waiting: Image(systemName: "circle.dotted").foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct BatchMockR1: View {
    private let states: [WorkbookProblemTileDTO.State] = [.correct, .correct, .correct, .correct, .correct, .correct, .wrong, .correct, .correct, .correct]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("頂点の座標が求められる · 演習").font(Typography.caption).foregroundStyle(Theme.secondaryText)
                        Text("10 問中 9 問 正解").font(Typography.heading1).foregroundStyle(Theme.primaryText)
                        Text("3 枚の写真から 10 問すべてを採点しました").font(Typography.caption).foregroundStyle(Theme.secondaryText)
                    }
                    HStack(spacing: 6) {
                        ForEach(Array(states.enumerated()), id: \.offset) { index, state in
                            WorkbookTile(state: state, size: 28)
                                .overlay {
                                    Text("\(index + 1)").font(Typography.micro.monospacedDigit())
                                        .foregroundStyle(state == .correct ? Theme.onAccent : Theme.secondaryText)
                                }
                        }
                    }
                    VStack(spacing: 8) {
                        BatchMockPaper.view(fill: false)
                            .frame(maxWidth: .infinity)
                            .frame(height: 300)
                            .overlay(alignment: .topTrailing) {
                                Text("2 / 3")
                                    .font(Typography.caption.monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(.black.opacity(0.55), in: Capsule())
                                    .padding(8)
                            }
                        HStack(spacing: 6) {
                            ForEach(0..<3, id: \.self) { index in
                                Circle().fill(index == 1 ? Theme.primaryText : Theme.primaryText.opacity(0.2)).frame(width: 7, height: 7)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        BatchMockVerdictHeader(text: "1 枚目 · 問1〜問4")
                        ForEach(1...4, id: \.self) { BatchMockVerdictRow(label: "問\($0)", correct: true, note: "手順が正しい") }
                        BatchMockVerdictHeader(text: "2 枚目 · 問5〜問7")
                        BatchMockVerdictRow(label: "問5", correct: true, note: "手順が正しい")
                        BatchMockVerdictRow(label: "問6", correct: true, note: "手順が正しい")
                        BatchMockVerdictRow(label: "問7", correct: false, note: "符号ミス · 平方完成で −3 を足している")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .struisSurface(radius: Theme.Radius.card)
                }
                .padding(20)
            }
            .background(Theme.ground)
            .navigationTitle("結果")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct BatchMockVerdictHeader: View {
    let text: String
    var body: some View {
        Text(text).font(Typography.caption).foregroundStyle(Theme.secondaryText)
            .padding(.top, 14).padding(.bottom, 4)
    }
}

private struct BatchMockVerdictRow: View {
    let label: String
    let correct: Bool
    let note: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: correct ? "circle" : "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(correct ? Theme.growthColor : Theme.regressColor)
                .frame(width: 20)
            Text(label).font(Typography.bodyEmphasized).foregroundStyle(Theme.primaryText)
            Text(note).font(Typography.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 7)
    }
}
#endif
