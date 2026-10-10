import SwiftUI

/// 数値の表示フォーマット (整数なら小数を落とし、それ以外は小数2桁まで)。
enum ImmersionFormat {
    static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded(), abs(rounded) < 1e12 {
            return String(Int(rounded))
        }
        return String(format: "%g", rounded)
    }
}

/// スカラー量がパラメータで変化する題材の数理モデル。
/// 新しい題材はこの enum のパラメータを埋めるだけで作れる
/// (題材固有の分岐を canvas 側に書かないのが趣旨)。
enum SimulationModel {
    /// 一次変化: value = start + rate × x (減少は負の rate)。
    case linear(start: Double, rate: Double)
    /// 区間変化: plateauUntil までは plateauLevel のまま、その後 rate で変化。
    case piecewise(plateauLevel: Double, plateauUntil: Double, thenRate: Double)
    /// 反比例: value = referenceLength ÷ x。
    case inverse(referenceLength: Double)

    func value(at x: Double) -> Double {
        switch self {
        case let .linear(start, rate):
            return start + rate * x
        case let .piecewise(plateauLevel, plateauUntil, thenRate):
            return x <= plateauUntil ? plateauLevel : plateauLevel + thenRate * (x - plateauUntil)
        case let .inverse(referenceLength):
            return referenceLength / max(x, 0.0001)
        }
    }
}

/// 汎用シミュレーション題材 (S1-S5) の全コンテンツ。
/// 文言・数値・モデルだけを持ち、描画は SimulationCanvas / SimulationFlowView が担う。
struct SimulationScenario: Identifiable {
    let id: String
    let emoji: String
    let title: String
    let sourceLabel: String
    let hook: String
    let hookSub: String

    let quantityLabel: String   // 例: 水位
    let unit: String            // 例: cm
    let paramLabel: String      // 例: 時間
    let paramUnit: String       // 例: 分
    let paramRange: ClosedRange<Double>
    let paramStep: Double
    let paramInitial: Double
    let predictAt: Double       // 予想対象のパラメータ値
    let compareLabel: String    // 例: 10 分後と比べる
    let consequenceTitle: String

    let gaugeMax: Double
    let gaugeTicks: [Double]
    let tint: Color
    let model: SimulationModel
    let startMarker: StartMarker?
    /// 典型的な誤予想 (デモ用ディープリンクで差の画面を再現するときに使う)。
    let demoPrediction: Double

    let hint: String
    /// 差分テキスト ({g} がギャップの絶対値に置換される)。
    let diffHigher: String
    let diffLower: String
    let diffExact: String

    let insightSerif: String
    let insightNote: String
    let formulaText: String

    let retryQuestion: String
    let retryChoices: [String]
    let retryCorrectIndex: Int
    let retryNudge: String
    let retrySuccessSerif: String

    let transferQuestion: String
    let transferKind: TransferKind
    let transferAnswer: String       // numeric: 期待する数値 / freeForm: 模範解答
    let transferPlaceholder: String
    let transferCorrectSerif: String
    let transferWrongSerif: String

    let boundarySerif: String

    enum TransferKind {
        case numeric
        case freeForm
    }

    struct StartMarker {
        let value: Double
        let label: String
    }

    var predictedActual: Double { model.value(at: predictAt) }

    func value(at x: Double) -> Double { model.value(at: x) }

    func format(_ value: Double) -> String { ImmersionFormat.number(value) }

    /// gap = 実際 − 予想。符号で 3 方向の差分テキストを切り替える。
    func diffText(gap: Double) -> String {
        let g = format(abs(gap))
        if gap > 0.001 {
            return diffHigher.replacingOccurrences(of: "{g}", with: g)
        }
        if gap < -0.001 {
            return diffLower.replacingOccurrences(of: "{g}", with: g)
        }
        return diffExact
    }
}

/// 固有値 playground (S6) のコンテンツ。canvas は EigenCanvas 固有。
struct EigenContent {
    let title = "固有値 playground"
    let emoji = "📐"
    let sourceLabel = "昨日の線形代数"
    let hook = "ほとんどの向きは変換で回転してしまう。\n向きが変わらない向きはある?"
    let hookSub = "行列 A = [[2, 0], [0, 1]] でベクトルを変換します。"
    let exploreHint = "ベクトルをドラッグして、向きを探って。"
    let predictButton = "この向きは変わらない"
    let consequenceInvariant = "その向きは変わらない — 固有ベクトルです。"
    let consequenceRotated = "その向きは回転してしまう。"
    let consequenceReveal = "不変なのは x 軸 (2 倍) と y 軸 (1 倍)。"
    let insightSerif = "変換の軸 = 固有ベクトル。\n軸ごとの伸び率 = 固有値。"
    let insightNote = "x 軸は 2 倍、y 軸は 1 倍に伸びる。向きはどちらも変わらない。"
    let retryIntro = "今度はせん断。A = [[1, 1], [0, 1]]。"
    let retryReveal = "今度は x 軸だけ。y 方向は x に引っ張られて回転する。"
    let transferQuestion = "A = [[3, 0], [0, 3]] なら、\n向きが変わらない向きは?"
    let transferChoices = ["全部の向き", "x 軸だけ", "ない"]
    let transferCorrectIndex = 0
    let transferCorrectSerif = "その通り。3 I は全方向を 3 倍にするだけ。"
    let transferWrongSerif = "対角成分が同じなら、どの向きも伸びるだけ。回転しません。"
    let boundarySerif = "向きが変わらない向きを、\n見つけられるようになった。"
}

/// 英語の文変形 (S7) のコンテンツ。選択肢ベースのシンプルな canvas。
struct TextTransformContent {
    let title = "英語の文変形"
    let emoji = "✍️"
    let sourceLabel = "昨日の英作文から"
    let baseSentence = "I go to school by bus."
    let hook = "\"yesterday\" を足すと、\nこの文はどう変わると思う?"
    let hookSub = "まず予想を置くところから。シェルはタンクのときと同じです。"
    let predictChoices = [
        "I went to school by bus yesterday.",
        "I goed to school by bus yesterday.",
        "I go to school by bus yesterday."
    ]
    let correctIndex = 0
    let diffText = "時を表す語が来ると、動詞が過去に変わる。go → went。"
    let insightSerif = "時を表す語が来ると、\n動詞が過去に変わる。"
    let insightNote = "yesterday / last week が来たら、動詞を過去形に。"
    let retryQuestion = "\"She plays tennis.\" に \"last week\" を足すと?"
    let retryChoices = ["played", "plaied", "plays"]
    let retryCorrectIndex = 0
    let retryNudge = "plays の過去形。y はそのまま残る。"
    let retrySuccessSerif = "played。\n読めましたね。"
    let transferQuestion = "He (watch) TV yesterday.\nをノートで完成させてみて。"
    let transferChoices = ["watching", "watched", "watches"]
    let transferCorrectIndex = 1
    let transferCorrectSerif = "watched。yesterday に合わせて過去形。"
    let transferWrongSerif = "yesterday があるから、動詞は過去形のはず。"
    let boundarySerif = "時を表す語で、\n文の変化が読めるようになった。"
}

/// Immersion Lab で扱う題材。S1-S5 は同じエンジン、S6/S7 は別 kind。
enum ImmersionScenario: Identifiable {
    case simulation(SimulationScenario)
    case eigen(EigenContent)
    case textTransform(TextTransformContent)

    var id: String {
        switch self {
        case .simulation(let scenario): return scenario.id
        case .eigen: return "eigen"
        case .textTransform: return "text-transform"
        }
    }

    var emoji: String {
        switch self {
        case .simulation(let scenario): return scenario.emoji
        case .eigen(let content): return content.emoji
        case .textTransform(let content): return content.emoji
        }
    }

    var title: String {
        switch self {
        case .simulation(let scenario): return scenario.title
        case .eigen(let content): return content.title
        case .textTransform(let content): return content.title
        }
    }

    var sourceLabel: String {
        switch self {
        case .simulation(let scenario): return scenario.sourceLabel
        case .eigen(let content): return content.sourceLabel
        case .textTransform(let content): return content.sourceLabel
        }
    }

    var hook: String {
        switch self {
        case .simulation(let scenario): return scenario.hook
        case .eigen(let content): return content.hook
        case .textTransform(let content): return content.hook
        }
    }
}
