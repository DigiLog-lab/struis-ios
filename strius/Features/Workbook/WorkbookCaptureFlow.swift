import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 撮った紙の束。カメラは閉じずに続けて撮れ(一括採点)、「採点する」で確認画面へ来る。
/// カメラ自体は `WorkbookHomeView` の根に付けた `ChatCameraPresentation`(別ウィンドウ)が出す。
struct WorkbookPendingPages: Identifiable {
    struct Page: Identifiable, Hashable {
        let id = UUID()
        let data: Data
    }

    let id = UUID()
    var pages: [Page]
    let context: WorkbookViewRef?

    /// 1 つの答案にまとめられる写真の上限(判定のターンに渡す画像の数)。
    static let limit = 8
}

/// 送る前の確認(並べ替え・外す・撮り足す)。「まとめて採点する」で全ページを 1 つの答案にして即「最近」へ入れ、
/// 判定は裏で走る。どこから撮ってもリザルト画面を開き、判定の段を見ながら待てる(A9)。
struct WorkbookCaptureFlow: View {
    @Environment(WorkbookStore.self) private var store
    @Environment(WorkbookCoordinator.self) private var coordinator
    let onFinish: () -> Void

    @State private var isSending = false
    @State private var confirmsDiscard = false
    @State private var dragging: UUID?

    private var pages: [WorkbookPendingPages.Page] { coordinator.pendingPages?.pages ?? [] }
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            pageTile(page, number: index + 1)
                        }
                        if pages.count < WorkbookPendingPages.limit {
                            addTile
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.ground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { confirmsDiscard = true }
                        .disabled(isSending)
                        .accessibilityIdentifier("workbook-capture-cancel")
                }
            }
            .safeAreaInset(edge: .bottom) { sendButton }
            .confirmationDialog("撮った \(pages.count) 枚を破棄しますか", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("破棄", role: .destructive) { onFinish() }
                Button("戻る", role: .cancel) {}
            }
        }
        .onChange(of: pages.isEmpty) { _, empty in
            // 全部外したら、確認画面を閉じる。
            if empty, !isSending { onFinish() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pages.count > 1 ? "\(pages.count) 枚をまとめて採点します" : "この 1 枚を採点します")
                .font(Typography.heading2)
                .foregroundStyle(Theme.primaryText)
                .accessibilityIdentifier("workbook-capture-title")
            Text(pages.count > 1 ? "並べた順に 1 つの答案として読みます。長押しして動かすと並べ替えられます。" : "続けて撮ると、何枚でもまとめて採点できます。")
                .font(Typography.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func pageTile(_ page: WorkbookPendingPages.Page, number: Int) -> some View {
        WorkbookPendingPageImage(data: page.data)
            .aspectRatio(3 / 4, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .overlay(alignment: .bottomLeading) {
                Text("\(number)")
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(.black.opacity(0.6), in: Circle())
                    .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation { coordinator.pendingPages?.pages.removeAll { $0.id == page.id } }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .padding(6)
                }
                .disabled(isSending)
                .accessibilityLabel("\(number) 枚目を外す")
                .accessibilityIdentifier("workbook-capture-remove-\(number)")
            }
            .opacity(dragging == page.id ? 0.4 : 1)
            .onDrag {
                dragging = page.id
                return NSItemProvider(object: page.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: WorkbookPageDropDelegate(target: page.id, dragging: $dragging) { from, to in
                guard var current = coordinator.pendingPages,
                      let source = current.pages.firstIndex(where: { $0.id == from }),
                      let destination = current.pages.firstIndex(where: { $0.id == to }) else { return }
                withAnimation {
                    current.pages.move(fromOffsets: IndexSet(integer: source), toOffset: destination > source ? destination + 1 : destination)
                    coordinator.pendingPages = current
                }
            })
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(number) 枚目")
            .accessibilityIdentifier("workbook-capture-page-\(number)")
    }

    private var addTile: some View {
        Button {
            coordinator.isCameraPresented = true
        } label: {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .aspectRatio(3 / 4, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "camera.fill").font(.system(size: 22))
                        Text("撮り足す").font(Typography.bodyEmphasized)
                    }
                    .foregroundStyle(Theme.accentColor)
                }
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .accessibilityIdentifier("workbook-capture-add")
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            Text(pages.count > 1 ? "\(pages.count) 枚をまとめて採点する" : "採点する")
                .font(Typography.bodyEmphasized)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.Palette.accentLight)
        .disabled(isSending || pages.isEmpty)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .accessibilityIdentifier("workbook-capture-use")
    }

    private func send() {
        guard !isSending, let pending = coordinator.pendingPages, !pending.pages.isEmpty else { return }
        isSending = true
        let data = pending.pages.map(\.data)
        let context = pending.context
        onFinish()
        // 撮った画面(保存している間に学習者が離れたら、リザルトを開かない)。
        let origin = coordinator.path.last
        Task {
            // そのままリザルト画面へ(判定中はそこで段の表示を見ながら待つ。A9: ホーム・小単元・単元から撮った時も)。
            if let capture = await store.submitCapture(pages: data, context: context),
               coordinator.path.last == origin {
                coordinator.open(.capture(capture.id))
            }
        }
    }
}

/// 束の 1 枚。縮小して読み込む(元の写真は送る時まで手を付けない)。
private struct WorkbookPendingPageImage: View {
    let data: Data
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.cardLow
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .clipped()
        .task(id: data.count) { image = try? await PreparedImage.decode(data, maxPixelSize: 600) }
    }
}

/// 長押しして動かした写真を、落とした所の写真の位置へ移す。
private struct WorkbookPageDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let move: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        move(dragging, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
