# struis-ios 検証と配信の方針

- 改訂: 2026-11-06(Issue #81: main のルールセットで PR と `Struis / verify` を必須にした。人の PR も同じ検証を通す。見た目だけの変更を Release archive だけで通す経路と、前提のある作業の起点を足した。GitHub のマージキューは組織のリポジトリでしか使えず、DigiLog-lab は個人のアカウントなので使わない)
- 前回: 2026-11-02(門を、Ready の HEAD を固定して見張る仕組みから、最新の main を含んだ HEAD を1回検証する形に変えた。チェックポイントと自動再開、Xcode Cloud の予備をやめた)
- 対象: DigiLog-lab/struis-ios の Issue エージェント、GitHub Actions
- 仕組みの説明は [agent.md](agent.md)、テストの選び方は [testing.md](testing.md) です。

## 方針

1. **確かめたものと、main に入るものを一致させる。** 検証は、最新の main を取り込んだ PR の HEAD に対して行います。main が先に進んだら、PR に取り込み直して検証し直します。古い main の上で緑だったものはマージしません。
2. **不具合を見つけて直すのはエージェント(手元検証)、マージしてよいかを決めるのは検証(`ios.yml`)。** 検証はエージェントの外で、main にある定義で流れ、エージェントは結果を変えられません。
3. **テストは品質の門。** 赤は skip・期待失敗化・判定の緩和・再実行で通さず、止めて直します。保険的な定期実行(夜間・週次の全件)はしません。
4. **runner はエージェントの作業に使う。** それ以外で macOS runner を使うのは、native cache の作成、PR の検証、プロトタイプ、main からの配信だけです。
5. **止まったら人が再開する。** 自動再開もチェックポイントもありません。指示を細かく出すので、1回の実行が上限(Claude の step 300分)に近づくことは想定しません。

## 流れ

| 段階 | どこで | 何をするか |
|---|---|---|
| 作業の開始 | `agent.yml` の `worker` | 作業ブランチに最新の main を取り込む(衝突したら最初に解消させる) |
| 手元検証 | エージェントの runner(`agentctl local-verify`) | push 済み HEAD で、全単体テスト＋変更に関係する UI テスト。失敗したテストと失敗メッセージを返す |
| Ready | `agentctl ready` | HEAD が push 済み・最新の main を含む・手元検証が緑、の3つを確かめ、PR をレビュー待ちにする。検証は起動しない(持ち主が自動マージを有効にすると、マージキューが起動する) |
| 検証 | `ios.yml`(`Verify PR #<n> <sha>`) | 最初にその SHA へ `Struis / verify` を「実行中(pending)」で付け、PR に検証中と出す。main の定義で、その SHA の native cache 確認 → 単体テスト全部(UI テストは門で流さない。2026-11-11 から)、と並行して Release archive |
| 報告 | `agent.yml` の `report`(Linux、main のコードだけ) | commit status `Struis / verify` をその SHA に書く。HEAD のままなら、緑は Issue に知らせ、赤は失敗を記録してエージェントを起こす。取り消された実行は `error` にし、誰も起こさない |
| マージ | 人 | PR の `Struis / verify` が緑であることを見てマージする |
| マージ | `merge-queue.yml`(Linux、`scripts/ci/merge_queue.py`) | 自動マージが有効な PR を1本ずつ、最新の main を取り込んでから `ios.yml` の `verify` で検証する。緑なら GitHub の自動マージがマージする。main が進むと、最新の main を含まない緑を pending に戻す(docs/development-method.md の「7. マージキュー」) |

- エージェントの worker には `statuses: write` も `actions: write` もありません。commit status を書けるのは `report` だけです。
- main のルールセット(「main: マージキュー(#81)」)が、PR 経由と `Struis / verify` の緑を必須にし、main の削除と強制 push を禁じます。`Struis / verify` を緑にするのは、マージキューが起動した検証だけです。
- 人(や web 版の Claude)が開いた PR も同じです。PR への push では検証は起動しません。持ち主が自動マージを有効にすると、マージキューが main の定義で検証します(Draft とフォークの PR は除く)。
- web 版の Claude が作業ブランチへ直接 push した時は、その HEAD の検証を同じ `verify` で起動します。

## 前提のある作業と並べ方

- Issue の本文に `前提: #<n>` と書くと、その Issue のエージェントは作業ブランチを `agent/issue-<n>`(前提の作業ブランチ)から切ります。前提がマージされてブランチが消えていれば main から切ります。前提の PR を先にマージします。
- 前提が無い作業は待たずに並べて進めます。エージェントは同時に3つまで(macOS runner 5台を、エージェント1台ずつと検証に2台で分けるため)。
- エージェントは、作業の途中で関係のない問題を見つけても直さず、返信に書きます(別の Issue にします)。

## 画面の描画だけの変更

- 差分が画面を描くファイルだけ(`scripts/ci/cosmetic.py` の `ALLOWED`、PR の版と main の版の両方が認める)の時、マージキューの検証は Release archive とシミュレータ向けのビルドだけを確かめ、`Struis / verify` に「画面の描画だけ」と出ます。ラベルは使いません(2026-11-07 から)。
- 変えた画面の iPhone と iPad のスクショ(動きが変わるなら録画)を最新の main と比べて PR に添え、持ち主はそれとコードを見てから自動マージを押します。会話のスクロールと固まり、オンボーディング、課金に関わる画面と、描画以外のファイルを含む変更は通常の検証です。
- 単体テストも UI テストも流さないので、この経路で入った変更は TestFlight に出す前に実機で確かめます(公開前の運用。公開後に見直します)。

## 配信

- TestFlight への配信は、main で `ios.yml` を手動実行して行います(全 UI テスト → `signed-archive`、`upload` で App Store Connect へ)。配信用の archive は、Actions cache を使わずに native 依存をソースから作ります。
- Ad Hoc のプロトタイプは `agent-prototype.yml` です([agent.md](agent.md))。
