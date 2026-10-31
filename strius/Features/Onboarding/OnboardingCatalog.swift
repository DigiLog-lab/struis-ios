import Foundation

/// オンボーディングで選ぶものの一覧(#40)。教科は当面数学だけ。
nonisolated enum OnboardingCatalog {
    static let grades = ["中1", "中2", "中3", "高1", "高2", "高3"]

    /// 学年ごとの単元(A:「どの単元ですか」)。
    static func units(grade: String) -> [String] {
        switch grade {
        case "中1": ["正負の数", "文字と式", "一次方程式", "比例と反比例", "平面図形", "空間図形", "データの活用"]
        case "中2": ["式の計算", "連立方程式", "一次関数", "図形の調べ方", "図形の合同", "確率", "データの比較"]
        case "中3": ["式の展開と因数分解", "平方根", "二次方程式", "関数 y = ax²", "相似な図形", "円", "三平方の定理", "標本調査"]
        case "高1": ["数と式", "二次関数", "二次不等式", "図形と計量(三角比)", "データの分析", "場合の数と確率", "整数の性質", "図形の性質"]
        case "高2": ["式と証明", "複素数と方程式", "図形と方程式", "三角関数", "指数関数・対数関数", "微分法", "積分法", "数列", "統計的な推測"]
        case "高3": ["極限", "微分法(数学III)", "積分法(数学III)", "ベクトル", "複素数平面", "平面上の曲線"]
        default: []
        }
    }

    /// やり直しで選びやすい単元(B:「やり直したい単元はどれですか」)。
    static func coreUnits(grade: String) -> [String] {
        switch grade {
        case "中1": ["正負の数", "文字と式", "一次方程式", "比例と反比例"]
        case "中2": ["連立方程式", "一次関数", "図形の合同", "確率"]
        case "中3": ["平方根", "二次方程式", "関数 y = ax²", "相似な図形", "三平方の定理"]
        case "高1": ["数と式", "二次関数", "図形と計量(三角比)", "場合の数と確率"]
        case "高2": ["三角関数", "指数関数・対数関数", "微分法", "積分法", "数列"]
        case "高3": ["極限", "微分法(数学III)", "積分法(数学III)", "ベクトル"]
        default: []
        }
    }

    /// B: 今の学年と、その前の 2 学年(前の学年の単元も選べる)。
    static func weakGroups(grade: String) -> [(grade: String, units: [String])] {
        guard let index = grades.firstIndex(of: grade) else { return [] }
        return (max(0, index - 2)...index).reversed().map { (grades[$0], coreUnits(grade: grades[$0])) }
    }

    /// A:「次のテストまでどれくらいですか」。
    static let untilTest = ["1週間以内", "2週間くらい", "1か月くらい", "まだ先・決まっていない"]

    /// U:「何を勉強しますか」の例。
    static let universityTopics = ["線形代数", "微分積分", "力学", "統計学", "資格試験"]

    /// U:「授業の資料はありますか」の例。
    static let universityMaterials = ["シラバス", "講義のスライド・プリント", "教科書の演習問題のページ", "過去の小テスト・レポート課題"]

    /// 通知の時刻。
    static let reminderHours = [17, 20, 21]
}
