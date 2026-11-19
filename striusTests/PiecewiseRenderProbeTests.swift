import SwiftMath
import SwiftUI
import Testing
import UIKit
@testable import strius

/// 調査用(後で消す): 場合分けの問題文の書き方ごとに、iPad の問題の欄と同じ幅で描いて PNG に書き出す。
@Suite(.serialized) @MainActor
struct PiecewiseRenderProbeTests {
    private static let head = "$m,n$ を正の整数とすると、次の関係が成り立ちます。"
    private static let tail = "この関係を使って、次の定積分の値を求めなさい。途中の式も書きなさい。"
    private static let integral = "\\int_{-\\pi}^{\\pi}\\sin mx\\sin nx\\,dx"

    private static let candidates: [(String, String)] = [
        ("a_inline_comma", head + "$\(integral)=\\pi\\ (m=n)$、$0\\ (m\\neq n)$。" + tail),
        ("b_displaystyle_comma", head + "$\\displaystyle \(integral)=\\pi\\ (m=n)$、$0\\ (m\\neq n)$。" + tail),
        ("c_display_comma_inside", head + "$$\(integral)=\\pi\\ (m=n)、$$$0\\ (m\\neq n)$。" + tail),
        ("d_inline_all", head + "$\(integral)=\\pi\\ (m=n)、0\\ (m\\neq n)$。" + tail),
        ("e_display_all", head + "$$\(integral)=\\pi\\ (m=n)、0\\ (m\\neq n)$$" + tail),
        ("f_display_then_inline", head + "$$\(integral)=\\pi\\ (m=n)$$、$0\\ (m\\neq n)$。" + tail),
        ("g_cases_inline", head + "$\(integral)=\\begin{cases}\\pi & (m=n)\\\\ 0 & (m\\neq n)\\end{cases}$" + tail),
        ("h_cases_display", head + "$$\(integral)=\\begin{cases}\\pi & (m=n)\\\\ 0 & (m\\neq n)\\end{cases}$$" + tail),
    ]

    @Test func printGlyphMetrics() throws {
        var lines: [String] = []
        let style = NativeMathStyle(color: .white, fontSize: 20, fontWeight: 700, scale: 3)
        for latex in ["\(Self.integral)=\\pi\\ (m=n)", "\(Self.integral)", "x=1", "\\frac{1}{2}"] {
            if let glyph = NativeMathRenderer.shared.glyph(latex: latex, display: false, style: style, highlighted: false) {
                lines.append("size=\(glyph.size) baseline=\(glyph.baseline) latex=\(latex)")
                let label = MTMathUILabel()
                label.font = MTFontManager.manager.latinModernFont(withSize: style.mathSize)
                label.labelMode = .text
                label.latex = MathSourceNormalizer.prepare(latex)
                let fitted = label.sizeThatFits(.zero)
                for width in [fitted.width, 100_000] {
                    label.frame = CGRect(origin: .zero, size: CGSize(width: width, height: fitted.height))
                    label.layoutSubviews()
                    if let list = label.displayList {
                        lines.append("  frameWidth=\(width) fitted=\(fitted) list w=\(list.width) a=\(list.ascent) d=\(list.descent) subs=\(list.subDisplays.count)")
                    }
                }
            }
        }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DEVBOX_FILES"] ?? NSTemporaryDirectory())
        try lines.joined(separator: "\n").write(to: directory.appendingPathComponent("metrics.txt"), atomically: true, encoding: .utf8)
    }

    @Test func renderCandidates() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DEVBOX_FILES"] ?? NSTemporaryDirectory())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (name, text) in Self.candidates {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 386, height: 700)
            let host = UIHostingController(rootView:
                TimelineQuestionText(text: text, size: 20)
                    .frame(width: 386, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color(white: 0.13))
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            try #require(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
}
