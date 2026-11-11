import AVFoundation
import PhotosUI
import SwiftMath
import SwiftUI
import UIKit

// MARK: - 数式

/// 式を1行で描く(SwiftMath で画像にする。本体の `NativeMathRenderer` と同じ組み方)。読めない式は文字のまま出す。
struct TimeAttackMath: View {
    let latex: String
    var size: CGFloat = 34
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let image = Self.render(latex, size: size, color: UIColor(Theme.textPrimary(scheme))) {
            Image(uiImage: image)
                .accessibilityLabel(Self.plain(latex))
        } else {
            Text(Self.plain(latex)).font(Typography.sans(size: size * 0.8, weight: .medium))
        }
    }

    static func render(_ latex: String, size: CGFloat, color: UIColor) -> UIImage? {
        let renderer = MTMathImage(latex: latex, fontSize: size, textColor: color, labelMode: .display, textAlignment: .left)
        renderer.font = MTFontManager.manager.latinModernFont(withSize: size)
        renderer.contentInsets = MTEdgeInsets(top: 2, left: 2, bottom: 2 + size * 0.15, right: 2)
        let (error, image) = renderer.asImage()
        guard error == nil, let image, image.size.width >= 1, image.size.height >= 1 else { return nil }
        return image
    }

    /// 1行の文字に直した式(結果の表・共有の文)。
    static func plain(_ latex: String) -> String {
        var text = latex
        let replacements: [(String, String)] = [
            ("\\left", ""), ("\\right", ""), ("\\cdot", "·"), ("\\times", "×"), ("\\pi", "π"), ("\\theta", "θ"),
            ("\\circ", "°"), ("^{\\circ}", "°"), ("\\sin", "sin"), ("\\cos", "cos"), ("\\tan", "tan"), ("\\log", "log"),
            ("\\sqrt", "√"), ("\\,", " "), ("\\ ", " "),
        ]
        for (from, to) in replacements { text = text.replacingOccurrences(of: from, with: to) }
        text = text.replacingOccurrences(of: #"\\d?frac\{([^{}]*)\}\{([^{}]*)\}"#, with: "$1/$2", options: .regularExpression)
        text = text.replacingOccurrences(of: "^°", with: "°")
        text = text.replacingOccurrences(of: #"\^\{([^{}]*)\}"#, with: "^$1", options: .regularExpression)
        return text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    }
}

// MARK: - 撮る

/// 紙を撮るカメラ。シャッターを押した時刻を先に知らせ(タイマーはここで止める)、写真はその後に渡す。
/// カメラが無い端末(Simulator)では写真を選ぶ。
struct TimeAttackCamera: UIViewControllerRepresentable {
    var onShutter: () -> Void
    var onPhoto: (Data) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> TimeAttackCameraController {
        let controller = TimeAttackCameraController()
        controller.onShutter = onShutter
        controller.onPhoto = onPhoto
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_ controller: TimeAttackCameraController, context: Context) {}
}

final class TimeAttackCameraController: UIViewController, AVCapturePhotoCaptureDelegate, PHPickerViewControllerDelegate {
    var onShutter: () -> Void = {}
    var onPhoto: (Data) -> Void = { _ in }
    var onCancel: () -> Void = {}

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var preview: AVCaptureVideoPreviewLayer?
    private let queue = DispatchQueue(label: "com.digiloglab.strius.timeattack.camera")
    private var pickerShown = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.13, green: 0.10, blue: 0.08, alpha: 1)
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input), session.canAddOutput(output) {
            session.sessionPreset = .photo
            session.addInput(input)
            session.addOutput(output)
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
            addControls()
            queue.async { [session] in session.startRunning() }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard preview == nil, !pickerShown else { return }
        pickerShown = true
        #if DEBUG
        // Simulator の検証: 決まった写真を使う。
        if let path = ProcessInfo.processInfo.environment["STRUIS_TIMEATTACK_PHOTO"], let data = FileManager.default.contents(atPath: path) {
            onShutter()
            onPhoto(data)
            return
        }
        #endif
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    private func addControls() {
        let hint = UILabel()
        hint.text = "紙全体が入るように撮る"
        hint.textColor = UIColor(red: 1, green: 0.957, blue: 0.902, alpha: 1)
        hint.font = Typography.sansUIFont(size: 15, weight: .medium, relativeTo: .body)
        hint.translatesAutoresizingMaskIntoConstraints = false

        let shutter = UIButton(type: .custom)
        shutter.backgroundColor = UIColor(Theme.accentColor)
        shutter.layer.cornerRadius = 38
        shutter.layer.borderWidth = 4
        shutter.layer.borderColor = UIColor(red: 1, green: 0.957, blue: 0.902, alpha: 1).cgColor
        shutter.accessibilityLabel = "撮る"
        shutter.accessibilityIdentifier = "timeattack-shutter"
        shutter.addTarget(self, action: #selector(capture), for: .touchUpInside)
        shutter.translatesAutoresizingMaskIntoConstraints = false

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = UIColor(red: 1, green: 0.957, blue: 0.902, alpha: 1)
        close.accessibilityLabel = "閉じる"
        close.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false

        [hint, shutter, close].forEach(view.addSubview)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            close.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            close.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 44), close.heightAnchor.constraint(equalToConstant: 44),
            shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            shutter.widthAnchor.constraint(equalToConstant: 76), shutter.heightAnchor.constraint(equalToConstant: 76),
        ])
    }

    @objc private func capture() {
        onShutter()
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    @objc private func cancel() { onCancel() }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        DispatchQueue.main.async {
            if let data { self.onPhoto(data) } else { self.onCancel() }
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
            onCancel()
            return
        }
        onShutter()
        provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
            DispatchQueue.main.async {
                if let data { self.onPhoto(data) } else { self.onCancel() }
            }
        }
    }
}

// MARK: - 共有

/// 共有シート(画像とリンクをまとめて渡す)。
struct TimeAttackShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 送る画像(LINE・ストーリー向けの縦長)。問題そのものは載せない(受け取った人が先に考えられないように)。
struct TimeAttackShareCard: View {
    let field: String
    let name: String
    let total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                TimeAttackMark(size: 32)
                Text("Struis").font(Typography.sans(size: 17, weight: .bold)).foregroundStyle(Theme.primaryText)
            }
            VStack(spacing: 12) {
                Text("\(field)　基礎 \(TimeAttack.problemCount)問")
                    .font(Typography.sans(size: 12, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Theme.accentColor.opacity(0.16), in: Capsule())
                if !name.isEmpty {
                    Text("\(name)さんの記録").font(Typography.sans(size: 15, weight: .bold))
                }
                Text(TimeAttack.clock(total)).font(.system(size: 64, weight: .bold)).monospacedDigit()
                Text("このタイム、\n抜けますか。").font(Typography.sans(size: 22, weight: .bold)).multilineTextAlignment(.center)
                Text("同じ5問を紙に解いて、最後に1枚撮るだけ\n誤答は1問 +10秒")
                    .font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center).lineSpacing(4)
            }
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
            .struisSurface(radius: Theme.Radius.cardLarge)
            Text("リンクを開くと、アプリを入れなくてもその場で解けます")
                .font(Typography.sans(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity)
        }
        .padding(EdgeInsets(top: 40, leading: 24, bottom: 32, trailing: 24))
        .frame(width: 360, height: 640)
        .background(Theme.ground)
    }

    @MainActor
    static func image(field: String, name: String, total: Double) -> UIImage? {
        let renderer = ImageRenderer(content: TimeAttackShareCard(field: field, name: name, total: total).environment(\.colorScheme, .light))
        renderer.scale = 3
        return renderer.uiImage
    }
}

/// ロゴマーク(墨の角丸正方形に3本の弧)。
struct TimeAttackMark: View {
    var size: CGFloat = 32

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 1024
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: canvas), cornerRadius: 224 * scale, style: .continuous),
                         with: .color(Color(red: 0.129, green: 0.098, blue: 0.078)))
            func arc(_ from: CGPoint, _ control: CGPoint, _ to: CGPoint, _ color: Color) {
                var path = Path()
                path.move(to: CGPoint(x: from.x * scale, y: from.y * scale))
                path.addQuadCurve(to: CGPoint(x: to.x * scale, y: to.y * scale), control: CGPoint(x: control.x * scale, y: control.y * scale))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 164 * scale, lineCap: .round))
            }
            let cream = Color(red: 1, green: 0.957, blue: 0.902)
            arc(CGPoint(x: 352, y: 294), CGPoint(x: 512, y: 194), CGPoint(x: 672, y: 294), cream)
            arc(CGPoint(x: 272, y: 456), CGPoint(x: 214, y: 638), CGPoint(x: 382, y: 758), cream)
            arc(CGPoint(x: 752, y: 456), CGPoint(x: 810, y: 638), CGPoint(x: 642, y: 758), Color(red: 0.722, green: 0.451, blue: 0.227))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
