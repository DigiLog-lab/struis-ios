# Issue エージェントと Ad Hoc プロトタイプ配布

GitHub Issue を会話の入口にして、GitHub-hosted macOS runner 上の Claude Code(公式の `anthropics/claude-code-action`)で相談・設計・実装・テスト・Pull Request 作成を行います。複数の実装案は、別々の Bundle ID を持つ Ad Hoc 署名アプリとして配布し、登録済みの iPhone に並べてインストールできます。

この文書は、仕組みを第三者が確認できるようにするためと、自分のリポジトリ・Claude 認証・Apple Developer アカウント・Cloudflare アカウントで同じ構成を導入するためのものです。

## 構成

| 部品 | 場所 | 役割 |
|---|---|---|
| Event Router | `.github/workflows/agent.yml` の `route` job(ubuntu) | `agent` ラベル付き Issue の作成・ラベル付与・コメントを受け、投稿者の権限と未処理の指示を確認してから macOS runner を起動 |
| macOS Worker | 同 `worker` job(`xcode-27`) | セッションと作業ブランチの復元、Claude Code の実行、返信・使用量・セッションの保存 |
| Claude Code | `anthropics/claude-code-action`(commit 固定) | 自動化モード(`prompt` 指定)で実行。`--resume` で Issue ごとのセッションを継続 |
| 制御スクリプト | `scripts/agent/agentctl.py`、`agentlib.py` | 経路判定、prompt 生成、実行結果の解析、Issue への返信、Claude から使う補助コマンド |
| 固定システムプロンプト | `scripts/agent/system-prompt.md` | エージェントの作業規則。会話ごとに変わる情報は含めない |
| 保存先 | `cloudflare/agent`(Worker)+ R2 バケット `struis-agent` | セッション、状態、使用量、プロトタイプの記録と IPA。CI は GitHub OIDC で認証 |
| native 依存の cache | `.github/workflows/agent-native-cache.yml` | 約50分かかる bootstrap の生成物を Actions cache に保存 |
| プロトタイプ | `.github/workflows/agent-prototype.yml`、`scripts/agent/prototype.py` | 識別子の割当、App Store Connect API、Ad Hoc 署名、IPA、配布ページ、Issue への投稿 |

## 起点ブランチとリリースブランチ

エージェントの作業ブランチは、進行中のリリースブランチ(Repository variable `RELEASE_BRANCH`、例: `release/1.2`)から切り、PRもそこへ向けます。変数が空、またはそのブランチがoriginに無い場合は`main`です。Issueは使ったリリースブランチを`state.json`の`baseBranch`に保存し、そのブランチが消える(リリースを終えて削除する)まで使い続けます。`main`で始めたIssueは、リリースブランチが設定された時点でそちらへ移ります。既存のPRは、次の`request-pr`で向き先を付け替えます(リリースブランチをmainへマージしてブランチを消すと、GitHubがそこへ向いていたPRをmainへ付け替えるため、その場合も次のリリースへ移ります)。起点はClaudeへの入力の`Base branch`に表示します。

mainにはリリースブランチでTestFlightの確認を終えたものだけを入れます。手順は[公開ソースと配布版の対応](source-and-releases.md#リリースの流れ)にあります。

## 会話の流れ

1. `agent` ラベルの付いた Issue を作成するか、Issue にコメントします。
2. `route` が、投稿者がリポジトリの OWNER / MEMBER / COLLABORATOR であること(Repository variable `AGENT_ALLOWED_USERS` を設定した場合はその一覧)と、未処理のコメントがあることを確認します。Bot の投稿とエージェント自身の返信は対象外です。
3. `worker` が R2 から `state.json` と Claude のセッション記録(`~/.claude/projects` の tar)を復元し、作業ブランチ `agent/issue-{番号}` を origin から取得します。
4. 新しいコメント(初回は Issue 本文)と実行環境の状態だけを prompt にして、`claude_args` の `--resume <session>` で同じセッションを再開します。
5. Claude の最終応答を Issue へ投稿し、セッション記録・状態・使用量を R2 へ保存します。処理に成功したコメントだけを処理済みにするので、失敗時は次のコメントや Re-run で同じ入力を再処理します。

### 進捗と成果の検証

Claudeのstepは240分で終了させ、340分のjob上限に対して保存・検証・再開予約の時間を確保します。中断時にはセッション、未コミットの差分・未追跡ファイル、未pushのcommitをR2のチェックポイントへ保存し、`workflow_dispatch`で同じIssueを新しいrunnerへ自動で引き継ぎます。入力コメントは未処理のまま保持し、同一Issueのconcurrencyで直列化します。連続自動再開は3回までです。成功または新しいユーザー指示で回数をリセットします。remoteが保存後に変わった場合は、上書きせずチェックポイントを保持して停止します。runnerの強制終了などで終了処理自体が走らない場合は、`agent-recovery.yml`が終了イベントを受け取り、未終了状態の同じ実行だけを再開します。この場合は最後に保存できた作業から復元します。通常の終了処理で再開予約済みの実行、後続runnerが始まった実行、別attemptの終了通知は重複起動しません。

コミット・push時にはテストを実行しません。pre-commitフックは設定せず、固定した`guard.py`の軽いpre-pushフックで、現在のHEADから main・`release/*` 以外のブランチへのpushだけを許可します。調査中に必要な個別テストはClaude自身が選んで実行します。

PR本文はチェックアウト外の`$AGENT_HOME/pr-body.md`に書き、`agentctl.py request-pr --title … --body-file …`を実行します。チェックアウト内に新規作成した未追跡の本文ファイルを指定した場合は、内容を`$AGENT_HOME/pr-bodies/`へ移して保存します。追跡済みファイルや本文以外の変更はこの対象にしません。

`request-pr`は、その場でPRを作成・更新し、push済みの作業ブランチで`iOS`と`Agent tests`のCIを明示的に起動します。`GITHUB_TOKEN`が作成したPRやpushからは通常の`pull_request`イベントが起動されないため、`workflow_dispatch`を使います。CI要求には一意の識別子を付け、ブランチ・対象HEAD・起動済みworkflowを記録します。要求の作成時と各workflowの起動直後にR2の`state.json`へ保存するため、終了処理前の中断でも記録を引き継ぎます。再開時は作業ブランチとHEADが一致する記録を復元します。`request-pr`を再実行しても、同じHEADで実行中・待機中・成功済みのCIは再利用します。完了したCI要求も`validatedCI`に保存し、次の会話からPRの説明だけを更新する場合も再利用できます。失敗・キャンセルしたworkflowだけに新しい要求識別子を発行して再起動します。起動成功の応答を保存する前に中断した場合も、GitHub上の同じ要求識別子の実行を検索して確認します。古い作業ブランチは事前に起点ブランチ(後述)のCI定義を取り込みます。

PR CIは制御スクリプトのテスト、Worker構文、Actions定義、Simulatorビルド、iOS単体/UIテスト、署名なし実機Release archiveを検証します。Claudeは実行結果を確認し、失敗時は個別テストで調査・修正・commit・pushして`request-pr`を再実行します。単体テストには1件あたり最大300秒・step全体30分、UIテストには1件あたり最大600秒・runnerごとに90分の上限があります。UIテストは`scripts/ci/ui_test_plan.py`がテストメソッド単位で複数のrunnerへ割り当て、並行して実行します(割り当ての設定は`scripts/ci/ui-test-plan.json`。詳細は[テスト](testing.md#ciでのuiテストの割り当て))。CIのxcresultは実行IDと再実行番号を含むartifact名で保存します。iOSのエージェントCIはブランチごとに実行を制御し、mainの手動リリース・アップロードの待ち行列と分離します。

Claude終了後のPython処理はテストや署名処理を実行しません。作業の保存・push状態とGitHub API上のCI結果を確認し、要求識別子・ブランチ・HEADが一致する両CIの最新attemptが成功した場合だけ、完成応答を投稿して入力を処理済みにします。未完了・失敗・記録不足では作業と依頼を保持し、上記の上限内で自動再開します。成功したHEADは`state.json`の`validatedHead`に保存します。同じHEADでコード変更のない次の相談は再検証せず、コードが変われば新しいCI結果が必要です。署名付きarchive・bundle監査はmainとリリースブランチへのpushで実行し、アップロードは明示的な配信操作で行います。任意の実AIテストは既存の条件に従ってskipされるため、全実AI経路の成功は保証しません。

実行開始時に専用のIssueコメントを作り、60秒ごとに更新します。Issueコメントにはツール名・開始/完了/失敗・最後の動作時刻だけを表示します。監視の更新時刻とClaudeの最後の動作時刻は別に表示します。

Actionsの`Claude Code`ログでは、説明文・実行コマンドなどのツール入力・ツール結果を`[Claude]`付きで逐次表示します。既知の秘密環境変数の値と代表的な認証情報形式を除去し、長い出力は先頭と末尾を表示します。元のプロンプトとthinkingブロックは表示しません。公式Actionの固定SHAに対応する出力整形部分だけを変更し、元のSDKメッセージや実行結果ファイルは変更しません。Actionを更新するときは`configure_logging.py`のSHA・ソースハッシュ・差し込み位置を確認します。これは任意の認証情報を確実に除去する仕組みではないため、秘密値をツール出力へ意図的に表示しないでください。

これらのフックと完了確認は、任意のシェルを実行できるClaudeに対するセキュリティ境界ではなく、誤pushと誤った成果提示を防ぐ実行制御です。

同じ Issue の実行は `concurrency` で直列になります。実行中に届いたコメントは次の実行で処理し、すでに処理済みなら macOS runner は起動しません。

### 保存される状態(R2 `sessions/{Issue番号}/`)

| キー | 内容 |
|---|---|
| `state.json` | Claude セッション ID、モデル、作業ブランチ、最終処理済みコメント ID、検証済みHEAD(`validatedHead`)、未完了のCI要求(`prCI`)、完了したCI要求(`validatedCI`)、Worker の稼働状態と実行 URL、記録された設計判断 |
| `claude-projects.tar.gz` | Claude Code の会話記録 |

使用量は `usage/{Issue番号}/{run}-{attempt}.json`、プロトタイプは `prototypes/{Issue番号}/{ID}/` に保存します。セッション記録を復元できない場合は、Issue の履歴・記録済みの設計判断・作業ブランチの log を prompt に入れた新しいセッションで再開します。

## プロンプトキャッシュ

- システムプロンプトは Claude Code の既定(`claude_code` preset)と固定の `system-prompt.md` だけです。`--exclude-dynamic-system-prompt-sections` を付け、時刻・Issue 番号・コメントなどは会話側に渡します。
- `CLAUDE_CODE_PROMPT_CACHE_TTL=1h` を指定しています。キャッシュは Anthropic 側にあり、ヒットするたびに期限が延びるので、runner が毎回入れ替わっても1時間以内の間隔なら再利用されます。
- モデルは Issue ごとに最初に解決されたモデル ID を `state.json` に保存して使い続けます。Claude Code の版は action の commit 固定で固定され、自動更新は無効です。自動化モードの action は MCP サーバーを追加しないため、ツール定義も毎回同じです。
- 各返信の「セッション情報」と Actions の summary に、入力・キャッシュ読取・キャッシュ作成(1h / 5m の内訳)・出力トークン、キャッシュヒット率、復元直後の最初の要求のヒット率を記録します。

## Ad Hoc プロトタイプ

Claude は Issue の依頼に応じて、案ごとのブランチ `prototype/{Issue番号}/{ID}` を作り、`python3 "$AGENT_CTL" prototype-build <ID> --title … --summary … --wait` で `agent-prototype.yml` を起動します。workflow は次を行います。

1. 識別子の割当: 新しい案には未使用の識別子枠を割り当て、`prototypes/{Issue}/{ID}/meta.json` に記録します。同じ案の再ビルドでは同じ枠(Bundle ID・App Group)を使い、Build Number を増やします。枠は再利用しません。
2. App Store Connect API: 3つの App ID の存在確認、登録済み端末と配布証明書の取得、端末一覧が変わったときの Ad Hoc profile の作成。profile に App Group が含まれていることを検査します。
3. 作業コピーだけでの識別情報の変更: 表示名(例 `2A Struis`)、アイコンの帯(`#2 A`)、拡張ポイントの宣言。リポジトリ上の本番設定は変更しません。
4. `STRUIS_BUNDLE_ID_BASE` / `STRUIS_APP_GROUP` を渡した archive と、`release-testing`(Ad Hoc)export。署名・Bundle ID・App Group・profile・拡張ポイントを IPA 上で検証します。
5. IPA と `build.json`(Issue、Prototype ID、Bundle ID、Version、Build Number、Commit、生成日時、結果)を R2 に保存し、期限付きのインストールページ、QR コード、Simulator の起動画面を Issue に投稿します。失敗時は段階・原因・再実行方法を投稿します。

状態は `draft / building / ready / testing / selected / archived / failed` で、workflow と Claude(`prototype-status`)がイベントとして記録します。

### 識別子枠

App Store Connect API キーでは App Group の作成と App ID への割当ができません(公開 API に該当する資源がなく、Xcode の自動プロビジョニングも API キーでは `appGroups` が `401 NOT_AUTHORIZED` になります)。そのため App Group だけは Developer ポータルで枠ごとに一度登録し、それ以外を自動化しています。

| 枠 | 本体 | extension | App Group |
|---|---|---|---|
| `s01`〜 | `com.digiloglab.strius.preview.sNN` | `.runtime`、`.exec` | `group.com.digiloglab.strius.preview.sNN` |

枠を追加するときは `agent-prototype.yml` を `operation=register-slots`、`slot_count` に新しい合計数で実行します(App ID と App Groups capability を API で作成し、summary にポータルでの残り作業を表示します)。その後 Developer ポータルで次の2つを行います。

1. App Group を登録し、3つの App ID の App Groups に割り当てる。
2. `.runtime` と `.exec` の App ID で **Enhanced Security** を有効にする(本番の extension と同じ。`com.apple.security.hardened-process` 系の entitlement に必要で、API では設定できません)。

未使用の枠が無い場合や、profile に App Group・Enhanced Security が含まれない場合、ビルドは原因を Issue に報告して止まります。

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
3. **GitHub**: ラベル `agent` を作成し、environment `prototype-distribution` を `main` 限定で作成します。エージェントに Pull Request を作らせる場合は、Settings → Actions → General → Workflow permissions の「Allow GitHub Actions to create and approve pull requests」を有効にします(無効のままだと、エージェントはブランチを push して PR の作成手順を Issue に返します)。任意の Repository variables は `RELEASE_BRANCH`(進行中のリリースブランチ。後述)、`AGENT_MODEL`(既定 `opus`)、`AGENT_EFFORT`、`AGENT_ALLOWED_USERS`、`AGENT_LABEL`、`AGENT_BUNDLE_PREFIX` です。
4. **Apple**: 既存の署名用 Secrets(`BUILD_CERTIFICATE_BASE64`、`P12_PASSWORD`、`APP_STORE_CONNECT_*`、`STRUIS_DELIVERY_APP_KEY`)を使います。API キーは App ID と profile を作成できる権限が必要です。`register-slots` を実行し、Developer ポータルで App Group を登録・割り当てます。テスト端末は Apple Developer に登録しておきます(Ad Hoc の端末数上限に従います)。
5. `Native runtime cache` workflow を一度実行して cache を作ります。

## 制約

- 1回のコメントごとに runner を起動して `--resume` で再開します。runner を待機させる方式は公式 action の実行モデルに合わないため採用していません。キャッシュは1時間 TTL のため、間隔が1時間を超えると次の最初の要求で再作成されます。
- `GITHUB_TOKEN` で作成した Pull Request では、ほかの workflow(`ios.yml`)が自動実行されません。必要な場合は GitHub App のトークンを `github_token` に渡してください。`.github/workflows/` の変更も `GITHUB_TOKEN` では push できません。
- native 依存を変える変更では、cache が更新されるまで bootstrap(約50分)が必要です。
- 実機へのインストールと実機上の操作は利用者が行います。
