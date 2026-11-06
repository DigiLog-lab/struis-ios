# Issue エージェントと Ad Hoc プロトタイプ配布

GitHub Issue を会話の入口にして、GitHub-hosted macOS runner 上の Claude Code(公式の `anthropics/claude-code-action`)で相談・設計・実装・テスト・Pull Request 作成を行います。指示を出すのは Tomochika か、Tomochika と会話している web 版の Claude です。複数の実装案は、別々の Bundle ID を持つ Ad Hoc 署名アプリとして配布し、登録済みの iPhone に並べてインストールできます。

この文書は、仕組みを第三者が確認できるようにするためと、自分のリポジトリ・Claude 認証・Apple Developer アカウント・Cloudflare アカウントで同じ構成を導入するためのものです。検証とマージの決まりは [verification-and-delivery-policy.md](verification-and-delivery-policy.md) です。

## 構成

| 部品 | 場所 | 役割 |
|---|---|---|
| Event Router | `.github/workflows/agent.yml` の `route` job(ubuntu) | `agent` ラベル付き Issue の作成・ラベル付与・コメント、赤い検証の通知を受け、未処理の指示があるときだけ macOS runner を起動 |
| macOS Worker | 同 `worker` job(`xcode-27`) | 作業ブランチの準備と main の取り込み、受け渡しファイルの展開、Claude Code の実行、返信・使用量・記録の保存 |
| Claude Code | `anthropics/claude-code-action`(commit 固定) | 自動化モード(`prompt` 指定)。毎回新しいセッションで、Issue のやり取りを履歴として渡す |
| 制御スクリプト | `scripts/agent/agentctl.py`、`agentlib.py` | 経路判定、prompt 生成、実行結果の解析、Issue への返信、Claude から使う補助コマンド |
| 検証の報告 | 同 `report` job と `queue-report` job(ubuntu)、`scripts/agent/verify_report.py` | `report` は `ios.yml` の `Verify PR #<n> <sha>`(キューに入れる前に1つの HEAD を確かめる時)の結果を commit status `Struis / verify` にする。`queue-report` はマージキューの検証が赤だった時に失敗を記録してエージェントを起こす |
| 衝突の確認 | 同 `refresh` job(ubuntu)、`scripts/agent/refresh.py` | main が進んだら、レビュー待ちのエージェントの PR のうち main と衝突するもののエージェントを起こす。あわせて、閉じた Issue の `agent/issue-<n>`(`-wip` などの付いた枝も含む)を、そこから開いた PR が無ければ削除する |
| 後片付け | 同 `cleanup` job(ubuntu)、`scripts/agent/cleanup.py` | Issue が閉じたら、作業ブランチの DerivedData cache、作業ブランチ(そこから開いた PR が無い時だけ。マージ済み・閉じた PR のページから復元できる)、`handoff/issue-<n>` を削除 |
| 固定システムプロンプト | `scripts/agent/system-prompt.md` | エージェントの作業規則。会話ごとに変わる情報は含めない |
| 保存先 | `cloudflare/agent`(Worker)+ R2 バケット `struis-agent` | 状態、使用量、返信の添付画像、プロトタイプの記録と IPA。CI は GitHub OIDC で認証(受け付けるのは `agent.yml` と `agent-prototype.yml`) |
| native 依存の cache | `.github/workflows/agent-native-cache.yml` | 約50分かかる bootstrap の生成物を Actions cache に作る唯一の場所。`ios.yml` と `agent-prototype.yml` が呼び出す |
| プロトタイプ | `.github/workflows/agent-prototype.yml`、`scripts/agent/prototype.py` | 識別子の割当と解放、App Store Connect API、Ad Hoc 署名、IPA、配布ページ、Issue への投稿 |

## 会話の流れ

1. `agent` ラベルの付いた Issue を作成するか、Issue にコメントします。
2. `route` が、投稿者がリポジトリの OWNER / MEMBER / COLLABORATOR であること(Repository variable `AGENT_ALLOWED_USERS` を設定した場合はその一覧)と、未処理のコメントがあることを確認します。Bot の投稿とエージェント自身の返信は対象外です。
3. `worker` が作業ブランチ(`agent/issue-<n>`)を origin から取り、最新の main を取り込みます。衝突したら取り込みを中止し、最初に解消するよう Claude に伝えます。`handoff/issue-<n>` があれば `$AGENT_HOME/handoff` に展開します。
4. Claude は毎回新しいセッションで、Issue 本文・それまでのやり取り・記録済みの設計判断(`decision`)・新しいコメントを受け取ります。
5. 作業を終えたら push 済み HEAD で `local-verify`(全単体テスト＋変更に関係する UI テスト)を流し、緑なら `ready` で PR をレビュー待ちにし、マージキューに入れられるようにします(`ios.yml` の `admit`)。そこでセッションを終えます。
6. 人がレビューして「Merge when ready」でキューに入れると、キューが「最新の main＋先に並んだ PR＋この PR」の commit を作り、`ios.yml` が検証します。緑ならそのまま main にマージされます。赤なら PR はキューから外れ、`queue-report` が失敗の内容を記録してエージェントを起こします。
7. main が進むと、`refresh` がレビュー待ちの PR のうち main と衝突するもののエージェントを起こして解消させます。衝突しない PR はそのまま待ちます(キューが最新の main と合わせて検証するため)。
8. Issue の本文に `前提: #<n>` があると、作業ブランチを前提の作業ブランチから切ります([verification-and-delivery-policy.md](verification-and-delivery-policy.md))。

実行が途中で止まっても自動では再開しません。push 済みの commit は作業ブランチに残り、Issue へのコメントで新しく始めます。失敗した実行が扱っていたコメントは未処理のまま残るので、次の実行で一緒に扱います。Claude の step は300分、job は340分です。

## web 版 Claude との受け渡し

- **指示**: Issue のコメントで出します。エージェントは前の会話を覚えていないので、指示は毎回それ単体で分かる形で書きます。
- **ファイル**: コメントに載せられないもの(参考スクリーンショット、デザインの寸法、AI 応答の固定データ)は、Issue ごとの `handoff/issue-<n>` に置きます。main と履歴を共有しない空のブランチで、workflow を含まないので push しても何も起動しません。中身は常に1コミットに上書きし、Issue が閉じたら `cleanup` が削除します。
- **結果**: 返信と、そこに貼られるスクリーンショット(`agentctl shot`)。run の artifact(`agent-issue-<n>-run-…`、14日保存)には、`screens.json`(画面名・起動引数・commit)、手元検証の結果と失敗の一覧(`failures.json`)、アプリのログ(`agentctl applog`)、模擬 Claude サーバーの要求と応答、Claude Code のセッション記録が入ります。Claude の説明・ツール呼出し・結果は Actions のログにも逐次出ます。
- **公開範囲**: リポジトリは公開なので、artifact も Actions のログも公開です。保存前に、認証情報の値(環境変数の値そのものと、トークン・鍵の形)を伏せ字にします(`agentlib.redact_tree`、`live-log.cjs`)。
- **直接修正**: web 版の Claude は作業ブランチへ直接 commit することがあります。エージェントの実行中は push せず、強制 push は使いません。コミットメッセージは `hotfix:` で始め、Issue に「hotfix: <SHA> 何を・なぜ」を残します。push した HEAD は `repository_dispatch` の `admit` でキューに入れられるようにします(キューに入れる前に確かめたい時は `verify`)。

## DerivedData と cache

DerivedData はブランチ名・OS/architecture・Xcode 版・native 依存の hash ごとの Actions cache で持ち越します。Issue が閉じたら `cleanup` がそのブランチの DerivedData cache を削除します。native cache は削除しません。単体テストは `python3 -m unittest discover -s scripts/agent/tests -v` です。

## Ad Hoc プロトタイプ

Claude は Issue の依頼に応じて `python3 "$AGENT_CTL" prototype-build <ID> [--ref <ブランチ>] --title … --summary … --wait` で `agent-prototype.yml` を起動します(`repository_dispatch` の `agent-prototype`)。ビルドするのはこのリポジトリのどのブランチでもよく(タグ・commit SHA・`refs/pull/` は不可)、今の作業を試すだけなら作業ブランチ `agent/issue-{番号}` をそのまま渡します。複数の案を並べて比べるときは、案ごとのブランチ(既定 `prototype/{Issue番号}/{ID}`)を作ります。人が起動するときは Actions → Agent prototype → Run workflow(branch は `main`、`operation=build`、Issue 番号、ID、ブランチ名)です。workflow は次を行います。

1. 識別子の割当: 新しい案には空いている識別子枠を名前順に割り当て、`prototypes/{Issue}/{ID}/meta.json` に記録します。同じ案の再ビルドでは同じ枠(Bundle ID・App Group)を使い、Build Number を増やします。アーカイブした案の枠は解放され、次の新しい案が使います。
2. App Store Connect API: 2つの App ID の存在確認、登録済み端末と配布証明書の取得、端末一覧が変わったときの Ad Hoc profile の作成。profile に App Group が含まれていることを検査します。
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
| `s01`〜 | `com.digiloglab.strius.preview.sNN` | `.exec` | `group.com.digiloglab.strius.preview.sNN` |

枠は名前順に割り当てるので、ポータルと Anthropic Console の登録を済ませた枠(現在 s01〜s05)が先に使われます。実機で Claude を使うには、枠の Bundle ID を Anthropic Console の App integration にも追加しておく必要があります(App Attest)。

枠を追加するときは `agent-prototype.yml` を `operation=register-slots`、`slot_count` に新しい合計数で実行します(App ID と App Groups capability を API で作成し、summary にポータルでの残り作業を表示します)。その後 Developer ポータルで次の2つを行います。

1. App Group を登録し、2つの App ID の App Groups に割り当てる。
2. `.exec` の App ID で **Enhanced Security** を有効にする(本番の extension と同じ。`com.apple.security.hardened-process` 系の entitlement に必要で、API では設定できません)。

空いている枠が無い場合や、profile に App Group・Enhanced Security が含まれない場合、ビルドは原因を Issue に報告して止まります。

### 配布ファイルの保護

- IPA・manifest・インストールページは R2 の非公開バケットに置き、Worker が HMAC 署名付きの期限付き URL(既定7日)でだけ配信します。Ad Hoc の IPA は profile に含まれる登録端末にしかインストールできません。
- インストールページの URL は Issue に投稿されるため、公開リポジトリでは期限内なら第三者も IPA を取得できます。より厳しくする場合は、`agent-struis.digiloglab.com/p/*` に Cloudflare Access を設定してください(manifest と IPA は署名 URL のままで動作します)。
- 署名用の Secrets は `prototype-distribution` environment からだけ渡ります。この environment は `main` からの実行に限定しており、reviewer を設定すると署名・配布ごとに手動承認になります。xcodebuild のログにはビルド設定が出力されるため、artifact には `record.json` だけを保存します。

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
4. **Apple**: 既存の署名用 Secrets(`BUILD_CERTIFICATE_BASE64`、`P12_PASSWORD`、`APP_STORE_CONNECT_*`)を使います。API キーは App ID と profile を作成できる権限が必要です。`register-slots` を実行し、Developer ポータルで App Group を登録・割り当てます。テスト端末は Apple Developer に登録しておきます(Ad Hoc の端末数上限に従います)。
5. `Native runtime cache` workflow を一度実行して cache を作ります。

## 制約

- 1回のコメントごとに runner を起動し、新しいセッションで始めます。runner を待機させる方式は公式 action の実行モデルに合わないため採用していません。
- `GITHUB_TOKEN` での push や PR 作成では、`pull_request` 系の workflow が起動しません。そのため PR の検証は `repository_dispatch`(`contents: write` で送れる)で起動します。`.github/workflows/` の変更も `GITHUB_TOKEN` では push できません。
- native 依存を変える変更では、cache が更新されるまで bootstrap(約50分)が必要です。
- 実機へのインストールと実機上の操作は利用者が行います。
