# 今回の仕事: 次の5枚

この生徒が次に解く5枚と、速攻用の3問を作ってください。

## 出力の形

- `reason`: この5枚にした理由。台帳に残ります。
- `cards[].kind`: カードの種類。solve(解いて撮る)・order(手順の並び替え)・find_error(間違い探し: `mistake_steps` の最初の行を、違う行として見せます)・compare(2つの解き方を比べる)・fill_line(1行だけ穴埋め)・next_step(次の一手を選ぶ)・graph_match(グラフと式を結ぶ)・sort(左右に仕分け)・predict(解く前に予想)・inverse(逆に作る)・reason(理由を選ぶ)。solve 以外は、`steps`・`mistake_steps`・`facts`・`compare`・`reason` からアプリが画面を組みます。
- `level`: 1〜4。今回の材料の `level_cap` があれば、それ以下にしてください(超えたカードは受け取れません)。
- `skills`: 今回の材料の `allowed_skill_ids` の ID だけ。グラフにない前提が要る時は `wanted_prerequisites` に書いてください。
- `subunit_id`: 単元ホームの小単元の演習に数える時の小単元の ID(今回の材料の `subunits`)。数えなければ null。
- `prompt`・`question`: 画面に出す日本語の文(文の中の式は `$…$`)。`math`: 画面に出す式(LaTeX)。
- `answer_key`: 正しい答え(区切りの無い LaTeX)。`answer_expr`・`checks`: プログラムで評価できる式(`*` を省かない、べき乗は `^`、関数は sqrt sin cos tan exp log abs、`pi`)。アプリが `checks` の両辺を数値で比べ、合わない・読めないカードは受け取りません。
- `steps`: 解き方の手順(1行ずつ)。採点の参考にもなります。`common_mistakes`・`mistake_steps`: よくある間違いと、手順の何行目がどう変わるか。
- `chain`: 「さっきの続き」の何問目か・全何問か・変えた所(`changed`。`prompt`・`math`・`question` のどこかにある文字列そのまま)・前の値(`previous`、LaTeX でよい)。
- `variant`: このカードを初めて間違えた時に次に出す、数値だけ変えた同じ形の問題。`easier`: やさしくした問題(画面では「一段戻す」と出ます)。
- `reveal`: 解き終わった後に、難しさを明かす言葉(この生徒の目標に合わせて)。明かさなければ空。
- `howto`: 生徒がまだ解いたことのないスキルを使うカードの「やり方の確認」。
- `rapid`: 速攻用の3問(10秒ほどで答えだけ)。
