# struis-ios 検証と配信の方針

- 改訂: 2026-11-06(Issue #81: 門をマージキューに移した。PR ごとの検証をやめ、キューで「最新の main＋先に並んだ PR＋この PR」を1回だけ検証する。見た目だけの変更は Release archive だけで通す)
- 前回: 2026-11-02(門を、Ready の HEAD を固定して見張る仕組みから、最新の main を含んだ HEAD を1回検証する形に変えた。チェックポイントと自動再開、Xcode Cloud の予備をやめた)
- 対象: DigiLog-lab/struis-ios の Issue エージェント、GitHub Actions
- 仕組みの説明は [agent.md](agent.md)、テストの選び方は [testing.md](testing.md) です。

## 方針

1. **確かめたものと、main に入るものを一致させる。** main に入るのはマージキューを通ったものだけです。キューは「最新の main＋先に並んだ PR＋この PR」の commit を作って検証し、緑のときだけその commit を main にします。別々に確かめた PR が合わさって main を壊すことはありません。
2. **不具合を見つけて直すのはエージェント(手元検証)、マージしてよいかを決めるのはキューの検証(`ios.yml`)。** エージェントは `.github/workflows/` を push できず、commit status も書けません。
3. **テストは品質の門。** 赤は skip・期待失敗化・判定の緩和・再実行で通さず、止めて直します。保険的な定期実行(夜間・週次の全件)はしません。
4. **runner はエージェントの作業に使う。** それ以外で macOS runner を使うのは、native cache の作成、PR の検証、プロトタイプ、main からの配信だけです。
5. **止まったら人が再開する。** 自動再開もチェックポイントもありません。指示を細かく出すので、1回の実行が上限(Claude の step 300分)に近づくことは想定しません。

## 流れ

| 段階 | どこで | 何をするか |
|---|---|---|
| 作業の開始 | `agent.yml` の `worker` | 作業ブランチに最新の main を取り込む(衝突したら最初に解消させる) |
| 手元検証 | エージェントの runner(`agentctl local-verify`) | push 済み HEAD で、全単体テスト＋変更に関係する UI テスト。失敗したテストと失敗メッセージを返す |
| Ready | `agentctl ready` | HEAD が push 済み・最新の main を含む・手元検証が緑、の3つを確かめ、PR をレビュー待ちにし、`repository_dispatch` の `admit` を送る |
| キューへの入場 | `ios.yml` の `admit`(Linux) | PR の HEAD に `Struis / verify: success`(説明は「マージキューへ」)を付ける。PR のコードは動かさない。人や web 版の Claude が開いた PR は、`pull_request` の発生で同じ印が付く(Draft とフォークの PR は除く) |
| レビュー | 人 | PR(見た目だけの変更はスクショも)を確かめ、「Merge when ready」でマージキューに入れる |
| 検証 | `ios.yml`(`Merge queue gh-readonly-queue/main/pr-<n>-…`) | キューが作った commit で、native cache 確認 → 単体テスト → 変更に関係する UI テスト、と並行して Release archive。見た目だけ(下)は Release archive だけ |
| 報告 | `ios.yml` の `queue-status`(Linux) | `Struis / verify` をキューの commit に書く。緑ならキューがそのまま main にマージする。赤なら PR はキューから外れ、`queue-result` を受けた `agent.yml` の `queue-report`(main のコード)が失敗を記録してエージェントを起こす |
| main が進んだ後 | `agent.yml` の `refresh`(Linux) | レビュー待ちのエージェントの PR のうち、main と衝突するようになったものはキューに入れられないので、エージェントを起こして解消させる。衝突しない PR には触らない(取り込み直すと入場の印が消えるため) |

- エージェントの worker には `statuses: write` も `actions: write` もありません。commit status を書けるのは `ios.yml` の `admit`・`pending`・`queue-status` と `agent.yml` の `report` だけです。
- main のルールセットは、マージキュー・`Struis / verify`・PR 経由を必須にし、main への直接の push と強制 push を禁じます。
- キューに入れる前に1つの HEAD だけを確かめたい時は、従来どおり `repository_dispatch` の `verify`(`Verify PR #<n> <sha>`)で流せます。結果は同じ `Struis / verify` に書かれます。

## 前提のある作業

- Issue の本文に `前提: #<n>` と書くと、その Issue のエージェントは作業ブランチを `agent/issue-<n>`(前提の作業ブランチ)から切ります。前提がマージされてブランチが消えていれば main から切ります。
- 前提の PR が先にキューに入るようにします。後の PR だけを先に入れると、前提の commit ごと main に入ります。
- 前提が無い作業は待たずに並べて進めます。エージェントは同時に3つまで(macOS runner 5台を、エージェント1台ずつと検証に2台で分けるため)。

## 見た目だけの変更

- Issue の指示で「見た目だけ」と最初に宣言し、エージェントは変えた画面の iPhone と iPad のスクショ(動きが変わるなら録画)を最新の main と比べて貼ります。
- 人がスクショとコードを確かめ、PR にラベル `見た目だけ` を付けてからキューに入れます。
- キューでは、そのラベルがあり、差分が描画のファイルだけ(`scripts/ci/cosmetic.py` の `ALLOWED`)の時に限り、Release archive だけを確かめます(5〜8分)。会話のスクロールと固まり、オンボーディング、課金に関わる画面は、ラベルがあっても通常の検証です。描画以外のファイルを含む時も通常の検証に回します。
- 単体テストも UI テストも流さないので、この経路で入った変更は TestFlight に出す前に実機で確かめます(公開前の運用。公開後に見直します)。

## 配信

- TestFlight への配信は、main で `ios.yml` を手動実行して行います(全 UI テスト → `signed-archive`、`upload` で App Store Connect へ)。配信用の archive は、Actions cache を使わずに native 依存をソースから作ります。
- Ad Hoc のプロトタイプは `agent-prototype.yml` です([agent.md](agent.md))。
