# `agentctl.py` を縮める(引き継ぎ 2.4)— 行数と機能の対応表と手順

2026-10-19 時点の `scripts/agent/agentctl.py` は 1,367 行(`agentlib.py` 309 行は別)。何が何行で、引き継ぎ 2.4 の置き換えでどこが消えるかの表。

| 機能 | 行 | 主な関数 | 置き換え(2.4) | 消える目安 | 前提 |
|---|---:|---|---|---:|---|
| PR CI の起動と確認 | 245 | `cmd_request_pr`, `verify_pr_ci`, `find_pr_ci_run`, `ci_request_id`, `save_pr_ci`, `restore_pr_ci`, `cmd_validate`, `record_validation_failure` | PR を作れば `pull_request` の CI が自動で走り、`gh pr checks <n> --watch` で待つ。`ci_request` の dispatch・run の題名での探索・`pr-ci.json` の保存と復元が不要 | 約 180 | **2.5**: エージェントの PR 作成が GitHub App のトークンで行われること(`github.token` で作った PR は `pull_request` の workflow が走らない。`docs/agent.md`)。#32 の `pr` 段階が main に入っていること |
| セッションの保存・復元と依頼本文の記録 | 160 | `save_session`, `restore_session`, `resumed_request_snapshot`, `record_request_history`, `request_snapshot` 系, `recovery_context` | 人の指示での再開は常に新しいセッション(Issue の履歴から再構成)。復元するのは自動再開(中断・0 ターン)だけ。復元 run の依頼は中断 run と同じなので、依頼本文の記録(`request-history.json`)と復元用の snapshot 合成が不要。修理 run の snapshot(`repair-request.json`)だけ残す | 約 90 | なし |
| 再開の種別と回数、修理の範囲 | 124 | `restart_interrupted`, `cmd_recover`, `fallback_restart_kind`, `repair_scope`, `repair_instructions` | 回数は Issue のラベル(`agent:retry-1`〜`3`)。状態の `autoRestarts`・`restartFromRun` と、それに伴う整合(`sessionStale`・`sessionRepair`・`pendingRestartKind`)が減る | 約 40 | なし |
| 未処理の検出 | (agentlib) | `pending_comments`, `lastCommentId`, `includedComments` | 処理し終えたコメントに bot が reaction(👀 → ✅)を付け、reaction の無い権限者のコメントが未処理。`lastCommentId`・`includedComments`・`issueBodyProcessed` の帳簿が不要。修理の範囲は「reaction を付けない」で表せる | 約 60(prepare/finalize 内) | reaction の書き込み権限(`issues: write`、`github.token` で可) |
| 使用量の集計と表 | 84 | `analyze`, `usage_table`, `usage_numbers` | 実行記録(JSONL)から `jq` で合計し、workflow の step summary に出す。Issue へのコメントには合計 1 行だけ | 約 60 | なし |
| 作業ツリーのチェックポイント | 61 | `save_workspace`, `restore_workspace` | 残す(中断からの復元に要る) | 0 | — |
| プロトタイプ | 90 | `cmd_prototype_build`, `prototype_summary` | `prototype.py` へ移す(既にある) | 約 90 | なし |
| 起点 | 430 | `cmd_route`, `cmd_prepare`, `cmd_finalize` | 上の置き換えで分岐が減る分 | 約 150 | 上の各項 |
| その他 | 139 | `main`, `upload_attachments`, `read_outbox` … | 残す | 0 | — |

合計 1,367 行 → 約 700 行(置き換え後の見積もり)。

## 手順(PR 単位)

1. **2.5 の判断を先に**: App のトークンで PR を作るなら、PR CI の 245 行が `gh pr checks` に置き換わる。これが最大の削減で、`ci_request`・`request-pr`・`pr-ci.json`・`verify_pr_ci` の全部が消える。2.5 を `pull_request_target`(ラベル起動)で行くなら、ここは残る。
2. 2.5 に依らないもの(セッション・再開回数・使用量・プロトタイプの移動)を 1 PR ずつ。各 PR は `scripts/agent/tests` の 118 件を落とさず、置き換えた機能のテストを reaction/ラベル版に書き換える。
3. 未処理の検出を reaction に替える(帳簿の削除)。修理の範囲・依頼本文の記録と絡むので最後。

## やらないこと

- 動きを変える変更(自動再開の上限 3 回、修理 run が次の項目に進まない、skip 禁止)は維持する。縮めるのは実装で、仕様ではない。
