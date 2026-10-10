import OSLog
import SwiftUI
import WebKit

private let sceneLog = Logger(subsystem: "com.digiloglab.strius", category: "scene")

/// シーンが commit した予想値 (契約 §4.2 prediction イベントの payload.value)。
enum ScenePrediction: Equatable {
    case number(Double)
    case text(String)

    /// enterStage("consequence", {prediction}) に渡す Any 表現。
    var jsValue: Any {
        switch self {
        case .number(let value): return value
        case .text(let value): return value
        }
    }

    var displayText: String {
        switch self {
        case .number(let value): return ImmersionFormat.number(value)
        case .text(let value): return value
        }
    }
}

/// SceneFlowView (親) と ScenePlayerView (WKWebView) をつなぐ双方向ハンドル。
/// 親は enterStage / snapshot / restore を呼び、シーンからのイベントをコールバックで受け取る。
final class ScenePlayerBridge {
    /// シーン初期化完了 (ready イベント)。
    var onReady: (() -> Void)?
    /// 学習者が予想を commit した。
    var onPrediction: ((ScenePrediction) -> Void)?
    /// 学習者がシーンを操作した (値の変更・なぞる動きのみ。単なるタップは来ない)。
    var onInteraction: (() -> Void)?
    /// シーンからのデバッグログ。
    var onLog: ((String) -> Void)?

    private weak var webView: WKWebView?
    /// ready 前に要求された enterStage。ready 後に再生する。
    private var pendingStage: (stage: String, context: [String: Any]?)?
    private(set) var isReady = false

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func detach() {
        webView = nil
        isReady = false
        pendingStage = nil
    }

    // MARK: シェル → シーン

    /// struisScene.enterStage(stage, context) を呼ぶ。window.struis.stage も同期する。
    /// シーンがまだ ready でなければ、ready 後に自動で再生する。
    func enterStage(_ stage: String, context: [String: Any]? = nil) {
        guard isReady, let webView else {
            pendingStage = (stage, context)
            return
        }
        var script = "window.struis.stage = \(Self.jsString(stage));"
        script += "if (window.struisScene && typeof window.struisScene.enterStage === 'function') {"
        script += "window.struisScene.enterStage(\(Self.jsString(stage)), \(Self.jsJSON(context)));"
        script += "}"
        evaluate(script, in: webView)
    }

    /// 復帰用 state を JSON 文字列で受け取る (シーン未実装なら nil)。
    func snapshot(completion: @escaping (String?) -> Void) {
        guard let webView else {
            completion(nil)
            return
        }
        let script = "(window.struisScene && typeof window.struisScene.snapshot === 'function')"
            + " ? JSON.stringify(window.struisScene.snapshot()) : null;"
        webView.evaluateJavaScript(script) { result, error in
            if let error {
                sceneLog.error("snapshot failed: \(error.localizedDescription)")
                completion(nil)
                return
            }
            completion(result as? String)
        }
    }

    /// snapshot() が返した state (JSON 文字列) をシーンへ戻す。
    func restore(_ stateJSON: String) {
        guard let webView else { return }
        let script = "if (window.struisScene && typeof window.struisScene.restore === 'function') {"
            + "window.struisScene.restore(\(stateJSON));"
            + "}"
        evaluate(script, in: webView)
    }

    // MARK: シーン → シェル (Coordinator から呼ばれる)

    func handleMessage(type: String, payload: Any?) {
        switch type {
        case "ready":
            isReady = true
            sceneLog.debug("scene ready")
            onReady?()
            if let pending = pendingStage {
                pendingStage = nil
                enterStage(pending.stage, context: pending.context)
            }
        case "interaction":
            onInteraction?()
        case "prediction":
            guard let payload = payload as? [String: Any], let value = payload["value"] else { return }
            if let number = value as? Double {
                onPrediction?(.number(number))
            } else if let number = value as? Int {
                onPrediction?(.number(Double(number)))
            } else if let text = value as? String {
                onPrediction?(.text(text))
            }
        case "log":
            let message = (payload as? [String: Any])?["message"] as? String ?? "\(String(describing: payload))"
            let level = (payload as? [String: Any])?["level"] as? String ?? "info"
            sceneLog.info("scene log [\(level)] \(message)")
            onLog?(message)
        default:
            sceneLog.debug("unknown scene message: \(type)")
        }
    }

    // MARK: 内部

    private func evaluate(_ script: String, in webView: WKWebView) {
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                sceneLog.error("evaluateJavaScript failed: \(error.localizedDescription)")
            }
        }
    }

    private static func jsString(_ value: String) -> String {
        // ステージ名は英小文字のみだが、防御的に JSON エンコードする。
        // トップレベルが String の場合は .fragmentsAllowed が必要 (ないと NSException で落ちる)。
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
    }

    private static func jsJSON(_ object: [String: Any]?) -> String {
        guard let object,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }
}

/// シーンパッケージの scene.html を再生する WKWebView (契約 §4)。
/// document start に window.struis を注入し、struis.post を messageHandlers.struis へ橋渡しする。
/// 背景は透明 — シェルの LiquidWallpaper を透かす。
struct ScenePlayerView: UIViewRepresentable {
    let meta: SceneMeta
    let sceneHTML: String
    let bridge: ScenePlayerBridge

    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        // window.struis 注入 (document start、main frame のみ)
        let injection = WKUserScript(
            source: Self.injectionScript(meta: meta, isDark: scheme == .dark),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(injection)
        contentController.add(context.coordinator, name: "struis")
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // 配信シーンの内容高は題材ごとに異なる。固定キャンバス高を超える場合も
        // 差の解釈や操作へ到達できるよう、シーン内の縦スクロールを許可する。
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        bridge.attach(webView)
        webView.loadHTMLString(sceneHTML, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "struis")
        webView.configuration.userContentController.removeAllUserScripts()
        webView.navigationDelegate = nil
        webView.stopLoading()
        coordinator.bridge.detach()
    }

    /// 契約 §4.1 の window.struis 定義。model は meta 由来、tokens は Theme と
    /// 同じ値をカラースキーム別に注入する (哲学 §5.1)。
    private static func injectionScript(meta: SceneMeta, isDark: Bool) -> String {
        let modelJSON = meta.model?.injectionJSON ?? #"{"kind":"unknown","parameters":{}}"#
        let reduceMotion = UIAccessibility.isReduceMotionEnabled ? "true" : "false"
        let tokensJSON = isDark
            ? """
            {
              accent: "#d7a15f",
              accentSoft: "rgba(215,161,95,0.16)",
              growth: "#7fbf95",
              textPrimary: "#f3e8d4",
              textSecondary: "#b8a890",
              textTertiary: "#7d7260",
              fontSans: "-apple-system, 'Hiragino Sans', sans-serif",
              fontSerif: "'HiraMinProN-W6', 'YuMincho', serif"
            }
            """
            : """
            {
              accent: "#b8733a",
              accentSoft: "rgba(184,115,58,0.14)",
              growth: "#3f8f62",
              textPrimary: "#1f1a14",
              textSecondary: "#5a5044",
              textTertiary: "#8a7f6f",
              fontSans: "-apple-system, 'Hiragino Sans', sans-serif",
              fontSerif: "'HiraMinProN-W6', 'YuMincho', serif"
            }
            """
        return """
        (function() {
          window.struis = {
            version: 1,
            stage: "predict",
            model: \(modelJSON),
            capabilities: { reduceMotion: \(reduceMotion), platform: "ios" },
            tokens: \(tokensJSON),
            post: function(type, payload) {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.struis) {
                window.webkit.messageHandlers.struis.postMessage({ type: type, payload: payload || null });
              }
            }
          };
          // シェル所有の汎用操作検知 (哲学 §2 Step4: 介入なしに結果へ進ませない)。
          // シーン実装に依存せず capture で拾って報告する。何も変えないタップは
          // 操作に数えない — 値の変更 (input/change)、なぞる動き (touchmove /
          // 押下中の pointermove)、そしてジェスチャ直後にシーンの DOM が変わった
          // 場合 (タップで値を置く介入) だけを「介入」として通知する。
          ["input", "change", "touchmove"].forEach(function(type) {
            window.addEventListener(type, function() {
              window.struis.post("interaction", { source: type });
            }, { capture: true, passive: true });
          });
          window.addEventListener("pointermove", function(event) {
            if (event.buttons) {
              window.struis.post("interaction", { source: "pointermove" });
            }
          }, { capture: true, passive: true });
          var lastGestureAt = 0;
          ["pointerdown", "touchstart"].forEach(function(type) {
            window.addEventListener(type, function() {
              lastGestureAt = Date.now();
            }, { capture: true, passive: true });
          });
          new MutationObserver(function() {
            if (Date.now() - lastGestureAt < 600) {
              window.struis.post("interaction", { source: "mutation" });
            }
          }).observe(document.documentElement, {
            subtree: true, childList: true, attributes: true, characterData: true
          });
        })();
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let bridge: ScenePlayerBridge

        init(bridge: ScenePlayerBridge) {
            self.bridge = bridge
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "struis",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            bridge.handleMessage(type: type, payload: body["payload"])
        }

        /// リンクナビゲーションは無効化。about:blank (loadHTMLString の初期ロード) のみ許可。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            if navigationAction.navigationType == .other, url?.scheme == "about" {
                decisionHandler(.allow)
            } else {
                sceneLog.debug("blocked navigation to \(url?.absoluteString ?? "nil")")
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            sceneLog.error("scene load failed: \(error.localizedDescription)")
        }
    }
}
