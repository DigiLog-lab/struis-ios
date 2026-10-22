# 日常CIの設計案 — 2026-10-22

採用候補は、**全Unit/結合テスト + 変更が影響するUIだけ**を1回検証し、そのHEADの証拠をmerge判定に使う構成。実験用実装・実測と通常CIへの組込みは分ける。通常CI/main/PR #39/配信は変更していない。最終の時間と採否は [測定結果](selected-final-20261022.md) を参照。

## 何を選ぶか

全56 UIの採用/除外理由と必要な代替は [判断表](ui-scope-decisions-20261022.md) と [JSON](ui-scope-decisions-20261022.json) が正本。全Unitは398件（既知29 skipを含む）。UIの常時必須は0件。既存コードだけで代替済みとする範囲と、短いUI等の追加が済むまで残す範囲を混ぜない。

| 変更契約 | 現在選べるUI | 追加する条件 |
|---|---:|---|
| 採点境界の内部ロジックのみ | 0 | DTO・action・stage・保存形式・画面通知が変われば、その利用画面を追加 |
| ヘッダー開閉・保持のみ | 2 | 共通ジェスチャ/会話レイアウトにも影響すればscroll等を追加 |
| 記録中の送信・ready通知 | 3 | 入力、添付、永続化、共通会話にも影響するなら対応UIを合併 |
| 没頭の候補・質問からの復帰・完走 | 3 | 共通入力/ナビゲーションの変更は対応UIを合併 |
| 会話のscroll・数式ジェスチャ・差分更新 | 9 | 長文20回の送信/scrollを含める。入力/readyも変われば上の3件等を合併 |

`benchmark_selected.py --profile ...` はこの明示的な契約profileを実行する。diffから自動決定していない。巨大なChatView/ChatStoreに触れた変更を、ファイル名だけで3件へ絞らない。共有部品・生成資産・Native・起動設定は利用機能へ伝播する。未対応path、複数契約、依存の判断がつかない変更は、影響を割り当てるまで狭いprofileを許可しない。

`selection-shadow.json` の過去20変更監査は、選択の過不足を調べる資料である。依存関係の安全性や過去PRの実際の平均を証明していない。Swiftのコンパイル依存だけでは、動的なfixture、文字列の資産参照、Nativeの接続、環境設定の影響が閉じない。

## どこで1回検証するか

PR #39の `scripts/agent/delivery.py::local_verify` は既に `AGENT_DERIVED_DATA` または固定のagent用DerivedDataを使う。`scripts/agent/gate.py` は、その手元検証の後に別の外部iOS gateを起動する設計になっている。日常構成では、作業用Macに残るbuild/Simulatorを使い、コード完成後の**信頼できる検証step**で1回実行した証拠を制御側で受け入れる案を優先する。

1. 制御側がbaseの信頼できるpolicyから、base/head・変更契約・全Unit inventory・必要UI集合・build/fixture/環境入力を確定する。PRから渡された自己申告の「UI0件」だけでは減らさない。policy変更自体も別のreview対象にする。
2. `local_verify` のbuildを1回にし、選択したUIと全Unitを同じ `test-without-building` で実行する。UI0件ではUIコマンドもprobeも作らず、空filterをxcodebuildへ渡さない。既存の空UI拒否と、成功条件で固定されている3つのcommand名を、この明示的な計画に合わせて変更する必要がある。
3. exact HEAD、work-items/requestのdigest、選択policy/fixture/toolchain/build inputs、コマンドの終了結果、raw xcresult、全caseのpassed/skipped/failed、artifactのorigin/hashを保存する。完了前後の `clean_pushed`、全work-item完了、Ready checkpoint整合性を維持する。
4. `gate.py` の `agent-tests.yml` によるLinux制御テストは維持する。外部iOS gateをもう1回起動する箇所を、同じHEADの証拠検証へ置き換える。コードや入力が変わった場合はその証拠を失効させる。アプリの失敗や新規skip、欠落を成功に変換しない。

手順2の実行部分は実験スクリプトにある。手順3/4の一部は `selected_receipt.py` のoffline試作にある。5つの実artifactを同じHEADで受け入れ、違うHEAD等を拒否することは確認した。実際に失敗した署名省略jobと、作業中の等価変更を使ったquality workflowも受け入れなかった。**agentのcheckpoint、通常CIのcheck公開、別VMからのダウンロード時間、policyを含む全入力の封印まで組み込んだものではない。** 実験workflowの定義commitを明示して信頼する限定的な試作である。

## 残す品質検証

- 既存の本物のCoordinator/ChatStore/台帳とWorkbookMachineを通るUnitを維持する。記録中に入力がbusyになる故障、未提出が残るセットを閉じる故障は、既存の2つのUnitが実際に検出した。意図的失敗2件は成功数に含めない。
- 5件の「代替完成後に置換」は、必要な短いUI・結合テストと故障検出の対応が揃うまで関連変更で維持する。今回の2故障の検出だけで全assertionの置換が完了したとはしない。
- `WorkbookStore.submitCapture(pages:)` の複数画像の枚数/順序/内容の受渡し、画像再起動保存、usage既定オフ等の不足は残る。関連する既存UIを先に外さない。
- Unit29 skipと専用環境UI10件は未検証範囲として表示する。環境依存のUIを必要な変更で選んだときに、skipのままmergeの品質確認が済んだ扱いにしない。
- 目視が必要なレイアウトは画像/録画の確認を別の証拠として残す。テストがPassedでも、assertしていない遮蔽や滑らかさまで自動保証したとはしない。

## 10分の測り方

新規Macの候補はworkflow作成からjob終了までを測る。queue、checkout/cache、build、boot、テスト、export、artifact保存、後処理を含める。準備済みworkerの区間はソース編集からjob終了までを別欄で示し、初回準備を除くことを明記する。実際の一連のmerge gate、結果取得とcheck公開を含む時間は組込み後に測る必要がある。

失敗した試行を捨てて成功だけの平均にしない。今回は署名省略でUnit1件が失敗し、その構成は採用しない。速い構成2回の成功から低いflake率を保証しない。PRの変更種類の実際の比率も未測定であり、異なるprofileの時間を無条件に平均して「全PR平均10分」としない。

組込み後は、少なくとも直近20回の実際のmerge判定要求で、要求から全必須結果公開までの時間を保存し、平均・最大・profile・cache hit/miss・queue・失敗/再実行を同時に出す。試行回数は低い失敗率を証明する条件ではなく、実際の変更分布を観測する初期窓である。タイムアウトで打ち切った回を「10分でmergeできた」に含めない。テスト失敗を理由なく自動再試行する仕組みも追加しない。

## 次に分割する実装単位

`WorkbookRules`、reply-tailの制御、scroll/数式のView部品、添付の保存/提出を、別の契約とテスト入口へ切り出す順に進める。依存先が変わったときの利用側UIを明示できるようにする。最初は実際に影響範囲が広いChatView/ChatStoreを、上表の契約と一致する単位にする。

今回のappは9350ファイル・701,362,877 bytesで、Native extension/frameworkやPython資産が大きい。軽いtest hostで純粋なロジックを実行する案には調査価値があるが、Native接続を検証する対象を別に維持し、実測してから採用する。**軽量host・cross-VM compiler cache・依存グラフによる自動選択・別ソース間のテスト結果再利用は未実装。** Simulator署名を外す案や、過去に失敗した同一VM2workersは今回の採用案に含めない。

先に試せる小さい候補は `strius.xcodeproj/project.pbxproj` の **Package Python** phase。`alwaysOutOfDate = 1` でinput/output指定がなく、同じNative/Python入力でも毎回実行する。今回のbuild timingでは初回21.381秒、最後の増分buildでも16.809秒を使用した。単純にskipせず、Pythonのlock/生成資産/梱包スクリプト・platform/SDK・Python compiler・署名条件と、梱包出力のmanifestが一致するときに再利用する案を次の小さな実験にする。Native入力や出力が欠落/変化した場合は必ず作り直す。節約候補はこのphaseの実測時間であり、CI全体で16.8秒短くなったという実測ではない。
