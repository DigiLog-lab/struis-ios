# struis-ios 検証と配信の方針

- 改訂: 2026-11-02(門を、Ready の HEAD を固定して見張る仕組みから、最新の main を含んだ HEAD を1回検証する形に変えた。チェックポイントと自動再開、Xcode Cloud の予備をやめた)
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
| Ready | `agentctl ready` | HEAD が push 済み・最新の main を含む・手元検証が緑、の3つを確かめ、PR をレビュー待ちにし、`repository_dispatch` の `verify` で検証を起動する |
| 検証 | `ios.yml`(`Verify PR #<n> <sha>`) | main の定義で、その SHA の native cache 確認 → 単体テスト → 変更に関係する UI テスト、と並行して Release archive |
| 報告 | `agent.yml` の `report`(Linux、main のコードだけ) | commit status `Struis / verify` をその SHA に書く。HEAD のままなら、緑は Issue に知らせ、赤は失敗を記録してエージェントを起こす。取り消された実行は `error` にし、誰も起こさない |
| マージ | 人 | PR の `Struis / verify` が緑で、GitHub が「ブランチが古い」と出していないことを見てマージする。出ていたら、Issue にコメントしてエージェントに main を取り込ませる |

- エージェントの worker には `statuses: write` も `actions: write` もありません。commit status を書けるのは `report` だけです。
- web 版の Claude が作業ブランチへ直接 push した時は、その HEAD の検証を同じ `verify` で起動します。

## 配信

- TestFlight への配信は、main で `ios.yml` を手動実行して行います(全 UI テスト → `signed-archive`、`upload` で App Store Connect へ)。配信用の archive は、Actions cache を使わずに native 依存をソースから作ります。
- Ad Hoc のプロトタイプは `agent-prototype.yml` です([agent.md](agent.md))。
