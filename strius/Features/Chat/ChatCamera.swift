import AVFoundation
import SwiftUI
import UIKit
import os

private let cameraLog = Logger(subsystem: "com.digiloglab.strius", category: "camera")

/// A recognizer cancels the button's touch on recognition, so releasing a long
/// press cannot also open the attachment palette.
struct ChatAttachmentButton: UIViewRepresentable {
    let expanded: Bool
    let enabled: Bool
    let tint: UIColor
    let onTap: () -> Void
    let onCamera: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "plus", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        button.accessibilityLabel = "添付"
        button.accessibilityIdentifier = "chat-attachment-button"
        button.addTarget(context.coordinator, action: #selector(Coordinator.prepareFeedback), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0.5
        button.addGestureRecognizer(press)
        button.accessibilityCustomActions = [UIAccessibilityCustomAction(
            name: "カメラを開く", target: context.coordinator, selector: #selector(Coordinator.camera))]
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = enabled
        button.tintColor = tint
        button.setImage(UIImage(systemName: expanded ? "xmark" : "plus", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
    }

    final class Coordinator: NSObject {
        var parent: ChatAttachmentButton
        private let feedback = UIImpactFeedbackGenerator(style: .medium)
        init(_ parent: ChatAttachmentButton) { self.parent = parent }
        @objc func prepareFeedback() { feedback.prepare() }
        @objc func tap() { parent.onTap() }
        @objc func press(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, parent.enabled else { return }
            feedback.impactOccurred()
            _ = camera()
        }
        @objc func camera() -> Bool {
            guard parent.enabled else { return false }
            parent.onCamera()
            return true
        }
    }
}

/// The camera overlays the chat. While the keyboard is hidden, an equal safe
/// area inset preserves the existing chat viewport and scroll position.
struct ChatCameraPresentation: UIViewRepresentable {
    @Binding var isPresented: Bool
    /// まとめて撮る(一括採点)。シャッターの後もカメラを閉じずに撮った写真を束ね、「採点する」で全部を渡す。
    var batch: ChatCameraBatch? = nil
    var onPhoto: (Data) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ anchor: UIView, context: Context) {
        if !isPresented {
            context.coordinator.close()
            return
        }
        guard context.coordinator.window == nil, let scene = anchor.window?.windowScene else { return }
        let coordinator = context.coordinator
        let window = UIWindow(windowScene: scene)
        let controller = ChatCameraController()
        controller.onClose = { isPresented = false }
        controller.onPhoto = { data in
            onPhoto(data)
            isPresented = false
        }
        if let batch {
            controller.batch = batch
            controller.onPhotos = { photos in
                batch.onPhotos(photos)
                isPresented = false
            }
        }
        window.rootViewController = controller
        window.backgroundColor = .clear
        window.windowLevel = .alert + 1
        coordinator.window = window
        coordinator.suspendKeyboard(from: anchor)
        window.isHidden = false
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.close() }
    final class Coordinator {
        var window: UIWindow?
        private weak var chatController: UIViewController?
        private weak var responder: UIView?
        private var originalInsets: UIEdgeInsets?
        private var scrollOffsets: [(UIScrollView, CGPoint)] = []
        private var closing = false

        func suspendKeyboard(from anchor: UIView) {
            guard let chatWindow = anchor.window else { return }
            func descendants(_ view: UIView) -> [UIView] {
                [view] + view.subviews.flatMap(descendants)
            }
            func owningController(of view: UIView) -> UIViewController? {
                var next: UIResponder? = view
                while let current = next {
                    if let controller = current as? UIViewController { return controller }
                    next = current.next
                }
                return nil
            }
            // A presented question sheet is outside the presenting root view's
            // subtree. Find its focused view in the actual window, then preserve
            // the keyboard inset on that view's controller, not the app root.
            let firstResponder = descendants(chatWindow).first(where: \.isFirstResponder)
            guard let root = owningController(of: firstResponder ?? anchor) else { return }
            scrollOffsets = descendants(root.view).compactMap { view in
                guard let scroll = view as? UIScrollView else { return nil }
                return (scroll, scroll.contentOffset)
            }
            guard let firstResponder else { return }
            let guide = root.view.keyboardLayoutGuide
            root.view.layoutIfNeeded()
            let keyboardInset = max(0, root.view.bounds.maxY - guide.layoutFrame.minY - root.view.safeAreaInsets.bottom)
            chatController = root
            responder = firstResponder
            originalInsets = root.additionalSafeAreaInsets
            UIView.performWithoutAnimation {
                root.additionalSafeAreaInsets.bottom += keyboardInset
                root.view.layoutIfNeeded()
                firstResponder.resignFirstResponder()
            }
        }

        func close() {
            guard window != nil, !closing else { return }
            closing = true
            (window?.rootViewController as? ChatCameraController)?.stop()
            if let responder, let root = chatController, let insets = originalInsets {
                responder.becomeFirstResponder()
                // Keep the overlay until the keyboard has restored its inset.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                    UIView.performWithoutAnimation {
                        root.additionalSafeAreaInsets = insets
                        root.view.layoutIfNeeded()
                        finishClosing()
                    }
                }
            } else {
                finishClosing()
            }
        }

        private func finishClosing() {
            for (scroll, offset) in scrollOffsets { scroll.setContentOffset(offset, animated: false) }
            scrollOffsets = []
            window?.isHidden = true
            window = nil
            responder = nil
            chatController = nil
            originalInsets = nil
            closing = false
        }
    }
}

/// まとめて撮る時の設定。`existingCount` は束に既にある枚数(撮り足す時)、`limit` は束の上限。
struct ChatCameraBatch {
    var existingCount = 0
    var limit = 8
    let onPhotos: ([Data]) -> Void
}

/// The preview is the view's backing layer so UIKit keeps its bounds in sync
/// throughout rotation, including the final layout after the transition.
private final class ChatCameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private final class ChatCameraController: UIViewController, AVCapturePhotoCaptureDelegate {
    var onClose: (() -> Void)?
    var onPhoto: ((Data) -> Void)?
    var batch: ChatCameraBatch?
    var onPhotos: (([Data]) -> Void)?
    private var shots: [Data] = []
    private let strip = UIStackView()
    private let done = UIButton(type: .system)
    private let counter = UILabel()
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.struis.chat-camera")
    private let panel = UIView()
    private let previewView = ChatCameraPreviewView()
    private var preview: AVCaptureVideoPreviewLayer { previewView.previewLayer }
    private let shutter = UIButton(type: .system)
    private let message = UILabel()
    private let focusIndicator = UIView()
    private var device: AVCaptureDevice?
    private var lensObservation: NSKeyValueObservation?
    private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var closed = false
    private var capturing = false
    private var processedPhoto: Data?

    #if DEBUG && targetEnvironment(simulator)
    // Simulator has no capture device. Opt-in UI tests supply only the sensor
    // image; JPEG processing, completion, attachment and HTTP sending stay real.
    private var testPhoto: Data? {
        guard let path = ProcessInfo.processInfo.environment["STRUIS_TEST_CAMERA_IMAGE"] else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        panel.backgroundColor = .black
        panel.layer.cornerRadius = 24
        panel.clipsToBounds = true
        panel.accessibilityIdentifier = "chat-camera-panel"
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.clipsToBounds = true
        previewView.accessibilityIdentifier = "chat-camera-preview"
        panel.addSubview(previewView)
        preview.videoGravity = .resizeAspectFill
        preview.session = session
        previewView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focus(_:))))
        focusIndicator.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        focusIndicator.layer.borderWidth = 1.5
        focusIndicator.layer.borderColor = UIColor.systemYellow.cgColor
        focusIndicator.isUserInteractionEnabled = false
        focusIndicator.alpha = 0
        previewView.addSubview(focusIndicator)

        let close = UIButton(type: .system)
        close.setTitle("キャンセル", for: .normal)
        close.tintColor = .white
        close.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(close)
        shutter.layer.cornerRadius = 32
        shutter.layer.borderWidth = 3
        shutter.layer.borderColor = UIColor.white.cgColor
        let shutterCenter = UIView()
        shutterCenter.backgroundColor = .white
        shutterCenter.layer.cornerRadius = 25
        shutterCenter.isUserInteractionEnabled = false
        shutterCenter.translatesAutoresizingMaskIntoConstraints = false
        shutter.addSubview(shutterCenter)
        NSLayoutConstraint.activate([
            shutterCenter.centerXAnchor.constraint(equalTo: shutter.centerXAnchor),
            shutterCenter.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            shutterCenter.widthAnchor.constraint(equalToConstant: 50),
            shutterCenter.heightAnchor.constraint(equalToConstant: 50)
        ])
        shutter.tintColor = .white
        shutter.accessibilityLabel = "撮影"
        shutter.accessibilityIdentifier = "chat-camera-shutter"
        shutter.isEnabled = false
        shutter.addTarget(self, action: #selector(capture), for: .touchUpInside)
        shutter.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(shutter)
        message.textColor = .white
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .body)
        message.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(message)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.65),
            close.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            close.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            close.heightAnchor.constraint(equalToConstant: 44),
            previewView.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            previewView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 4),
            previewView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -4),
            previewView.bottomAnchor.constraint(equalTo: shutter.topAnchor, constant: batch == nil ? -8 : -76),
            shutter.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            shutter.widthAnchor.constraint(equalToConstant: 64),
            shutter.heightAnchor.constraint(equalToConstant: 64),
            shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            message.centerYAnchor.constraint(equalTo: previewView.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: previewView.leadingAnchor, constant: 12),
            message.trailingAnchor.constraint(equalTo: previewView.trailingAnchor, constant: -12)
        ])
        if batch != nil { layoutBatchControls() }
        NotificationCenter.default.addObserver(self, selector: #selector(cancel),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        Task { await authorize() }
    }

    /// まとめて撮る時の、撮った写真の列・「採点する N」・何枚目かの表示。
    private func layoutBatchControls() {
        strip.axis = .horizontal
        strip.spacing = 8
        strip.alignment = .center
        strip.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(strip)
        panel.addSubview(scroll)
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor(Theme.Palette.accentLight)
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        done.configuration = configuration
        done.accessibilityIdentifier = "chat-camera-done"
        done.addTarget(self, action: #selector(finishBatch), for: .touchUpInside)
        done.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(done)
        counter.font = .preferredFont(forTextStyle: .footnote)
        counter.textColor = .white
        counter.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        counter.textAlignment = .center
        counter.layer.cornerRadius = 14
        counter.clipsToBounds = true
        counter.accessibilityIdentifier = "chat-camera-counter"
        counter.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(counter)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 60),
            strip.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            strip.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            strip.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            done.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            done.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            counter.topAnchor.constraint(equalTo: previewView.topAnchor, constant: 10),
            counter.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),
            counter.heightAnchor.constraint(equalToConstant: 28),
        ])
        updateBatchControls()
    }

    private var batchTotal: Int { (batch?.existingCount ?? 0) + shots.count }

    private func updateBatchControls() {
        guard let batch else { return }
        let total = batchTotal
        done.isHidden = total == 0
        done.configuration?.attributedTitle = AttributedString("採点する \(total)", attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold)
        ]))
        done.accessibilityLabel = "\(total) 枚を採点する"
        let full = total >= batch.limit
        counter.text = full ? "  \(batch.limit) 枚まで撮れます  " : "  \(total + 1) 枚目  "
        counter.isHidden = total == 0
        if full { shutter.isEnabled = false }
    }

    private func appendShot(_ data: Data) {
        shots.append(data)
        let thumb = UIImageView(image: UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 120, height: 160)))
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 6
        thumb.layer.borderWidth = 1
        thumb.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
        thumb.accessibilityIdentifier = "chat-camera-shot-\(shots.count)"
        thumb.translatesAutoresizingMaskIntoConstraints = false
        let number = UILabel()
        number.text = "\((batch?.existingCount ?? 0) + shots.count)"
        number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        number.textColor = .white
        number.textAlignment = .center
        number.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        number.layer.cornerRadius = 8
        number.clipsToBounds = true
        number.translatesAutoresizingMaskIntoConstraints = false
        thumb.addSubview(number)
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: 44),
            thumb.heightAnchor.constraint(equalToConstant: 58),
            number.leadingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: 3),
            number.bottomAnchor.constraint(equalTo: thumb.bottomAnchor, constant: -3),
            number.heightAnchor.constraint(equalToConstant: 16),
            number.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
        ])
        strip.addArrangedSubview(thumb)
        // 撮れたことを、写真が一瞬暗くなることで伝える。
        previewView.alpha = 0.25
        UIView.animate(withDuration: 0.3) { self.previewView.alpha = 1 }
        updateBatchControls()
    }

    @objc private func finishBatch() {
        guard !closed, !capturing, batchTotal > 0 else { return }
        let photos = shots
        stop { [self] in onPhotos?(photos) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreviewOrientation()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.updatePreviewOrientation()
        }
    }

    private func updatePreviewOrientation() {
        guard !capturing else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let connection = preview.connection {
            let angle: CGFloat
            switch view.window?.windowScene?.effectiveGeometry.interfaceOrientation {
            case .landscapeLeft: angle = 180
            case .landscapeRight: angle = 0
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
        CATransaction.commit()
    }

    private func authorize() async {
        #if DEBUG && targetEnvironment(simulator)
        if let data = testPhoto, let image = UIImage(data: data) {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.frame = previewView.bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            previewView.addSubview(imageView)
            shutter.isEnabled = true
            updateBatchControls()
            return
        }
        #endif
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        guard !closed else { return }
        guard authorized else {
            message.text = "カメラを使うには、設定でStruisのカメラへのアクセスを許可してください。"
            return
        }
        queue.async { [self] in
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard let device = Self.backCamera(),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.message.text = "カメラを起動できませんでした。" }
                return
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            configureFocus(device)
            session.startRunning()
            DispatchQueue.main.async {
                guard !self.closed else { self.stop(); return }
                self.device = device
                self.shutter.isEnabled = true
                self.updateBatchControls()
                self.view.setNeedsLayout()
            }
        }
    }

    /// Notes are shot close up. On multi-camera iPhones the wide lens alone
    /// cannot focus that near, so prefer a virtual device that switches to the
    /// ultra wide (macro) lens automatically, as the system Camera app does.
    private static func backCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .back).devices.first
    }

    private func configureFocus(_ device: AVCaptureDevice) {
        do { try device.lockForConfiguration() } catch { return }
        defer { device.unlockForConfiguration() }
        // Virtual devices start at the ultra wide's field of view; start at
        // the wide lens like the Camera app's 1x.
        if device.isVirtualDevice, let wide = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            device.videoZoomFactor = CGFloat(truncating: wide)
        }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.isSubjectAreaChangeMonitoringEnabled = true
        cameraLog.info("camera \(device.deviceType.rawValue, privacy: .public) zoom=\(device.videoZoomFactor) focus=\(device.focusMode.rawValue) near=\(device.autoFocusRangeRestriction.rawValue) minFocus=\(device.minimumFocusDistance)")
        lensObservation = device.observe(\.activePrimaryConstituent, options: [.initial, .new]) { device, _ in
            guard let lens = device.activePrimaryConstituent else { return }
            cameraLog.info("camera lens \(lens.deviceType.rawValue, privacy: .public) minFocus=\(lens.minimumFocusDistance)")
        }
        NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaDidChange),
            name: AVCaptureDevice.subjectAreaDidChangeNotification, object: device)
    }

    @objc private func focus(_ gesture: UITapGestureRecognizer) {
        guard let device, !capturing else { return }
        let location = gesture.location(in: previewView)
        let point = preview.captureDevicePointConverted(fromLayerPoint: location)
        queue.async {
            do { try device.lockForConfiguration() } catch { return }
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose
            }
        }
        focusIndicator.layer.removeAllAnimations()
        focusIndicator.center = location
        focusIndicator.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
        focusIndicator.alpha = 1
        UIView.animate(withDuration: 0.2) { self.focusIndicator.transform = .identity }
        UIView.animate(withDuration: 0.3, delay: 1.2) { self.focusIndicator.alpha = 0 }
    }

    /// After a tap-to-focus, return to continuous focus once the scene moves.
    @objc private func subjectAreaDidChange() {
        queue.async { [self] in
            guard let device = session.inputs.compactMap({ ($0 as? AVCaptureDeviceInput)?.device }).first else { return }
            do { try device.lockForConfiguration() } catch { return }
            defer { device.unlockForConfiguration() }
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        }
    }

    @objc private func capture() {
        #if DEBUG && targetEnvironment(simulator)
        if let data = testPhoto, !closed, !capturing {
            capturing = true
            shutter.isEnabled = false
            processedPhoto = nil
            processPhoto(data)
            // Leave a deterministic interval between processing and completion
            // to exercise immediate-send races without a physical camera.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                finishCapture(error: nil)
            }
            return
        }
        #endif
        guard !closed, !capturing, session.isRunning,
              let connection = output.connection(with: .video) else { return }
        // Coordinates are in the unrotated sensor space. Keep the still photo
        // unrotated while cropping, then preserve the preview's orientation.
        cropRect = preview.metadataOutputRectConverted(fromLayerRect: preview.bounds)
        connection.videoRotationAngle = preview.connection?.videoRotationAngle ?? 90
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        shutter.isEnabled = false
        message.text = nil
        capturing = true
        processedPhoto = nil
        output.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        DispatchQueue.main.async { [self] in
            guard !closed else { return }
            guard error == nil, let data = photo.fileDataRepresentation() else {
                processedPhoto = nil
                return
            }
            processPhoto(data)
        }
    }

    private func processPhoto(_ data: Data) {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else {
            return
        }
        let rect = CGRect(x: cropRect.minX * CGFloat(cgImage.width),
                          y: cropRect.minY * CGFloat(cgImage.height),
                          width: cropRect.width * CGFloat(cgImage.width),
                          height: cropRect.height * CGFloat(cgImage.height)).integral
            .intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let cropped = cgImage.cropping(to: rect) else { return }
        let oriented = UIImage(cgImage: cropped, scale: 1, orientation: image.imageOrientation)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: oriented.size, format: format).image { _ in
            oriented.draw(in: CGRect(origin: .zero, size: oriented.size))
        }
        guard let jpeg = normalized.jpegData(compressionQuality: 0.95) else { return }
        // Processing finishes before the capture itself has finished.
        // Keep the bytes private until didFinishCaptureFor and stopRunning
        // have completed, so the composer cannot send during teardown.
        processedPhoto = jpeg
    }

    private func captureFailed() {
        capturing = false
        processedPhoto = nil
        updatePreviewOrientation()
        shutter.isEnabled = true
        message.text = "撮影できませんでした。もう一度お試しください。"
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        DispatchQueue.main.async { [self] in
            finishCapture(error: error)
        }
    }

    private func finishCapture(error: Error?) {
        guard !closed else { return }
        guard error == nil, let data = processedPhoto else {
            captureFailed()
            return
        }
        processedPhoto = nil
        if batch != nil {
            // まとめて撮る: カメラを閉じずに次を撮れるようにする。
            capturing = false
            updatePreviewOrientation()
            shutter.isEnabled = true
            appendShot(data)
            return
        }
        stop { [self] in onPhoto?(data) }
    }

    @objc private func cancel() {
        // まとめて撮った写真がある時は、捨ててよいかを確かめる(アプリが裏に回った時は確かめずに閉じる)。
        if !shots.isEmpty, UIApplication.shared.applicationState == .active, presentedViewController == nil {
            let alert = UIAlertController(title: "撮った \(shots.count) 枚を破棄しますか", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "撮影を続ける", style: .cancel))
            alert.addAction(UIAlertAction(title: "破棄", style: .destructive) { [weak self] _ in self?.close() })
            present(alert, animated: true)
            return
        }
        close()
    }

    private func close() {
        onPhoto = nil
        onPhotos = nil
        onClose?()
    }

    func stop(completion: @escaping () -> Void = {}) {
        closed = true
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            DispatchQueue.main.async(execute: completion)
        }
    }
}
