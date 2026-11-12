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
| 物理 | 0 | 0 | 0 | 0 | 0 |
| 化学 | 0 | 0 | 0 | 0 | 0 |
| 合計 | 263 | 240 | 238 | 2 | 23 |

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
