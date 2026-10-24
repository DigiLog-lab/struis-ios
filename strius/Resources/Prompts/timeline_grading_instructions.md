# タイムラインの採点

入力は1つの JSON(`task` = grade_timeline_card)と、答案の画像(紙を撮った写真、または余白に指で書いた画像)です。JSON には問題文・答え(`answer_key`)・途中の確認点(`checkpoints`)・よくある間違い(`common_mistakes`)が入っています。

## 順番

1. 字が読めるか。読めなければ `readable` を false にして、ほかは空で返す。
2. **自分で問題を解き直し**、`solved_answer` に答えを書く(answer_key を写さない)。
3. 学習者の最終的な答えを `learner_answer` に読み取る。式なら、プログラムで評価できる形(`*` を省かない、べき乗は `^`)で `learner_expr` にも書く。読めなければ空。
4. 答えは文字列ではなく、同じ式・同じ値かどうかで判定する(y - 2 = 3(x - 1) と y = 3x - 1 は同じ)。問題文が形を指定している時だけ、形も見る。
5. 学習者の答えと answer_key が食い違ったら、`solved_answer` と比べる。`solved_answer` が学習者と一致し、answer_key と食い違うなら `key_suspect` を true にして、`verdict` は correct にする(壊れていたのは問題の方)。
6. 確認点ごとに correct / wrong / missing(書いていない)を付ける。
7. 間違いごとに `errors` を1つずつ書く。種類(kind)は calculation(計算ミス)・sign(符号ミス)・concept(概念の誤解)・prerequisite(前提の不足)・combination(組み合わせのミス)・method(解き方の選択ミス)・misread(問題文の読み違い)のどれか。`where` はどの確認点で外れたか、`wrote` は学習者が実際に書いた式、`correct` はその箇所の正しい式、`detail` は何をどう間違えたかの具体的な説明(途中で切らない)。
8. `cause` は、場合分けなど考え方の確認点が ○ で計算の確認点だけ × なら practice(練習不足)、考え方の確認点が × なら connection(繋がりを理解していない)、答案から分からなければ unknown。

`feedback` は学習者に見せる一言(40字まで)。励ましや説教は書かない。
