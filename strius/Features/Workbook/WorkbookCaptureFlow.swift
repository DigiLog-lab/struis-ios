import SwiftUI
import UIKit

/// 撮った紙の確認(撮り直す / 使う)。「使う」で即「最近」へ入り、判定は裏で走る。どこから撮っても
/// リザルト画面を開き、判定の段を見ながら待てる。判定が終わればそこに結果と次の行動が出る(A9)。
/// カメラ自体は `WorkbookHomeView` の根に付けた `ChatCameraPresentation`(別ウィンドウ)が出す。
struct WorkbookPendingPhoto: Identifiable {
    let id = UUID()
    let data: Data
    let context: WorkbookViewRef?
}

struct WorkbookCaptureFlow: View {
    @Environment(WorkbookStore.self) private var store
    @Environment(WorkbookCoordinator.self) private var coordinator
    let photo: WorkbookPendingPhoto
    let onFinish: () -> Void

    @State private var isSending = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = UIImage(data: photo.data) {
                confirmScreen(image: image)
            } else {
                VStack(spacing: 16) {
                    Text("写真を読み込めませんでした")
                        .foregroundStyle(.white)
                    Button("閉じる") { onFinish() }
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func confirmScreen(image: UIImage) -> some View {
        VStack(spacing: 0) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
                .accessibilityIdentifier("workbook-capture-preview")
            HStack(spacing: 16) {
                Button {
                    onFinish()
                    coordinator.capture(context: photo.context)
                } label: {
                    Text("撮り直す")
                        .font(Typography.bodyEmphasized)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(isSending)
                .accessibilityIdentifier("workbook-capture-retake")

                Button {
                    guard !isSending else { return }
                    isSending = true
                    let data = photo.data
                    let context = photo.context
                    onFinish()
                    // 撮った一枚の画面(保存している間に学習者が離れたら、リザルトを開かない)。
                    let origin = coordinator.path.last
                    Task {
                        // そのままリザルト画面へ(判定中はそこで段の表示を見ながら待つ。A9: ホーム・小単元・単元から撮った時も)。
                        if let capture = await store.submitCapture(imageData: data, context: context),
                           coordinator.path.last == origin {
                            coordinator.open(.capture(capture.id))
                        }
                    }
                } label: {
                    Text("使う")
                        .font(Typography.bodyEmphasized)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending)
                .accessibilityIdentifier("workbook-capture-use")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }
}
