# struis-ios 検証と配信の方針(草案)

- 作成: 2026-10-20
- 状態: 実装中。段階ごとの実装・実測は `docs/xcode-cloud.md` を参照。
- 対象: DigiLog-lab/struis-ios の Issue エージェント、GitHub Actions、Xcode Cloud

この文書では、確かめた事実には根拠を付けます。確かめていないことは「仮説」、まだ決めていないことは「未決」と書きます。「CI」という語は、手元検証と門を混同させるので使いません。

---

## 1. 定義

この文書の語は、すべてこの節の定義どおりの意味で使います。

### 1.1 場所と仕組み

| 語 | 定義 |
|---|---|
| runner | GitHub が用意する macOS の実行マシン(ラベル `xcode-27`)。Linux のマシンを指す時は「Linux のジョブ」と書きます |
| エージェント | `agent` ラベルの付いた Issue から起動され、`agent.yml` の `worker` ジョブの中で、runner の上で動く Claude Code |
| worker | `agent.yml` の `worker` ジョブ。1回の起動で runner を1台使います |
| セッション | Claude Code の会話の続き。`--resume` で再開する単位です |
| main | リポジトリの既定のブランチ |
| マージ | PR の変更を main に取り込むこと。行うのは Tomochika で、エージェントは行いません |
| リリースブランチ | 未決。運用は別の Issue で決めます。決まるまでは、Release workflow を手動で起動します |

### 1.2 PR と commit

| 語 | 定義 |
|---|---|
| PR のブランチ | PR の変更元のブランチ。エージェントの場合は作業ブランチです |
| HEAD | PR のブランチの先頭の commit。commit の SHA(40文字)で特定します。この文書で HEAD に結び付けるもの(手元検証の記録、Ready、門の結果)は、すべて SHA で記録します |
| HEAD が変わる | PR のブランチの先頭の commit の SHA が、記録した SHA と違う状態になること。commit の追加、force push、main の取り込みのどれでも当てはまります |
| push | ローカルの commit を GitHub の PR のブランチへ送ること |
| Draft | GitHub の PR の Draft 状態 |
| WIP | Draft の PR に push された、作業途中の変更 |

### 1.3 作業の単位

| 語 | 定義 |
|---|---|
| 依頼 | Issue の本文と、権限のある人が Issue に書いたコメントの指示の全体 |
| 項目 | 依頼の中の、1つずつ完了を判断できる作業。本文に番号付きの「やること」があれば、その1つずつです。番号付きの一覧がなければ、依頼全体を1つの項目とします。コメントで追加・変更された指示は、新しい項目か、既存の項目の変更として扱います |
| 全項目が終わる | すべての項目について、エージェントが実装を終えたと判断し、その判断をチェックポイントに記録した状態 |
| 依頼の完了 | Ready にした HEAD で、門の結果が緑になった時点 |

### 1.4 テストと結果

| 語 | 定義 |
|---|---|
| 単体テスト全部 | `striusTests` ターゲットのすべてのテスト |
| E2E | `scripts/ci/ui-test-plan.json` の `pr` に載っている UI テストのクラス。2026-10-20 時点では `WorkbookE2EFixesUITests`・`DeviceWorkbookUITests`・`DeviceChatUITests`・`MinimumLoopE2ETests`・`E2EDriverUITests` |
| 変更に関係する UI テスト | `scripts/ci/ui_test_plan.py --tier pr` が、main との差分のファイルと `ui-test-plan.json` の `paths` の対応表から選ぶ UI テストのクラス。差分が `["*"]` の対象に当たれば、すべての UI テストになります |
| 緑 | 対象のテストがすべて成功し、ビルドも成功した状態。外部の入力がない時に理由付きで skip する既存のテスト(`docs/testing.md`)は許します。skip・期待失敗化・判定緩和・Re-run を新たに加えて成功させたものは、緑に含めません |
| 赤 | 緑でない状態。テストの失敗、時間切れ、ビルドの失敗、途中で終わった実行を含みます |
| ソースを読むテスト | 実行中にリポジトリのファイルを読むテスト。Xcode Cloud のテスト側のマシンにはソースがないので、そこでは必ず赤になります |
| カメラを使うテスト | simulator のカメラを起動するテスト |

### 1.5 手元検証と門

| 語 | 定義 |
|---|---|
| 手元検証 | エージェントが自分の runner で流すテスト。目的は、不具合を見つけてその場で直すことです |
| 作業中の手元検証 | 全項目が終わる前に、エージェントが自分の判断で流す手元検証。対象も回数も問いません |
| 完了前の手元検証 | 全項目が終わった後、Ready にする前に流す手元検証。対象は、単体テスト全部、E2E、変更に関係する UI テストです |
| 手元検証の記録 | 完了前の手元検証について、HEAD の SHA、流したテストの一覧、それぞれの結果、実行した日時をまとめたもの。チェックポイントと PR の本文に残します |
| 門 | マージしてよいかを決める検証。エージェントの外(Xcode Cloud)で流し、エージェントは結果を変えられません。対象は、完了前の手元検証と同じセットから、ソースを読むテストとカメラを使うテストを除いたものです |
| 門の結果 | 門を流した HEAD の SHA と、その緑か赤か |
| 門の予備 | Xcode Cloud の時間が尽きた時に、門の代わりに GitHub で流す `ios.yml` の `pr` 段階 |
| Xcode Cloud の今月の時間 | Apple の請求期間ごとの使用可能時間(無料枠は25時間)。カレンダー月とは限りません |
| 時間が尽きた | Xcode Cloud の今月の残り時間が、門1回の見積もり時間を下回った状態。残り時間をどう取得するかは未決です |
| 門の起動回数の上限 | 1つの Issue で門を起動できる回数の上限。Ready にするたびに1回と数えます。具体的な数は未決で、門1回の実測時間が出てから決めます |
| 待たない | 門を起動したエージェントが、その結果が出るまで runner を使い続けないこと。門を起動したら、セッションを終えて runner を手放します |
| 起こす | 門の結果が出た時に、同じ Issue の worker を新しく起動すること |

### 1.6 Ready と中断

| 語 | 定義 |
|---|---|
| Ready | ある HEAD について「作業を終え、完了前の手元検証が緑だったので、門にかけてほしい」と宣言した状態。PR の Draft を外すことで表します。条件と解除は4節に書きます |
| 6時間の上限 | GitHub の job の実行時間の上限。2026-10-20 時点の設定は、Claude の step が240分、`worker` ジョブ全体が340分です |
| 上限が近づく | Claude の step が240分の打ち切りに達した状態 |
| 中断 | 上限が近づいた時、または runner の強制終了などで、エージェントの作業が途中で終わること |
| 自動再開 | 中断の後、最新のチェックポイントから同じ Issue の作業を新しい runner で続けること。連続して3回までです |
| Linux で済む検査 | `agent-tests.yml`(エージェントの仕組みのテスト)。Linux のジョブで走ります |

### 1.7 チェックポイント

| 語 | 定義 |
|---|---|
| チェックポイント | runner を引き継ぐために R2 に保存するデータ一式。中身は、セッション、未コミットの差分、未追跡のファイル、未 push の commit、項目ごとの完了の記録、手元検証の記録です。保存先は `sessions/{Issue番号}/checkpoints/{保存ID}/` です |
| 最新のチェックポイント | `sessions/{Issue番号}/workspace.json` が指しているチェックポイント。自動再開は常にこれから行います |
| 定期バックアップ | worker の実行中、15分ごとにチェックポイントを保存すること。15分は仮の値です |
| 使わなかったチェックポイント | 最新と、その1つ前以外のチェックポイント。依頼の完了の後は、その Issue のすべてのチェックポイントです |

---

## 2. 方針の柱

1. 不具合を見つけて直す作業は、エージェントが手元検証でやります。
2. マージしてよいかは、門で決めます。手元検証が緑でも門は省略しません。門が緑でも、手元検証の記録がない変更はマージしません。
3. 門は Ready の HEAD に対して流します。Draft の間は流しません。
4. runner はエージェントの作業に使います。エージェント以外で使うのは、bootstrap のキャッシュ作成、prototype、門の予備、の3つに限ります。
5. 門とリリースは、Xcode Cloud を基本にします。
6. 使わなかったチェックポイントと cache は、削除します。削除を忘れても期限で消える仕組みを、最後の段に置きます。

---

## 3. 前提

### 3.1 確かめた事実

| 事実 | 根拠 |
|---|---|
| 家に常時動かせる Mac がないので、runner がエージェントの Mac になっている | Tomochika の説明 |
| runner は同時に5台まで。1台は M1・3コア・7GB | `ios.yml` のコメント、Issue #22 |
| 自動再開で持ち越しているのは、bootstrap の成果物(Actions cache)とチェックポイント(R2)。DerivedData は持ち越していない | `agentctl.py` の `save_workspace` |
| チェックポイントの保存は、worker の終了処理と中断の時だけ。runner が強制終了されて終了処理が走らないと、前に保存できたチェックポイントから復元する | `agentctl.py`、`docs/agent.md` |
| チェックポイントは実行のたびに別の保存先に作られ、古いものは消されない。R2 の前の Worker には、オブジェクトの削除の API がない(PUT と GET だけ) | `agentctl.py`、`cloudflare/agent/src/index.js` |
| エージェントは `GITHUB_TOKEN` で PR を操作している。`GITHUB_TOKEN` による操作では、`pull_request` 系の workflow が起動しない | `docs/agent.md` |
| 2026-10-20 時点の仕組みでは、エージェント1体が PR の CI を待つ間、自分の runner に加えて、最大3台の runner を使っていた | `scripts/agent/system-prompt.md`、`ios.yml` |
| 2026-10-15〜16 の #22 のループは、「CI が赤なら自動再開」と「再開後に #22 の次の番号の項目に進み、HEAD が変わる」の組み合わせで起きた。エージェントは CI で落ちたテストを手元で再現していたが、push の前に全体を手元で確かめてはいなかった | `docs/handoff-2026-10-17.md`、worker のログ(run 38814258093 など) |
| Xcode Cloud の無料枠は月25時間で、並列に走るアクションの時間は合算で数える。余った時間は繰り越せない | Apple「Get started with Xcode Cloud」 |
| 今月の Xcode Cloud の残りは25時間 | Tomochika の確認(2026-10-20) |
| Xcode Cloud のテストは、ビルドとは別のマシンで流れる。そのマシンにはソースがない | Apple「Configuring your Xcode Cloud workflow's actions」 |
| Xcode Cloud の simulator ではカメラが使えなかった | 旧リポジトリの `docs/verification/subunit-layout-2026-09-25/README.md` |
| Xcode Cloud は、Clean にしなければ DerivedData とキャッシュ情報をビルド間で保存する | Apple「Xcode Cloud workflow reference」 |
| 2026-10-20 の初回調査時、Xcode Cloud の `Default` は旧パスを参照して #38 のマージで失敗していた。その後 Tomochika から修正済みとの報告があった | #38 の merge commit の check run、Tomochika の説明(2026-10-20) |
| `ci_post_clone.sh` は、旧リポジトリの workflow 名(`Hyotan Native ...`)で処理を分けている。ビルド番号は `CI_BUILD_NUMBER` で自動で上げている | `ci_scripts/ci_post_clone.sh` |
| GitHub の `signed-archive` は、手入力の `build_number` を使う | `ios.yml` |
| Actions cache は、リポジトリあたり既定で10GB、最終アクセスから7日で消える。上限を超えると、最近使われていないものから消される | GitHub Changelog(2025-11-20) |
| R2 の lifecycle rule は、接頭辞ごとに「作成から N 日で削除」を設定できる。期限から24時間以内に消える | Cloudflare「Object lifecycles」 |
| E2E のクラスのうち、`DeviceWorkbookUITests`・`WorkbookE2EFixesUITests` にはカメラに触れる記述があり、`DeviceChatUITests` には `#filePath` を使う記述がある。実際にカメラやソースを使うテストメソッドがどれかは、まだ確かめていない | grep の結果 |

### 3.2 仮説

| 仮説 | 根拠 |
|---|---|
| Xcode Cloud のマシンは、runner より大幅に強い | simulator 8台での並列テスト(旧リポジトリの 2026-09-25 の記録)。Python・rustup の導入から BSD・dash の device 用ビルドまでが2分弱で終わっていた(Cloud120 の `ci_post_clone.log`) |
| Xcode Cloud で時間がかかっていた主な原因は、Codex の Rust ビルドをゼロからやり直していることと、テストを2台のマシンに分けて流すこと | `NativeRuntime/Scripts/build-codex.py` が毎回 openai/codex を clone して release でビルドする。Xcode Cloud では `~/.cargo` と `NativeRuntime/.build/codex` が毎回空になる |

---

## 4. Ready の条件と解除

### 4.1 Ready にしてよい条件

次の3つを、すべて満たした時だけ Ready にできます。

1. 全項目が終わっている。
2. HEAD を push してある。
3. その HEAD の SHA で、完了前の手元検証が緑だった手元検証の記録がある。

### 4.2 Ready にする手順

| 誰が | どう Ready にするか | 門の起動 |
|---|---|---|
| エージェント | `agentctl` で4.1の3つの条件を確かめてから Draft を外す | `agentctl` が同時に起動する(`GITHUB_TOKEN` の操作では `pull_request` のイベントが起きないため) |
| Tomochika | GitHub の画面で Draft を外す | `pull_request` の `ready_for_review` イベントで、Linux のジョブが起動する |

どちらの場合も、門を起動する処理は同じスクリプトを使います。

### 4.3 Ready が意味しないこと

Ready は、マージの承認でも、依頼の完了でもありません。

### 4.4 Ready の解除

| 起きたこと | 解除の仕方 |
|---|---|
| 門の結果が赤だった | エージェントが Draft に戻し、直して、完了前の手元検証からやり直します |
| Ready の後に HEAD が変わった | Linux のジョブが Draft に戻します。前の SHA の門の結果は使いません |
| 門の起動回数の上限に達した | Ready にできなくなります。その後どうするかは、Tomochika が Issue のコメントで指示します |

---

## 5. 役割分担

| 仕事 | どこで | いつ |
|---|---|---|
| 作業中の手元検証 | エージェントの runner | 全項目が終わる前、エージェントの判断で |
| 完了前の手元検証 | エージェントの runner | Ready にする前に毎回 |
| 門 | Xcode Cloud | Ready になるたびに |
| 門の予備 | GitHub(`ios.yml`) | Xcode Cloud の時間が尽きた時 |
| リリース(全件の UI テストと、TestFlight 内部配布用の archive) | Xcode Cloud | リリースブランチが決まるまでは手動で |
| bootstrap のキャッシュ作成 | GitHub(`agent-native-cache.yml`) | `NativeRuntime/` が変わった時(今のまま) |
| prototype | GitHub(`agent-prototype.yml`) | 依頼された時(今のまま) |

Draft への push と main への push では、macOS の検証を起動しません。Linux で済む検査は今のまま走らせます。

### 5.1 やめる候補

| やめる候補 | やめる条件 |
|---|---|
| 毎晩の全件 UI テスト(`ios.yml` の `schedule`) | Release workflow で全件が通るのを確かめてから |
| main への push ごとの `signed-archive` | TestFlight 配信を Xcode Cloud に移してから |
| `ios-cold.yml` | Release workflow のビルドが、まっさらな clone から通るのを確かめてから |

---

## 6. エージェントの流れ

1. 全項目をやります。途中で作業中の手元検証を流し、WIP を push します。
2. 全項目が終わったら、完了前の手元検証を流します。赤なら直して流し直します。
3. 緑になったら、手元検証の記録を残して Ready にし、門を起動して待ちません。
4. 門の結果が出たら起こされます。緑なら依頼の完了です。赤なら Draft に戻して直し、2に戻ります。
5. 中断したら、どの段階でも、最新のチェックポイントから自動再開して続けます。

worker の実行中は、どの段階でも定期バックアップを取ります。

---

## 7. チェックポイントの保存と削除

### 7.1 保存

- worker の終了処理と中断の時の保存に加えて、定期バックアップを取ります。定期バックアップは、Claude の実行中ずっと動いている `progress.py` から行います。
- 保存の順番は、新しい保存先に全部の部品を書き終えてから、`workspace.json` を新しい保存先に向け直す、です。書いている途中で runner が落ちても、`workspace.json` は直前の完全な保存先を指したままになります。
- `workspace.json` の書き換えには、条件付き書き込み(`If-Match`)を使います。終了処理の保存と定期バックアップがぶつかっても、片方が古い内容で上書きしないようにするためです。

### 7.2 削除

削除は3段にします。

| 段 | いつ | 何を消すか |
|---|---|---|
| 1. 保存のたびに | `workspace.json` を新しい保存先に向け直した直後 | 同じ Issue の、使わなかったチェックポイント(最新と1つ前以外) |
| 2. 依頼が終わったら | 依頼の完了、Issue のクローズ、PR のマージ、PR のクローズのどれかが起きた時 | その Issue のすべてのチェックポイント |
| 3. 期限で | R2 の lifecycle rule。作成から14日(仮の値) | `sessions/` の下のチェックポイント |

- 人の指示での再開は新しいセッションで始める方針なので、依頼の完了の後のチェックポイントは使いません。
- 1段目と2段目のために、Worker に削除の API を加えます。削除できる範囲は `sessions/{Issue番号}/checkpoints/` の下だけに限ります。
- 3段目は、1段目と2段目が失敗した時の最後の歯止めです。

### 7.3 DerivedData の cache

- エージェントの runner で使う DerivedData を、ブランチごとに Actions cache に置きます。
- PR がマージされた時かクローズされた時に、Linux のジョブでそのブランチの cache を削除します。
- 理由は、Actions cache の上限(既定で10GB)を超えると、最近使われていないものから消されるためです。DerivedData の cache が溜まると、bootstrap の成果物の cache(作り直しに約43分)が消されるおそれがあります。
- cache の今の合計サイズは未確認です。8節の1本目の PR の中で、workflow から測ります。

---

## 8. 変更点

### 8.1 エージェント(`scripts/agent/`、`agent.yml`)

- `system-prompt.md` の19・22・24行目を、1節の語で書き直します。
- 終了処理の完了の条件を、依頼の完了の定義に合わせます。
- `agentctl` に、Ready にする処理(4.1の条件を確かめ、Draft を外し、門を起動する)と、Draft に戻す処理を加えます。
- 2026-10-20 時点の `request-pr` の CI の dispatch と、`verify_pr_ci`・`pr-ci.json` などは、エージェントが結果を待つ前提で作られています。これを門の起動の仕組みに置き換えます。起動先は Xcode Cloud で、門の予備として `ios.yml` も使える形にします。待つ部分は消します。
- PR #29 で入れた `restartKind=validation` は、門の結果が赤の時の再開と役割が重なります。消すか作り直すかは未決です。
- 自動再開(連続3回まで)は残します。
- チェックポイントに、項目ごとの完了の記録と、手元検証の記録を加えます。
- `progress.py` に定期バックアップを加えます。
- 7.2 の削除の1段目と2段目を実装します。
- ブランチごとの DerivedData の Actions cache を加えます。

### 8.2 Worker と R2(`cloudflare/agent/`)

- Worker に、`sessions/{Issue番号}/checkpoints/` の下に限った削除の API を加えます。
- R2 のバケット `struis-agent` に、7.2 の3段目の lifecycle rule を設定します。

### 8.3 Xcode Cloud

- `Default` workflow を「PR Gate」に作り替えます。プロジェクトのパスを `strius.xcodeproj` に直し、App Store Connect API から起動します。録画とコードカバレッジは切ります。
- 「Release」workflow を新しく作ります。
- テストプランを、PR Gate 用と Release 用の2つ作ります(2026-10-20 時点で `.xctestplan` はありません)。ソースを読むテストとカメラを使うテストの一覧は、テストプランを作る時にテストメソッドの単位で確かめて決めます。E2E のメソッドがこれに当たった場合、そのメソッドは門から外れ、完了前の手元検証だけで確かめることになります。
- `ci_post_clone.sh` を直します。workflow 名での分岐を新しい名前に合わせ、工程ごとの時刻とマシンのスペックを出し、Codex のビルド先(`CARGO_TARGET_DIR`)を `CI_DERIVED_DATA_PATH` の下に置いて、キャッシュが効くかを試します。
- ビルド番号の付け方を一本化します。TestFlight 配信を Xcode Cloud に移した時点で、`CI_BUILD_NUMBER` による自動の番号に揃えます。

### 8.4 GitHub の workflow

- `ios.yml`:`pull_request` での macOS ジョブを止め、門の予備として手動で起動できる形に変えます。毎晩の実行と、push での `signed-archive` は、5.1 のやめる条件を満たしてから外します。
- Linux のジョブを3つ加えます。
  - `ready_for_review` で門を起動するジョブ
  - Ready の後に HEAD が変わったら Draft に戻すジョブ
  - PR のマージかクローズで、チェックポイントと DerivedData の cache を削除するジョブ
- 門の結果が出たら worker を起こす配線を入れます。第一案は `check_run`(completed)イベントです。動かなかった場合は、門を起動した側が定期的に結果を確かめる方式にします。

---

## 9. 確かめる仮説

| 仮説 | 確かめ方 | 外れた時 |
|---|---|---|
| Codex のビルドを Xcode Cloud のキャッシュで持ち越せる | 同じ workflow を2回走らせて比べる | Codex の成果物を R2 などに置いて取ってくる方式を検討する |
| 門1回は15分前後で終わる | PR Gate の実測 | 門の対象を減らす |
| UI テストの前の長い待ち(2026-09-25 の記録で50〜60分)は、録画・カバレッジと件数が原因 | 両方を切って測る | 門から UI テストを外し、完了前の手元検証で担う |
| Xcode Cloud の check run で `check_run` イベントが起動する | テスト用の workflow で試す | 定期的に結果を確かめる方式にする |
| 定期バックアップを15分ごとに取っても、エージェントの作業を遅らせない | 保存1回にかかる時間を測る | 間隔を延ばすか、差分だけを保存する |

---

## 10. 進める順番

PR は3本にまとめ、それぞれ出す前に相談します。

1. **Xcode Cloud の土台。** `ci_post_clone.sh`、テストプラン、この文書の `docs/` への追加です。App Store Connect の `Default` の作り替えは、Tomochika が内蔵ブラウザで App Store Connect にサインインした後、Claude が行います。2回走らせて、9節の1〜3を確かめます。Actions cache の合計サイズもここで測ります。
2. **エージェントの流れ。** 8.1 と 8.2 です。1の実測が出てから入れます。
3. **GitHub の workflow の整理。** 8.4 です。

---

## 11. 参照

- `docs/agent.md`、`docs/agent-slimming.md`、`docs/handoff-2026-10-17.md`、`docs/build.md`、`docs/testing.md`
- `scripts/agent/system-prompt.md`、`scripts/agent/agentctl.py`、`scripts/agent/progress.py`
- `scripts/ci/ui_test_plan.py`、`scripts/ci/ui-test-plan.json`
- `.github/workflows/ios.yml`、`agent.yml`、`agent-recovery.yml`、`agent-native-cache.yml`、`agent-prototype.yml`、`ios-cold.yml`
- `ci_scripts/ci_post_clone.sh`、`ci_scripts/ci_post_xcodebuild.sh`
- `cloudflare/agent/src/index.js`、`cloudflare/agent/wrangler.toml`
- 旧リポジトリ DigiLog-lab/struis:`docs/verification/subunit-layout-2026-09-25/README.md`、`docs/verification/hyotan-operation-harness-2026-10-02/cloud120-dash-build-graph-fix/cloud120-build-failure-excerpt.txt`
- Apple「Get started with Xcode Cloud」 https://developer.apple.com/xcode-cloud/get-started
- Apple「Xcode Cloud workflow reference」 https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference
- Apple「Configuring your Xcode Cloud workflow's actions」 https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions
- GitHub Changelog「GitHub Actions cache size can now exceed 10 GB per repository」(2025-11-20) https://github.blog/changelog/2025-11-20-github-actions-cache-size-can-now-exceed-10-gb-per-repository/
- Cloudflare「Object lifecycles」 https://developers.cloudflare.com/r2/buckets/object-lifecycles