# struis-ios 検証と配信の方針

- 作成: 2026-10-20、改訂: 2026-10-21
- 状態: PR #39 で実装。マージは Tomochika が行う
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
| 制御ジョブ | `agent.yml` の `control` ジョブ(門の起動と結果の照合)と `cleanup` ジョブ(削除)。Linux のジョブで、main のコードだけを実行します |
| セッション | Claude Code の会話の続き。`--resume` で再開する単位です |
| main | リポジトリの既定のブランチ |
| マージ | PR の変更を main に取り込むこと。行うのは Tomochika で、エージェントは行いません |
| リリースブランチ | 未決。決まるまでは、Release を main から依頼に応じて起動します(5節) |

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
| E2E | `scripts/ci/ui-test-plan.json` の `pr` に載っている UI テストのクラス。2026-10-21 時点では `WorkbookE2EFixesUITests`・`WorkbookLongConversationUITests`・`WorkbookOnboardingUITests`・`DeviceWorkbookUITests`・`DeviceChatUITests`・`MinimumLoopE2ETests`・`E2EDriverUITests` |
| 変更に関係する UI テスト | `scripts/ci/ui_test_plan.py --tier pr` が、main との差分のファイルと `ui-test-plan.json` の `paths` の対応表から選ぶ UI テストのクラス。差分が `["*"]` の対象に当たれば、すべての UI テストになります。変更した UI テストのファイルに書かれたクラスは、すべて選ばれます |
| 緑 | 対象のテストがすべて成功し、ビルドも成功した状態。外部の入力がない時に理由付きで skip する既存のテスト(`docs/testing.md`)は許します。skip・期待失敗化・判定緩和・Re-run を新たに加えて成功させたものは、緑に含めません |
| 赤 | 緑でない状態。テストの失敗、時間切れ、ビルドの失敗、途中で終わった実行を含みます |
| 性能テスト | 時間を測るテスト。2026-10-21 時点では `striusUITests/testLaunchPerformance` だけです |

### 1.5 手元検証と門

| 語 | 定義 |
|---|---|
| 手元検証 | エージェントが自分の runner で流すテスト。目的は、不具合を見つけてその場で直すことです |
| 作業中の手元検証 | 全項目が終わる前に、エージェントが自分の判断で流す手元検証。対象も回数も問いません |
| 完了前の手元検証 | 全項目が終わった後、Ready にする前に流す手元検証。対象は、単体テスト全部、E2E、変更に関係する UI テストです |
| 手元検証の記録 | 完了前の手元検証について、HEAD の SHA、流したテストの一覧、それぞれの結果、実行した日時をまとめたもの。チェックポイントと PR の本文に残します |
| 門 | マージしてよいかを決める検証。エージェントの外(Xcode Cloud)で流し、エージェントは結果を変えられません。対象は、完了前の手元検証と同じセットから、性能テストを除いたものです。UI テストはクラスを単位に並列で流すので、性能テストの値は意味を持たないためです(性能テストは Release で直列に流します) |
| 門の結果 | 門を流した HEAD の SHA と、その緑か赤か。制御ジョブが commit status `Struis / Ready gate` に書きます |
| 門の予備 | Xcode Cloud が門の開始を受け付けなかった時に、門の代わりに GitHub で流す `ios.yml` の `pr` 段階 |
| Xcode Cloud の今月の時間 | Apple の請求期間ごとの使用可能時間(無料枠は25時間)。カレンダー月とは限りません |
| 時間が尽きた | Xcode Cloud が門の開始の要求に HTTP 4xx で応え、ビルドを作らなかった状態。今月の時間切れを含みます。残り時間を API で前もって知る方法は確かめられていないので、開始を試して断られたら切り替えます |
| 門の起動回数の上限 | 1つの Issue で門を起動できる回数の上限。Ready にするたびに1回と数えます。3回です(`scripts/agent/gate-config.json`) |
| 待たない | 門を起動したエージェントが、その結果が出るまで runner を使い続けないこと。門を起動したら、セッションを終えて runner を手放します。結果を待つのは制御ジョブ(Linux)です |
| 起こす | 門の結果が出た時に、同じ Issue の worker を新しく起動すること |

### 1.6 Ready と中断

| 語 | 定義 |
|---|---|
| Ready | ある HEAD について「作業を終え、完了前の手元検証が緑だったので、門にかけてほしい」と宣言した状態。PR の Draft を外すことで表します。条件と解除は4節に書きます |
| 6時間の上限 | GitHub の job の実行時間の上限。設定は、Claude の step が240分、`worker` ジョブ全体が340分です |
| 上限が近づく | Claude の step が240分の打ち切りに達した状態 |
| 中断 | 上限が近づいた時、または runner の強制終了などで、エージェントの作業が途中で終わること |
| 自動再開 | 中断の後、最新のチェックポイントから同じ Issue の作業を新しい runner で続けること。連続して3回までです |
| Linux で済む検査 | `agent-tests.yml`(エージェントの仕組みのテスト)。Linux のジョブで走ります |

### 1.7 チェックポイント

| 語 | 定義 |
|---|---|
| チェックポイント | runner を引き継ぐためのデータ一式。中身は、セッション、未コミットの差分、未追跡のファイル、未 push の commit、項目ごとの完了の記録、手元検証の記録です。1回の保存を、worker の実行の GitHub の Artifact 1つ(名前は `agent-ckpt-{Issue番号}-{保存ID}`)として保存します |
| 最新のチェックポイント | 保存先(Cloudflare の Worker と R2)の `sessions/{Issue番号}/workspace.json` が指しているチェックポイント。自動再開は常にこれから行います |
| 定期バックアップ | worker の実行中、15分ごとにチェックポイントを保存すること |
| 使わなかったチェックポイント | 最新と、その1つ前以外のチェックポイント。依頼の完了の後は、その Issue のすべてのチェックポイントです |

---

## 2. 方針の柱

1. 不具合を見つけて直す作業は、エージェントが手元検証でやります。
2. マージしてよいかは、門で決めます。手元検証が緑でも門は省略しません。門が緑でも、手元検証の記録がない変更はマージしません。
3. 門は Ready の HEAD に対して流します。Draft の間は流しません。
4. runner はエージェントの作業に使います。エージェント以外で使うのは、bootstrap のキャッシュ作成、prototype、門の予備、の3つに限ります。
5. 門とリリースは、Xcode Cloud を基本にします。
6. 使わなかったチェックポイントと cache は、削除します。削除を忘れても期限で消える仕組み(Artifact の保存期間14日)を、最後の段に置きます。
7. 仕組みを動かすのに、リポジトリの変数・Secrets の追加、Worker のデプロイ、R2 の設定変更を要しません。設定はリポジトリのファイルに置きます。

---

## 3. 前提

### 3.1 確かめた事実

| 事実 | 根拠 |
|---|---|
| 家に常時動かせる Mac がないので、runner がエージェントの Mac になっている | Tomochika の説明 |
| runner は同時に5台まで。1台は M1・3コア・7GB | `ios.yml` のコメント、Issue #22 |
| 2026-10-20 時点の仕組みでは、チェックポイントの保存は worker の終了処理と中断の時だけで、古いものは消されなかった | 当時の `agentctl.py`、`cloudflare/agent/src/index.js` |
| デプロイ済みの Worker は main のコードのままで、オブジェクトを削除する機能がない(PUT・GET・multipart の中断だけ)。認証は job の workflow ファイル(`job_workflow_ref`)で判定する | デプロイ済みのコードを Cloudflare の API で取得して確認(2026-10-21) |
| R2 の lifecycle rule の接頭辞にはワイルドカードが使えず、`sessions/*/checkpoints/` は書けない | Cloudflare「Object lifecycles」 |
| エージェントは `GITHUB_TOKEN` で PR を操作している。`GITHUB_TOKEN` による操作では、`pull_request` 系の workflow が起動しない。`workflow_dispatch` と `repository_dispatch` は起動する | `docs/agent.md`、GitHub「GITHUB_TOKEN」 |
| `repository_dispatch` の送信は `contents: write` で足りる | GitHub の REST API 文書 |
| 2026-10-20 時点の worker は `actions: write` を持っていた(main も同じ)。workflow の起動に使っていたが、実行の Re-run・取消・Artifact の削除もできる権限だった | `agent.yml` |
| 2026-10-15〜16 の #22 のループは、「CI が赤なら自動再開」と「再開後に #22 の次の番号の項目に進み、HEAD が変わる」の組み合わせで起きた | `docs/handoff-2026-10-17.md`、worker のログ(run 38814258093 など) |
| Xcode Cloud の無料枠は月25時間で、並列に走るアクションの時間は合算で数える。余った時間は繰り越せない | Apple「Get started with Xcode Cloud」 |
| 2026-10-21 時点の Xcode Cloud の残りは13時間 | Tomochika の確認(2026-10-21) |
| Xcode Cloud のテストは、ビルドとは別のマシンで流れる。そのマシンにはソースがない | Apple「Configuring your Xcode Cloud workflow's actions」 |
| カメラを使う UI テストは Xcode Cloud でも動く。simulator ではテスト用の紙の画像を使う。Release 154 では、カメラ画面を開く13本のうち11本が成功し、2本は既存の skip(実機・実 Codex)だった | App Store Connect API のテスト結果(2026-10-21)、`striusUITests/UITestSupport.swift` |
| Xcode Cloud は、Clean にしなくても、カスタムの Rust の出力(`CI_DERIVED_DATA_PATH/StruisNative/cargo`)を次のビルドに持ち越さなかった(PR Gate 153 の終了時 3,941,748 KiB → 156 の開始時 0 KiB) | PR Gate 153・156 のログ |
| 門(PR Gate)は1回44分だった。内訳はテストの実行29分36秒、post-clone 7分04秒(うち native の準備6分01秒)、テスト用のビルド1分28秒、その他約6分 | PR Gate 153・156 のログ |
| PR Gate 156 の UI テスト44本の所要時間の合計は約1,012秒、単体テストは約56秒。UI テストは直列(`parallelizable: false`)で流れていた | App Store Connect API のテスト結果、当時の `TestPlans/PRGate.xctestplan` |
| Xcode Cloud のテストの実行は `-maximum-parallel-testing-workers 8` で起動される | Release 155 のテストのログ |
| Xcode の並列テストは、クラスを単位にシミュレーターの複製へ配る。1つのクラスに詰めたテストは並列にならない | Apple WWDC18「What's New in Testing」 |
| Xcode Cloud での UI テストの画面録画は、開始・終了とも1回0.03〜0.05秒で、時間の原因ではない | PR Gate 156 の結果の束の runner のログ |
| TestFlight には、バージョン 1.0 のビルド 156・157・158(旧経路、10/8〜10/13)が残っている。Xcode Cloud の次のビルド番号は158 | App Store Connect API(2026-10-21) |
| 2026-10-21 06:05 の main の夜間の赤(`ChatCameraUITests` の「Failed to terminate」)では、xcodebuild はアプリの終了を要求の約9秒後に観測していた。XCTest の runner だけが状態を「Running Foreground」のまま60秒待って失敗した。要求が xcodebuild に届くまで4.4秒かかっており、3コアの runner の負荷が高かった | 夜間の実行の結果の束(run 39497496212) |
| Actions cache は、リポジトリあたり既定で10GB、最終アクセスから7日で消える。上限を超えると、最近使われていないものから消される | GitHub Changelog(2025-11-20) |

### 3.2 仮説

| 仮説 | 根拠 |
|---|---|
| 門の UI テストを8台の複製で並列にし、長いテストを1クラス1本に分ければ、門は15分前後になる | 3.1 の内訳と UI テストの所要時間の合計。最長の1本は20往復の会話で約187秒 |
| UI テストで要素の確認1回が十数秒返らない場面は、XCUITest がアプリのメインスレッドで要素の木を作らせていることによる | `WorkbookE2EFixesUITests` のコメント、GitHub の UI テストのログの集計。8.3 の計測で確かめる |

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
| エージェント | `agentctl ready` で4.1の3つの条件を確かめてから Draft を外す | 同時に `repository_dispatch`(`agent-gate`)で制御ジョブを起動する |
| Tomochika | GitHub の画面で Draft を外す | `pull_request_target` の `ready_for_review` で制御ジョブが起動する |

どちらの場合も、制御ジョブは同じ手順で最新のチェックポイントの手元検証の記録を確かめてから門を起動します。

### 4.3 Ready が意味しないこと

Ready は、マージの承認でも、依頼の完了でもありません。

### 4.4 Ready の解除

| 起きたこと | 解除の仕方 |
|---|---|
| 門の結果が赤だった | 制御ジョブが Draft に戻し、エージェントを起こします。エージェントは直して、完了前の手元検証からやり直します |
| Ready の後に HEAD が変わった | 制御ジョブが Draft に戻します。前の SHA の門の結果は使いません |
| 門の起動回数の上限に達した | Ready にできなくなります。その後どうするかは、Tomochika が Issue のコメントで指示します |

---

## 5. 役割分担

| 仕事 | どこで | いつ |
|---|---|---|
| 作業中の手元検証 | エージェントの runner | 全項目が終わる前、エージェントの判断で |
| 完了前の手元検証 | エージェントの runner | Ready にする前に毎回 |
| 門 | Xcode Cloud(PR Gate) | Ready になるたびに |
| 門の予備 | GitHub(`ios.yml`) | Xcode Cloud が門の開始を受け付けなかった時 |
| 門の結果を待つ | 制御ジョブ(Linux) | 門の実行中 |
| リリース(全件の UI テストを直列で、TestFlight 内部配布用の archive) | Xcode Cloud(Release) | 依頼された時だけ。`repository_dispatch`(`xcode-cloud`)で、main から |
| bootstrap のキャッシュ作成と、Xcode Cloud 用の native の生成物の公開 | GitHub(`agent-native-cache.yml`) | `NativeRuntime/` が変わった時 |
| prototype | GitHub(`agent-prototype.yml`) | 依頼された時 |

Draft への push と main への push では、macOS の検証を起動しません。Linux で済む検査は今のまま走らせます。PR に `ios-verify` ラベルを付けた時だけ、GitHub の iOS 検証を診断として流せます。

### 5.1 やめたもの

| やめたもの | 理由 |
|---|---|
| 毎晩の全件 UI テスト(`ios.yml` の `schedule`) | Release(Xcode Cloud)で全件が通ることを確かめた(Release 154・155)。全件は依頼に応じて Release で流す |
| main への push ごとの `signed-archive` | TestFlight 配信を Xcode Cloud の Release で確かめた(Release 155) |

`ios-cold.yml`(まっさらな clone からの build)は残します。

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
- 1回の保存の部品は、worker の実行の Artifact 1つにまとめます。Artifact の保存には、JavaScript の action にだけ渡される資格情報が要るので、`actions/github-script` で worker の作業フォルダの権限0600のファイルに書き出して使います。
- 保存の順番は、Artifact のアップロードを終えてから、`workspace.json` を新しい保存に向け直す、です。書いている途中で runner が落ちても、`workspace.json` は直前の完全な保存を指したままになります。
- `workspace.json` の書き換えには、条件付き書き込み(`If-Match`)を使います。終了処理の保存と定期バックアップがぶつかっても、片方が古い内容で上書きしないようにするためです。
- 復元の時は、各部品の SHA-256 を確かめ、Artifact を作った実行が main の `agent.yml` であることを API で確かめます。公開リポジトリなので、フォークや別のブランチの実行が同じ名前の Artifact を作れるためです。

### 7.2 削除

削除は3段にします。

| 段 | いつ | 何を消すか |
|---|---|---|
| 1. worker の後に | 同じ実行の `checkpoint-gc` ジョブ(Linux) | 同じ Issue の、使わなかったチェックポイント |
| 2. 依頼が終わったら | 依頼の完了、Issue のクローズ、PR のマージ、PR のクローズのどれかが起きた時。取りこぼしは1時間ごとの照合で拾う | その Issue のすべてのチェックポイント |
| 3. 期限で | Artifact の保存期間14日 | すべてのチェックポイント |

- worker は `actions: write` を持たないので、削除は Linux のジョブで行います。
- 作られてから10分未満の、`workspace.json` がまだ指していない Artifact は消しません。保存の途中のものを消さないためです。
- 人の指示での再開は新しいセッションで始める方針なので、依頼の完了の後のチェックポイントは使いません。
- 2026-10-20 以前に R2 に保存されたチェックポイントは、消す手段がないので残します。

### 7.3 DerivedData の cache

- エージェントの runner で使う DerivedData を、ブランチごとに Actions cache に置きます。
- PR がマージされた時かクローズされた時に、Linux のジョブでそのブランチの cache を削除します。
- 理由は、Actions cache の上限(既定で10GB)を超えると、最近使われていないものから消されるためです。DerivedData の cache が溜まると、bootstrap の成果物の cache(作り直しに約43分)が消されるおそれがあります。
- cache の合計サイズは、`Agent tests` の実行のたびに記録します。

---

## 8. 変更点(PR #39)

### 8.1 エージェント(`scripts/agent/`、`agent.yml`)

- `agentctl` に、Ready にする処理(4.1の条件を確かめ、Draft を外し、門を起動する)と、Draft に戻す処理を加えました。
- 結果を待つ前提だった `request-pr` の CI の起動と確認を、門の起動の仕組みに置き換えました。
- チェックポイントに、項目ごとの完了の記録と、手元検証の記録を加えました。部品は Artifact に、指し先だけを R2 に置きます(`checkpoints.py`、`artifacts.py`)。
- `progress.py` に定期バックアップを加えました。
- worker の権限から `actions: write` を外し、起動(自動再開、門、prototype、Release)を `repository_dispatch` にしました。エージェントは門を決める実行の Re-run・取消・Artifact の削除ができません。
- 門の制御ジョブと削除のジョブを `agent.yml` に置きました。デプロイ済みの Worker が受け付ける workflow ファイルだからです。制御ジョブの実行名は「Agent control …」で、`agent-recovery.yml` は中断した worker と区別します。
- 門の結果は、制御ジョブだけが書ける commit status で判定します。保存先の記録は、どの `agent.yml` のジョブからも書けるので、それだけでは依頼を完了にしません。門の起動回数も commit status から数えます。
- 門の実行中は、制御ジョブが1分ごとに結果を確かめて待ちます(最長95分。それを超えたら次のイベントか1時間ごとの照合で続けます)。
- 設定は `scripts/agent/gate-config.json` に置きました(門の上限3回、定期バックアップ15分、保存期間14日、Xcode Cloud の workflow の ID など)。

### 8.2 Worker と R2(`cloudflare/agent/`)

- 変更しません。チェックポイントの削除と期限は Artifact で行います。

### 8.3 Xcode Cloud

- `Default` workflow を「PR Gate」に作り替え、「Release」を作りました。どちらも手動起動、Clean OFF です。
- テストプランを、PR Gate 用と Release 用の2つ作りました。PR Gate は UI テストを並列に流し、Release は直列に流します。
- 長い UI テストのクラスを、1クラス1本か数本に分けました(`WorkbookE2EFixesUITests` を3つ、`WorkbookSplitGradingUITests` を3つ)。テストの中身と判定は変えていません。
- `ci_post_clone.sh` は、`agent-native-cache.yml` が GitHub の Release `native-runtime` に公開した native の生成物を、同じ入力のキーで取得し、SHA-256 を確かめて使います。公開されていない入力なら、今までどおり作ります。
- UI テストで、アプリ側から見た起動の各段階とメインスレッドの止まりを記録し、テストごとに xcodebuild のログへ要約を書きます(`UITestDiagnostics`、`UITestDiagnosticsObserver`)。
- ビルド番号は `CI_BUILD_NUMBER` のままです。TestFlight の旧経路の番号と重ならないよう、`MARKETING_VERSION` を 1.0.1 にしました。

### 8.4 GitHub の workflow

- `ios.yml`:`pull_request` での実行は `ios-verify` ラベルの時だけにしました。`schedule` と `push` をやめ、門の予備と手動のリリースの経路(`workflow_dispatch`)を残しました。
- `agent.yml` に、門の起動・照合(`control`)、使わなかったチェックポイントの削除(`checkpoint-gc`)、閉じた Issue・PR の削除(`cleanup`)を加えました。
- `agent-native-cache.yml` は、cache の作成に加えて、Xcode Cloud 用の native の生成物を公開します。

---

## 9. 確かめる仮説

| 仮説 | 確かめ方 | 外れた時 |
|---|---|---|
| 門1回は15分前後で終わる | PR Gate の実測(マージ前に1回、マージ後に native の生成物を使って1回) | 門の対象のクラスの分け方と、UI テストを単体テストに移す一覧(Tomochika が判断する)で縮める |
| 要素の確認が十数秒返らないのは、XCUITest に要素の木を作らされているため | `UI_DIAGNOSTICS` の止まりの時刻と XCUITest の操作の時刻を突き合わせる | アプリが固まっているなら、操作する人にも起きる不具合として直す |
| Xcode Cloud の check run・commit status のイベントで制御ジョブが起動する | マージ後の実地検証 | 起動しなくても、制御ジョブが結果を待つので門は完了する |
| 定期バックアップを15分ごとに取っても、エージェントの作業を遅らせない | 保存1回にかかる時間を測る | 間隔を延ばす |

---

## 10. 進める順番

8.1〜8.4の実装は PR #39 の1本にまとめます。

1. マージ前:Linux の検査、GitHub の iOS 検証、Xcode Cloud の PR Gate を1回流して、門の時間と計測の数字を確かめます。
2. マージ:Tomochika が行います。
3. マージ後:エージェントが検証用の Issue を作り、Ready→門→依頼の完了と、定期バックアップの作成・削除を実地で確かめます。門が赤の時と中断の時は単体テストで確かめています。Issue #22 は、この文書に置き換えた旨を書いて閉じます。

---

## 11. 参照

- `docs/agent.md`、`docs/agent-gate.md`、`docs/xcode-cloud.md`、`docs/testing.md`
- `scripts/agent/system-prompt.md`、`scripts/agent/agentctl.py`、`scripts/agent/gate.py`、`scripts/agent/checkpoints.py`、`scripts/agent/artifacts.py`、`scripts/agent/gate-config.json`
- `scripts/ci/ui_test_plan.py`、`scripts/ci/ui-test-plan.json`、`scripts/ci/xcode_test_plan.py`、`scripts/ci/native_prebuilt.py`
- `.github/workflows/agent.yml`、`agent-recovery.yml`、`agent-native-cache.yml`、`agent-prototype.yml`、`ios.yml`、`ios-cold.yml`
- `ci_scripts/ci_post_clone.sh`、`ci_scripts/ci_post_xcodebuild.sh`
- Apple「Get started with Xcode Cloud」 https://developer.apple.com/xcode-cloud/get-started
- Apple「Xcode Cloud workflow reference」 https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference
- Apple「Configuring your Xcode Cloud workflow's actions」 https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions
- WWDC18「What's New in Testing」 https://wwdcnotes.com/notes/wwdc18/403
- GitHub「GITHUB_TOKEN」 https://docs.github.com/en/actions/concepts/security/github_token
- GitHub Changelog「GitHub Actions cache size can now exceed 10 GB per repository」(2025-11-20) https://github.blog/changelog/2025-11-20-github-actions-cache-size-can-now-exceed-10-gb-per-repository/
- Cloudflare「Object lifecycles」 https://developers.cloudflare.com/r2/buckets/object-lifecycles
