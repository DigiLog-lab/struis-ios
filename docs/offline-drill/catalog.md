# オフライン反復モード 計算操作の一覧

この文書は `striusTests/Fixtures/drill-templates/catalog.json` から単体テスト(`DrillCatalogTests`)が作ります。手で直さず、`catalog.json` と型を直してから作り直してください
(`cd scripts/offline-drill && DRILL_WRITE_CATALOG=1 swift test --filter DrillCatalogTests`)。

- 1 行は、知識グラフの `procedure` の点と同じくらいの細かさ(1 つの手順で解ける計算操作)です。概念の理解・証明・暗記だけの事項は対象外です。
- 「例題」は、型がある行では型から実際に作った 1 問です。
- 「数値点検」は、型の `checks` で答えの公式を数値で確かめているかです。「なし」の型は、型の `no_numeric_check` に理由があります。
- 「表せない理由」は、書式(`docs/offline-drill/format.md`)で表せない操作に付けます。

## 集計

| 教科 | 行 | 型あり | 数値点検あり | 数値点検なし | 表せない |
| --- | --- | --- | --- | --- | --- |
| 数学 | 263 | 240 | 238 | 2 | 23 |
| 物理 | 126 | 118 | 116 | 2 | 8 |
| 化学 | 70 | 63 | 60 | 3 | 7 |
| 合計 | 459 | 421 | 414 | 7 | 38 |

## 数学 中学1年

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 数学 | 正負の数 | 正負の数の加法・減法 | 次の計算をしなさい。 $(-11) + (-9) - (-7)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.signed_add_sub.json) | あり |  |
| 数学 | 正負の数 | 正負の数の乗法・除法 | 次の計算をしなさい。 $(-8) \times 42 \div (-7)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.signed_mul_div.json) | あり |  |
| 数学 | 正負の数 | 累乗の計算 | 次の計算をしなさい。 $(-2)^{2} \times 2$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.signed_power.json) | あり |  |
| 数学 | 正負の数 | 四則の混じった計算 | 次の計算をしなさい。 $-8 + (-5) \times (-4)^{2} - 4$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.signed_mixed.json) | あり |  |
| 数学 | 正負の数 | 分数の加法・減法 | 次の計算をしなさい。 $\frac{1}{2} + \frac{4}{3}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.fraction_add_sub.json) | あり |  |
| 数学 | 正負の数 | 分数の乗法・除法 | 次の計算をしなさい。 $\frac{1}{2} \times (-\frac{2}{3}) \div \frac{8}{3}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.fraction_mul_div.json) | あり |  |
| 数学 | 正負の数 | 小数をふくむ計算 | 次の計算をしなさい。 $(-8.8) - 1.6 \times (-6)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.decimal_arithmetic.json) | あり |  |
| 数学 | 正負の数 | 素因数分解 | $6$ を素因数分解しなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.prime_factorization.json) | あり |  |
| 数学 | 文字と式 | 同類項をまとめる | 次の式を計算しなさい。 $-8x - 7 - 6x + 9$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.like_terms.json) | あり |  |
| 数学 | 文字と式 | 分配法則でかっこをはずす | 次の式を計算しなさい。 $-9(-7x - 6)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.distribute.json) | あり |  |
| 数学 | 文字と式 | かっこのある一次式の加減 | 次の式を計算しなさい。 $2(-5x - 6) - 6(-2x - 4)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.linear_expr_combine.json) | あり |  |
| 数学 | 文字と式 | 式の値(代入) | $x = -4$ のとき、次の式の値を求めなさい。 $-6x^{2} - 7x$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.expression_value.json) | あり |  |
| 数学 | 一次方程式 | 一次方程式(ax + b = c) | 次の方程式を解きなさい。 $-9x - 7 = 56$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.linear_eq_basic.json) | あり |  |
| 数学 | 一次方程式 | 一次方程式(両辺に x がある) | 次の方程式を解きなさい。 $-8x + 12 = -7x + 17$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.linear_eq_both_sides.json) | あり |  |
| 数学 | 一次方程式 | かっこのある一次方程式 | 次の方程式を解きなさい。 $2(x - 4) = 9x + 6$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.linear_eq_parentheses.json) | あり |  |
| 数学 | 一次方程式 | 分数をふくむ一次方程式 | 次の方程式を解きなさい。 $\frac{x - 4}{4} - \frac{x - 6}{2} = 4$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.linear_eq_fraction.json) | あり |  |
| 数学 | 一次方程式 | 比例式を解く | 次の比例式で、$x$ の値を求めなさい。 $x : 9 = 2 : 3$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.proportion_eq.json) | あり |  |
| 数学 | 比例と反比例 | 比例の式を求める | $y$ は $x$ に比例し、$x = -8$ のとき $y = -4$ である。$y$ を $x$ の式で表しなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.proportional_formula.json) | あり |  |
| 数学 | 比例と反比例 | 反比例の式を求める | $y$ は $x$ に反比例し、$x = 8$ のとき $y = -2$ である。$x = -4$ のときの $y$ の値を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.inverse_proportional_formula.json) | あり |  |
| 数学 | 平面図形 | おうぎ形の弧の長さと面積 | 半径 $2\,\mathrm{cm}$、中心角 $45^{\circ}$ のおうぎ形の弧の長さと面積を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.sector.json) | あり |  |
| 数学 | 空間図形 | 円柱・円錐の体積 | 底面の半径が $2\,\mathrm{cm}$、高さが $3\,\mathrm{cm}$ の円柱の体積を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.cylinder_cone_volume.json) | あり |  |
| 数学 | 空間図形 | 球の表面積と体積 | 半径 $2\,\mathrm{cm}$ の球の表面積と体積を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.sphere.json) | あり |  |
| 数学 | データの活用 | 平均値・中央値・範囲 | 次のデータの平均値、中央値、範囲を求めなさい。 $6,\ 1,\ 4,\ 12,\ 12$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs1.mean_median_range.json) | あり |  |
| 数学 | 平面図形 | 基本の作図(垂直二等分線・角の二等分線) | 線分 AB の垂直二等分線を作図しなさい。 | なし | — | 答えが図で、数字を入れ替える計算ではない |
| 数学 | 空間図形 | 投影図・展開図を読む | 投影図で表された立体の名前を答えなさい。 | なし | — | 問題文に図が要る。書式は文と式だけを作る |

## 数学 中学2年

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 数学 | 式の計算 | 多項式の加法・減法 | 次の式を計算しなさい。 $(-8x - 7y) + (-6x + 9y)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.polynomial_add_sub.json) | あり |  |
| 数学 | 式の計算 | 数と多項式の乗法をふくむ計算 | 次の式を計算しなさい。 $2(-4x - 3y) - 5(-2x - 3y)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.polynomial_scalar_combine.json) | あり |  |
| 数学 | 式の計算 | 単項式の乗法 | 次の計算をしなさい。 $-9xy^{2} \times (-7xy)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.monomial_mul.json) | あり |  |
| 数学 | 式の計算 | 単項式の除法 | 次の計算をしなさい。 $-49x^{4}y^{3} \div (-7x^{3}y)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.monomial_div.json) | あり |  |
| 数学 | 式の計算 | 式の値(2 つの文字) | $x = -3$、$y = 5$ のとき、次の式の値を求めなさい。 $2x^{2}y - 5xy^{2}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.expression_value_two.json) | あり |  |
| 数学 | 式の計算 | 等式の変形(ある文字について解く) | 次の等式を $y$ について解きなさい。 $-8x + 3y = -12$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.solve_for_letter.json) | あり |  |
| 数学 | 連立方程式 | 連立方程式(加減法) | 次の連立方程式を解きなさい。 $\begin{cases} x - 5y = 13 \\ 2x + 6y = -22 \end{cases}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.simultaneous_elimination.json) | あり |  |
| 数学 | 連立方程式 | 連立方程式(代入法) | 次の連立方程式を解きなさい。 $\begin{cases} y = -5x - 7 \\ 2x + 6y = 14 \end{cases}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.simultaneous_substitution.json) | あり |  |
| 数学 | 一次関数 | 傾きと 1 点から一次関数の式を求める | 傾きが $\frac{2}{3}$ で、点 $(-6,\ -5)$ を通る直線の式を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.linear_function_slope_point.json) | あり |  |
| 数学 | 一次関数 | 2 点を通る直線の式を求める | 2 点 $(-6,\ -7)$、$(-4,\ 9)$ を通る直線の式を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.linear_function_two_points.json) | あり |  |
| 数学 | 一次関数 | 一次関数の変化の割合と y の増加量 | 一次関数 $y = -\frac{7}{2}x - 7$ で、$x$ の増加量が $4$ のときの $y$ の増加量を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.linear_function_rate.json) | あり |  |
| 数学 | 一次関数 | 2 直線の交点の座標 | 2 直線 $y = -4x - 7$ と $y = -3x - 3$ の交点の座標を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.lines_intersection.json) | あり |  |
| 数学 | 図形の性質 | 多角形の内角の和 | $6$ 角形の内角の和を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.polygon_angle_sum.json) | あり |  |
| 数学 | 図形の性質 | 正多角形の 1 つの内角・外角 | 正 $5$ 角形の 1 つの内角の大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.regular_polygon_angle.json) | あり |  |
| 数学 | 確率 | 2 つのさいころの目の和の確率 | 大小 2 つのさいころを同時に投げるとき、出た目の数の和が $2$ になる確率を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.probability_two_dice.json) | なし |  |
| 数学 | 確率 | 玉を 2 個取り出す確率 | 赤玉 $2$ 個と白玉 $2$ 個が入った袋から、同時に 2 個の玉を取り出す。2 個とも赤玉である確率を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.probability_balls.json) | あり |  |
| 数学 | データの活用 | 四分位数と四分位範囲 | 次の 7 個のデータの第 1 四分位数、第 2 四分位数、第 3 四分位数と四分位範囲を求めなさい。 $2,\ 5,\ 7,\ 30,\ 12,\ 9,\ 1$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs2.quartiles.json) | あり |  |
| 数学 | 図形の性質 | 平行線と角(同位角・錯角)から角度を求める | ℓ ∥ m のとき、∠x の大きさを求めなさい。(図) | なし | — | 問題文に図が要る。書式は文と式だけを作る |
| 数学 | 図形の性質 | 三角形の合同の証明 | △ABC ≡ △DEF を証明しなさい。 | なし | — | 証明は計算操作ではない(対象外) |

## 数学 中学3年

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 数学 | 式の展開と因数分解 | (x + a)(x + b) の展開 | 次の式を展開しなさい。 $(x - 8)(x - 7)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.expand_xa_xb.json) | あり |  |
| 数学 | 式の展開と因数分解 | (ax + b)² の展開 | 次の式を展開しなさい。 $(x - 7)^{2}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.expand_square.json) | あり |  |
| 数学 | 式の展開と因数分解 | (ax + b)(ax − b) の展開 | 次の式を展開しなさい。 $(x + 2)(x - 2)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.expand_sum_difference.json) | あり |  |
| 数学 | 式の展開と因数分解 | (ax + b)(cx + d) の展開 | 次の式を展開しなさい。 $(2x - 5)(2x + 7)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.expand_general.json) | あり |  |
| 数学 | 式の展開と因数分解 | 共通因数をくくり出す | 次の式を因数分解しなさい。 $15x^{2} - 35x$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.factor_common.json) | あり |  |
| 数学 | 式の展開と因数分解 | x² + (a + b)x + ab の因数分解 | 次の式を因数分解しなさい。 $x^{2} - 15x + 56$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.factor_xa_xb.json) | あり |  |
| 数学 | 式の展開と因数分解 | x² ± 2ax + a² の因数分解 | 次の式を因数分解しなさい。 $x^{2} - 22x + 121$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.factor_square.json) | あり |  |
| 数学 | 式の展開と因数分解 | x² − a² の因数分解 | 次の式を因数分解しなさい。 $x^{2} - 4$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.factor_difference_of_squares.json) | あり |  |
| 数学 | 平方根 | 根号の中を簡単にする(a√b の形) | $\sqrt{12}$ を $a\sqrt{b}$ の形に変形しなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.sqrt_simplify.json) | あり |  |
| 数学 | 平方根 | 平方根の乗法・除法 | 次の計算をしなさい。 $2\sqrt{2} \times \sqrt{3}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.sqrt_mul_div.json) | あり |  |
| 数学 | 平方根 | 平方根の加法・減法 | 次の計算をしなさい。 $\sqrt{80} - \sqrt{45} -4\sqrt{5}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.sqrt_add_sub.json) | あり |  |
| 数学 | 平方根 | 分母の有理化 | 次の数の分母を有理化しなさい。 $\frac{1}{\sqrt{2}}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.rationalize.json) | あり |  |
| 数学 | 平方根 | 平方根をふくむ式の展開 | 次の計算をしなさい。 $(\sqrt{7} + 2\sqrt{3})^{2}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.sqrt_expand.json) | あり |  |
| 数学 | 二次方程式 | 二次方程式(平方根の考えを使う) | 次の方程式を解きなさい。 $(x + 8)^{2} = 11$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.quadratic_square_root.json) | あり |  |
| 数学 | 二次方程式 | 二次方程式(因数分解を使う) | 次の方程式を解きなさい。 $x^{2} + 15x + 56 = 0$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.quadratic_factoring.json) | あり |  |
| 数学 | 二次方程式 | 二次方程式(解の公式) | 次の方程式を解きなさい。 $x^{2} - 7x - 6 = 0$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.quadratic_formula.json) | あり |  |
| 数学 | 関数 y = ax² | y = ax² の式を求める | $y$ は $x$ の 2 乗に比例し、$x = -3$ のとき $y = -15$ である。$y$ を $x$ の式で表しなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.parabola_value.json) | あり |  |
| 数学 | 関数 y = ax² | y = ax² の変化の割合 | 関数 $y = -\frac{5}{2}x^{2}$ について、$x$ の値が $-4$ から $1$ まで増加するときの変化の割合を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.parabola_rate_of_change.json) | あり |  |
| 数学 | 関数 y = ax² | y = ax² の y の変域 | 関数 $y = -\frac{3}{2}x^{2}$ について、$x$ の変域が $-6 \le x \le 2$ のときの $y$ の変域を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.parabola_range.json) | あり |  |
| 数学 | 相似 | 相似比から面積比・体積比を求める | 相似な 2 つの立体があり、相似比は $1 : 2$ である。表面積の比と体積の比を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.similarity_ratio.json) | あり |  |
| 数学 | 三平方の定理 | 三平方の定理(斜辺を求める) | 直角をはさむ 2 辺の長さが $1\,\mathrm{cm}$、$2\,\mathrm{cm}$ の直角三角形の斜辺の長さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.pythagorean_hypotenuse.json) | あり |  |
| 数学 | 三平方の定理 | 三平方の定理(斜辺以外の辺を求める) | 斜辺の長さが $4\,\mathrm{cm}$、他の 1 辺の長さが $1\,\mathrm{cm}$ の直角三角形の、残りの辺の長さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.pythagorean_leg.json) | あり |  |
| 数学 | 三平方の定理 | 2 点間の距離 | 2 点 $\mathrm{A}(-6,\ -4)$、$\mathrm{B}(-4,\ 6)$ の間の距離を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.distance_two_points.json) | あり |  |
| 数学 | 三平方の定理 | 特別な直角三角形の辺の比 | 3 つの角が $45^{\circ}、45^{\circ}、90^{\circ}$ の直角三角形で、等しい 2 辺の 1 つの長さが $1\,\mathrm{cm}$ のとき、斜辺と残りの辺の長さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.special_right_triangles.json) | あり |  |
| 数学 | 円 | 円周角と中心角 | ある弧に対する中心角が $28^{\circ}$ のとき、同じ弧に対する円周角の大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.inscribed_angle.json) | あり |  |
| 数学 | 標本調査 | 標本調査から全体の数を推定する | 箱の中に同じ大きさの玉が $2000$ 個入っている。よくかき混ぜて $20$ 個を取り出したところ、赤玉が $4$ 個ふくまれていた。箱の中の赤玉はおよそ何個と推定できるか。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.jhs3.sampling_estimate.json) | あり |  |
| 数学 | 相似 | 三角形の相似の証明 | △ABC ∽ △DEF を証明しなさい。 | なし | — | 証明は計算操作ではない(対象外) |
| 数学 | 相似 | 平行線と線分の比から長さを求める | ℓ ∥ m ∥ n のとき、x の値を求めなさい。(図) | なし | — | 問題文に図が要る。書式は文と式だけを作る |

## 数学 高校 数学I

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 数学 | 数と式 | (a + b + c)² の展開 | 次の式を展開しなさい。 $(x - 3y - 3)^{2}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.expand_three_terms.json) | あり |  |
| 数学 | 数と式 | たすき掛けによる因数分解 | 次の式を因数分解しなさい。 $2x^{2} - 3x - 35$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.factor_cross.json) | あり |  |
| 数学 | 数と式 | 2 文字の二次式の因数分解 | 次の式を因数分解しなさい。 $x^{2} - 12xy + 35y^{2}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.factor_two_variables.json) | あり |  |
| 数学 | 数と式 | 分母の有理化(分母が 2 項) | 次の式の分母を有理化しなさい。 $\frac{2}{\sqrt{7} + \sqrt{2}}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.rationalize_binomial.json) | あり |  |
| 数学 | 数と式 | 二重根号をはずす | 次の式の二重根号をはずしなさい。 $\sqrt{3 + 2\sqrt{2}}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.double_radical.json) | あり |  |
| 数学 | 数と式 | 対称式の値 | $x = 1+\sqrt{2}$、$y = -1+\sqrt{2}$ のとき、$x + y$、$xy$、$x^{2} + y^{2}$ の値を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.symmetric_value.json) | あり |  |
| 数学 | 数と式 | 絶対値の計算 | 次の値を求めなさい。 $\vert -8 - (-7)\vert  - \vert -6\vert $ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.absolute_value_calc.json) | あり |  |
| 数学 | 数と式 | 一次不等式 | 次の不等式を解きなさい。 $-9x - 9 > -6x + 12$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.linear_inequality.json) | あり |  |
| 数学 | 数と式 | 連立不等式 | 次の連立不等式を解きなさい。 $\begin{cases} x - 2 > -9 \\ 2x - 4 \le 14 \end{cases}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.simultaneous_inequalities.json) | あり |  |
| 数学 | 数と式 | 絶対値をふくむ方程式 | 次の方程式を解きなさい。 $\vert x + 8\vert  = 2$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.absolute_equation.json) | あり |  |
| 数学 | 数と式 | 絶対値をふくむ不等式 | 次の不等式を解きなさい。 $\vert x + 8\vert  < 2$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.absolute_inequality.json) | あり |  |
| 数学 | 集合と命題 | 和集合の要素の個数 | $n(A) = 11$、$n(B) = 14$、$n(A \cap B) = 4$ のとき、$n(A \cup B)$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.set_count.json) | あり |  |
| 数学 | 二次関数 | 平方完成して頂点を求める | 次の二次関数を平方完成して、グラフの頂点の座標を求めなさい。 $y = -3x^{2} - 24x - 53$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.complete_square_vertex.json) | あり |  |
| 数学 | 二次関数 | 平方完成(頂点が分数になる) | 次の二次関数を $y = a(x - p)^{2} + q$ の形に変形しなさい。 $y = x^{2} - 7x - 5$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.complete_square_fraction.json) | あり |  |
| 数学 | 二次関数 | 定義域のある二次関数の最大値・最小値 | 二次関数 $y = -2x^{2} - 8x - 12$($3 \le x \le 6$)の最大値と最小値を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.quadratic_max_min_domain.json) | あり |  |
| 数学 | 二次関数 | 放物線の平行移動 | 放物線 $y = -3x^{2}$ を、$x$ 軸方向に $-4$、$y$ 軸方向に $-4$ だけ平行移動した放物線の方程式を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.parabola_translation.json) | あり |  |
| 数学 | 二次関数 | 頂点と 1 点から二次関数を決める | 頂点が点 $(-3,\ -4)$ で、点 $(-1,\ -16)$ を通る放物線をグラフとする二次関数を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.quadratic_from_vertex.json) | あり |  |
| 数学 | 二次関数 | 判別式で実数解の個数を調べる | 二次方程式 $x^{2} - 6x - 5 = 0$ の判別式 $D$ の値と、実数解の個数を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.discriminant_count.json) | あり |  |
| 数学 | 二次関数 | 放物線と x 軸の共有点の座標 | 放物線 $y = x^{2} - 7x - 5$ と $x$ 軸の共有点の $x$ 座標を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.parabola_x_intercepts.json) | あり |  |
| 数学 | 二次関数 | 二次不等式 | 次の二次不等式を解きなさい。 $x^{2} + 14x + 48 < 0$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.quadratic_inequality.json) | あり |  |
| 数学 | 図形と計量 | 三角比の値(0° から 180°) | 次の値を求めなさい。 $\sin 30^{\circ}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.trig_ratio_values.json) | あり |  |
| 数学 | 図形と計量 | 三角比の相互関係(sin から cos・tan) | $0^{\circ} < \theta < 90^{\circ}$ で $\sin\theta = \frac{3}{5}$ のとき、$\cos\theta$ と $\tan\theta$ の値を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.trig_mutual_relations.json) | あり |  |
| 数学 | 図形と計量 | 正弦定理(辺と外接円の半径) | $\triangle \mathrm{ABC}$ において、$a = 12$、$A = 60^{\circ}$、$B = 30^{\circ}$ のとき、$b$ と外接円の半径 $R$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.sine_rule.json) | あり |  |
| 数学 | 図形と計量 | 余弦定理(辺を求める) | $\triangle \mathrm{ABC}$ において、$b = 1$、$c = 2$、$A = 120^{\circ}$ のとき、$a$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.cosine_rule_side.json) | あり |  |
| 数学 | 図形と計量 | 余弦定理(角を求める) | $\triangle \mathrm{ABC}$ において、$a = 19$、$b = 5$、$c = 21$ のとき、$\cos A$ の値と $A$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.cosine_rule_angle.json) | あり |  |
| 数学 | 図形と計量 | 三角形の面積(2 辺とその間の角) | $\triangle \mathrm{ABC}$ において、$b = 2$、$c = 3$、$A = 45^{\circ}$ のとき、面積 $S$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.triangle_area_sine.json) | あり |  |
| 数学 | データの分析 | 分散と標準偏差 | 次のデータの平均値、分散、標準偏差を求めなさい。 $14,\ 10,\ 12,\ 3,\ 11$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m1.variance_sd.json) | あり |  |
| 数学 | 集合と命題 | 命題の真偽と証明(対偶・背理法) | √2 が無理数であることを証明しなさい。 | なし | — | 証明は計算操作ではない(対象外) |
| 数学 | 二次関数 | 二次関数のグラフをかく | y = x² − 4x + 3 のグラフをかきなさい。 | なし | — | 答えが図で、数字を入れ替える計算ではない(頂点・軸・共有点を求める所までは型にしてある) |
| 数学 | データの分析 | 散布図・箱ひげ図を読み取る | 散布図から相関の正負を答えなさい。(図) | なし | — | 問題文に図が要る。書式は文と式だけを作る |

## 数学 高校 数学A

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 数学 | 場合の数と確率 | 順列 nPr の計算 | 次の値を求めなさい。 ${}_{4}\mathrm{P}_{2}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.permutation.json) | あり |  |
| 数学 | 場合の数と確率 | 組合せ nCr の計算 | 次の値を求めなさい。 ${}_{4}\mathrm{C}_{2}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.combination.json) | あり |  |
| 数学 | 場合の数と確率 | 順列(並べ方の総数) | $5$ 人の中から $2$ 人を選んで 1 列に並べる方法は何通りあるか。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.arrangement_people.json) | あり |  |
| 数学 | 場合の数と確率 | 円順列 | $3$ 人が円形のテーブルのまわりに座る方法は何通りあるか。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.circular_permutation.json) | あり |  |
| 数学 | 場合の数と確率 | 同じものをふくむ順列 | a が $2$ 個、b が $1$ 個、c が $1$ 個ある。この $4$ 個の文字を 1 列に並べる方法は何通りあるか。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.permutation_with_repeats.json) | あり |  |
| 数学 | 場合の数と確率 | 重複順列 | $2$ 種類の数字をくり返し使ってよいとき、$2$ けたの番号は何通り作れるか。ただし、どの位にも $2$ 種類すべての数字を使えるものとする。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.repeated_permutation.json) | あり |  |
| 数学 | 場合の数と確率 | 組合せ(男女から選ぶ) | 男子 $5$ 人、女子 $4$ 人の中から、男子 $1$ 人、女子 $1$ 人を選ぶ方法は何通りあるか。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.combination_groups.json) | あり |  |
| 数学 | 場合の数と確率 | 余事象の確率(少なくとも 1 つ) | 赤玉 $2$ 個と白玉 $2$ 個が入った袋から、同時に $2$ 個の玉を取り出すとき、少なくとも 1 個が赤玉である確率を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.probability_complement.json) | あり |  |
| 数学 | 場合の数と確率 | 反復試行の確率 | 1 個のさいころを $3$ 回投げるとき、1 の目がちょうど $1$ 回出る確率を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.repeated_trials.json) | あり |  |
| 数学 | 場合の数と確率 | 条件付き確率 | ある集団 $17$ 人を調べたところ、条件 A を満たす人は $5$ 人、そのうち条件 B も満たす人は $2$ 人であった。この集団から 1 人を選ぶとき、その人が A を満たすことが分かっているとして、B も満たす条件付き確率 $P_{A}(B)$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.conditional_probability.json) | あり |  |
| 数学 | 場合の数と確率 | 期待値 | $15$ 本のくじの中に、$600$ 円の当たりが $1$ 本、$80$ 円の当たりが $3$ 本あり、残りははずれである。このくじを 1 本引くときの賞金の期待値を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.expected_value.json) | あり |  |
| 数学 | 数学と人間の活動(整数) | 正の約数の個数 | $48$ の正の約数の個数を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.divisor_count.json) | あり |  |
| 数学 | 数学と人間の活動(整数) | 最大公約数と最小公倍数 | $45$ と $63$ の最大公約数と最小公倍数を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.gcd_lcm.json) | あり |  |
| 数学 | 数学と人間の活動(整数) | ユークリッドの互除法 | ユークリッドの互除法を用いて、$760$ と $440$ の最大公約数を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.euclidean_algorithm.json) | あり |  |
| 数学 | 数学と人間の活動(整数) | 一次不定方程式の整数解 | 方程式 $2x + 3y = 9$ の整数解をすべて求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.linear_diophantine.json) | あり |  |
| 数学 | 数学と人間の活動(整数) | n 進法から 10 進法へ | $2$ 進法で表された数 $10011_{(2)}$ を 10 進法で表しなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.base_to_decimal.json) | あり |  |
| 数学 | 数学と人間の活動(整数) | 10 進法から n 進法へ | 10 進法の数 $19$ を $2$ 進法で表しなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.decimal_to_base.json) | あり |  |
| 数学 | 数学と人間の活動(整数) | 余りの計算(合同式) | 整数 $a$、$b$ を $5$ で割った余りがそれぞれ $2$、$3$ であるとき、$a + b$ と $ab$ を $5$ で割った余りを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.remainder.json) | あり |  |
| 数学 | 図形の性質 | 角の二等分線と線分の比 | $\triangle \mathrm{ABC}$ で $\mathrm{AB} = 2$、$\mathrm{AC} = 3$、$\mathrm{BC} = 5$ とする。$\angle \mathrm{A}$ の二等分線と辺 $\mathrm{BC}$ の交点を $\mathrm{D}$ とするとき、$\mathrm{BD}$ の長さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.angle_bisector_ratio.json) | あり |  |
| 数学 | 図形の性質 | 方べきの定理 | 円の外部の点 $\mathrm{P}$ を通る 2 直線が、円とそれぞれ 2 点 $\mathrm{A}$、$\mathrm{B}$ と 2 点 $\mathrm{C}$、$\mathrm{D}$ で交わっている。$\mathrm{PA} = 6$、$\mathrm{PB} = 10$、$\mathrm{PC} = 2$ のとき、$\mathrm{PD}$ の長さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.ma.power_of_a_point.json) | あり |  |
| 数学 | 図形の性質 | チェバの定理・メネラウスの定理で線分の比を求める | △ABC の辺上の点 P、Q、R について、BP : PC を求めなさい。(図) | なし | — | 点の位置関係を図で示す必要がある。書式は文と式だけを作る |
| 数学 | 場合の数と確率 | 樹形図・辞書式配列で数え上げる | a、b、c、d の 4 文字を辞書式に並べるとき、bdca は何番目か。 | なし | — | 数字を入れ替えると数え上げの手順そのものが変わり、答えを式で書けない |

## 数学 高校 数学II

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 数学 | 式と証明 | (a + b)³ の展開 | 次の式を展開しなさい。 $(x - 4)^{3}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.expand_cube.json) | あり |  |
| 数学 | 式と証明 | x³ ± a³ の因数分解 | 次の式を因数分解しなさい。 $x^{3} - 64$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.factor_sum_of_cubes.json) | あり |  |
| 数学 | 式と証明 | 二項定理(指定された項の係数) | $(2x + 1)^{5}$ の展開式における $x^{4}$ の係数を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.binomial_coefficient.json) | あり |  |
| 数学 | 式と証明 | 多項式の割り算(商と余り) | 多項式 $A$ を多項式 $B$ で割った商と余りを求めなさい。 $A = x^{3} - 19x - 14,\quad B = x + 4$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.polynomial_division.json) | あり |  |
| 数学 | 式と証明 | 分数式の加法・減法 | 次の計算をしなさい。 $\frac{1}{x - 6} + \frac{1}{x - 5}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.rational_expression_add.json) | あり |  |
| 数学 | 式と証明 | 分数式の約分 | 次の分数式を約分しなさい。 $\frac{x^{2} - 12x + 35}{x^{2} - 11x + 28}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.rational_expression_reduce.json) | あり |  |
| 数学 | 複素数と方程式 | 複素数の乗法 | 次の計算をしなさい。 $(-6 - 5i)(-4 + 6i)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.complex_mul.json) | あり |  |
| 数学 | 複素数と方程式 | 複素数の除法 | 次の計算をしなさい。 $\frac{-6 - 5i}{-3 + 4i}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.complex_div.json) | あり |  |
| 数学 | 複素数と方程式 | 二次方程式の虚数解 | 次の二次方程式を解きなさい。 $3x^{2} - x + 3 = 0$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.quadratic_complex_roots.json) | あり |  |
| 数学 | 複素数と方程式 | 解と係数の関係 | 二次方程式 $x^{2} - 7x - 6 = 0$ の 2 つの解を $\alpha$、$\beta$ とするとき、$\alpha + \beta$、$\alpha\beta$、$\alpha^{2} + \beta^{2}$ の値を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.vieta.json) | あり |  |
| 数学 | 複素数と方程式 | 剰余の定理 | 多項式 $P(x) = x^{3} - 4x^{2} - 3x + 9$ を $x + 1$ で割った余りを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.remainder_theorem.json) | あり |  |
| 数学 | 複素数と方程式 | 因数定理を使って三次方程式を解く | 次の方程式を解きなさい。 $x^{3} + 6x^{2} + 5x - 12 = 0$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.cubic_equation.json) | あり |  |
| 数学 | 図形と方程式 | 内分点・外分点の座標 | 2 点 $\mathrm{A}(6,\ -1)$、$\mathrm{B}(-1,\ 4)$ を結ぶ線分 $\mathrm{AB}$ を $3 : 2$ に外分する点の座標を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.internal_division_point.json) | あり |  |
| 数学 | 図形と方程式 | 点と傾きから直線の方程式を求める | 点 $(-6,\ -4)$ を通り、傾きが $-3$ の直線の方程式を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.line_through_point_slope.json) | あり |  |
| 数学 | 図形と方程式 | 平行・垂直な直線の方程式 | 点 $(5,\ -1)$ を通り、直線 $x - 4y - 5 = 0$ に平行な直線の方程式を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.parallel_perpendicular_line.json) | あり |  |
| 数学 | 図形と方程式 | 点と直線の距離 | 点 $(6,\ -1)$ と直線 $x - 5y - 5 = 0$ の距離を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.point_line_distance.json) | あり |  |
| 数学 | 図形と方程式 | 中心と半径から円の方程式を求める | 中心が点 $(-6,\ -4)$、半径が $2$ の円の方程式を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.circle_equation.json) | あり |  |
| 数学 | 図形と方程式 | 円の方程式から中心と半径を求める | 方程式 $x^{2} + y^{2} + 12x + 10y + 52 = 0$ が表す円の中心の座標と半径を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.circle_center_radius.json) | あり |  |
| 数学 | 図形と方程式 | 円周上の点における接線の方程式 | 円 $x^{2} + y^{2} = 74$ 上の点 $(-7,\ -5)$ における接線の方程式を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.circle_tangent.json) | あり |  |
| 数学 | 三角関数 | 度数法と弧度法の変換 | $30^{\circ}$ を弧度法で表しなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.degree_to_radian.json) | あり |  |
| 数学 | 三角関数 | 一般角の三角関数の値(弧度法) | 次の値を求めなさい。 $\sin \frac{5}{6}\pi$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.trig_general_angle.json) | あり |  |
| 数学 | 三角関数 | 加法定理で値を求める | 加法定理を用いて、次の値を求めなさい。 $\sin 75^{\circ}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.addition_theorem.json) | あり |  |
| 数学 | 三角関数 | 2 倍角の公式 | $0 < \alpha < \frac{\pi}{2}$ で $\sin\alpha = \frac{3}{5}$ のとき、$\sin 2\alpha$ と $\cos 2\alpha$ の値を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.double_angle.json) | あり |  |
| 数学 | 三角関数 | 三角関数の合成 | 次の式を $r\sin(\theta + \alpha)$ の形に変形しなさい。ただし、$r > 0$、$-\pi < \alpha \le \pi$ とする。 $\frac{\sqrt{2}}{2}\sin\theta + \frac{\sqrt{2}}{2}\cos\theta$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.trig_composition.json) | あり |  |
| 数学 | 三角関数 | 三角方程式 | $0 \le \theta < 2\pi$ のとき、次の方程式を解きなさい。 $\sin\theta = \frac{\sqrt{2}}{2}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.trig_equation.json) | あり |  |
| 数学 | 指数関数と対数関数 | 指数法則 | 次の計算をしなさい。 $3^{3} \times 3^{-1} \div 3^{-2}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.exponent_laws.json) | あり |  |
| 数学 | 指数関数と対数関数 | 累乗根と有理数の指数 | 次の値を求めなさい。 $4^{\frac{3}{2}}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.rational_exponent.json) | あり |  |
| 数学 | 指数関数と対数関数 | 指数方程式 | 次の方程式を解きなさい。 $2^{x - 3} = 2$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.exponential_equation.json) | あり |  |
| 数学 | 指数関数と対数関数 | 対数の値 | 次の値を求めなさい。 $\log_{2} \frac{1}{4}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.logarithm_value.json) | あり |  |
| 数学 | 指数関数と対数関数 | 対数の性質を使った計算 | 次の計算をしなさい。 $\log_{6} 2 + \log_{6} 9 - \log_{6} 3$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.logarithm_properties.json) | あり |  |
| 数学 | 指数関数と対数関数 | 底の変換公式 | 次の値を求めなさい。 $\log_{9} 3$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.change_of_base.json) | あり |  |
| 数学 | 指数関数と対数関数 | 対数方程式 | 次の方程式を解きなさい。 $\log_{2} (x - 6) = 1$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.logarithmic_equation.json) | あり |  |
| 数学 | 指数関数と対数関数 | 常用対数で桁数を求める | $\log_{10} 2 = 0.3010$ とする。$2^{19}$ は何桁の整数か。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.digits_by_common_log.json) | あり |  |
| 数学 | 微分と積分 | 平均変化率 | 関数 $f(x) = -3x^{2} - 4x$ について、$x$ が $-3$ から $1$ まで変化するときの平均変化率を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.average_rate_of_change.json) | あり |  |
| 数学 | 微分と積分 | 多項式の導関数 | 次の関数を微分しなさい。 $y = -4x^{3} - 4x^{2} - 5x + 9$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.derivative_polynomial.json) | あり |  |
| 数学 | 微分と積分 | 微分係数 | 関数 $f(x) = -3x^{3} - 4x^{2} - 5x$ について、微分係数 $f'(4)$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.derivative_at_point.json) | あり |  |
| 数学 | 微分と積分 | 接線の方程式 | 曲線 $y = -3x^{2} - 4x - 4$ 上の点 $(3,\ -43)$ における接線の方程式を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.tangent_line.json) | あり |  |
| 数学 | 微分と積分 | 三次関数の極値 | 関数 $y = x^{3} + 3x^{2} + 6$ の極値を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.cubic_extrema.json) | あり |  |
| 数学 | 微分と積分 | 多項式の不定積分 | 次の不定積分を求めなさい。 $\int (-12x^{2} - 10x - 5)\,dx$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.indefinite_integral_polynomial.json) | あり |  |
| 数学 | 微分と積分 | 多項式の定積分 | 次の定積分を求めなさい。 $\int_{2}^{4} (-3x^{2} - 4x - 4)\,dx$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.definite_integral_polynomial.json) | あり |  |
| 数学 | 微分と積分 | 放物線と x 軸で囲まれた部分の面積 | 放物線 $y = x^{2} + 6x + 8$ と $x$ 軸で囲まれた部分の面積を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.area_parabola_x_axis.json) | あり |  |
| 数学 | 微分と積分 | 放物線と直線で囲まれた部分の面積 | 放物線 $y = x^{2} + 7x + 2$ と直線 $y = 3x - 1$ で囲まれた部分の面積を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m2.area_parabola_line.json) | あり |  |
| 数学 | 図形と方程式 | 軌跡の方程式を求める | 2 点 A、B からの距離の比が 2 : 1 である点 P の軌跡を求めなさい。 | なし | — | 条件の式を立てて整理する過程が答えで、数字を入れ替えても式の変形が要る(数式処理は作らない) |
| 数学 | 図形と方程式 | 不等式の表す領域を図示する | 不等式 y > x² − 1 の表す領域を図示しなさい。 | なし | — | 答えが図で、数字を入れ替える計算ではない |
| 数学 | 式と証明 | 等式・不等式の証明 | a + b = 1 のとき、a² + b = b² + a を証明しなさい。 | なし | — | 証明は計算操作ではない(対象外) |

## 数学 高校 数学B

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 数学 | 数列 | 等差数列の一般項 | 初項 $-11$、公差 $-5$ の等差数列 $\{a_{n}\}$ の一般項と、第 $13$ 項を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mb.arithmetic_general_term.json) | あり |  |
| 数学 | 数列 | 等差数列の和 | 初項 $-11$、公差 $-5$ の等差数列の、初項から第 $11$ 項までの和を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mb.arithmetic_sum.json) | あり |  |
| 数学 | 数列 | 等比数列の一般項 | 初項 $-5$、公比 $2$ の等比数列 $\{a_{n}\}$ の一般項と、第 $4$ 項を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mb.geometric_general_term.json) | あり |  |
| 数学 | 数列 | 等比数列の和 | 初項 $1$、公比 $2$ の等比数列の、初項から第 $4$ 項までの和を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mb.geometric_sum.json) | あり |  |
| 数学 | 数列 | Σ の計算(一次式) | 次の和を求めなさい。 $\sum_{k=1}^{10} (-6k - 7)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.mb.sigma_linear.json) | あり |  |
| 数学 | 数列 | Σ の計算(二次式) | 次の和を求めなさい。 $\sum_{k=1}^{7} (k^{2} - 4k)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.mb.sigma_quadratic.json) | あり |  |
| 数学 | 数列 | Σ の計算(n の式で表す) | 次の和を $n$ の式で表しなさい。 $\sum_{k=1}^{n} (k - 7)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.mb.sigma_general_n.json) | あり |  |
| 数学 | 数列 | 階差数列から一般項を求める | 次の数列 $\{a_{n}\}$ の一般項を、階差数列を利用して求めなさい。 $-6,\ -5,\ -3,\ 0,\ 4,\ \cdots$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.mb.difference_sequence.json) | あり |  |
| 数学 | 数列 | 漸化式 a_{n+1} = p a_n + q | $a_{1} = -5$、$a_{n+1} = 2a_{n} + 3$ で定められる数列 $\{a_{n}\}$ の一般項を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mb.recurrence_linear.json) | あり |  |
| 数学 | 統計的な推測 | 確率変数の期待値と分散 | 確率変数 $X$ のとる値が $0$、$1$、$2$ で、それぞれの確率が $\frac{1}{7}$、$\frac{4}{7}$、$\frac{2}{7}$ であるとき、$X$ の期待値 $E(X)$ と分散 $V(X)$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mb.random_variable_mean_variance.json) | あり |  |
| 数学 | 統計的な推測 | aX + b の期待値と分散 | 確率変数 $X$ の期待値が $2$、分散が $3$ のとき、$Y = -4X + 9$ の期待値、分散、標準偏差を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mb.linear_transform_mean_variance.json) | あり |  |
| 数学 | 統計的な推測 | 二項分布の期待値と標準偏差 | 確率変数 $X$ が二項分布 $B\left(30,\ \frac{1}{3}\right)$ に従うとき、$X$ の期待値、分散、標準偏差を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mb.binomial_distribution.json) | あり |  |
| 数学 | 統計的な推測 | 正規分布の標準化 | 確率変数 $X$ が正規分布 $N(40,\ 4^{2})$ に従うとき、$X = 34$ を標準化した値 $Z = \frac{X - m}{\sigma}$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mb.standardize.json) | あり |  |
| 数学 | 統計的な推測 | 母平均の信頼区間(信頼度 95%) | 母標準偏差が $6$ の母集団から大きさ $36$ の標本を取り出したところ、標本平均は $51$ であった。母平均 $m$ に対する信頼度 95% の信頼区間を、小数第 2 位まで求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mb.confidence_interval.json) | あり |  |
| 数学 | 数列 | 数学的帰納法による証明 | 1 + 3 + 5 + … + (2n − 1) = n² を数学的帰納法で証明しなさい。 | なし | — | 証明は計算操作ではない(対象外) |
| 数学 | 統計的な推測 | 正規分布表から確率を読む | Z が標準正規分布に従うとき、P(0 ≤ Z ≤ 1.25) を正規分布表から求めなさい。 | なし | — | 正規分布表(数表)を引く操作で、表を端末に持たせていない。書式の関数に正規分布の累積確率が無い |

## 数学 高校 数学C

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 数学 | ベクトル | ベクトルの成分の計算 | $\vec{a} = (-6,\ -4)$、$\vec{b} = (-4,\ 6)$ のとき、$3\vec{a} - 2\vec{b}$ を成分で表しなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.vector_linear_combination.json) | あり |  |
| 数学 | ベクトル | ベクトルの大きさ | $\vec{a} = (-8,\ -7)$ の大きさ $\vert \vec{a}\vert $ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.vector_magnitude.json) | あり |  |
| 数学 | ベクトル | 内積(成分) | $\vec{a} = (-7,\ -5)$、$\vec{b} = (-4,\ 7)$ のとき、内積 $\vec{a} \cdot \vec{b}$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.dot_product_components.json) | あり |  |
| 数学 | ベクトル | 内積(大きさとなす角) | $\vert \vec{a}\vert  = 1$、$\vert \vec{b}\vert  = 2$ で、$\vec{a}$ と $\vec{b}$ のなす角が $45^{\circ}$ のとき、内積 $\vec{a} \cdot \vec{b}$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.dot_product_angle_form.json) | あり |  |
| 数学 | ベクトル | 2 つのベクトルのなす角 | $\vec{a} = (1,\ 0)$、$\vec{b} = (1,\ 1)$ のなす角 $\theta$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.vector_angle.json) | あり |  |
| 数学 | ベクトル | ベクトルが垂直になる条件 | $\vec{a} = (1,\ 2)$ と $\vec{b} = (x + 7,\ -1)$ が垂直になるとき、$x$ の値を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.vector_perpendicular.json) | あり |  |
| 数学 | ベクトル | 内分点の位置ベクトル | 2 点 $\mathrm{A}(\vec{a})$、$\mathrm{B}(\vec{b})$ を結ぶ線分 $\mathrm{AB}$ を $1 : 2$ に内分する点 $\mathrm{P}$ の位置ベクトル $\vec{p}$ を、$\vec{a}$、$\vec{b}$ で表しなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.position_vector_division.json) | なし |  |
| 数学 | ベクトル | 空間ベクトルの大きさと内積 | $\vec{a} = (-5,\ -4,\ -3)$、$\vec{b} = (5,\ -2,\ -2)$ のとき、$\vert \vec{a}\vert $ と $\vec{a} \cdot \vec{b}$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.space_vector_magnitude_dot.json) | あり |  |
| 数学 | 複素数平面 | 複素数の絶対値 | 複素数 $z = -8-7i$ の絶対値 $\vert z\vert $ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.complex_modulus.json) | あり |  |
| 数学 | 複素数平面 | 極形式で表す | 複素数 $z = \frac{1}{2}+\frac{\sqrt{3}}{2}i$ を極形式で表しなさい。ただし、偏角 $\theta$ は $0 \le \theta < 2\pi$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.polar_form.json) | あり |  |
| 数学 | 複素数平面 | 極形式の積と商 | $z_{1} = 2\left(\cos \frac{\pi}{2} + i\sin \frac{\pi}{2}\right)$、$z_{2} = \left(\cos \frac{\pi}{2} + i\sin \frac{\pi}{2}\right)$ のとき、$z_{1}z_{2}$ を極形式で表しなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.polar_product_quotient.json) | あり |  |
| 数学 | 複素数平面 | ド・モアブルの定理 | 次の式を計算しなさい。 $(1+i)^{4}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.de_moivre.json) | あり |  |
| 数学 | 複素数平面 | ド・モアブルの定理(1 + √3 i など) | 次の式を計算しなさい。 $(1+\sqrt{3}i)^{8}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.de_moivre_sqrt3.json) | あり |  |
| 数学 | 式と曲線 | 楕円の焦点と長軸・短軸の長さ | 楕円 $\frac{x^{2}}{36} + \frac{y^{2}}{16} = 1$ の焦点の座標と、長軸・短軸の長さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.ellipse_foci.json) | あり |  |
| 数学 | 式と曲線 | 双曲線の焦点と漸近線 | 双曲線 $\frac{x^{2}}{4} - \frac{y^{2}}{9} = 1$ の焦点の座標と漸近線の方程式を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.hyperbola_asymptotes.json) | あり |  |
| 数学 | 式と曲線 | 放物線の焦点と準線 | 放物線 $y^{2} = -36x$ の焦点の座標と準線の方程式を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.parabola_focus.json) | あり |  |
| 数学 | 式と曲線 | 極座標を直交座標に直す | 極座標が $\left(1,\ \frac{\pi}{3}\right)$ である点の直交座標を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.mc.polar_to_cartesian.json) | あり |  |
| 数学 | ベクトル | ベクトルを使った図形の証明 | △ABC の重心 G について、GA + GB + GC = 0 を証明しなさい。 | なし | — | 証明は計算操作ではない(対象外) |
| 数学 | 式と曲線 | 媒介変数表示された曲線の概形をかく | x = cos θ、y = sin 2θ で表される曲線の概形をかきなさい。 | なし | — | 答えが図で、数字を入れ替える計算ではない |

## 数学 高校 数学III

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 数学 | 極限 | 数列の極限(分数式) | 次の極限を求めなさい。 $\lim_{n \to \infty} \frac{n - 7}{2n + 9}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.sequence_limit_rational.json) | あり |  |
| 数学 | 極限 | 無限等比級数の和 | 初項 $2$、公比 $\frac{5}{6}$ の無限等比級数の和を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.infinite_geometric_series.json) | あり |  |
| 数学 | 極限 | 関数の極限(約分する 0/0 の形) | 次の極限を求めなさい。 $\lim_{x \to 6} \frac{x^{2} - 5x - 6}{x^{2} - 3x - 18}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.function_limit_factor.json) | あり |  |
| 数学 | 極限 | 三角関数の極限(sin x / x の利用) | 次の極限を求めなさい。 $\lim_{x \to 0} \frac{\sin x}{2x}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.trig_limit.json) | あり |  |
| 数学 | 微分法 | 積の微分 | 次の関数を微分しなさい。 $y = (x - 5)(x^{2} + 6)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.derivative_product.json) | あり |  |
| 数学 | 微分法 | 商の微分 | 次の関数を微分しなさい。 $y = \frac{-5x - 4}{x + 6}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.derivative_quotient.json) | あり |  |
| 数学 | 微分法 | 合成関数の微分((ax + b)ⁿ) | 次の関数を微分しなさい。 $y = (-5x - 5)^{4}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.derivative_chain_power.json) | あり |  |
| 数学 | 微分法 | 三角関数の微分 | 次の関数を微分しなさい。 $y = -6\sin 2x$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.derivative_trig.json) | あり |  |
| 数学 | 微分法 | tan の微分 | 次の関数を微分しなさい。 $y = -5\tan x$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.derivative_tan.json) | あり |  |
| 数学 | 微分法 | 指数関数の微分 | 次の関数を微分しなさい。 $y = -6e^{-5x}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.derivative_exponential.json) | あり |  |
| 数学 | 微分法 | 対数関数の微分 | 次の関数を微分しなさい。 $y = 2\log (x + 2)$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.derivative_logarithm.json) | あり |  |
| 数学 | 微分法 | 積の微分(xⁿ e^{ax}) | 次の関数を微分しなさい。 $y = xe^{-4x}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.derivative_x_exp.json) | あり |  |
| 数学 | 微分法 | 積の微分(xⁿ log x) | 次の関数を微分しなさい。 $y = x\log x$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.derivative_x_log.json) | あり |  |
| 数学 | 微分法 | 第 2 次導関数 | 次の関数の第 2 次導関数を求めなさい。 $y = -4x^{5} - 5x^{2} - 4x$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.second_derivative.json) | あり |  |
| 数学 | 微分法 | 接線の方程式(指数・対数) | 曲線 $y = \log x$ 上の $x = 1$ の点における接線の傾きを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.tangent_line_exp_log.json) | あり |  |
| 数学 | 積分法 | 不定積分(x の有理数乗) | 次の不定積分を求めなさい。 $\int x^{\frac{1}{2}}\,dx$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.integral_power_rational.json) | あり |  |
| 数学 | 積分法 | 不定積分(e^{ax}、sin ax、cos ax) | 次の不定積分を求めなさい。 $\int e^{-6x}\,dx$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.integral_exp_trig.json) | あり |  |
| 数学 | 積分法 | 不定積分(1/(ax + b)) | 次の不定積分を求めなさい。 $\int \frac{2}{x - 7}\,dx$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.integral_reciprocal_linear.json) | あり |  |
| 数学 | 積分法 | 置換積分((ax + b)ⁿ) | 次の不定積分を求めなさい。 $\int (-5x - 5)^{3}\,dx$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.integral_substitution_power.json) | あり |  |
| 数学 | 積分法 | 置換積分(f'(x)/f(x) の形) | 次の不定積分を求めなさい。 $\int \frac{8x - 1}{4x^{2} - x + 3}\,dx$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.integral_substitution_log.json) | あり |  |
| 数学 | 積分法 | 部分積分(x e^{ax}) | 次の不定積分を求めなさい。 $\int xe^{-6x}\,dx$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.integral_by_parts_exp.json) | あり |  |
| 数学 | 積分法 | 部分積分(x sin ax、x cos ax) | 次の不定積分を求めなさい。 $\int x\sin x\,dx$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.integral_by_parts_trig.json) | あり |  |
| 数学 | 積分法 | 部分積分(xⁿ log x) | 次の不定積分を求めなさい。 $\int \log x\,dx$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.integral_by_parts_log.json) | あり |  |
| 数学 | 積分法 | 定積分(三角関数) | 次の定積分を求めなさい。 $\int_{0}^{\frac{\pi}{4}} \sin x\,dx$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.definite_integral_trig.json) | あり |  |
| 数学 | 積分法 | 定積分(指数関数) | 次の定積分を求めなさい。 $\int_{0}^{1} e^{x}\,dx$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.definite_integral_exp.json) | あり |  |
| 数学 | 積分法 | 定積分(1/x) | 次の定積分を求めなさい。 $\int_{1}^{2} \frac{1}{x}\,dx$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.definite_integral_log.json) | あり |  |
| 数学 | 積分法 | 回転体の体積 | 曲線 $y = x$ と $x$ 軸、直線 $x = 1$ で囲まれた部分を、$x$ 軸のまわりに 1 回転させてできる立体の体積を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.volume_of_revolution.json) | あり |  |
| 数学 | 積分法 | 曲線と x 軸で囲まれた部分の面積(三角関数) | 曲線 $y = \sin x$($0 \le x \le \pi$)と $x$ 軸で囲まれた部分の面積を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.m3.area_between_curves_trig.json) | あり |  |
| 数学 | 微分法 | 増減・凹凸を調べてグラフの概形をかく | y = x e^{−x} の増減、凹凸を調べてグラフの概形をかきなさい。 | なし | — | 答えが増減表と図で、数字を入れ替える計算ではない |
| 数学 | 積分法 | 置換のしかたを自分で選ぶ置換積分 | ∫ x√(1 − x²) dx を求めなさい。 | なし | — | 被積分関数の形ごとに置き方と答えの式の形が変わる。形を決めた置換積分((ax + b)ⁿ、f'/f)は型にしてある。形を選ぶ所は数式処理が要る |

## 数学 大学初年

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 数学 | 偏微分 | 多項式の偏導関数 | 次の関数の偏導関数 $f_{x}$、$f_{y}$ を求めなさい。 $f(x, y) = -5x^{3}y^{2} - 4x^{2} - 3y^{3}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.partial_derivative_polynomial.json) | あり |  |
| 数学 | 偏微分 | 指数関数・三角関数の偏導関数 | 次の関数の偏導関数 $f_{x}$、$f_{y}$ を求めなさい。 $f(x, y) = e^{-4x - 3y}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.partial_derivative_exp.json) | あり |  |
| 数学 | 偏微分 | 2 階の偏導関数 | 次の関数の 2 階の偏導関数 $f_{xx}$、$f_{xy}$、$f_{yy}$ を求めなさい。 $f(x, y) = -4x^{2}y^{3} - 3x^{2}y$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.second_partial_derivatives.json) | あり |  |
| 数学 | 偏微分 | 接平面の方程式 | 曲面 $z = -3x^{2} - 3y^{2}$ 上の点 $(-2,\ 3,\ -39)$ における接平面の方程式を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.total_differential_value.json) | あり |  |
| 数学 | 重積分 | 長方形領域での重積分 | 次の重積分を求めなさい。ただし、$D = \{(x, y) \mid 0 \le x \le 2,\ 0 \le y \le 2\}$ とする。 $\iint_{D} 3xy^{2}\,dx\,dy$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.double_integral_rectangle.json) | あり |  |
| 数学 | テイラー展開 | マクローリン展開の係数(e^{ax}) | $f(x) = e^{-4x}$ のマクローリン展開における $x^{2}$ の係数を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.taylor_coefficients.json) | あり |  |
| 数学 | 微分の応用 | ロピタルの定理による極限 | 次の極限を求めなさい。 $\lim_{x \to 0} \frac{e^{6x} - 1}{\sin 3x}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.lhopital.json) | あり |  |
| 数学 | 微分の応用 | 逆三角関数の微分 | 次の関数を微分しなさい。 $y = \sin^{-1} \frac{x}{2}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.inverse_trig_derivative.json) | あり |  |
| 数学 | 行列 | 行列の和とスカラー倍 | $A = \begin{pmatrix} -5 & -4 \\ -3 & 5 \end{pmatrix}$、$B = \begin{pmatrix} -1 & -2 \\ -5 & -4 \end{pmatrix}$ のとき、$3A - B$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.matrix_linear_combination.json) | あり |  |
| 数学 | 行列 | 行列の積(2 × 2) | 次の行列の積を計算しなさい。 $\begin{pmatrix} -4 & -3 \\ -3 & 4 \end{pmatrix}\begin{pmatrix} -1 & -2 \\ -4 & -3 \end{pmatrix}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.matrix_product.json) | あり |  |
| 数学 | 行列 | 行列式(2 × 2) | 次の行列式の値を求めなさい。 $\begin{vmatrix} -8 & -7 \\ -5 & 9 \end{vmatrix}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.determinant_2x2.json) | あり |  |
| 数学 | 行列 | 行列式(3 × 3、サラスの方法) | 次の行列式の値を求めなさい。 $\begin{vmatrix} -3 & -2 & -2 \\ 3 & -1 & -1 \\ -3 & -2 & 0 \end{vmatrix}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.determinant_3x3.json) | あり |  |
| 数学 | 行列 | 逆行列(2 × 2) | 次の行列の逆行列を求めなさい。 $A = \begin{pmatrix} -6 & -4 \\ -4 & 6 \end{pmatrix}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.inverse_2x2.json) | あり |  |
| 数学 | 行列 | 連立一次方程式(クラメルの公式) | クラメルの公式を用いて、次の連立一次方程式を解きなさい。 $\begin{cases} -5x - 4y = 13 \\ -3x + 5y = -7 \end{cases}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.cramer_2x2.json) | あり |  |
| 数学 | 行列 | 連立一次方程式(3 元、掃き出し法) | 次の連立一次方程式を解きなさい。 $\begin{cases} x - 2y - 2z = 1 \\ -x + 3y + 4z = -3 \\ -x + y + z = 1 \end{cases}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.linear_system_3x3.json) | あり |  |
| 数学 | 行列 | 固有値(2 × 2) | 次の行列の固有値を求めなさい。 $A = \begin{pmatrix} -3 & 1 \\ -2 & -6 \end{pmatrix}$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.eigenvalues_2x2.json) | あり |  |
| 数学 | ベクトル | 外積(ベクトル積) | $\boldsymbol{a} = (-4,\ -3,\ -3)$、$\boldsymbol{b} = (4,\ -1,\ -2)$ のとき、外積 $\boldsymbol{a} \times \boldsymbol{b}$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.cross_product.json) | あり |  |
| 数学 | 微分方程式 | 変数分離形(y' = ay、初期条件つき) | 次の微分方程式を、初期条件 $y(0) = -5$ のもとで解きなさい。 $\frac{dy}{dx} = -5y$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.ode_separable.json) | あり |  |
| 数学 | 微分方程式 | 1 階線形微分方程式(y' + ay = b) | 次の微分方程式の一般解を求めなさい。 $y' - 4y = 20$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.ode_first_order_linear.json) | あり |  |
| 数学 | 微分方程式 | 2 階定数係数同次形(異なる 2 つの実数解) | 次の微分方程式の一般解を求めなさい。 $y'' + 7y' + 12y = 0$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.ode_second_order_real.json) | あり |  |
| 数学 | 微分方程式 | 2 階定数係数同次形(重解) | 次の微分方程式の一般解を求めなさい。 $y'' + 12y' + 36y = 0$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.ode_second_order_repeated.json) | あり |  |
| 数学 | 微分方程式 | 2 階定数係数同次形(複素数解) | 次の微分方程式の一般解を求めなさい。 $y'' + 8y' + 17y = 0$ | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.ode_second_order_complex.json) | あり |  |
| 数学 | フーリエ級数 | フーリエ係数 b_n(f(x) = kx) | $f(x) = x$($-\pi < x < \pi$)のフーリエ係数 $b_{2} = \frac{1}{\pi}\int_{-\pi}^{\pi} f(x)\sin 2x\,dx$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.fourier_sine_coefficient_x.json) | あり |  |
| 数学 | フーリエ級数 | フーリエ係数 a_n(f(x) = kx²) | $f(x) = x^{2}$($-\pi \le x \le \pi$)のフーリエ係数 $a_{2} = \frac{1}{\pi}\int_{-\pi}^{\pi} f(x)\cos 2x\,dx$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.fourier_cosine_coefficient_x2.json) | あり |  |
| 数学 | フーリエ級数 | フーリエ係数 b_n(矩形波) | $f(x) = -1$($-\pi < x < 0$)、$f(x) = 1$($0 < x < \pi$)で定められる関数のフーリエ係数 $b_{2} = \frac{1}{\pi}\int_{-\pi}^{\pi} f(x)\sin 2x\,dx$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.fourier_square_wave.json) | あり |  |
| 数学 | フーリエ級数 | フーリエ係数 a_0 | $f(x) = \vert x\vert $($-\pi \le x \le \pi$)のフーリエ係数 $a_{0} = \frac{1}{\pi}\int_{-\pi}^{\pi} f(x)\,dx$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/math/math.univ.fourier_a0.json) | あり |  |
| 数学 | 行列 | 行列の階数を行基本変形で求める | 行列 A の階数を求めなさい。 | なし | — | 数字を入れ替えると基本変形の手順と階数そのものが変わる。答えを決まった式で書けない |
| 数学 | 極限 | ε-δ 論法による極限の証明 | lim_{x→1} (2x + 1) = 3 を ε-δ 論法で証明しなさい。 | なし | — | 証明は計算操作ではない(対象外) |
| 数学 | 行列 | 行列の対角化(固有ベクトルを求めて P を作る) | 行列 A を対角化しなさい。 | なし | — | 固有ベクトルは定数倍の取り方が決まらず、答えが 1 つに定まらない。固有値を求める所までは型にしてある |

## 物理 高校 物理

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 物理 | 運動の表し方 | 等速直線運動(距離・速さ・時間) | 速さ $1.5\,\mathrm{m/s}$ で等速直線運動をする物体が、$3.0\,\mathrm{s}$ 間に進む距離を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.uniform_motion.json) | あり |  |
| 物理 | 運動の表し方 | 平均の速さと単位の換算(km/h と m/s) | $20\,\mathrm{km}$ の道のりを $0.5\,\mathrm{h}$ かけて走った自動車の平均の速さは何 km/h か。また、それは何 m/s か。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.average_speed_kmh.json) | あり |  |
| 物理 | 運動の表し方 | 相対速度(一直線上) | 一直線上を、自動車 A が速さ $6\,\mathrm{m/s}$ で、自動車 B が A と同じ向きに速さ $9\,\mathrm{m/s}$ で進んでいる。A から見た B の相対速度の向きと大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.relative_velocity.json) | あり |  |
| 物理 | 等加速度直線運動 | 等加速度直線運動(v = v₀ + at) | 初速度 $1.5\,\mathrm{m/s}$ で進んでいた物体が、一定の加速度 $1.0\,\mathrm{m/s^{2}}$ で $2.5\,\mathrm{s}$ 間加速した。加速した後の速さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.velocity_time.json) | あり |  |
| 物理 | 等加速度直線運動 | 等加速度直線運動(x = v₀t + ½at²) | 初速度 $0.0\,\mathrm{m/s}$、加速度 $1.0\,\mathrm{m/s^{2}}$ の等加速度直線運動をする物体が、$2.0\,\mathrm{s}$ 間に進む距離を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.displacement_time.json) | あり |  |
| 物理 | 等加速度直線運動 | 等加速度直線運動(v² − v₀² = 2ax) | 速さ $10\,\mathrm{m/s}$ で走っていた自動車がブレーキをかけ、一定の加速度(大きさ $1.5\,\mathrm{m/s^{2}}$)で減速して止まった。ブレーキをかけてから止まるまでに進んだ距離を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.velocity_displacement.json) | あり |  |
| 物理 | 落体の運動 | 自由落下(速さと落下距離) | 物体を静かに放して自由落下させた。放してから $1.0\,\mathrm{s}$ 後の速さと、それまでに落下した距離を求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.free_fall.json) | あり |  |
| 物理 | 落体の運動 | 鉛直投げ上げ(最高点の高さと時間) | 物体を初速度 $10\,\mathrm{m/s}$ で鉛直上向きに投げ上げた。最高点に達するまでの時間と、最高点の高さを求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.throw_up_max_height.json) | あり |  |
| 物理 | 落体の運動 | 水平投射(落下時間と水平距離) | 高さ $4.90\,\mathrm{m}$ の所から、小球を水平方向に速さ $6.0\,\mathrm{m/s}$ で投げ出した。地面に達するまでの時間と、その間に水平方向に進む距離を求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.horizontal_projection.json) | あり |  |
| 物理 | 落体の運動 | 斜方投射(最高点の高さと水平到達距離) | 小球を、水平面から $30^{\circ}$ の向きに初速度 $14.7\,\mathrm{m/s}$ で投げ上げた。最高点の高さと、水平到達距離を求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.projectile_range.json) | あり |  |
| 物理 | 力のつり合い | 重力の大きさ(W = mg) | 質量 $3.5\,\mathrm{kg}$ の物体にはたらく重力の大きさを求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.weight.json) | あり |  |
| 物理 | 力のつり合い | フックの法則(F = kx) | ばね定数 $30\,\mathrm{N/m}$ のばねを $5.0\,\mathrm{cm}$ だけ伸ばすのに必要な力の大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.hooke.json) | あり |  |
| 物理 | 力のつり合い | ばねにつるしたおもりのつり合い | ばね定数 $60\,\mathrm{N/m}$ の軽いばねの一端を天井に固定し、他端に質量 $0.40\,\mathrm{kg}$ のおもりをつるして静止させた。ばねの伸びを求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.spring_hanging.json) | あり |  |
| 物理 | 力のつり合い | 斜面上の物体にはたらく重力の分力 | 水平面と $30^{\circ}$ の角をなすなめらかな斜面上に、質量 $2.0\,\mathrm{kg}$ の物体を置いた。重力の、斜面に平行な方向の分力の大きさと、斜面に垂直な方向の分力の大きさを求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.incline_components.json) | あり |  |
| 物理 | 力のつり合い | 2 本の糸でつるした物体の張力 | 質量 $2.0\,\mathrm{kg}$ のおもりを、同じ長さの 2 本の軽い糸で天井からつるした。どちらの糸も鉛直方向と $30^{\circ}$ の角をなしているとき、糸 1 本の張力の大きさを求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.two_strings_tension.json) | あり |  |
| 物理 | 力のつり合い | 最大摩擦力と動摩擦力 | 水平なあらい床の上に質量 $6.0\,\mathrm{kg}$ の物体が置かれている。物体と床の間の静止摩擦係数は $0.20$、動摩擦係数は $0.15$ である。最大摩擦力の大きさと、物体がすべっているときの動摩擦力の大きさを求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.friction_max_static.json) | あり |  |
| 物理 | 力のつり合い | 圧力(p = F/S) | 面積 $0.40\,\mathrm{m^{2}}$ の面を、大きさ $30\,\mathrm{N}$ の力で垂直に押している。この面が受ける圧力を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.pressure.json) | あり |  |
| 物理 | 力のつり合い | 水圧(p = ρgh) | 水深 $4.5\,\mathrm{m}$ の所での、水による圧力を求めなさい。水の密度を $1.0 \times 10^{3}\,\mathrm{kg/m^{3}}$ とし、重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.water_pressure.json) | あり |  |
| 物理 | 力のつり合い | 浮力(F = ρVg) | 体積 $1.2 \times 10^{3}\,\mathrm{cm^{3}}$ の物体を水中に完全に沈めた。物体が受ける浮力の大きさを求めなさい。水の密度を $1.0 \times 10^{3}\,\mathrm{kg/m^{3}}$ とし、重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.buoyancy.json) | あり |  |
| 物理 | 運動の法則 | 運動方程式(ma = F) | なめらかな水平面上に置いた質量 $2.0\,\mathrm{kg}$ の物体に、水平方向に大きさ $10\,\mathrm{N}$ の力を加えた。物体に生じる加速度の大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.newton_second.json) | あり |  |
| 物理 | 運動の法則 | 動摩擦力がはたらく物体の加速度 | あらい水平面上で、質量 $2.0\,\mathrm{kg}$ の物体を水平方向に大きさ $25\,\mathrm{N}$ の力で引いた。物体と面の間の動摩擦係数を $0.50$ として、物体の加速度の大きさを求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.friction_acceleration.json) | あり |  |
| 物理 | 運動の法則 | 糸でつながれた 2 物体の運動 | なめらかな水平面上で、質量 $1.0\,\mathrm{kg}$ の物体 A と質量 $1.5\,\mathrm{kg}$ の物体 B を軽い糸でつなぎ、B を水平方向に大きさ $14\,\mathrm{N}$ の力で引いた。加速度の大きさと、糸の張力の大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.two_blocks_string.json) | あり |  |
| 物理 | 運動の法則 | 定滑車にかけた 2 物体の運動 | 軽い定滑車に軽い糸をかけ、両端に質量 $3.0\,\mathrm{kg}$ の物体 A と質量 $2.5\,\mathrm{kg}$ の物体 B をつるして静かに放した。物体の加速度の大きさと、糸の張力の大きさを求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.atwood.json) | あり |  |
| 物理 | 運動の法則 | 斜面をすべり下りる物体の加速度 | 水平面と $30^{\circ}$ の角をなすあらい斜面(動摩擦係数 $0.10$)を、質量 $5.0\,\mathrm{kg}$ の物体がすべり下りている。物体の加速度の大きさを求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.incline_acceleration.json) | あり |  |
| 物理 | 仕事と力学的エネルギー | 仕事(W = Fx cos θ) | 物体に大きさ $5.0\,\mathrm{N}$ の力を加え続けて、力の向きに $2.5\,\mathrm{m}$ だけ動かした。この力がした仕事を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.work.json) | あり |  |
| 物理 | 仕事と力学的エネルギー | 仕事率(P = W/t) | 質量 $20\,\mathrm{kg}$ の荷物を、$20\,\mathrm{s}$ かけて一定の速さで $6.0\,\mathrm{m}$ の高さまで持ち上げた。このときの仕事と仕事率を求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.power.json) | あり |  |
| 物理 | 仕事と力学的エネルギー | 運動エネルギー(½mv²) | 質量 $1.5\,\mathrm{kg}$ の物体が速さ $4.0\,\mathrm{m/s}$ で運動しているときの運動エネルギーを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.kinetic_energy.json) | あり |  |
| 物理 | 仕事と力学的エネルギー | 重力による位置エネルギー(mgh) | 地面を基準として、高さ $7.0\,\mathrm{m}$ の所にある質量 $3.5\,\mathrm{kg}$ の物体の、重力による位置エネルギーを求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.potential_energy_gravity.json) | あり |  |
| 物理 | 仕事と力学的エネルギー | 弾性力による位置エネルギー(½kx²) | ばね定数 $40\,\mathrm{N/m}$ のばねが自然の長さから $0.10\,\mathrm{m}$ だけ伸びているとき、弾性力による位置エネルギーを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.potential_energy_spring.json) | あり |  |
| 物理 | 仕事と力学的エネルギー | 力学的エネルギーの保存(落下する物体の速さ) | なめらかな斜面上の、水平面からの高さが $3.5\,\mathrm{m}$ の点から、小球を静かに放した。小球が水平面に達したときの速さを求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.energy_conservation_fall.json) | あり |  |
| 物理 | 仕事と力学的エネルギー | 力学的エネルギーの保存(ばねから離れる物体の速さ) | なめらかな水平面上で、ばね定数 $50\,\mathrm{N/m}$ のばねの一端を固定し、他端に質量 $1.0\,\mathrm{kg}$ の物体を押しつけて $0.15\,\mathrm{m}$ だけ縮めてから静かに放した。物体がばねから離れるときの速さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.energy_conservation_spring.json) | あり |  |
| 物理 | 運動量の保存 | 運動量と力積 | 質量 $0.20\,\mathrm{kg}$ のボールが速さ $6.0\,\mathrm{m/s}$ で壁に垂直に当たり、逆向きに速さ $8.0\,\mathrm{m/s}$ ではね返った。ボールが壁から受けた力積の大きさと、接触していた時間が $0.20\,\mathrm{s}$ のときの平均の力の大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.momentum_impulse.json) | あり |  |
| 物理 | 運動量の保存 | 運動量保存(衝突して一体になる) | なめらかな水平面上で、速さ $3.0\,\mathrm{m/s}$ で進む質量 $1.0\,\mathrm{kg}$ の物体 A が、静止している質量 $2.0\,\mathrm{kg}$ の物体 B に衝突し、一体となって進んだ。衝突後の速さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.momentum_conservation_merge.json) | あり |  |
| 物理 | 運動量の保存 | 反発係数(床ではね返る小球) | 高さ $1.0\,\mathrm{m}$ の所から小球を自由落下させたところ、床ではね返った。小球と床の間の反発係数を $0.40$ として、はね返った後に達する最高点の高さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.restitution.json) | あり |  |
| 物理 | 運動量の保存 | 一直線上の衝突(運動量保存と反発係数) | なめらかな水平面上で、速さ $2.0\,\mathrm{m/s}$ で進む質量 $2.0\,\mathrm{kg}$ の小球 A が、静止している質量 $2.0\,\mathrm{kg}$ の小球 B に正面衝突した。反発係数を $0.2$ として、衝突後の A、B の速さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.collision_1d.json) | あり |  |
| 物理 | 円運動と単振動 | 等速円運動(周期・角速度・向心加速度) | 半径 $0.30\,\mathrm{m}$ の円周上を、速さ $2.0\,\mathrm{m/s}$ で等速円運動をする物体がある。角速度、周期、向心加速度の大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.circular_motion.json) | あり |  |
| 物理 | 円運動と単振動 | 向心力(F = mv²/r) | 質量 $0.20\,\mathrm{kg}$ の物体が、半径 $0.40\,\mathrm{m}$ の円周上を速さ $3.0\,\mathrm{m/s}$ で等速円運動をしている。物体にはたらく向心力の大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.centripetal_force.json) | あり |  |
| 物理 | 円運動と単振動 | ばね振り子の周期(T = 2π√(m/k)) | ばね定数 $40\,\mathrm{N/m}$ の軽いばねに質量 $0.20\,\mathrm{kg}$ のおもりをつけて単振動させた。周期を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.spring_pendulum_period.json) | あり |  |
| 物理 | 円運動と単振動 | 単振り子の周期(T = 2π√(L/g)) | 長さ $0.45\,\mathrm{m}$ の単振り子の周期を求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.simple_pendulum_period.json) | あり |  |
| 物理 | 円運動と単振動 | 単振動の最大の速さと加速度 | 振幅 $0.050\,\mathrm{m}$、周期 $1.0\,\mathrm{s}$ の単振動をする物体の、速さの最大値と加速度の大きさの最大値を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.shm_max_speed.json) | あり |  |
| 物理 | 万有引力 | 万有引力の法則 | 質量 $2.0\,\mathrm{kg}$ と $2.0\,\mathrm{kg}$ の 2 つの小球が、中心間の距離 $1.0\,\mathrm{m}$ だけ離れて置かれている。2 球の間にはたらく万有引力の大きさを求めなさい。万有引力定数を $6.67 \times 10^{-11}\,\mathrm{N \cdot m^{2}/kg^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.gravitation.json) | あり |  |
| 物理 | 万有引力 | 第一宇宙速度(v = √(gR)) | 地球の半径を $6.4 \times 10^{6}\,\mathrm{m}$、表面での重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。地球の中心から、地球の半径の $1.0$ 倍の距離を等速円運動する人工衛星の速さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.orbital_speed.json) | あり |  |
| 物理 | 万有引力 | ケプラーの第 3 法則 | ある恒星のまわりを、惑星 A が公転周期 $2.5$ 年、軌道の長半径 $a$ の楕円軌道を描いて回っている。同じ恒星のまわりを回る惑星 B の軌道の長半径が $4a$ のとき、B の公転周期は何年か。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.kepler_third.json) | あり |  |
| 物理 | 剛体のつり合い | 力のモーメント(M = Fl) | 回転軸から $0.40\,\mathrm{m}$ 離れた点に、腕に垂直な向きに大きさ $4.0\,\mathrm{N}$ の力を加えた。回転軸のまわりの力のモーメントの大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.torque.json) | あり |  |
| 物理 | 剛体のつり合い | てこのつり合い(力のモーメントのつり合い) | 軽い棒を支点で支え、支点から左に $0.50\,\mathrm{m}$ の点に重さ $90\,\mathrm{N}$ のおもりをつるした。支点から右に $0.40\,\mathrm{m}$ の点に何 N のおもりをつるせば、棒は水平につり合うか。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.lever_balance.json) | あり |  |
| 物理 | 剛体のつり合い | 2 物体の重心の位置 | 質量 $1.0\,\mathrm{kg}$ の小球 A と質量 $1.5\,\mathrm{kg}$ の小球 B を、長さ $0.60\,\mathrm{m}$ の軽い棒の両端に取りつけた。A から重心までの距離を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.mech.center_of_mass.json) | あり |  |
| 物理 | 運動の表し方 | v-t グラフから加速度と移動距離を読み取る | v-t グラフから、0 s から 4 s までの加速度と移動距離を求めなさい。(図) | なし | — | 問題文にグラフが要る。書式は文と式だけを作る |
| 物理 | 力のつり合い | 物体にはたらく力を図示する | 斜面上で静止している物体にはたらく力をすべて図示しなさい。 | なし | — | 答えが図で、数字を入れ替える計算ではない |
| 物理 | 熱と温度 | 熱量(Q = mcΔT) | 質量 $1.0 \times 10^{2}\,\mathrm{g}$ の水の温度を $15\,\mathrm{K}$ だけ上げるのに必要な熱量を求めなさい。水の比熱を $4.2\,\mathrm{J/(g \cdot K)}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.heat.heat_quantity.json) | あり |  |
| 物理 | 熱と温度 | 熱容量(C = mc) | 質量 $2.0 \times 10^{2}\,\mathrm{g}$ の水でできた物体の熱容量を求めなさい。水の比熱を $4.2\,\mathrm{J/(g \cdot K)}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.heat.heat_capacity.json) | あり |  |
| 物理 | 熱と温度 | 熱量の保存(混ぜた後の温度) | $10^{\circ}\mathrm{C}$ の水 $100\,\mathrm{g}$ と $90^{\circ}\mathrm{C}$ の水 $150\,\mathrm{g}$ を混ぜた。熱は外に逃げないものとして、全体の温度が一様になったときの温度を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.heat.calorimetry_mixing.json) | あり |  |
| 物理 | 熱と温度 | 熱量の保存から比熱を求める | $80^{\circ}\mathrm{C}$ に熱した質量 $100\,\mathrm{g}$ の金属球を、$25^{\circ}\mathrm{C}$ の水 $150\,\mathrm{g}$ の中に入れたところ、全体の温度が $29^{\circ}\mathrm{C}$ になった。水の比熱を $4.2\,\mathrm{J/(g \cdot K)}$ として、この金属の比熱を求めなさい。熱は外に逃げないものとする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.heat.specific_heat_measurement.json) | あり |  |
| 物理 | 熱と温度 | 融解熱・蒸発熱 | 質量 $40\,\mathrm{g}$ の 0℃ の氷を、すべて 0℃ の水にするのに必要な熱量を求めなさい。融解熱を $334\,\mathrm{J/g}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.heat.latent_heat.json) | あり |  |
| 物理 | 気体の法則 | ボイル・シャルルの法則 | 圧力 $1.0 \times 10^{5}\,\mathrm{Pa}$、体積 $1.5\,\mathrm{L}$、温度 $27^{\circ}\mathrm{C}$ の気体を、圧力 $4.0 \times 10^{5}\,\mathrm{Pa}$、温度 $127^{\circ}\mathrm{C}$ にした。このときの体積を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.heat.boyle_charles.json) | あり |  |
| 物理 | 気体の法則 | 理想気体の状態方程式(PV = nRT) | 物質量 $0.40\,\mathrm{mol}$ の理想気体が、温度 $280\,\mathrm{K}$ で体積 $50\,\mathrm{L}$ の容器に入っている。気体の圧力を求めなさい。気体定数を $8.31\,\mathrm{J/(mol \cdot K)}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.heat.ideal_gas_law.json) | あり |  |
| 物理 | 気体の内部エネルギー | 単原子分子理想気体の内部エネルギー | 温度 $280\,\mathrm{K}$ の単原子分子理想気体 $1.0\,\mathrm{mol}$ の内部エネルギーを求めなさい。気体定数を $8.31\,\mathrm{J/(mol \cdot K)}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.heat.internal_energy.json) | あり |  |
| 物理 | 気体の内部エネルギー | 熱力学第 1 法則(ΔU = Q + W) | 気体が $9.0 \times 10^{2}\,\mathrm{J}$ の熱量を吸収し、同時に $2.5 \times 10^{2}\,\mathrm{J}$ の外部から仕事をされた。気体の内部エネルギーの変化を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.heat.first_law.json) | あり |  |
| 物理 | 気体の内部エネルギー | 定圧変化で気体がする仕事(W = pΔV) | 圧力を $1.0 \times 10^{5}\,\mathrm{Pa}$ に保ったまま、気体の体積を $1.5\,\mathrm{L}$ から $2.5\,\mathrm{L}$ に膨張させた。気体が外部にした仕事を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.heat.work_isobaric.json) | あり |  |
| 物理 | 気体の内部エネルギー | 熱機関の熱効率 | ある熱機関が、高温の熱源から $1.0 \times 10^{3}\,\mathrm{J}$ の熱量を受け取り、低温の熱源に $6.0 \times 10^{2}\,\mathrm{J}$ の熱量を放出した。この熱機関がした仕事と熱効率を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.heat.thermal_efficiency.json) | あり |  |
| 物理 | 波の性質 | 波の基本式(v = fλ) | 振動数 $1.0\,\mathrm{Hz}$、波長 $0.80\,\mathrm{m}$ の波の速さと周期を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.wave.wave_speed.json) | あり |  |
| 物理 | 波の性質 | 正弦波の式から振幅・周期・波長・速さを読み取る | $x$ 軸の正の向きに進む正弦波が $y = 0.10\sin 2\pi\left(\frac{t}{0.40} - \frac{x}{1.00}\right)$ と表される($x$、$y$ の単位は m、$t$ の単位は s)。振幅、周期、波長、波の速さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.wave.sine_wave_reading.json) | あり |  |
| 物理 | 音 | 気温と音速(V = 331.5 + 0.6t) | 気温 $-8^{\circ}\mathrm{C}$ のとき、空気中を伝わる音の速さは何 m/s か。$V = 331.5 + 0.6t$ を用いて求めなさい。また、この音が $1.0\,\mathrm{s}$ の間に進む距離を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.wave.sound_speed_temperature.json) | あり |  |
| 物理 | 音 | うなりの回数 | 振動数 $268\,\mathrm{Hz}$ のおんさと振動数 $269\,\mathrm{Hz}$ のおんさを同時に鳴らした。1 秒間に聞こえるうなりの回数を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.wave.beats.json) | あり |  |
| 物理 | 音 | 弦の固有振動 | 両端を固定した長さ $0.40\,\mathrm{m}$ の弦を伝わる波の速さが $140\,\mathrm{m/s}$ である。この弦が基本振動をしているときの、波長と振動数を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.wave.string_harmonics.json) | あり |  |
| 物理 | 音 | 気柱の固有振動(閉管・開管) | 長さ $0.20\,\mathrm{m}$ の閉管が基本振動をしているときの、音波の波長と振動数を求めなさい。音の速さを $340\,\mathrm{m/s}$ とし、開口端補正は無視する。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.wave.closed_pipe.json) | あり |  |
| 物理 | 音 | ドップラー効果 | 振動数 $480\,\mathrm{Hz}$ の音を出す音源がある。観測者が、静止している音源から遠ざかるとき(動く速さは $15\,\mathrm{m/s}$)、観測者が聞く音の振動数を求めなさい。音の速さを $340\,\mathrm{m/s}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.wave.doppler.json) | あり |  |
| 物理 | 光 | 屈折の法則(屈折率と屈折角) | 光が空気中からある媒質に入射角 $45^{\circ}$ で入射し、屈折角 $30^{\circ}$ で屈折した。空気の屈折率を 1 として、この媒質の屈折率を求めなさい。また、空気中での波長が $4.4 \times 10^{-7}\,\mathrm{m}$ の光の、媒質中での波長を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.wave.refraction_index.json) | あり |  |
| 物理 | 光 | 全反射の臨界角(sin θ₀ = 1/n) | 屈折率 $1.25$ の媒質から空気(屈折率 1)へ光が進むときの臨界角を $\theta_{0}$ とする。$\sin\theta_{0}$ の値を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.wave.critical_angle.json) | あり |  |
| 物理 | 光 | レンズの式と倍率(凸レンズ) | 焦点距離 $5.0\,\mathrm{cm}$ の凸レンズの前方 $10\,\mathrm{cm}$ の位置に物体を置いた。像ができる位置(レンズからの距離)と倍率を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.wave.lens_formula.json) | あり |  |
| 物理 | 光 | ヤングの実験(明線の間隔) | 間隔 $0.10\,\mathrm{mm}$ の複スリットに波長 $4.0 \times 10^{-7}\,\mathrm{m}$ の単色光を当て、スリットから $1.5\,\mathrm{m}$ 離れたスクリーン上に干渉じまを作った。隣り合う明線の間隔を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.wave.young_double_slit.json) | あり |  |
| 物理 | 光 | 回折格子(d sin θ = mλ) | 回折格子に波長 $4.5 \times 10^{-7}\,\mathrm{m}$ の単色光を垂直に当てたところ、入射方向と $30^{\circ}$ の角をなす方向に $1$ 次の明線が観測された。格子定数(隣り合うスリットの間隔)を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.wave.diffraction_grating.json) | あり |  |
| 物理 | 波の性質 | y-x グラフ・y-t グラフから波長・周期を読み取る | 図の正弦波の波長と振幅を読み取りなさい。(図) | なし | — | 問題文にグラフが要る。書式は文と式だけを作る |
| 物理 | 光 | レンズによる像を作図する | 凸レンズによる物体の像を作図しなさい。 | なし | — | 答えが図で、数字を入れ替える計算ではない |
| 物理 | 電場と電位 | クーロンの法則 | $2.0\,\mathrm{\mu C}$ と $2.0\,\mathrm{\mu C}$ の 2 つの点電荷が、$0.90\,\mathrm{m}$ 離れて置かれている。2 つの点電荷の間にはたらく静電気力の大きさを求めなさい。クーロンの法則の比例定数を $9.0 \times 10^{9}\,\mathrm{N \cdot m^{2}/C^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.coulomb_law.json) | あり |  |
| 物理 | 電場と電位 | 電場から受ける力(F = qE) | 強さ $2.0 \times 10^{3}\,\mathrm{N/C}$ の電場の中に置かれた $1.0\,\mathrm{\mu C}$ の点電荷が受ける力の大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.electric_field_force.json) | あり |  |
| 物理 | 電場と電位 | 点電荷がつくる電場と電位 | $2.0\,\mathrm{\mu C}$ の点電荷から $0.20\,\mathrm{m}$ 離れた点の、電場の強さと電位を求めなさい。電位の基準は無限遠とし、クーロンの法則の比例定数を $9.0 \times 10^{9}\,\mathrm{N \cdot m^{2}/C^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.point_charge_field_potential.json) | あり |  |
| 物理 | 電場と電位 | 一様な電場と電位差(V = Ed) | 間隔 $2.0\,\mathrm{cm}$ の平行な 2 枚の金属板の間に $30\,\mathrm{V}$ の電位差を与えた。金属板の間の一様な電場の強さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.uniform_field_potential.json) | あり |  |
| 物理 | 電場と電位 | 電場がする仕事(W = qV) | $1.0\,\mathrm{\mu C}$ の点電荷が、電位差 $80\,\mathrm{V}$ の 2 点間を、電位の高い点から低い点へ移動した。この間に電場がした仕事を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.work_by_field.json) | あり |  |
| 物理 | コンデンサー | コンデンサーの電気量(Q = CV) | 電気容量 $3.0\,\mathrm{\mu F}$ のコンデンサーに $35\,\mathrm{V}$ の電圧を加えた。たくわえられる電気量と静電エネルギーを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.capacitor_charge.json) | あり |  |
| 物理 | コンデンサー | コンデンサーの合成容量 | 電気容量 $1.0\,\mathrm{\mu F}$ と $2.0\,\mathrm{\mu F}$ のコンデンサーを並列に接続した。合成容量を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.capacitor_combined.json) | あり |  |
| 物理 | コンデンサー | 平行板コンデンサーの電気容量の変化 | 電気容量 $3.0\,\mathrm{pF}$ の平行板コンデンサーがある。極板の面積を $2$ 倍、極板の間隔を $2$ 倍にし、極板間を比誘電率 $5$ の誘電体で満たしたときの電気容量を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.parallel_plate_capacitance.json) | あり |  |
| 物理 | 電流 | 電流と電気量(I = Q/t) | 導線に $0.30\,\mathrm{A}$ の電流が $1.0 \times 10^{2}\,\mathrm{s}$ 間流れた。導線の断面を通過した電気量を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.current_definition.json) | あり |  |
| 物理 | 電流 | オームの法則(V = RI) | 抵抗値 $15\,\mathrm{\Omega }$ の抵抗に $4.5\,\mathrm{V}$ の電圧を加えた。流れる電流の大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.ohm_law.json) | あり |  |
| 物理 | 電流 | 抵抗率と抵抗(R = ρL/S) | 抵抗率 $1.7 \times 10^{-8}\,\mathrm{\Omega  \cdot m}$ の銅でできた、長さ $4.0\,\mathrm{m}$、断面積 $0.50\,\mathrm{mm^{2}}$ の導線の抵抗値を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.resistivity.json) | あり |  |
| 物理 | 電流 | 合成抵抗(直列・並列) | 抵抗値 $4.0\,\mathrm{\Omega }$ と $10\,\mathrm{\Omega }$ の 2 つの抵抗を直列に接続した。合成抵抗を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.resistors_combined.json) | あり |  |
| 物理 | 電流 | 直列回路の電流と各抵抗の電圧 | 抵抗値 $5.0\,\mathrm{\Omega }$ の抵抗 $R_{1}$ と $10\,\mathrm{\Omega }$ の抵抗 $R_{2}$ を直列に接続し、両端に $6.0\,\mathrm{V}$ の電圧を加えた。回路を流れる電流と、$R_{1}$ の両端の電圧を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.series_circuit_voltage.json) | あり |  |
| 物理 | 電流 | 電力とジュール熱 | 抵抗値 $10\,\mathrm{\Omega }$ の抵抗に $0.60\,\mathrm{A}$ の電流を $70\,\mathrm{s}$ 間流した。抵抗で消費される電力と、発生するジュール熱を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.electric_power.json) | あり |  |
| 物理 | 電流 | 電力量(kWh と J) | 消費電力 $1.0 \times 10^{2}\,\mathrm{W}$ の電気器具を $1.5\,\mathrm{h}$ 使用した。消費した電力量は何 kWh か。また、それは何 J か。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.energy_kwh.json) | あり |  |
| 物理 | 電流 | 電池の起電力と内部抵抗 | 起電力 $1.5\,\mathrm{V}$、内部抵抗 $0.40\,\mathrm{\Omega }$ の電池に、抵抗値 $6.0\,\mathrm{\Omega }$ の抵抗を接続した。回路を流れる電流と、電池の端子電圧を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.internal_resistance.json) | あり |  |
| 物理 | 電流と磁場 | 直線電流がつくる磁場(H = I/2πr) | 十分に長い直線状の導線に $1.0\,\mathrm{A}$ の電流が流れている。導線から $0.10\,\mathrm{m}$ 離れた点の磁場の強さを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.magnetic_field_wire.json) | あり |  |
| 物理 | 電流と磁場 | 電流が磁場から受ける力(F = IBL sin θ) | 磁束密度 $0.40\,\mathrm{T}$ の一様な磁場の中に、長さ $0.30\,\mathrm{m}$ の導線を磁場の向きと $60^{\circ}$ の角をなすように置き、$1.0\,\mathrm{A}$ の電流を流した。導線が磁場から受ける力の大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.force_on_current.json) | あり |  |
| 物理 | 電流と磁場 | ローレンツ力と円運動の半径 | 磁束密度 $0.0090\,\mathrm{T}$ の一様な磁場に垂直に、電子が速さ $2.0 \times 10^{6}\,\mathrm{m/s}$ で入射した。電子が受けるローレンツ力の大きさと、円運動の半径を求めなさい。電気素量を $1.6 \times 10^{-19}\,\mathrm{C}$、電子の質量を $9.1 \times 10^{-31}\,\mathrm{kg}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.lorentz_force.json) | あり |  |
| 物理 | 電磁誘導 | ファラデーの電磁誘導の法則 | $50$ 回巻きのコイルを貫く磁束が、$0.30\,\mathrm{s}$ の間に $0.0020\,\mathrm{Wb}$ だけ一様に変化した。コイルに生じる誘導起電力の大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.faraday_law.json) | あり |  |
| 物理 | 電磁誘導 | 磁場を横切る導体棒の誘導起電力(V = vBL) | 磁束密度 $0.40\,\mathrm{T}$ の一様な磁場に垂直な面内で、長さ $0.30\,\mathrm{m}$ の導体棒を、棒と磁場の両方に垂直な向きに速さ $1.0\,\mathrm{m/s}$ で動かした。導体棒に生じる誘導起電力の大きさを求めなさい。また、棒を抵抗値 $10\,\mathrm{\Omega }$ の抵抗につないだときに流れる電流の大きさを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.motional_emf.json) | あり |  |
| 物理 | 電磁誘導 | 自己誘導(V = L ΔI/Δt) | 自己インダクタンス $0.20\,\mathrm{H}$ のコイルを流れる電流が、$0.030\,\mathrm{s}$ の間に 0 から $1.0\,\mathrm{A}$ まで一様に増加した。コイルに生じる誘導起電力の大きさと、電流が $1.0\,\mathrm{A}$ のときにコイルにたくわえられているエネルギーを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.self_induction.json) | あり |  |
| 物理 | 交流 | 交流の実効値と最大値 | 実効値 $60.0\,\mathrm{V}$ の交流電圧を、抵抗値 $40\,\mathrm{\Omega }$ の抵抗に加えた。電圧の最大値、電流の実効値、平均の消費電力を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.ac_effective.json) | あり |  |
| 物理 | 交流 | 変圧器(電圧と巻数の比) | 一次コイルが $100$ 回巻き、二次コイルが $350$ 回巻きの変圧器がある。一次コイルに実効値 $100\,\mathrm{V}$ の交流電圧を加えたとき、二次コイルに生じる電圧の実効値を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.transformer.json) | あり |  |
| 物理 | 交流 | コイルとコンデンサーのリアクタンス | 周波数 $50\,\mathrm{Hz}$ の交流に対する、自己インダクタンス $0.20\,\mathrm{H}$ のコイルのリアクタンスと、電気容量 $30\,\mathrm{\mu F}$ のコンデンサーのリアクタンスを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.reactance.json) | あり |  |
| 物理 | 交流 | 共振周波数(f = 1/2π√(LC)) | 自己インダクタンス $1.0\,\mathrm{mH}$ のコイルと電気容量 $2.0\,\mathrm{\mu F}$ のコンデンサーからなる回路の共振周波数を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.resonance_frequency.json) | あり |  |
| 物理 | 交流 | 電磁波の波長と周波数(c = fλ) | 周波数 $2.0 \times 10^{6}\,\mathrm{Hz}$ の電磁波の、真空中での波長を求めなさい。真空中の光の速さを $3.0 \times 10^{8}\,\mathrm{m/s}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.em.electromagnetic_wave.json) | あり |  |
| 物理 | 原子 | 光子のエネルギー(E = hc/λ) | 波長 $3.2 \times 10^{-7}\,\mathrm{m}$ の光の光子 1 個のエネルギーを求めなさい。プランク定数を $6.6 \times 10^{-34}\,\mathrm{J \cdot s}$、真空中の光の速さを $3.0 \times 10^{8}\,\mathrm{m/s}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.atom.photon_energy.json) | あり |  |
| 物理 | 原子 | 光電効果(K = hν − W) | 仕事関数が $2.8\,\mathrm{eV}$ の金属に、光子のエネルギーが $4.4\,\mathrm{eV}$ の光を当てた。飛び出す光電子の運動エネルギーの最大値は何 eV か。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.atom.photoelectric_effect.json) | あり |  |
| 物理 | 原子 | ド・ブロイ波長(λ = h/mv) | 速さ $2.5 \times 10^{7}\,\mathrm{m/s}$ で運動する電子のド・ブロイ波長を求めなさい。プランク定数を $6.6 \times 10^{-34}\,\mathrm{J \cdot s}$、電子の質量を $9.1 \times 10^{-31}\,\mathrm{kg}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.atom.de_broglie.json) | あり |  |
| 物理 | 原子 | 半減期 | 半減期が $3$ 日の放射性原子核が、はじめ $32.0 \times 10^{20}$ 個あった。$3$ 日後に崩壊せずに残っている原子核の数を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.atom.half_life.json) | あり |  |
| 物理 | 原子 | 質量とエネルギーの等価性(E = mc²) | 核反応で質量が $2.0 \times 10^{-30}\,\mathrm{kg}$ だけ減少した。このとき放出されるエネルギーを求めなさい。真空中の光の速さを $3.0 \times 10^{8}\,\mathrm{m/s}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.atom.mass_energy.json) | あり |  |
| 物理 | 電場と電位 | 電気力線・等電位線を図示する | 正負の点電荷のまわりの電気力線の概形をかきなさい。 | なし | — | 答えが図で、数字を入れ替える計算ではない |
| 物理 | 電流 | キルヒホッフの法則で複雑な回路の電流を求める | 図の回路で、各抵抗を流れる電流を求めなさい。(図) | なし | — | 回路のつながりを図で示す必要がある。直列・並列と内部抵抗までは、文だけで書ける型にしてある |

## 物理 大学初年 物理

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 物理 | 力学(微積分を使う) | 位置の式から速度・加速度を求める | $x$ 軸上を運動する質点の位置が $x(t) = -4t^{3} - 4t^{2} - 6t$($x$ の単位は m、$t$ の単位は s)で表される。速度 $v(t)$ と加速度 $a(t)$ を求め、$t = 4\,\mathrm{s}$ での値も答えなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.univ.velocity_from_position.json) | あり |  |
| 物理 | 力学(微積分を使う) | 位置によって変わる力がする仕事(積分) | $x$ 軸上を運動する物体に、力 $F(x) = x^{2} + 1$($F$ の単位は N、$x$ の単位は m)がはたらいている。物体が $x = 0\,\mathrm{m}$ から $x = 4\,\mathrm{m}$ まで動く間に、この力がする仕事を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.univ.work_integral.json) | あり |  |
| 物理 | 力学(微積分を使う) | 空気抵抗を受ける落下の終端速度 | 質量 $0.040\,\mathrm{kg}$ の物体が、速さ $v$ に比例する空気抵抗 $kv$($k = 0.030\,\mathrm{kg/s}$)を受けながら落下している。終端速度を求めなさい。重力加速度の大きさを $9.8\,\mathrm{m/s^{2}}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.univ.terminal_velocity.json) | あり |  |
| 物理 | 剛体の回転 | 回転の運動エネルギー(½Iω²) | 質量 $1.0\,\mathrm{kg}$、半径 $0.20\,\mathrm{m}$ の一様な円板(中心軸のまわり)が、角速度 $20\,\mathrm{rad/s}$ で回転している。慣性モーメントと回転の運動エネルギーを求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.univ.moment_of_inertia_energy.json) | あり |  |
| 物理 | 剛体の回転 | 角運動量(L = Iω)と角運動量保存 | 慣性モーメント $1.0\,\mathrm{kg \cdot m^{2}}$ の物体が角速度 $3.0\,\mathrm{rad/s}$ で回転している。角運動量の大きさを求めなさい。また、外力のモーメントがはたらかないまま慣性モーメントが $1.5\,\mathrm{kg \cdot m^{2}}$ に変わったときの角速度を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.univ.angular_momentum.json) | あり |  |
| 物理 | 振動 | 単振動の微分方程式から角振動数と周期を求める | 質点の運動方程式が $\frac{d^{2}x}{dt^{2}} = -x$($x$ の単位は m、$t$ の単位は s)で与えられる。この単振動の角振動数 $\omega$ と周期 $T$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.univ.shm_angular_frequency.json) | あり |  |
| 物理 | 熱力学 | カルノーサイクルの熱効率 | 高温の熱源の温度が $400\,\mathrm{K}$、低温の熱源の温度が $275\,\mathrm{K}$ のカルノーサイクルの熱効率を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.univ.carnot_efficiency.json) | あり |  |
| 物理 | 熱力学 | エントロピーの変化(ΔS = Q/T) | 温度 $300\,\mathrm{K}$ の熱源から、可逆的に $3.0 \times 10^{2}\,\mathrm{J}$ の熱量を受け取った。系のエントロピーの変化を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.univ.entropy_change.json) | あり |  |
| 物理 | 熱力学 | 等温変化で理想気体がする仕事(W = nRT ln(V₂/V₁)) | $0.50\,\mathrm{mol}$ の理想気体を、温度 $300\,\mathrm{K}$ に保ったまま体積を $5$ 倍に膨張させた。気体が外部にした仕事を求めなさい。気体定数を $8.31\,\mathrm{J/(mol \cdot K)}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.univ.isothermal_work.json) | あり |  |
| 物理 | 電気回路 | RC 回路の時定数 | 抵抗値 $6.0\,\mathrm{k\Omega}$ の抵抗と電気容量 $16\,\mathrm{\mu F}$ のコンデンサーを直列につないだ回路の時定数を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.univ.rc_time_constant.json) | あり |  |
| 物理 | 電気回路 | LC 回路の電気振動の周期 | 自己インダクタンス $1.0\,\mathrm{mH}$ のコイルと電気容量 $2.0\,\mathrm{\mu F}$ のコンデンサーからなる回路の電気振動の周期を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.univ.lc_oscillation_period.json) | あり |  |
| 物理 | 電磁気学 | ガウスの法則(一様に帯電した球の外側の電場) | 全電荷 $2.0\,\mathrm{nC}$ が一様に分布した球がある。球の中心から $0.30\,\mathrm{m}$ 離れた、球の外側の点の電場の強さを求めなさい。真空の誘電率を $8.85 \times 10^{-12}\,\mathrm{C^{2}/(N \cdot m^{2})}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.univ.gauss_sphere_field.json) | あり |  |
| 物理 | 単位と次元 | 速さの単位換算(km/h と m/s) | $27\,\mathrm{km/h}$ は何 m/s か。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.unit.speed_conversion.json) | あり |  |
| 物理 | 単位と次元 | 密度の単位換算(g/cm³ と kg/m³) | $1.20\,\mathrm{g/cm^{3}}$ は何 $\mathrm{kg/m^{3}}$ か。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.unit.density_conversion.json) | あり |  |
| 物理 | 単位と次元 | エネルギーの単位換算(kWh・J) | $1.5\,\mathrm{kWh}$ は何 J か。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.unit.energy_conversion.json) | あり |  |
| 物理 | 単位と次元 | 接頭語のついた単位の換算 | $1.5\,\mathrm{km}$ を、単位 $\mathrm{m}$ で表しなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.unit.prefix_conversion.json) | なし |  |
| 物理 | 単位と次元 | 組立単位を SI 基本単位で表す(次元の確認) | 仕事・エネルギーの単位 $\mathrm{J}$ を、SI 基本単位(m、kg、s、A、K、mol)だけで表しなさい。 | [あり](../../striusTests/Fixtures/drill-templates/physics/physics.unit.si_base_units.json) | なし |  |
| 物理 | 単位と次元 | 次元解析で公式の指数を決める | 単振り子の周期 T が長さ L と重力加速度 g だけで決まるとして、T ∝ L^a g^b の a、b を次元解析で求めなさい。 | なし | — | 数字を入れ替える所が無く、型にすると毎回同じ問題になる(関係する量の組を選ぶ所が問題の本体) |
| 物理 | 力学(微積分を使う) | 運動方程式を立てて解く(束縛のある系) | 斜面上を転がる円柱の加速度を、並進と回転の運動方程式から求めなさい。 | なし | — | 式を立てて連立して整理する過程が答えで、数字を入れ替えても式の変形が要る(数式処理は作らない)。結果の公式に数を入れる所は、円運動や回転のエネルギーの型にしてある |

## 化学 高校 化学基礎

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 化学 | 物質の構成 | 同位体の存在比から原子量を求める | 塩素には、相対質量 $35$ の同位体が $30\%$、相対質量 $37$ の同位体が $70\%$ の割合で存在するとする。このときの塩素の原子量を、小数第 1 位まで求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.average_atomic_mass.json) | あり |  |
| 化学 | 物質量と化学反応式 | 分子量・式量の計算 | $\mathrm{CO_2}$ の分子量(または式量)を求めなさい。原子量は H = 1.0、C = 12、N = 14、O = 16、Na = 23、S = 32、Cl = 35.5、Ca = 40 とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.formula_weight.json) | なし |  |
| 化学 | 物質量と化学反応式 | 質量から物質量を求める | 水 $\mathrm{H_2O}$(モル質量 $18\,\mathrm{g/mol}$)$9.9\,\mathrm{g}$ の物質量を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.mass_to_moles.json) | あり |  |
| 化学 | 物質量と化学反応式 | 物質量から質量を求める | 水 $\mathrm{H_2O}$(モル質量 $18\,\mathrm{g/mol}$)$0.55\,\mathrm{mol}$ の質量を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.moles_to_mass.json) | あり |  |
| 化学 | 物質量と化学反応式 | 物質量と粒子の数(アボガドロ定数) | 塩化ナトリウム $\mathrm{NaCl}$ $0.85\,\mathrm{mol}$ にふくまれる分子(または組成式の単位)の数を求めなさい。アボガドロ定数を $6.0 \times 10^{23}\,\mathrm{/mol}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.particles.json) | あり |  |
| 化学 | 物質量と化学反応式 | 標準状態の気体の体積と物質量 | 二酸化炭素 $\mathrm{CO_2}$ $0.55\,\mathrm{mol}$ が標準状態で占める体積を求めなさい。標準状態での気体のモル体積を $22.4\,\mathrm{L/mol}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.gas_volume_stp.json) | あり |  |
| 化学 | 物質量と化学反応式 | 質量パーセント濃度 | 水 $80\,\mathrm{g}$ に溶質 $5.0\,\mathrm{g}$ を溶かした水溶液の質量パーセント濃度を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.mass_percent.json) | あり |  |
| 化学 | 物質量と化学反応式 | モル濃度(溶質の質量と溶液の体積から) | 塩化ナトリウム $\mathrm{NaCl}$(モル質量 $58.5\,\mathrm{g/mol}$)$12\,\mathrm{g}$ を水に溶かして $200\,\mathrm{mL}$ にした。この水溶液のモル濃度を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.molarity.json) | あり |  |
| 化学 | 物質量と化学反応式 | 決まったモル濃度の水溶液をつくるのに必要な溶質の質量 | $0.40\,\mathrm{mol/L}$ の塩化ナトリウム水溶液を $200\,\mathrm{mL}$ つくるのに必要な塩化ナトリウム $\mathrm{NaCl}$(モル質量 $58.5\,\mathrm{g/mol}$)の質量を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.solution_preparation.json) | あり |  |
| 化学 | 物質量と化学反応式 | 水溶液の希釈 | $1.5\,\mathrm{mol/L}$ の塩酸を水でうすめて、$0.40\,\mathrm{mol/L}$ の塩酸を $100\,\mathrm{mL}$ つくりたい。もとの塩酸は何 mL 必要か。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.dilution.json) | あり |  |
| 化学 | 物質量と化学反応式 | 質量パーセント濃度からモル濃度への換算 | 質量パーセント濃度 $36.5\%$、密度 $1.18\,\mathrm{g/cm^{3}}$ の塩酸(塩化水素)の水溶液がある。溶質 $\mathrm{HCl}$ のモル質量を $36.5\,\mathrm{g/mol}$ として、モル濃度を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.percent_to_molarity.json) | あり |  |
| 化学 | 物質量と化学反応式 | 化学反応式の係数を合わせる | プロパンの完全燃焼について、次の式に係数を付けて化学反応式を完成させなさい。 $\mathrm{C_3H_8} + \mathrm{O_2} \longrightarrow \mathrm{CO_2} + \mathrm{H_2O}$ | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.balance_equation.json) | なし |  |
| 化学 | 物質量と化学反応式 | 炭化水素の完全燃焼の係数(一般式) | 炭化水素 $\mathrm{CH}_{4}$ 1 mol を完全燃焼させたとき、必要な酸素の物質量と、生じる二酸化炭素と水の物質量を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.combustion_alkane_coefficients.json) | あり |  |
| 化学 | 物質量と化学反応式 | 化学反応の量的関係(質量から質量) | メタン CH₄ を完全燃焼させた。反応したメタンが $6.4\,\mathrm{g}$ のとき、生じる水の質量を求めなさい。モル質量はメタン $16\,\mathrm{g/mol}$、水 $18\,\mathrm{g/mol}$ とする。 $\mathrm{CH_4} + 2\mathrm{O_2} \longrightarrow \mathrm{CO_2} + 2\mathrm{H_2O}$ | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.stoichiometry_mass_mass.json) | あり |  |
| 化学 | 物質量と化学反応式 | 化学反応の量的関係(質量から気体の体積) | 亜鉛 Zn を希硫酸に完全に溶かした。反応した亜鉛が $26\,\mathrm{g}$ のとき、発生する水素の標準状態での体積を求めなさい。亜鉛のモル質量を $65\,\mathrm{g/mol}$、標準状態での気体のモル体積を $22.4\,\mathrm{L/mol}$ とする。 $\mathrm{Zn} + \mathrm{H_2SO_4} \longrightarrow \mathrm{ZnSO_4} + \mathrm{H_2}$ | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.stoichiometry_mass_gas.json) | あり |  |
| 化学 | 物質量と化学反応式 | 過不足のある反応(どちらが残るか) | 水素 $0.20\,\mathrm{mol}$ と酸素 $0.30\,\mathrm{mol}$ を混ぜて点火し、完全に反応させた。生じた水の物質量と、反応せずに残った気体の種類と物質量を求めなさい。 $2\mathrm{H_2} + \mathrm{O_2} \longrightarrow 2\mathrm{H_2O}$ | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.limiting_reagent.json) | あり |  |
| 化学 | 酸と塩基 | 強酸の水溶液の pH | $0.10\,\mathrm{mol/L}$ の塩酸の pH を求めなさい。ただし、塩酸は完全に電離しているものとする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.ph_strong_acid.json) | あり |  |
| 化学 | 酸と塩基 | 強塩基の水溶液の pH | $0.10\,\mathrm{mol/L}$ の水酸化ナトリウム水溶液の pH を求めなさい。ただし、水酸化ナトリウムは完全に電離しているものとし、水のイオン積を $1.0 \times 10^{-14}\,(\mathrm{mol/L})^{2}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.ph_strong_base.json) | あり |  |
| 化学 | 酸と塩基 | 水素イオン濃度から pH を求める(log を使う) | 水素イオン濃度が $[\mathrm{H^{+}}] = 2.0 \times 10^{-2}\,\mathrm{mol/L}$ の水溶液の pH を、小数第 1 位まで求めなさい。$\log_{10} 2 = 0.30$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.ph_from_concentration.json) | あり |  |
| 化学 | 酸と塩基 | 中和滴定(濃度を求める) | 濃度のわからない塩酸 $10.0\,\mathrm{mL}$ を、$0.0800\,\mathrm{mol/L}$ の水酸化ナトリウム水溶液で滴定したところ、中和点までに $25.0\,\mathrm{mL}$ を要した。この塩酸のモル濃度を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.neutralization_titration.json) | あり |  |
| 化学 | 酸化還元反応 | 酸化数を求める | $\mathrm{SO_2}$ の中の $\mathrm{S}$ 原子の酸化数を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.oxidation_number.json) | なし |  |
| 化学 | 酸化還元反応 | 酸化還元滴定(過マンガン酸カリウム) | 硫酸で酸性にした過酸化水素水 $10.0\,\mathrm{mL}$ を、$0.015\,\mathrm{mol/L}$ の過マンガン酸カリウム水溶液で滴定したところ、$25.0\,\mathrm{mL}$ を加えた所で赤紫色が消えなくなった。過酸化水素水のモル濃度を求めなさい。過マンガン酸イオン 1 mol は電子 5 mol を受け取り、過酸化水素水の溶質 1 mol は電子 $2$ mol を与える。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.redox_titration.json) | あり |  |
| 化学 | 酸化還元反応 | 電気分解の量的関係(ファラデーの法則) | $\mathrm{Ni^{2+}}$ をふくむ水溶液を、$1.00\,\mathrm{A}$ の電流で $1.93 \times 10^{3}\,\mathrm{s}$ 間電気分解した。流れた電子の物質量と、陰極に析出するニッケルの質量を求めなさい。ファラデー定数を $9.65 \times 10^{4}\,\mathrm{C/mol}$、ニッケルのモル質量を $58.7\,\mathrm{g/mol}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.basic.faraday_electrolysis.json) | あり |  |
| 化学 | 物質の構成 | 電子配置・電子式を書く | 塩素原子の電子配置と、塩化水素の電子式を書きなさい。 | なし | — | 答えが図(電子式)や決まった配置の暗記で、数字を入れ替える計算ではない |
| 化学 | 物質量と化学反応式 | 反応物と生成物から化学反応式を自分で書く | アルミニウムと希硫酸の反応を化学反応式で表しなさい。 | なし | — | 生成物を化学の知識から決める所が答えで、数字を入れ替える計算ではない(係数を合わせる所は、反応の表から出す型にしてある) |

## 化学 高校 化学

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 化学 | 物質の状態 | 気体の状態方程式(物質量を求める) | $127^{\circ}\mathrm{C}$、$1.5 \times 10^{5}\,\mathrm{Pa}$ で体積が $5.0\,\mathrm{L}$ の気体の物質量を求めなさい。気体定数を $8.3 \times 10^{3}\,\mathrm{Pa \cdot L/(K \cdot mol)}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.ideal_gas_moles.json) | あり |  |
| 化学 | 物質の状態 | 気体の密度・質量から分子量を求める | ある気体 $1.9\,\mathrm{g}$ は、$127^{\circ}\mathrm{C}$、$1.5 \times 10^{5}\,\mathrm{Pa}$ で $1.5\,\mathrm{L}$ の体積を占める。この気体の分子量を求めなさい。気体定数を $8.3 \times 10^{3}\,\mathrm{Pa \cdot L/(K \cdot mol)}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.molar_mass_from_gas.json) | あり |  |
| 化学 | 物質の状態 | 混合気体の分圧(ドルトンの分圧の法則) | 窒素 $0.10\,\mathrm{mol}$ と酸素 $0.20\,\mathrm{mol}$ の混合気体の全圧が $1.5 \times 10^{5}\,\mathrm{Pa}$ である。窒素のモル分率と分圧を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.partial_pressure.json) | あり |  |
| 化学 | 物質の状態 | 沸点上昇・凝固点降下(Δt = K m) | 水 $100\,\mathrm{g}$ に非電解質 $0.040\,\mathrm{mol}$ を溶かした水溶液の沸点上昇度を求めなさい。水のモル沸点上昇を $0.52\,\mathrm{K \cdot kg/mol}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.boiling_point_elevation.json) | あり |  |
| 化学 | 物質の状態 | 浸透圧(Π = cRT) | $17^{\circ}\mathrm{C}$ で、モル濃度 $0.040\,\mathrm{mol/L}$ の非電解質の水溶液の浸透圧を求めなさい。気体定数を $8.3 \times 10^{3}\,\mathrm{Pa \cdot L/(K \cdot mol)}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.osmotic_pressure.json) | あり |  |
| 化学 | 物質の状態 | 溶解度と析出量 | ある物質の溶解度(水 100 g に溶ける質量)は、60℃ で $60$、20℃ で $15$ である。60℃ の水 $100\,\mathrm{g}$ にこの物質を溶かして飽和水溶液をつくり、20℃ まで冷やした。析出する結晶の質量を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.solubility_crystallization.json) | あり |  |
| 化学 | 物質の状態 | ヘンリーの法則 | ある気体は、ある温度で圧力が $1.0 \times 10^{5}\,\mathrm{Pa}$ のとき、水 1.0 L に $1.0 \times 10^{-3}\,\mathrm{mol}$ 溶ける。同じ温度で、圧力 $2.5 \times 10^{5}\,\mathrm{Pa}$ のこの気体が水 $1.5\,\mathrm{L}$ に接しているとき、溶ける気体の物質量を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.henry_law.json) | あり |  |
| 化学 | 化学反応とエネルギー | ヘスの法則(生成エンタルピーから反応エンタルピーを求める) | メタン $\mathrm{CH_4}$ の生成エンタルピーは $-75\,\mathrm{kJ/mol}$、二酸化炭素と水の生成エンタルピーはそれぞれ $-394\,\mathrm{kJ/mol}$、$-286\,\mathrm{kJ/mol}$ である。メタン 1 mol が完全燃焼するときの反応エンタルピー(燃焼エンタルピー)を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.hess_formation.json) | あり |  |
| 化学 | 化学反応とエネルギー | 温度変化から反応で出入りした熱量を求める | ある物質 $0.030\,\mathrm{mol}$ を水に溶かしたところ、水溶液 $100\,\mathrm{g}$ の温度が $3.5\,\mathrm{K}$ 上昇した。発生した熱量と、この物質 1 mol あたりの発熱量を求めなさい。水溶液の比熱を $4.2\,\mathrm{J/(g \cdot K)}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.calorimetry_reaction.json) | あり |  |
| 化学 | 化学反応とエネルギー | 結合エネルギーから反応エンタルピーを求める | H–H、塩素分子の結合、H と塩素原子の結合の結合エネルギーは、それぞれ $433\,\mathrm{kJ/mol}$、$243\,\mathrm{kJ/mol}$、$432\,\mathrm{kJ/mol}$ である。次の反応の反応エンタルピーを求めなさい。 $\mathrm{H_2} + \mathrm{Cl_2} \longrightarrow 2\mathrm{HCl}$ | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.bond_energy.json) | あり |  |
| 化学 | 化学反応とエネルギー | 電池から取り出せる電気量と反応する物質の量 | ダニエル電池から $0.40\,\mathrm{A}$ の電流を $1.93 \times 10^{3}\,\mathrm{s}$ 間取り出した。流れた電気量、電子の物質量、溶け出した亜鉛の質量を求めなさい。ファラデー定数を $9.65 \times 10^{4}\,\mathrm{C/mol}$、亜鉛のモル質量を $65.4\,\mathrm{g/mol}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.battery_charge.json) | あり |  |
| 化学 | 化学反応の速さと平衡 | 平均の反応速度 | ある反応で、反応物の濃度が $20\,\mathrm{s}$ の間に $0.50\,\mathrm{mol/L}$ から $0.40\,\mathrm{mol/L}$ に減少した。この間の平均の反応速度を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.reaction_rate_average.json) | あり |  |
| 化学 | 化学反応の速さと平衡 | 反応速度式から速度定数を求める | 反応速度式が $v = k[\mathrm{A}]$ で表される反応がある。$[\mathrm{A}] = 0.20\,\mathrm{mol/L}$ のとき、反応速度は $1.0 \times 10^{-3}\,\mathrm{mol/(L \cdot s)}$ であった。速度定数 $k$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.rate_law.json) | あり |  |
| 化学 | 化学反応の速さと平衡 | 平衡定数を求める | ある温度で $\mathrm{H_2} + \mathrm{I_2}$ ⇄ $2\mathrm{HI}$ の反応が平衡状態にあり、各物質の濃度は $[\mathrm{H_2}] = 0.10\,\mathrm{mol/L}$、$[\mathrm{I_2}] = 0.20\,\mathrm{mol/L}$、$[\mathrm{HI}] = 1.00\,\mathrm{mol/L}$ であった。この温度での平衡定数 $K$ を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.equilibrium_constant.json) | あり |  |
| 化学 | 化学反応の速さと平衡 | 平衡定数から平衡時の物質量を求める | 体積一定の容器に水素とヨウ素を $0.50\,\mathrm{mol}$ ずつ入れ、ある温度に保ったところ、$\mathrm{H_2} + \mathrm{I_2}$ ⇄ $2\mathrm{HI}$ の反応が平衡状態になった。この温度での平衡定数が $4$ であるとき、平衡時のヨウ化水素の物質量を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.equilibrium_amounts.json) | あり |  |
| 化学 | 化学反応の速さと平衡 | 弱酸の電離度と pH | 濃度 $0.10\,\mathrm{mol/L}$ の酢酸の水溶液がある。電離度が $0.010$ のとき、水素イオン濃度と pH を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.weak_acid_ph.json) | あり |  |
| 化学 | 化学反応の速さと平衡 | 電離定数から弱酸の水素イオン濃度を求める | 電離定数が $K_{a} = 1.0 \times 10^{-5}\,\mathrm{mol/L}$ の弱酸の $0.10\,\mathrm{mol/L}$ 水溶液の水素イオン濃度を求めなさい。電離度は 1 に比べて十分小さいものとする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.weak_acid_ka.json) | あり |  |
| 化学 | 化学反応の速さと平衡 | 溶解度積から溶解度を求める | 塩化銀 $\mathrm{AgCl}$ の溶解度積を $K_{sp} = 1.8 \times 10^{-10}\,(\mathrm{mol/L})^{2}$ とする。塩化銀の飽和水溶液のモル濃度を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.solubility_product.json) | あり |  |
| 化学 | 有機化合物 | 元素分析から組成式を求める | 炭素、水素、酸素だけからなる有機化合物 $300\,\mathrm{mg}$ を完全燃焼させたところ、二酸化炭素 $440\,\mathrm{mg}$ と水 $180\,\mathrm{mg}$ が生じた。この化合物の組成式を求めなさい。原子量は H = 1.0、C = 12、O = 16 とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.elemental_analysis.json) | あり |  |
| 化学 | 有機化合物 | 組成式と分子量から分子式を求める | 組成式が $\mathrm{CH_2O}$(式量 $30$)で、分子量が $60$ の化合物がある。分子式は組成式を何倍したものか。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.molecular_formula.json) | あり |  |
| 化学 | 物質の状態 | ボイル・シャルルの法則 | $27^{\circ}\mathrm{C}$、$1.0 \times 10^{5}\,\mathrm{Pa}$ で体積が $2.0\,\mathrm{L}$ の気体を、$127^{\circ}\mathrm{C}$、$4.0 \times 10^{5}\,\mathrm{Pa}$ にしたときの体積を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.combined_gas_law.json) | あり |  |
| 化学 | 物質の状態 | 水上置換で集めた気体の分圧と物質量 | 水上置換で気体を集めたところ、$27^{\circ}\mathrm{C}$、大気圧 $99.0\,\mathrm{kPa}$ で体積は $1.0\,\mathrm{L}$ であった。$27^{\circ}\mathrm{C}$ の水の蒸気圧を $3.6\,\mathrm{kPa}$ として、集めた気体の分圧と物質量を求めなさい。気体定数を $8.3 \times 10^{3}\,\mathrm{Pa \cdot L/(K \cdot mol)}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.gas_over_water.json) | あり |  |
| 化学 | 物質の状態 | 単位格子から結晶の密度を求める | 銅の結晶は面心立方格子で、単位格子の一辺の長さは $3.5 \times 10^{-8}\,\mathrm{cm}$ である。銅の結晶の密度を求めなさい。銅のモル質量を $63.5\,\mathrm{g/mol}$、アボガドロ定数を $6.0 \times 10^{23}\,\mathrm{/mol}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.unit_cell_density.json) | あり |  |
| 化学 | 化学反応の速さと平衡 | 電離定数から弱酸の電離度を求める | 電離定数が $K_{a} = 1.0 \times 10^{-5}\,\mathrm{mol/L}$ の弱酸の $0.10\,\mathrm{mol/L}$ 水溶液における電離度 $\alpha$ を求めなさい。$\alpha$ は 1 に比べて十分小さいものとする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.degree_of_ionization.json) | あり |  |
| 化学 | 化学反応とエネルギー | 鉛蓄電池の放電による電極の質量変化 | 鉛蓄電池を放電して、電子 $0.20\,\mathrm{mol}$ が流れた。負極と正極の質量は、それぞれ何 g 増加するか。原子量は O = 16、S = 32 とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.lead_storage_battery.json) | あり |  |
| 化学 | 高分子化合物 | 平均分子量から重合度を求める | 平均分子量が $28000$ のポリエチレンがある。繰り返し単位 $\mathrm{C_2H_4}$ の式量を $28$ として、平均の重合度を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.theory.degree_of_polymerization.json) | あり |  |
| 化学 | 有機化合物 | 構造式を書く・異性体を数え上げる | 分子式 C₄H₁₀O の構造異性体をすべて構造式で書きなさい。 | なし | — | 答えが構造式(図)で、数字を入れ替える計算ではない |
| 化学 | 化学反応の速さと平衡 | 滴定曲線から中和点や指示薬を読み取る | 滴定曲線から、適切な指示薬を選びなさい。(図) | なし | — | 問題文にグラフが要る。書式は文と式だけを作る |
| 化学 | 化学反応の速さと平衡 | ルシャトリエの原理で平衡の移動の向きを判断する | N₂ + 3H₂ ⇄ 2NH₃ の平衡で、圧力を上げると平衡はどちらに移動するか。 | なし | — | 計算ではなく、原理を当てはめて向きを判断する問題(概念の理解は対象外) |

## 化学 大学初年 化学

| 教科 | 分野 | 操作の名前 | 例題 | 型 | 数値点検 | 表せない理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 化学 | 反応速度論 | 1 次反応の半減期(t½ = ln 2 / k) | 速度定数が $k = 1.5 \times 10^{-2}\,\mathrm{/s}$ の 1 次反応の半減期を求めなさい。$\ln 2 = 0.693$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.univ.first_order_half_life.json) | あり |  |
| 化学 | 反応速度論 | 1 次反応の濃度の時間変化 | 半減期が $20\,\mathrm{s}$ の 1 次反応で、はじめの濃度が $0.20\,\mathrm{mol/L}$ であった。$40\,\mathrm{s}$ 後の濃度を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.univ.first_order_remaining.json) | あり |  |
| 化学 | 反応速度論 | アレニウスの式から活性化エネルギーを求める | ある反応の速度定数は、温度を $280\,\mathrm{K}$ から $290\,\mathrm{K}$ に上げると $3$ 倍になった。この反応の活性化エネルギーを求めなさい。気体定数を $8.31\,\mathrm{J/(mol \cdot K)}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.univ.arrhenius_activation_energy.json) | あり |  |
| 化学 | 化学熱力学 | ギブズエネルギー変化(ΔG = ΔH − TΔS) | ある反応の $\Delta H = -180\,\mathrm{kJ/mol}$、$\Delta S = -220\,\mathrm{J/(mol \cdot K)}$ である。$300\,\mathrm{K}$ での $\Delta G$ を求め、この温度で反応が自発的に進むかどうかを答えなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.univ.gibbs_energy.json) | あり |  |
| 化学 | 化学熱力学 | 標準ギブズエネルギー変化から平衡定数を求める | ある反応の $298\,\mathrm{K}$ での標準ギブズエネルギー変化が $\Delta G^{\circ} = -28.0\,\mathrm{kJ/mol}$ である。$\Delta G^{\circ} = -RT\ln K$ を用いて、平衡定数の自然対数 $\ln K$ を求めなさい。気体定数を $8.31\,\mathrm{J/(mol \cdot K)}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.univ.equilibrium_from_gibbs.json) | あり |  |
| 化学 | 電気化学 | ネルンストの式 | 標準起電力が $1.10\,\mathrm{V}$ のダニエル電池(反応にかかわる電子は $2$ 個)で、反応商が $Q = 10^{-4}$ のときの起電力を、$E = E^{\circ} - \frac{0.0592}{n}\log_{10} Q$ を用いて求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.univ.nernst.json) | あり |  |
| 化学 | 酸と塩基の平衡 | 緩衝液の pH(ヘンダーソン・ハッセルバルヒの式) | 酢酸(p$K_{a}$ = $4.76$)が $0.30\,\mathrm{mol/L}$、その共役塩基が $0.030\,\mathrm{mol/L}$ ふくまれる緩衝液の pH を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.univ.buffer_ph.json) | あり |  |
| 化学 | 量子化学の基礎 | 光の波長から 1 mol あたりのエネルギーを求める | 波長 $220\,\mathrm{nm}$ の光の、光子 1 mol あたりのエネルギーを求めなさい。プランク定数を $6.63 \times 10^{-34}\,\mathrm{J \cdot s}$、光の速さを $3.00 \times 10^{8}\,\mathrm{m/s}$、アボガドロ定数を $6.02 \times 10^{23}\,\mathrm{/mol}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.univ.photon_energy_per_mole.json) | あり |  |
| 化学 | 気体 | 実在気体の圧縮因子(Z = PV/nRT) | ある実在気体 $1.0\,\mathrm{mol}$ が、$250\,\mathrm{K}$、$8.0\,\mathrm{MPa}$ で $0.60\,\mathrm{L}$ の体積を占めている。圧縮因子 $Z = \frac{PV}{nRT}$ を求めなさい。気体定数を $8.31\,\mathrm{J/(mol \cdot K)}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.univ.compression_factor.json) | あり |  |
| 化学 | 化学熱力学 | 相転移のエントロピー変化(ΔS = ΔH/T) | ある物質の蒸発エンタルピーは $5.0\,\mathrm{kJ/mol}$、沸点は $225\,\mathrm{K}$ である。沸点における蒸発のエントロピー変化を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.univ.entropy_phase_change.json) | あり |  |
| 化学 | 化学熱力学 | 内部エネルギー変化から反応エンタルピーを求める(ΔH = ΔU + ΔnRT) | ある反応の $298\,\mathrm{K}$ での内部エネルギー変化は $\Delta U = -900\,\mathrm{kJ}$ で、反応によって気体の物質量は $-3\,\mathrm{mol}$ 変化する。反応エンタルピー $\Delta H$ を求めなさい。気体は理想気体とし、気体定数を $8.31\,\mathrm{J/(mol \cdot K)}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.univ.enthalpy_from_internal_energy.json) | あり |  |
| 化学 | 化学熱力学 | クラウジウス・クラペイロンの式から蒸発エンタルピーを求める | ある液体の蒸気圧は、温度を $300\,\mathrm{K}$ から $310\,\mathrm{K}$ に上げると $2$ 倍になった。蒸発エンタルピーを求めなさい。気体定数を $8.31\,\mathrm{J/(mol \cdot K)}$、$\ln 2 = 0.693$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.univ.clausius_clapeyron.json) | あり |  |
| 化学 | 分析化学の基礎 | ランベルト・ベールの法則(A = εcl) | モル吸光係数が $6.5 \times 10^{4}\,\mathrm{L/(mol \cdot cm)}$ の物質の、濃度 $1.0 \times 10^{-5}\,\mathrm{mol/L}$ の溶液を、光路長 $1.0\,\mathrm{cm}$ のセルに入れた。吸光度を求めなさい。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.univ.beer_lambert.json) | あり |  |
| 化学 | 溶液 | 質量モル濃度とモル分率 | グルコース(モル質量 $180\,\mathrm{g/mol}$)$36.0\,\mathrm{g}$ を水 $100\,\mathrm{g}$ に溶かした。この溶液の質量モル濃度と、グルコースのモル分率を求めなさい。水のモル質量を $18\,\mathrm{g/mol}$ とする。 | [あり](../../striusTests/Fixtures/drill-templates/chemistry/chemistry.univ.molality.json) | あり |  |
| 化学 | 量子化学の基礎 | 電子配置と軌道図を書く | 鉄原子の電子配置を書きなさい。 | なし | — | 決まった配置を書く問題で、数字を入れ替える計算ではない(暗記事項は対象外) |
| 化学 | 有機化学 | 反応機構を矢印で書く | SN2 反応の機構を、電子の動きを示す矢印を使って書きなさい。 | なし | — | 答えが図で、数字を入れ替える計算ではない |
