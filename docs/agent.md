# Issue エージェントと Ad Hoc プロトタイプ配布

GitHub Issue を会話の入口にして、GitHub-hosted macOS runner 上の Claude Code(公式の `anthropics/claude-code-action`)で相談・設計・実装・テスト・Pull Request 作成を行います。複数の実装案は、別々の Bundle ID を持つ Ad Hoc 署名アプリとして配布し、登録済みの iPhone に並べてインストールできます。

この文書は、仕組みを第三者が確認できるようにするためと、自分のリポジトリ・Claude 認証・Apple Developer アカウント・Cloudflare アカウントで同じ構成を導入するためのものです。

## 構成

| 部品 | 場所 | 役割 |
|---|---|---|
| Event Router | `.github/workflows/agent.yml` の `route` job(ubuntu) | `agent` ラベル付き Issue の作成・ラベル付与・コメントを受け、投稿者の権限と未処理の指示を確認してから macOS runner を起動 |
| macOS Worker | 同 `worker` job(`xcode-27`) | セッションと作業ブランチの復元、Claude Code の実行、返信・使用量・セッションの保存 |
| Claude Code | `anthropics/claude-code-action`(commit 固定) | 自動化モード(`prompt` 指定)で実行。人の指示は新規セッション、中断の自動再開だけ `--resume` |
| 制御スクリプト | `scripts/agent/agentctl.py`、`agentlib.py` | 経路判定、prompt 生成、実行結果の解析、Issue への返信、Claude から使う補助コマンド |
| 固定システムプロンプト | `scripts/agent/system-prompt.md` | エージェントの作業規則。会話ごとに変わる情報は含めない |
| 保存先 | `cloudflare/agent`(Worker)+ R2 バケット `struis-agent` | 状態、チェックポイントの指し先、使用量、プロトタイプの記録と IPA。CI は GitHub OIDC で認証(受け付けるのは `agent.yml` と `agent-prototype.yml`) |
| チェックポイント | worker の実行の GitHub Artifact(`scripts/agent/checkpoints.py`、`artifacts.py`) | セッション・作業中の差分など。保存期間14日 |
| 門の制御 | `agent.yml` の `control`・`checkpoint-gc`・`cleanup` job(ubuntu) | Ready の門の起動と照合、使わなかったチェックポイントと DerivedData cache の削除 |
| native 依存の cache | `.github/workflows/agent-native-cache.yml` | 約50分かかる bootstrap の生成物を Actions cache に保存 |
| プロトタイプ | `.github/workflows/agent-prototype.yml`、`scripts/agent/prototype.py` | 識別子の割当と解放、App Store Connect API、Ad Hoc 署名、IPA、配布ページ、Issue への投稿 |

## 会話の流れ

1. `agent` ラベルの付いた Issue を作成するか、Issue にコメントします。
2. `route` が、投稿者がリポジトリの OWNER / MEMBER / COLLABORATOR であること(Repository variable `AGENT_ALLOWED_USERS` を設定した場合はその一覧)と、未処理のコメントがあることを確認します。Bot の投稿とエージェント自身の返信は対象外です。
3. `worker` が作業ブランチを取得し、最新の完全なチェックポイントがあれば復元します。人の指示では新規セッション、中断の自動再開では保存したセッションを使います。権限のある人の指示とエージェントの返信を履歴として渡します。
4. 全項目を実装し、完了を記録します。途中のテストはエージェントの判断で流し、WIPは1つのDraft PRへpushします。
5. 全項目完了後、push済みHEADで `local-verify` を流します。全単体テスト・必須E2E・差分UI(カメラのテストを含む)を検証します。
6. `ready` が全項目完了・push済み・同じSHAの手元検証成功を確認し、記録をPR本文とチェックポイントへ保存します。Draftを外し、`repository_dispatch`(`GITHUB_TOKEN` の `contents: write` で送れる)で門を起動します。
7. macOS workerは門を待たずに終了します。LinuxがXcode Cloud／予備のGitHub実行を確認し、緑なら完了を記録し、赤ならDraftへ戻して同じIssueのworkerを起こします。HEADが変わった結果は採用しません。マージは人が行います。

### 保存と中断

Claudeのstepは240分、jobは340分です。実行中は `progress.py` が900秒ごとに、終了時はfinalizeがチェックポイントを作ります。セッション・dirty diff・未追跡ファイル・未push commit・依頼のスナップショット・項目の完了・手元検証の記録を1つのArtifactへ書き、アップロード後に `workspace.json` をCASで更新します。常に最新と1つ前を残します。強制終了でfinalizeが走らなかった場合も `agent-recovery.yml` が最新の完全な保存から再開します。連続自動再開は3回までです。

PRの結果待ちは自動再開の理由にしません。門の赤では、失敗したHEADと元の依頼だけを対象に新規セッションで修正し、完了前の手元検証を全体でやり直します。中断時は修正セッション自身を引き継ぎます。後から届いた指示は自動再開の入力へ混ぜません。

### DerivedData・削除・運用設定

DerivedDataはブランチ名・OS/architecture・Xcode版・native依存のhashごとのActions cacheで持ち越します。PRのclose/merge時にLinuxがそのブランチのDerivedData cacheを削除します。native cacheは削除しません。チェックポイントはworkerの後のLinux jobが最新と1つ前以外を削除し、完了・Issue close・PR close/mergeで全件を削除します。1時間ごとの照合も行い、最後はArtifactの保存期間14日で消えます。

仕組み・権限・設定は [agent-gate.md](agent-gate.md) を参照してください。リポジトリの変数やWorkerの設定変更は要りません。単体テストは `python3 -m unittest discover -s scripts/agent/tests -v` です。PR定義を変更するLinuxの検査と、Xcode/macOSでの実測は別に記録します。

## Ad Hoc プロトタイプ

Claude は Issue の依頼に応じて `python3 "$AGENT_CTL" prototype-build <ID> [--ref <ブランチ>] --title … --summary … --wait` で `agent-prototype.yml` を起動します(`repository_dispatch` の `agent-prototype`)。ビルドするのはこのリポジトリのどのブランチでもよく(タグ・commit SHA・`refs/pull/` は不可)、今の作業を試すだけなら作業ブランチ `agent/issue-{番号}` をそのまま渡します。複数の案を並べて比べるときは、案ごとのブランチ(既定 `prototype/{Issue番号}/{ID}`)を作ります。人が起動するときは Actions → Agent prototype → Run workflow(branch は `main`、`operation=build`、Issue 番号、ID、ブランチ名)です。workflow は次を行います。

1. 識別子の割当: 新しい案には空いている識別子枠を名前順に割り当て、`prototypes/{Issue}/{ID}/meta.json` に記録します。同じ案の再ビルドでは同じ枠(Bundle ID・App Group)を使い、Build Number を増やします。アーカイブした案の枠は解放され、次の新しい案が使います。
2. App Store Connect API: 3つの App ID の存在確認、登録済み端末と配布証明書の取得、端末一覧が変わったときの Ad Hoc profile の作成。profile に App Group が含まれていることを検査します。
3. 作業コピーだけでの識別情報の変更: 表示名(例 `2A Struis`)、アイコンの帯(`#2 A`)、拡張ポイントの宣言。リポジトリ上の本番設定は変更しません。
4. `STRUIS_BUNDLE_ID_BASE` / `STRUIS_APP_GROUP` を渡した archive と、`release-testing`(Ad Hoc)export。署名・Bundle ID・App Group・profile・拡張ポイントを IPA 上で検証します。
5. IPA と `build.json`(Issue、Prototype ID、Bundle ID、Version、Build Number、Commit、生成日時、結果)を R2 に保存し、期限付きのインストールページ、QR コード、Simulator の起動画面を Issue に投稿します。失敗時は段階・原因・再実行方法を投稿します。

状態は `draft / building / ready / testing / selected / archived / failed` で、workflow と Claude(`prototype-status`)がイベントとして記録します。

### アーカイブと枠の解放

比べ終わった案をアーカイブすると、その案の枠が空きます。Claude は Issue で `prototype-status <ID> archived` を記録します(ターン終了時に `operation=archive` を起動し、そのジョブが解放します。同じ案のビルドが走っている間は、ビルドが終わるのを待ってから解放します)。閉じた Issue の案など、Claude のセッションが無い案は Actions → Agent prototype → Run workflow で `operation=archive`、Issue 番号、ID(任意で `summary` に理由)を指定します。アーカイブした案をもう一度ビルドすると、空いている枠を取り直します。

空いた枠を次の案が使うと、端末上では同じ Bundle ID への上書きインストールになり、前の案のアプリの鍵と台帳のデータを引き継ぎます。きれいな状態から試すときは、前の案のアプリを先に削除してください。空いている枠が無いときは、ビルドが理由を Issue に投稿して止まります。

### 識別子枠

App Store Connect API キーでは App Group の作成と App ID への割当ができません(公開 API に該当する資源がなく、Xcode の自動プロビジョニングも API キーでは `appGroups` が `401 NOT_AUTHORIZED` になります)。そのため App Group だけは Developer ポータルで枠ごとに一度登録し、それ以外を自動化しています。

| 枠 | 本体 | extension | App Group |
|---|---|---|---|
| `s01`〜 | `com.digiloglab.strius.preview.sNN` | `.runtime`、`.exec` | `group.com.digiloglab.strius.preview.sNN` |

枠は名前順に割り当てるので、ポータルと Anthropic Console の登録を済ませた枠(現在 s01〜s05)が先に使われます。実機で Claude を使うには、枠の Bundle ID を Anthropic Console の App integration にも追加しておく必要があります(App Attest)。

枠を追加するときは `agent-prototype.yml` を `operation=register-slots`、`slot_count` に新しい合計数で実行します(App ID と App Groups capability を API で作成し、summary にポータルでの残り作業を表示します)。その後 Developer ポータルで次の2つを行います。

1. App Group を登録し、3つの App ID の App Groups に割り当てる。
2. `.runtime` と `.exec` の App ID で **Enhanced Security** を有効にする(本番の extension と同じ。`com.apple.security.hardened-process` 系の entitlement に必要で、API では設定できません)。

空いている枠が無い場合や、profile に App Group・Enhanced Security が含まれない場合、ビルドは原因を Issue に報告して止まります。

### 配布ファイルの保護

- IPA・manifest・インストールページは R2 の非公開バケットに置き、Worker が HMAC 署名付きの期限付き URL(既定7日)でだけ配信します。Ad Hoc の IPA は profile に含まれる登録端末にしかインストールできません。
- インストールページの URL は Issue に投稿されるため、公開リポジトリでは期限内なら第三者も IPA を取得できます。IPA には配信キーが含まれます。より厳しくする場合は、`agent-struis.digiloglab.com/p/*` に Cloudflare Access を設定してください(manifest と IPA は署名 URL のままで動作します)。
- 署名用の Secrets は `prototype-distribution` environment からだけ渡ります。この environment は `main` からの実行に限定しており、reviewer を設定すると署名・配布ごとに手動承認になります。xcodebuild のログには配信キーを含むビルド設定が出力されるため、artifact には `record.json` だけを保存します。

## 導入手順

1. **Claude**: `claude setup-token` で発行したトークンを Secret `CLAUDE_CODE_OAUTH_TOKEN` に登録します。
2. **Cloudflare**: `cloudflare/agent/wrangler.toml` のホスト名・リポジトリ名・リポジトリ ID を自分のものに変え、次を実行します。
   ```sh
   cd cloudflare/agent && npm ci
   npx wrangler r2 bucket create struis-agent
   npx wrangler deploy
   openssl rand -base64 48 | npx wrangler secret put LINK_SECRET
   ```
   Worker の URL が既定と異なる場合は Repository variable `AGENT_STORE_URL` に設定します。保存用の秘密値は GitHub に置きません。
3. **GitHub**: ラベル `agent` を作成し、environment `prototype-distribution` を `main` 限定で作成します。エージェントに Pull Request を作らせる場合は、Settings → Actions → General → Workflow permissions の「Allow GitHub Actions to create and approve pull requests」を有効にします(無効のままだと、エージェントはブランチを push して PR の作成手順を Issue に返します)。任意の Repository variables は `AGENT_MODEL`(既定 `opus`)、`AGENT_EFFORT`、`AGENT_ALLOWED_USERS`、`AGENT_LABEL`、`AGENT_BUNDLE_PREFIX` です。
4. **Apple**: 既存の署名用 Secrets(`BUILD_CERTIFICATE_BASE64`、`P12_PASSWORD`、`APP_STORE_CONNECT_*`、`STRUIS_DELIVERY_APP_KEY`)を使います。API キーは App ID と profile を作成できる権限が必要です。`register-slots` を実行し、Developer ポータルで App Group を登録・割り当てます。テスト端末は Apple Developer に登録しておきます(Ad Hoc の端末数上限に従います)。
5. `Native runtime cache` workflow を一度実行して cache を作ります。

## 制約

- 1回のコメントごとに runner を起動して `--resume` で再開します。runner を待機させる方式は公式 action の実行モデルに合わないため採用していません。キャッシュは1時間 TTL のため、間隔が1時間を超えると次の最初の要求で再作成されます。
- `GITHUB_TOKEN` で作成した Pull Request では、ほかの workflow(`ios.yml`)が自動実行されません。必要な場合は GitHub App のトークンを `github_token` に渡してください。`.github/workflows/` の変更も `GITHUB_TOKEN` では push できません。
- native 依存を変える変更では、cache が更新されるまで bootstrap(約50分)が必要です。
- 実機へのインストールと実機上の操作は利用者が行います。
