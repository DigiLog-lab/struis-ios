# Struis 開発手法 仕様(struis-ios)

- 版: 8(2026-11-11)。マージキューの門から UI テストを外した(10/20〜11/11 に UI テストがアプリの不具合を見つけたことは無く、11/7〜11/11 の門の赤のうち4回は PR が触っていない画面の UI テストだった。持ち主の判断で、また必要になったら考える)。版7は、ビルドの使い回し、落ちた UI テストの録画とスクショ、ラベルを使わない描画だけの判定、Dev Box のコンパイルキャッシュと前後比較の「前」を足した版。
- 対象: `DigiLog-lab/struis-ios` の実装・検証・マージ・報告の回し方
- 状態: Dev Box(#94)とマージキュー(#95)は実装済みで、「Allow auto-merge」も有効。自動マージからマージまでの流れは #96 で確かめた(2026-11-07)。
- 名前は業界で通じる言葉を使う。独自の GitHub のラベルは使わない。

---

## 1. 目的
- 常駐の Mac が無くても、web 版の Claude が PM として、実装から main へのマージまでを回す。
- Claude は、Mac の上の Claude が手元で `xcodebuild` を使うのと同じ感覚で、CI の macOS ランナーを使って書く・ビルドする・テストする・画面を見る。
- macOS ランナー(同時5台)は、実際に使っている間だけ握る。使っていない時は返す。
- main に入るのは、最新の main と合わせて検証したものだけにする。
- 夜中にどこか1か所が詰まっても、それ以外は朝までに終わらせる。持ち主が夜中に監視しなくてよい。

## 2. 前提
- 常駐の Mac は無い。ビルド・テスト・シミュレータは GitHub Actions の macOS ランナー(`xcode-27`、3コア・7GB)で回す。リポジトリは公開(macOS ランナーを無料で使うため)。
- 持ち主はスマホから指示とレビューをする。設定やサインインなどの手作業は持ち主に回さない。ただし、Claude の環境で止められて代わりが利かないもの(「12. 持ち主の操作」)だけは持ち主に頼む。
- PR はまとめる。新しい PR を作る前に持ち主に相談する。ただし「11. 作業の決まり」の「1つの Issue で変える機能は1つ」で分ける PR は、相談済みとみなす。
- テストは最小限。UI テストの全件は流さない。赤は skip・再試行・判定の緩和で通さず、止めて直す。
- 持ち主が許可した PR はマージしてよい(実際のマージは GitHub の自動マージが行う)。
- main はルールセットで保護する(PR 経由、必須のステータスチェック `Struis / verify`、削除と force push の禁止、マージの方法は `merge` だけ)。GitHub 標準のマージキューは個人のアカウントのリポジトリでは使えないので、マージキューは自前で持つ。

## 3. 役割
| 役 | やること |
|---|---|
| 持ち主 | 指示、判断、PR のマージの許可(自動マージの有効化)、見た目と動きの最終確認 |
| web 版 Claude(PM) | Issue の分解と事前検証、コードを書く、Dev Box でのビルド・テスト・画面の確認、PR、マージキューの監視、日次レポート |
| Dev Box | Claude がコードを書いている間ずっと使う macOS ランナー。Claude のリモート実行の命令をそのまま実行する |
| マージキュー(自前) | 自動マージが有効になった PR を1本ずつ、最新の main の上で検証する。main に入る前の唯一のゲート |
| Issue エージェント | 原則使わない。Dev Box で代わりが利かない時だけ、1回の実行で終わる範囲と時間を区切って指示する |

## 4. 全体の流れ
1. **受ける**: 持ち主の指示を受けたら、作業を段階に分ける。
2. **事前検証(preflight check)**: 全部の段階を試す。使う API を実際に呼び(書き込みは害のない形で)、権限・機能が使えるか、持ち主の手作業が要るかを確かめる。持ち主の判断や操作が要る箇所は、着手の前にまとめて全部伝える。判断は1つずつ聞く。
3. **Dev Box を立てる**: アプリのコードに触る作業なら、最初に Dev Box を立て、Claude がコードを読んでいる間に温めておく。
4. **書く・ビルドする・テストする・画面を見る**: Claude の環境でコードを書いて作業ブランチに push し、リモート実行で Dev Box に `xcodebuild` やシミュレータの命令を出す。
5. **PR**: Issue ごとに PR を1本にまとめる。Dev Box で流したテストとその結果を PR に書く。変えた画面の前後比較のスクショと、動きが変わるなら動画を、持ち主に会話で送る。
6. **許可**: 持ち主が PR で GitHub の「Enable auto-merge」(自動マージ)を押す。GitHub Mobile からも押せる。
7. **マージ**: マージキューが1本ずつ、最新の main の上で検証して `Struis / verify` を書く。緑になった時点で、GitHub の自動マージが、ボタンを押した持ち主の名前でマージする。
8. **監視**: Claude はスケジュール実行で起き、結果を見て次を進める。
9. **日次レポート**: 朝に1回。終わったもの、持ち主の操作が要るもの(何を1つ)。

## 5. Dev Box(Claude のリモート開発環境)
- **いつ立てるか**: アプリのコードに触る作業を始めたら、最初に立てる。
- **作業ブランチごとに1台**: Dev Box は作業ブランチごとに立ち、別のブランチの Dev Box と同時に動く(2026-11-09 から。それまではリポジトリ全体で1台で、別のセッションの Dev Box が終わるまで待たされ、その間に送った命令は別のセッションのブランチの上で実行されていた)。`devbox.yml` の concurrency はブランチごと(`devbox-<branch>`)で、同じブランチの2台目だけが1台目の後ろで待つ。命令と結果のブランチもブランチごとに分かれている(「やり取りの経路」)。`mac.py` は、手元で checkout しているブランチの Dev Box に命令を送る(`--branch` か環境変数 `DEVBOX_BRANCH` で変えられる)。
- **起動**: `mac.py start <branch>` が `repository_dispatch`(型 `devbox`)を送り、`.github/workflows/devbox.yml` が main の定義のまま動いて、作業ブランチを checkout する。作業ブランチの定義で起動すると、そのブランチがジョブの権限を書き換えられるため。serve.sh も main のものを作業ツリーの外にコピーして動かす(bash は実行中のスクリプトを少しずつ読むので、作業ブランチへの切り替えで書き換わると壊れる)。
- **立ち上がり**: ネイティブ依存のキャッシュを戻して(作業ブランチが `NativeRuntime` を変えていてキャッシュが無ければ、先に `agent-native-cache.yml` が作る。約50分)1回ビルドし、それからシミュレータを起動して待機する。ビルド中に起動すると、メモリ(7GB)の取り合いでビルドが4倍に延びた。かかる時間は「14. 見込み」。
- **コンパイルキャッシュ**: Xcode のコンパイルキャッシュ(`COMPILATION_CACHE_ENABLE_CACHING`、中身のハッシュで引くので古いものは使われない)を Actions のキャッシュに置き、次の Dev Box に戻す。初回のビルドが772秒から155秒になった。保存は1日1回(キーが日付)。命令で何でも書き込めるので、ゲートのビルド(`ios.yml`)はこのキャッシュを読まない。DerivedData をまるごと戻す方法は、Swift を全部コンパイルし直して226秒かかり、採らなかった(git の checkout がファイルの更新時刻を今にするため)。
- **リモート実行(`mac` コマンド)**: `scripts/devbox/mac.py`。手元の端末と同じ感覚で使う。
  - 例: `mac.py run -- xcodebuild test-without-building -only-testing:striusTests/UsageGateTests`、`mac.py run -- 'xcrun simctl io booted screenshot "$DEVBOX_FILES/home.png"'`。命令の中では `$SIMULATOR_UDID`(起動済みの iPhone 17)と `$DERIVED_DATA` が使える。
  - 引数が1つならシェルの1行として、2つ以上ならそのままの引数として実行する。
  - 命令を実行する前に、Dev Box は作業ブランチの最新を取り込む。DerivedData は作業ツリーの外に置くので、2回目以降はインクリメンタルビルドになる。
  - 返ってくるもの: ログの末尾(全文は gzip)、終了コード、時刻、命令が `$DEVBOX_FILES` に置いたファイル(手元の `devbox-out/<id>/` に入る)。
  - 長い命令は15秒ごとにログの末尾を返すので、終わる前から進み具合が見える。`mac.py run --async` で裏で走らせ、`mac.py wait <id>` で後から結果を取る(Claude の環境の1回の待ちは10分まで)。
- **やり取りの経路**: 命令は1件ごとのブランチ `devboxes/<key>/cmd/<id>`、結果も1件ごとのブランチ `devboxes/<key>/out/<id>`(実行中は15秒ごとに force push で更新)。`<key>` は作業ブランチの名前の SHA-1 の先頭12桁(`mac.py` と `serve.sh` の `box_key`)。ブランチ名の `/` をそのまま入れると、`claude/a` と `claude/a/b` のような名前でブランチの階層がぶつかるため。待機中の目印は `devboxes/<key>/out/ready`。id は送った時刻で始まるので、名前の順に実行する。1本のブランチを使い回すと、Dev Box が拾う前に次の命令で上書きされたり、続けて終わった結果が上書きし合ったりする(事前検証で起きた)。両側とも `git ls-remote` で数秒おきに見る。git の操作は GITHUB_TOKEN の REST の上限(1リポジトリにつき1時間1,000回)に数えられない。3秒おきに REST で見ると1時間1,200回になり、上限を超える。
  - ブランチを消すのは Dev Box だけ(Claude の環境はブランチを消せない)。命令のブランチは拾った時に、結果のブランチは終わってから1時間後に消す。終わった Dev Box(`ready` が無いもの)と、1台だけだった頃の `devbox-out/*` が残した結果は、次に起動した Dev Box が、まとめて1回の fetch と1回の push で消す。動いている別の Dev Box の結果には触らない。
  - 実行中の命令は `mac.py kill` で止める。1つの命令は1時間で打ち切る。命令は job control を有効にして動かす(録画を SIGINT で止めるため)。
  - ファイルも Artifact ではなく結果のブランチで返す。Artifact はステップとしてしか置けず、命令を待つ1つのステップの途中では置けないため。
  - `devboxes/*` への push で動くワークフローは無い(どのワークフローも、push で動くのは main だけ)。
- **アイドルタイムアウト**: 命令が15分来なければ、Dev Box は自分で終わる。必要になったら立て直す。`mac.py stop` ですぐ終わらせることもできる。Claude の環境からは実行を取り消せないので、命令が終わらなくなった時は `mac.py kill` が唯一の止め方になる。
- **6時間の上限**: 1本のジョブは6時間で切れる。その20分前に命令を受けるのをやめる。次の Dev Box はコンパイルキャッシュで立ち上がる。
- **ランナーの割り当て**: 同時5台を、作業中のセッションの Dev Box(1セッション1台)、マージキューの検証、Ad Hoc のプロトタイプのビルドやネイティブ依存のキャッシュ作りで分け合う。Dev Box が3台を超えるとマージキューの検証が待たされるので、使わない Dev Box は `mac.py stop` で畳む。
- **ゲートには使わない**: Dev Box で作ったビルドは、マージのゲートには使わない。命令で何でも実行できるので、push したコードと同じものから作られた保証が無いため。Dev Box のジョブには `statuses: write` を持たせない(`Struis / verify` を書けないようにする)。権限は結果のブランチの push と命令のブランチの削除に要る `contents: write` と、main のビルドの Artifact を読む `actions: read` だけ。Dev Box は Artifact を置かない(命令からは Artifact を置く鍵が見えない)。
- **公開されること**: リポジトリは公開なので、命令と出力は誰でも読める。秘密の値を命令や出力に出さない。Dev Box のジョブに渡す秘密の値は、実際の Claude で確かめるための Anthropic の API キー(Issue エージェントと同じ `CLAUDE_AGENT_API_KEY`)だけ(2026-11-09 から)。
  - 命令には値を渡さず、0600 のファイルの場所だけを `$DEVBOX_ANTHROPIC_KEY_FILE` で渡す。DEBUG の Simulator のアプリには `SIMCTL_CHILD_STRUIS_DEBUG_ANTHROPIC_KEY_FILE`、XCTest には `TEST_RUNNER_STRUIS_DEBUG_ANTHROPIC_KEY_FILE` で渡す。
  - `serve.sh` は結果を push する前に、結果の写しを作り、写しのファイル全部の中のキーの文字列を `[redacted]` に置き換える(`redact_tree`)。圧縮されたファイル(gzip・zip・bzip2 など)の中身にキーがあれば、そのファイルを注記に差し替える。写しを直すので、命令が書き続けているファイルには触らない。全文のログは命令が終わった後に置き換えてから圧縮する。キーそのものを表示する命令は打たない(一部だけを切り出した文字列や、base64 などに変えた文字列は置き換えられない)。

## 6. テストの選び方(テスト影響分析)
- マージキューの門では UI テストを流さない(版8から)。門は、ビルド・単体テスト全部・Release archive。
- Dev Box で UI テストを流す時は、`scripts/ci/ui-test-plan.json` の規則で変更から選ぶ(`python3 scripts/ci/ui_test_plan.py --list --changed-files ...`)。
- マージキューは、UI だけの判定(`cosmetic.py` の `ALLOWED`)を、**main の版**でも使う。PR の版だけを使うと、PR が自分の `ALLOWED` を広げて自分のテストを外せるため。
- 「全件に回す」(`everything`)規則は、本当に全画面に効くものだけにする(`strius/App/**`、`strius/striusApp.swift`、`Info.plist` など)。
- 外すもの:
  - `scripts/ci/ui-test-plan.json`・`scripts/ci/ui_test_plan.py`: 選び方の変更は、選び方の単体テストで確かめる。
  - `strius/Auth/**`: ファイルごとに関係する画面のテストへ割り当てる。
- 検証のワークフローの変更は、「7. マージキュー」のとおり、PR の定義で1回流す。UI テストの選び方のファイル(`ui-test-plan.json`、`ui_test_plan.py`、`ui_failures.py`、`video_frame.swift`)は門に関わらないので、PR の定義では流さない。

## 7. マージキュー(自前、main に入る前の唯一のゲート)
実装: `.github/workflows/merge-queue.yml`(Linux)と `scripts/ci/merge_queue.py`(テストは `scripts/ci/test_merge_queue.py`)。
- **起動**: `pull_request_target`(`auto_merge_enabled`・`auto_merge_disabled`・`synchronize`・`closed`・`reopened`・`ready_for_review`)、main への `push`、`iOS` と `Agent tests` の `workflow_run` の完了、キュー自身が起動した実行の最後のジョブ(`wake-queue`)が送る `repository_dispatch`(`merge-queue`)、持ち主の手での `workflow_dispatch`、30分ごとの `schedule`。
  - キューが起動した実行(PR の定義での `workflow_dispatch`、検証の `repository_dispatch`)は GITHUB_TOKEN で起動されるので、終わっても `workflow_run` を起こさない。#97 で、PR の定義の検証が緑で終わった後、キューが止まったままになった(2026-11-07)。だから実行の最後に自分でキューを起こす。
  - `schedule` は、足してから3時間、一度も動かなかった(2026-11-07)。当てにしない。`pull_request_target` は main の定義で動く(`pull_request` は PR のマージ用コミットの定義で動くので使わない)。キューのジョブは PR のコードを checkout も実行もしない。API で読み書きするだけ。
- **入口**: 持ち主が PR で「Enable auto-merge」を押すと、キューに入る。自動マージを押すことがマージの許可。
  - 合図にレビューの承認(Approve)は使わない。PR の作成者は自分の PR を承認できず、Claude が作る PR は持ち主のアカウント(`DigiLog-lab`)の名前で作られるため。
  - ルールセットが求める承認数は0なので、承認が無くてもマージの妨げにはならない。
  - GitHub は、すぐマージできる PR には「Enable auto-merge」を出さない。だからキュー以外が `Struis / verify` を緑にしてはいけない(緑だとボタンが出ず、キューに入れない)。PR への push では、もう検証は起動しない(`ios.yml` の `pull_request` と `request` ジョブ、`agentctl ready` の検証の起動、main が進んだ時の `refresh` の再検証を外した)。
  - このリポジトリの PR だけを受ける。フォークからの PR、Draft の PR はキューに入れない。
- **状態を持たない**: キューは起動のたびに、GitHub の状態から次にやることを1段だけ進める。待ちのファイルもラベルも持たない。
  - キューの中身: 開いていて、main 向けで、自動マージが有効な PR。
  - 並び順: 「自動マージを押した時刻」(タイムラインの `auto_merge_enabled`)と「先頭のコミットの時刻」の遅い方が早い順。赤を直して push した PR は、これで自然に最後に並ぶ。
  - PR 自身か、PR が閉じる Issue(本文の `Closes #n` など)が、閉じていない Issue に Blocked by されていたら飛ばし、次の PR を見る。先頭で止めない。
  - 先頭のコミットの `Struis / verify` が赤の PR は、push されるまでキューの外で待つ。
  - 同時実行の制御は既定のまま(待ちは1本)。新しい起動が待っている起動を取り消しても、新しい起動が GitHub の状態から全部を読み直すので、何も失わない。
- **先頭に来たら**:
  1. PR が最新の main を含んでいなければ、GITHUB_TOKEN で最新の main を取り込む(Update branch)。衝突したら赤にして PR に理由を書き、次の PR へ進む。
  2. 検証のワークフローに触る PR は、先に PR のブランチの定義のままで流す(`workflow_dispatch`)。`ios.yml`・`agent.yml`・`agent-native-cache.yml`・検証のスクリプトに触れば `ios.yml` を、`scripts/` や `cloudflare/`、キューのワークフロー、`ios.yml`・`agent.yml` に触れば `agent-tests.yml` を流す。`workflow_dispatch` での実行はキューの経路(`repository_dispatch` の `verify`、`pending`、`report`)を通らないので、その部分が残っていることは `scripts/ci/test_queue_contract.py` が PR のファイルで確かめる。緑なら次へ進み、赤なら PR に理由を書いて外す。main の定義だけで流すと、検証を壊す変更が検証されずに main に入り、次からキューが全部赤になって、直す PR もマージできなくなるため(持ち主の判断で、ルールセットの例外は入れずにキュー側で防ぐ。2026-11-07)。
  3. main の定義の `ios.yml` の検証を `repository_dispatch`(`verify`)で起動する。中身は変更で決まる。
     - アプリに触らない変更(`scripts/ci/app_free.py`: 文書、`scripts/agent`・`scripts/ci`・`scripts/devbox`、`.github`、`cloudflare` だけ): macOS を使わない(段階 `none`)。スクリプトとワークフローは `agent-tests.yml` が確かめている。
     - 差分が画面を描くファイルだけ(PR の `cosmetic.py` と main の `cosmetic.py` の両方が認める。ラベルは使わない): Release archive とシミュレータ向けのビルドだけ(段階 `cosmetic`、テストなし)。持ち主は前後比較のスクショを見てから自動マージを押す。会話・オンボーディング・課金の画面は、この経路に乗らない。
     - それ以外: `build-for-testing` → 単体テスト全部を流し、並行して Release archive を1回流す。UI テストは流さない(版8から。版7までは関係する UI テストを流し、長い時は2台目のランナー `verify-shard` に分けていた)。検証が使う macOS ランナーは2台。
- **ビルドの使い回し**: シミュレータ向けのビルド(`Build/Products`)は、tree の SHA と Xcode の版の名前(`sim-build-<tree>-xcode<版>`)で Artifact に置く(14日)。同じ tree の検証をやり直す時や Dev Box の「前」のスクショは、ビルドせずにそれを使う(`scripts/ci/sim_build.py`)。使うのは main の定義の `ios.yml` の `repository_dispatch` の実行が置いたものだけ。PR の定義の実行(`workflow_dispatch`)は何でも置けるので数えない。PR が最新の main を含んでからマージされるので、main のマージコミットの tree は検証した PR の tree と同じになり、検証のビルドがそのまま main のビルドになる。
- **取り消された検証**: 検証の実行が取り消された時(ランナーが失われた、ジョブの時間切れ)は、コードについて何も言っていないので、そのコミットにつき1回だけ自動で検証し直す。2回目の取り消しは赤と同じく push を待つ。
- **落ちた UI テスト**: Xcode は UI テストごとに画面を録画し、落ちたテストの録画だけを結果に残す。`scripts/ci/ui_failures.py` がそれを取り出し、落ちた時刻の0.3秒前のコマを PNG にする(`scripts/ci/video_frame.swift`)。版8から門では UI テストを流さないので、Dev Box で UI テストを流して落ちた時に使う。
- **緑**: `ios.yml` の `report` が `Struis / verify` を緑にする。GitHub の自動マージが、ボタンを押した持ち主の名前でマージする。マージは持ち主の名前の push になるので、main への push で動くワークフローは普段どおり起動する。main が進むと、キューは次の PR へ進む。
  - 緑になってから10分たってもマージされない時は、赤にして PR に理由を書き、次へ進む。
  - 検証が2時間たっても終わらない時は、赤にして PR に理由を書き、次へ進む。
- **古い緑を残さない**: ルールセットの「最新の main を含むことを求める」(strict)は無効なので、古い main の上の緑はマージできてしまう。キューは起動のたびに、最新の main を含まない先頭のコミットにある緑の `Struis / verify` を pending に書き直す。
- **キューを離れた PR**: 検証中か緑のまま、自動マージが外された・Draft に戻された・ブロックされた・閉じられた PR は、次の PR へ進む前に、その結果を「並び直したら検証し直す」の pending にする。`verify_report.py` は、キューが付けた赤と、この pending と、main が進んで pending に戻した印を上書きせず、閉じた PR には緑を書かない。離れた PR が古い main の上の結果でマージされないため。自動マージを有効に戻せば、push しなくても検証し直しから並び直す。
- **PR の定義での実行の使い回し**: 同じコミットに、キュー自身(`github-actions[bot]`)が起動した実行がある時だけ使い回す。手で起動した実行は入力が違うことがある(`ui_tier=unit` など)ので数えない。
- **赤**: `ios.yml` の検証が赤なら、キューはその先頭のコミットにつき1回だけ PR に理由を書く。自動マージは有効のまま残す。Claude が直して push したら、そのままキューの最後に並び直す。持ち主が押し直す必要は無い。
- **マージするのは GitHub**: キューも Claude もマージの API は呼ばない。Claude の環境ではマージの API が止められる(2026-11-06・07 に確認)。
- **強制の範囲**: `Struis / verify` を書くのは、キューと、キューが起動した `ios.yml` の検証だけの決まり。ルールセットが強制しているのは「`Struis / verify` が緑でないとマージできない」ことだけで、誰が書いたかは見ていない(必須チェックに書き手の指定が無い)。他のジョブに `statuses: write` を持たせない。
- **Update branch**: ワークフローの変更が main に入った後でも、GITHUB_TOKEN で Update branch ができる(2026-11-07、#94 のマージの後に #89 で確認。`github-actions[bot]` のコミット 4f64411)。
- **push の禁止**: キューの先頭で検証中の PR のブランチには push しない。

## 8. スクショと動画
- **撮る場所**: 開発中は Dev Box で撮る(`$DEVBOX_FILES` に置けば手元に届く)。Dev Box で UI テストが落ちた時は、`scripts/ci/ui_failures.py` で録画と落ちた瞬間のスクショを取り出す。
- **持ち主に見せる**: Claude が先に確かめてから、会話にファイルとして送る(SendUserFile)。
  - 変えた画面ごとに、最新の main と PR の前後比較の画像を送る(iPhone と iPad)。動きが変わる時は動画も送る。
  - 「前」のスクショは、検証が Artifact に置いた main のシミュレータ向けのビルドを、Dev Box のシミュレータに入れて撮る。`python3 scripts/ci/sim_build.py main "$RUNNER_TEMP/main-build"` が main の直近50コミットを新しい順にさかのぼり、tree の SHA でビルドを探して取ってくる(Linux だけで検証した変更はビルドを作らないため)。`xcrun simctl install "$SIMULATOR_UDID" "$RUNNER_TEMP/main-build/Build/Products/Debug-iphonesimulator/strius.app"` で入れて撮り、PR のビルドを入れ直して「後」を撮る。
  - PR のコメントには、文字の要約だけを残す。
- **Claude の見方**: Claude は動画を再生できないので、フレームを切り出して見る(Claude の環境では ffmpeg、ランナーでは `scripts/ci/video_frame.swift`。ランナーに ffmpeg は無い)。一瞬のちらつきや動きの滑らかさの最終判断は持ち主がする。
- **撮り方**: 録画はアプリが開いてから始める。送る前に縮める。

## 9. 監視(スケジュール実行)
- **仕組み**: この会話に一回限りのスケジュール実行(`send_later`)を入れて、Claude を起こす。1分刻みで、最大1分ほど遅れる。起きた時に結果を見て、まだなら次を入れ直す。
- **間隔**: 終わる時刻の見当がつくもの(マージキューの検証)は、終わる頃に1回起きる。まだの時だけ2分間隔でポーリングし、回数に上限を付ける。夜中は1時間ごとにキューと PR を見回る。
- **使用量**: 起きるたびに Claude の作業が1回分発生するので、細かくしすぎない。
- **持ち主への通知**: 詰まった時と、自動マージを押してほしい PR がある時は、Claude がスマホにプッシュ通知を送る。
- **キューからの通知**: キューが止まった時と赤が出た時は、キューが Issue に書き込む。
- **GitHub の通知の限界**: GitHub の PR の購読は、ステータスチェックの変化では Claude を起こさないことがある。だから監視はスケジュール実行で行う。

## 10. 依存関係と並列化
- 依存の無い作業は待たずに並べて進める。
- 依存は GitHub の Issue の依存関係(Blocked by / Blocking)で表す(Claude の環境から REST で書ける。2026-11-07 に #92←#91 で確認)。後の作業は、ブロックしている Issue の作業ブランチの上で進め、その PR がマージされるまでキューで待つ。
- ブロックしている作業が詰まっても、後の作業はその作業ブランチの上で進め、詰まった1か所以外を終わらせる。

## 11. 作業の決まり
- 作業を段階に分けたら、着手する前に全部の段階を事前検証する。権限・機能・持ち主の手作業を、実際に呼んで確かめる。
- 持ち主の判断や操作が要る箇所は、作業を始める前にまとめて全部伝える。
- Issue に書く前提は、確かめたもの(いつ・どの手段で)と未検証のものを分けて書く。未検証のまま実装に入らない。
- 「できない」と書くのは、実際に試して通らなかった時だけ。何を試し、何に止められたかを書く。
- 詰まったら、すぐ持ち主に知らせる。依存しない作業は進める。
- 作業の途中で関係のない問題を見つけたら、直さずに報告し、別の Issue にする。
- 1つの Issue で変える機能は1つ。UI だけの変更と、データや処理に触れる変更は Issue を分ける。

## 12. 持ち主の操作(これで全部)
- 済み(2026-11-07): リポジトリの設定の「Allow auto-merge」の有効化(Claude の API での有効化は、安全確認に「共有の設定の変更」として止められた)、キューができる前の PR(#94、#95)の手でのマージ、検証のワークフローを変える #95 を PR の定義で流す「Run workflow」(Claude の環境からは `workflow_dispatch` を送れない)。
- PR ごと: 「Enable auto-merge」を押す(マージの許可)。
- ルールセットの例外(bypass)は入れない(2026-11-07、持ち主の判断)。検証を壊す変更は、キューが PR の定義で先に流して防ぐ。

## 13. Claude の環境の制約(試した結果)
- **マージ**: PR のマージの API は、安全確認に「レビューなしのマージ」として止められる。持ち主の許可があっても止まる(2026-11-06、2026-11-07 に #88 で再確認)。
- **リポジトリの設定**: `PATCH /repos`(Allow auto-merge)は、安全確認に「共有の設定の変更」として止められる(2026-11-07)。
- **名義**: Claude の環境は GitHub で `DigiLog-lab`(持ち主のアカウント)を名乗る。Claude が作る PR・コメント・push は持ち主の名前になる。commit の作者は `claude`。
- **ルールセット**: 作成・変更は、通信の中継に書き込みを拒否される。読み取りはできる。
- **ブランチ保護**: 読み取りも「Resource not accessible by integration」で通らない。
- **Actions**: 実行・ジョブ・ログ・Artifact の読み取りはできる。キャッシュ、ランナー(`/actions/runners`)、変数(`/actions/variables`)の API は、通信の中継に拒否される。`workflow_dispatch` と実行の取り消しは「Resource not accessible by integration」で拒否される(2026-11-07)。キャッシュの使用量は `agent-tests` のログで読む。
- **ブランチの削除**: git の push による削除は通信の中継に 403 で拒否され、REST の削除は安全確認に止められる(2026-11-07)。
- **GraphQL**: 拒否されるので REST を使う。
- **iOS 向けのビルド**: Claude の環境ではできない。だから Dev Box を使う。
- **できること**: clone と push(`.github/workflows/` の変更も含む、ブランチの作成と force push)、Issue・PR・コメント・ラベル、Issue の依存関係の読み書き、`repository_dispatch` の送信、Actions の実行とログの読み取り、Artifact のダウンロード、ffmpeg、持ち主へのファイル送信(SendUserFile)、プッシュ通知。

## 14. 見込み
2026-11-07 の事前検証(`xcode-27`、Xcode 27.1、macOS 27.0.1、実行 42249529088・42255903507)で測った値。
- Dev Box の立ち上がり(DerivedData のキャッシュ無し): 起動から待機まで約8分(初回のビルド323秒、シミュレータの起動156秒)。ビルド中にシミュレータを起動すると、初回のビルドが1,296秒(21.6分)に延びた。だからビルドしてから起動する。
- リモート実行1回の上乗せ: 10〜13秒(6回)。
- 何も変えずにもう一度ビルド: 約91秒。Swift のファイルを1つ変えてビルド: 105秒(Dev Box の立ち上がり直後)。同じ Dev Box で続けて測ると、何も変えずに30秒、Swift を1つ変えて43秒で、そのうち「Package Python」の段階が毎回18秒(2026-11-07)。#93 でこの段階を飛ばせるようにして、14秒と25秒になった。
- Dev Box の初回のビルド: キャッシュ無しで772秒、コンパイルキャッシュ(666MB)を戻して155秒。DerivedData(1.6GB)をまるごと戻すと226秒(Swift を全部コンパイルし直す)。
- 単体テスト1クラス(`UsageGateTests`)の `test-without-building`: 57秒。
- 単体テスト全部: 直列で5分27秒(マージキューの前身の検証の記録)、並列(`-parallel-testing-enabled YES`)で490秒。3コアのランナーでは直列のままにする。
- DerivedData は1.6GB、ビルド成果物(`Build/Products`)は442MB。Artifact に置くのに30秒、別のランナーで取るのに9秒。別のランナーで `test-without-building` が通った(シミュレータの起動込みで347秒)。
- iPad のシミュレータ: iPad (A16)、iPad Air 11・13インチ(M4)、iPad mini(A17 Pro・A20 Pro)、iPad Pro 11・13インチ(M5)がある。iPhone のシミュレータを動かしたまま iPad を起動すると624秒かかった。前後比較で iPad を撮る時は、iPhone のシミュレータを止めてから起動する。
- マージキューの検証: 版7(UI テストあり)の実測は、普通の PR の `verify` ジョブで24〜36分(2026-11-08〜11、16回)。版8(UI テストなし)の所要時間は、版8の後の PR で測って書き足す。

## 15. 未検証の前提(実装の前に、この順番で試す)
確かめたもの(2026-11-07):
- Dev Box: ブランチ経由で命令と結果をやり取りできる。上乗せは10〜13秒。`git ls-remote` で数秒おきに見ても REST の上限に関係しない。命令を続けて送っても、1件ごとのブランチなので消えない(手元の bare リポジトリでの単体テスト、`scripts/devbox/test_devbox.py`)。
- 録画: `simctl io recordVideo` は SIGINT で止まる。命令の中で job control(`set -m`)を有効にしないと、裏で起動した録画に SIGINT が届かない(1本目の事前検証で、録画が止まらず命令が終わらなくなった)。
- ビルド成果物の大きさと、Artifact の置き取りの時間、別のランナーでの `test-without-building`、iPad のシミュレータ(「14. 見込み」)。
- 自動マージ: 「Enable auto-merge」でキューが起動し、キューの `Struis / verify` で GitHub がマージし、main への push で動くワークフローも起動した(#96)。
- 落ちた UI テストの録画: Xcode 27 は UI テストごとに録画し、落ちたテストの録画だけを結果に残す。`xcresulttool export attachments --test-id` で取り出せ、落ちた時刻は結果のアクティビティから分かる(Dev Box で、わざと落としたテストで確かめた)。だからテストごとの切り出しは要らない。
- Dev Box の DerivedData のキャッシュ: 戻しても226秒(採らない)。コンパイルキャッシュで155秒(採った)。
- Claude の環境から: `repository_dispatch` の送信、Issue の依存関係(Blocked by)の書き込み、ブランチの作成と force push はできる。ブランチの削除(git の push は 403、REST は安全確認に止められる)、`workflow_dispatch`、実行の取り消しはできない。だから Dev Box は `repository_dispatch` で起動し、ブランチの後片付けは Dev Box がする。
- Actions のキャッシュの使用量は、`agent-tests` のログ(`scripts/ci/cache_usage.py`)で読める。2026-11-06 時点で約1.07GB・3件(上限10GB)。
- main に `.github/workflows/` の変更が入った後でも、GITHUB_TOKEN で Update branch ができる(#89、4f64411)。
- `send_later`: スケジュール実行で起こされた中から、次の一回限りのスケジュール実行を入れ直せる(2026-11-07 03:51)。
- 本番の Dev Box(`repository_dispatch` で main の定義から起動): 依頼から待機まで13.5分。うちビルドと起動が9分20秒、前の Dev Box が残した結果5件の後片付けが約3分20秒(1件ずつ取ってきて消していた。まとめて消すように直した)。上乗せは13秒。

未検証(この順で試す):
1. 検証のワークフローに触る PR を、キューが `workflow_dispatch` で PR のブランチの定義のまま流し、その結果を読めるか(`workflow_dispatch` は GITHUB_TOKEN からでも別の実行を起こせる例外の1つ、という GitHub の文書どおりか)。版7の PR で確かめる。
2. `require_extra_approval_for_unattributed_changes`(ルールセットで有効)が、キューの Update branch が作るコミットで承認を求めないか。版7の PR の後ろに並べた PR で確かめる。
3. 前後比較の「前」: main のビルドの Artifact を Dev Box で取って入れ、撮れるか(別のランナーで Artifact のビルドを入れて起動するのは確かめた)。版7が main に入り、main のビルドが Artifact に置かれた後に確かめる。

## 16. 残る弱点
- Dev Box は、Claude が考えている間もランナーを1台握る。握るのは Claude が作業している間だけで、待っている間はアイドルタイムアウトで返す。
- Dev Box を使えるのは Claude が動いている間だけ。夜中はスケジュール実行で起きた時にまとめて回す。
- マージキューは1本ずつしか通らない。
- 2本の PR が合わさった時の不具合が、選ばれなかった画面で出ると見逃す。
- 自動マージが押されていない PR は、持ち主が押すまで止まる。
- `Struis / verify` を書けるのがキューだけであることは、決まりで守っていて、ルールセットでは強制していない。

## 17. 実装の段取り
1. PR その1(#91): Dev Box とリモート実行(`mac` コマンド)、この仕様。以降の作業をこれで進めるので最初に作る。
2. PR その2(#92): テストの選び方、マージキュー、古い流れ(`refresh` の再検証、PR ごとの `Struis / verify`、`agentctl ready` の検証の起動)の撤去。キューは起動のたびに、最新の main を含まない緑を pending に書き直す。
3. 持ち主が Allow auto-merge を有効にした後、文書だけの害のない PR で自動マージの流れを確かめる。

## 18. 用語
| 言葉 | 意味 |
|---|---|
| Dev Box | Claude がコードを書いている間ずっと使う macOS ランナーのジョブ。Claude のリモート開発環境 |
| リモート実行(`mac` コマンド) | Claude の環境から Dev Box に命令を出し、結果を受け取るコマンド(`scripts/devbox/mac.py`) |
| マージキュー | 自前のマージキュー。main に入る前の唯一のゲート |
| `Struis / verify` | main へのマージに必須のステータスチェック。キューだけが書く決まり |
| 自動マージ(auto-merge) | GitHub 標準の機能。PR で「Enable auto-merge」を押しておくと、必須のステータスチェックが揃った時点で GitHub がマージする。持ち主がこれを押すことがマージの許可 |
| Blocked by | GitHub の Issue の依存関係。後の作業はブロックしている作業の後にマージする |
| 事前検証(preflight check) | 着手の前に、全部の段階を実際に試して、権限・機能・持ち主の手作業を確かめること |
| Issue エージェント | `agent` ラベルの Issue へのコメントで、macOS ランナー上の Claude Code が動く既存の仕組み。原則使わない |
