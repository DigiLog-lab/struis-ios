import Foundation
import SwiftMath

/// 端末の点検(`DrillValidator.renderProbe`)に渡す、画面の数式描画で読めるかの確認。
/// アプリが式を描く時と同じ前処理(`MathSourceNormalizer.prepare`)をしてから、SwiftMath に解析させる。
nonisolated enum DrillRenderProbe {
    /// 読めなければ理由を返す。
    static let swiftMath: @Sendable (String) -> String? = { (latex: String) -> String? in
        let prepared: String = MathSourceNormalizer.prepare(latex)
        var error: NSError?
        let list: MTMathList? = MTMathListBuilder.build(fromString: prepared, error: &error)
        if let error: NSError = error { return error.localizedDescription }
        return list == nil ? "解析できない" : nil
    }

    /// 端末で使う点検器。
    static var validator: DrillValidator { DrillValidator(renderProbe: swiftMath) }
}
