import Foundation

/// アプリに同梱する単元一覧(待ち時間の体験 §4)。単元づくりの待ちで、学習者の言葉から科目・単元名を拾う辞書と、
/// 小単元の候補の並びに使う。中身は学習指導要領(中学 2021・高校 2022)の単元構成を元にした一覧で、
/// 範囲と出典は今後決める(要件 §8)。ここに無い単元は、全体像の結果にだけ現れる。
nonisolated enum UnitCatalog {
    struct Unit: Sendable, Hashable {
        let subject: String
        let grades: [String]
        let name: String
        /// 学習者が書きそうな別の書き方(「二次関数」「2次関数」など。正規化して比べる)。
        let aliases: [String]
        let subunits: [String]
    }

    /// 小単元の候補 1 つ。
    struct Candidate: Sendable, Hashable, Identifiable {
        let unit: Unit
        let title: String
        var id: String { unit.subject + "/" + unit.name + "/" + title }
    }

    /// 科目の書き方(正規化前)→ 一覧の科目名。「数学」は数学の全科目にかかる。
    static let subjectAliases: [(String, String)] = [
        ("数学Ⅰ", "数学Ⅰ"), ("数学I", "数学Ⅰ"), ("数学1", "数学Ⅰ"), ("数Ⅰ", "数学Ⅰ"), ("数I", "数学Ⅰ"), ("数1", "数学Ⅰ"),
        ("数学Ⅱ", "数学Ⅱ"), ("数学II", "数学Ⅱ"), ("数学2", "数学Ⅱ"), ("数Ⅱ", "数学Ⅱ"), ("数II", "数学Ⅱ"), ("数2", "数学Ⅱ"),
        ("数学Ⅲ", "数学Ⅲ"), ("数学III", "数学Ⅲ"), ("数学3", "数学Ⅲ"), ("数Ⅲ", "数学Ⅲ"), ("数III", "数学Ⅲ"), ("数3", "数学Ⅲ"),
        ("数学A", "数学A"), ("数A", "数学A"), ("数学B", "数学B"), ("数B", "数学B"), ("数学C", "数学C"), ("数C", "数学C"),
        ("数学", "数学"), ("算数", "数学"), ("数検", "数学"),
        ("物理基礎", "物理基礎"), ("化学基礎", "化学基礎"), ("生物基礎", "生物基礎"),
        ("物理", "物理基礎"), ("化学", "化学基礎"), ("生物", "生物基礎"),
        ("理科", "理科"), ("英語", "英語"), ("英文法", "英語"),
    ]

    /// 科目の家族(「数学」は数学Ⅰ〜C と中学の数学を含む)。
    static func subjectMatches(unitSubject: String, chip: String) -> Bool {
        if unitSubject == chip { return true }
        switch chip {
        case "数学": return unitSubject.hasPrefix("数学")
        case "理科": return unitSubject == "理科" || unitSubject.hasSuffix("基礎")
        default: return false
        }
    }

    static let units: [Unit] = [
        // 中学 数学
        Unit(subject: "数学", grades: ["中1"], name: "正の数と負の数", aliases: ["正負の数", "正の数負の数", "負の数"], subunits: ["正の数・負の数", "加法と減法", "乗法と除法", "四則の混じった計算", "素因数分解"]),
        Unit(subject: "数学", grades: ["中1"], name: "文字と式", aliases: ["文字式"], subunits: ["文字式の表し方", "式の値", "1次式の計算", "関係を表す式"]),
        Unit(subject: "数学", grades: ["中1"], name: "1次方程式", aliases: ["方程式", "一次方程式"], subunits: ["1次方程式の解き方", "比例式", "方程式の利用"]),
        Unit(subject: "数学", grades: ["中1"], name: "比例と反比例", aliases: ["比例", "反比例"], subunits: ["比例", "反比例", "座標", "比例と反比例の利用"]),
        Unit(subject: "数学", grades: ["中1"], name: "平面図形", aliases: ["作図", "おうぎ形"], subunits: ["図形の移動", "基本の作図", "円とおうぎ形"]),
        Unit(subject: "数学", grades: ["中1"], name: "空間図形", aliases: ["立体", "体積", "表面積"], subunits: ["いろいろな立体", "立体の見方", "表面積と体積"]),
        Unit(subject: "数学", grades: ["中1"], name: "データの活用", aliases: ["ヒストグラム", "度数分布"], subunits: ["度数分布表とヒストグラム", "相対度数", "代表値"]),
        Unit(subject: "数学", grades: ["中2"], name: "式の計算", aliases: ["多項式", "等式の変形"], subunits: ["多項式の計算", "単項式の乗法と除法", "文字式の利用", "等式の変形"]),
        Unit(subject: "数学", grades: ["中2"], name: "連立方程式", aliases: ["連立"], subunits: ["加減法", "代入法", "いろいろな連立方程式", "連立方程式の利用"]),
        Unit(subject: "数学", grades: ["中2"], name: "1次関数", aliases: ["一次関数"], subunits: ["1次関数とグラフ", "変化の割合", "1次関数の式を求める", "方程式とグラフ", "1次関数の利用"]),
        Unit(subject: "数学", grades: ["中2"], name: "図形の性質と証明", aliases: ["証明", "合同", "平行線と角", "多角形の角"], subunits: ["平行線と角", "多角形の角", "三角形の合同条件", "証明のしかた", "二等辺三角形", "平行四辺形"]),
        Unit(subject: "数学", grades: ["中2"], name: "確率", aliases: [], subunits: ["確率の求め方", "いろいろな確率"]),
        Unit(subject: "数学", grades: ["中2"], name: "データの分布", aliases: ["箱ひげ図", "四分位範囲"], subunits: ["四分位範囲", "箱ひげ図"]),
        Unit(subject: "数学", grades: ["中3"], name: "式の展開と因数分解", aliases: ["展開", "因数分解", "乗法公式"], subunits: ["多項式の乗法", "乗法公式", "因数分解", "式の計算の利用"]),
        Unit(subject: "数学", grades: ["中3"], name: "平方根", aliases: ["ルート", "根号", "有理化"], subunits: ["平方根の意味", "根号をふくむ式の計算", "分母の有理化"]),
        Unit(subject: "数学", grades: ["中3"], name: "2次方程式", aliases: ["二次方程式", "解の公式"], subunits: ["因数分解による解き方", "平方根による解き方", "解の公式", "2次方程式の利用"]),
        Unit(subject: "数学", grades: ["中3"], name: "関数y=ax²", aliases: ["2乗に比例する関数", "二乗に比例", "y=ax2", "y=ax^2", "放物線"], subunits: ["関数y=ax²とグラフ", "y=ax²の変化の割合", "いろいろな関数"]),
        Unit(subject: "数学", grades: ["中3"], name: "相似な図形", aliases: ["相似", "中点連結定理", "平行線と線分の比"], subunits: ["三角形の相似条件", "平行線と線分の比", "中点連結定理", "面積比と体積比"]),
        Unit(subject: "数学", grades: ["中3"], name: "円周角", aliases: ["円周角の定理", "円"], subunits: ["円周角の定理", "円周角の定理の逆", "円の性質の利用"]),
        Unit(subject: "数学", grades: ["中3"], name: "三平方の定理", aliases: ["ピタゴラス"], subunits: ["三平方の定理", "三平方の定理の逆", "三平方の定理の利用"]),
        Unit(subject: "数学", grades: ["中3"], name: "標本調査", aliases: [], subunits: ["全数調査と標本調査", "標本調査の利用"]),
        // 数学Ⅰ
        Unit(subject: "数学Ⅰ", grades: ["高1"], name: "数と式", aliases: ["整式", "展開と因数分解", "実数", "1次不等式", "一次不等式"], subunits: ["整式の計算", "展開と因数分解", "実数と根号", "1次不等式"]),
        Unit(subject: "数学Ⅰ", grades: ["高1"], name: "集合と命題", aliases: ["集合", "命題", "必要条件", "十分条件", "対偶"], subunits: ["集合", "命題と条件", "必要条件と十分条件", "逆・裏・対偶", "背理法"]),
        Unit(subject: "数学Ⅰ", grades: ["高1"], name: "2次関数", aliases: ["二次関数", "平方完成", "判別式", "2次不等式", "二次不等式"], subunits: ["2次関数のグラフ", "平方完成", "2次関数の最大・最小", "2次方程式と判別式", "グラフとx軸の位置関係", "2次不等式"]),
        Unit(subject: "数学Ⅰ", grades: ["高1"], name: "図形と計量", aliases: ["三角比", "正弦定理", "余弦定理"], subunits: ["三角比", "三角比の相互関係", "正弦定理", "余弦定理", "三角形の面積", "空間図形への応用"]),
        Unit(subject: "数学Ⅰ", grades: ["高1"], name: "データの分析", aliases: ["分散", "標準偏差", "相関係数"], subunits: ["分散と標準偏差", "散布図と相関係数", "仮説検定の考え方"]),
        // 数学A
        Unit(subject: "数学A", grades: ["高1"], name: "場合の数と確率", aliases: ["場合の数", "順列", "組合せ", "条件付き確率", "反復試行"], subunits: ["場合の数", "順列", "組合せ", "確率の基本", "独立な試行の確率", "反復試行の確率", "条件付き確率", "期待値"]),
        Unit(subject: "数学A", grades: ["高1"], name: "図形の性質", aliases: ["チェバ", "メネラウス", "方べき", "五心"], subunits: ["三角形の辺の比", "三角形の五心", "チェバの定理とメネラウスの定理", "円に内接する四角形", "方べきの定理"]),
        Unit(subject: "数学A", grades: ["高1"], name: "数学と人間の活動", aliases: ["整数の性質", "互除法", "不定方程式", "n進法"], subunits: ["約数と倍数", "ユークリッドの互除法", "1次不定方程式", "n進法"]),
        // 数学Ⅱ
        Unit(subject: "数学Ⅱ", grades: ["高2"], name: "式と証明", aliases: ["二項定理", "恒等式", "等式の証明", "不等式の証明"], subunits: ["二項定理", "整式の割り算", "分数式", "恒等式", "等式の証明", "不等式の証明"]),
        Unit(subject: "数学Ⅱ", grades: ["高2"], name: "複素数と方程式", aliases: ["複素数", "解と係数の関係", "因数定理", "剰余の定理", "高次方程式"], subunits: ["複素数", "解と係数の関係", "剰余の定理と因数定理", "高次方程式"]),
        Unit(subject: "数学Ⅱ", grades: ["高2"], name: "図形と方程式", aliases: ["円の方程式", "直線の方程式", "軌跡", "領域"], subunits: ["点と座標", "直線の方程式", "円の方程式", "円と直線", "軌跡", "不等式の表す領域"]),
        Unit(subject: "数学Ⅱ", grades: ["高2"], name: "三角関数", aliases: ["加法定理", "弧度法", "三角関数の合成"], subunits: ["一般角と弧度法", "三角関数のグラフ", "加法定理", "2倍角の公式", "三角関数の合成"]),
        Unit(subject: "数学Ⅱ", grades: ["高2"], name: "指数関数と対数関数", aliases: ["指数関数", "対数関数", "対数", "log", "常用対数"], subunits: ["指数の拡張", "指数関数", "対数とその性質", "対数関数", "常用対数"]),
        Unit(subject: "数学Ⅱ", grades: ["高2"], name: "微分と積分", aliases: ["微分", "積分", "微分法", "積分法", "極値", "接線"], subunits: ["微分係数と導関数", "接線の方程式", "関数の増減と極値", "不定積分", "定積分", "面積"]),
        // 数学B・C・Ⅲ
        Unit(subject: "数学B", grades: ["高2"], name: "数列", aliases: ["等差数列", "等比数列", "漸化式", "シグマ", "Σ", "数学的帰納法"], subunits: ["等差数列", "等比数列", "Σの計算", "階差数列", "漸化式", "数学的帰納法"]),
        Unit(subject: "数学B", grades: ["高2"], name: "統計的な推測", aliases: ["確率分布", "二項分布", "正規分布", "推定", "仮説検定"], subunits: ["確率変数と確率分布", "二項分布", "正規分布", "母平均の推定", "仮説検定"]),
        Unit(subject: "数学C", grades: ["高2", "高3"], name: "ベクトル", aliases: ["内積", "位置ベクトル", "空間ベクトル"], subunits: ["ベクトルの演算", "成分表示", "内積", "位置ベクトル", "空間のベクトル"]),
        Unit(subject: "数学C", grades: ["高3"], name: "平面上の曲線と複素数平面", aliases: ["複素数平面", "2次曲線", "楕円", "双曲線", "極座標", "媒介変数"], subunits: ["放物線・楕円・双曲線", "媒介変数表示と極座標", "複素数平面", "ド・モアブルの定理"]),
        Unit(subject: "数学Ⅲ", grades: ["高3"], name: "極限", aliases: ["数列の極限", "関数の極限", "無限級数"], subunits: ["数列の極限", "無限級数", "関数の極限", "関数の連続性"]),
        Unit(subject: "数学Ⅲ", grades: ["高3"], name: "微分法", aliases: ["合成関数の微分", "導関数"], subunits: ["導関数の計算", "合成関数の微分", "接線と法線", "関数のグラフ"]),
        Unit(subject: "数学Ⅲ", grades: ["高3"], name: "積分法", aliases: ["置換積分", "部分積分", "体積"], subunits: ["置換積分法", "部分積分法", "定積分と面積", "体積", "曲線の長さ"]),
        // 中学 理科
        Unit(subject: "理科", grades: ["中1"], name: "身のまわりの物質", aliases: ["水溶液", "状態変化", "気体の性質"], subunits: ["物質の性質", "気体の性質", "水溶液", "状態変化"]),
        Unit(subject: "理科", grades: ["中1"], name: "光・音・力", aliases: ["光の屈折", "凸レンズ", "力のはたらき", "フックの法則"], subunits: ["光の反射と屈折", "凸レンズ", "音の性質", "力のはたらき"]),
        Unit(subject: "理科", grades: ["中2"], name: "化学変化と原子・分子", aliases: ["化学変化", "化学反応式", "原子", "分子", "酸化", "還元"], subunits: ["原子と分子", "化学反応式", "酸化と還元", "化学変化と質量"]),
        Unit(subject: "理科", grades: ["中2"], name: "電流とその利用", aliases: ["電流", "電圧", "オームの法則", "電磁誘導"], subunits: ["回路と電流・電圧", "オームの法則", "電力と熱", "電流と磁界"]),
        Unit(subject: "理科", grades: ["中3"], name: "化学変化とイオン", aliases: ["イオン", "電池", "中和"], subunits: ["水溶液とイオン", "電池", "酸・アルカリと中和"]),
        Unit(subject: "理科", grades: ["中3"], name: "運動とエネルギー", aliases: ["運動", "仕事", "エネルギー", "浮力"], subunits: ["力の合成と分解", "物体の運動", "仕事とエネルギー"]),
        Unit(subject: "物理基礎", grades: ["高1", "高2"], name: "運動とエネルギー", aliases: ["等加速度", "運動方程式", "力学", "力学的エネルギー"], subunits: ["等加速度直線運動", "落体の運動", "運動の法則", "仕事と力学的エネルギー"]),
        Unit(subject: "化学基礎", grades: ["高1", "高2"], name: "物質の変化", aliases: ["物質量", "モル", "酸と塩基", "酸化還元"], subunits: ["物質量", "化学反応式と量的関係", "酸と塩基", "酸化還元反応"]),
        // 英語
        Unit(subject: "英語", grades: ["中1", "中2"], name: "動詞と時制", aliases: ["be動詞", "一般動詞", "過去形", "進行形", "未来形"], subunits: ["be動詞と一般動詞", "過去形", "進行形", "未来の表現"]),
        Unit(subject: "英語", grades: ["中2", "中3"], name: "不定詞と動名詞", aliases: ["不定詞", "動名詞"], subunits: ["不定詞の3用法", "動名詞", "不定詞と動名詞の使い分け"]),
        Unit(subject: "英語", grades: ["中2", "中3"], name: "比較と受け身", aliases: ["比較", "比較級", "最上級", "受け身", "受動態"], subunits: ["比較級と最上級", "as 〜 as", "受け身"]),
        Unit(subject: "英語", grades: ["中3", "高1"], name: "現在完了と関係代名詞", aliases: ["現在完了", "関係代名詞", "分詞"], subunits: ["現在完了", "関係代名詞", "分詞の後置修飾"]),
    ]

    static var candidates: [Candidate] {
        units.flatMap { unit in unit.subunits.map { Candidate(unit: unit, title: $0) } }
    }

    /// 比べるための正規化: 全角→半角・上付き数字→数字(NFKC)、漢数字の「一次・二次・三次」を数字に、空白・中黒・^ を除く。
    static func normalize(_ text: String) -> String {
        var value = text.precomposedStringWithCompatibilityMapping.lowercased()
        for (from, to) in [("一次", "1次"), ("二次", "2次"), ("三次", "3次"), ("二乗", "2乗")] {
            value = value.replacingOccurrences(of: from, with: to)
        }
        return value.filter { !$0.isWhitespace && $0 != "・" && $0 != "、" && $0 != "^" }
    }
}
