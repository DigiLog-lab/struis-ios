# 公開ソースと配布版の対応

この独立リポジトリは、統合リポジトリ`DigiLog-lab/struis`のcommit
`99ed86e0a6bc6b7063d6512069d5ebaf7c920413`にある`ios/strius/`をルートへ配置して、新しい履歴として開始しました。旧iSH/rootfs資源、backend、Web、配信本文、内部資料、個人の学習データ、取得cache、生成frameworkは含みません。

学習規則、モデル設定、画面、Bundle ID、App Groups、台帳形式、現行サーバーとの通信契約は抽出元に対応します。独立配置に必要な参照、公開用設定、説明、テスト入力の扱いが異なります。共有の合成JSONは同じbytesで収録し、個人の答案画像は生成画像に置き換えています。

従来の配布版は統合リポジトリから作られています。この独立リポジトリからの配布は、次の表へversion・build・commitまたはtag・CI実archiveを対応づけて記録します。まだ登録されていない配布版を、このソースからビルドしたものとは扱いません。

| version | build | 公開commitまたはtag | CI archive |
|---|---|---|---|

配布版ごとに、CIが取得したcommitとarchiveの元commitを照合し、同じcommitへtagを付けて表を更新します。署名・認証値・端末の会話・写真は公開する対応記録へ含めません。

## リリースの流れ

mainを「TestFlightで確かめて出したもの」だけにするため、リリースごとの短命ブランチ`release/x.y`を経由します。

1. **切る**: mainから`release/x.y`を作り、Repository variable `RELEASE_BRANCH`に`release/x.y`を設定する。以後に始まるエージェントの作業は、このブランチから切られ、PRもこのブランチへ向く。
2. **入れる**: 機能のPRを`release/x.y`へマージする。PRのCIはビルド・単体テスト・UIテストなど(`ios.yml`の`pull_request`)。
3. **全部入り**: `release/x.y`へのpushごとに、`iOS`がUIテストの全部入り・署名なし実機Release archive・署名付きarchiveを実行する。前のステップが失敗すると、署名付きarchiveは実行されない。
4. **TestFlight**: 全部入りが緑のcommitで、Actionsの`iOS`を`release/x.y`に対して手動実行し、`upload`を有効にして新しいbuild番号を入れる。UIテストを含む全部入りを通った後にだけ、署名・アップロードされる。
5. **確かめる**: TestFlightの版を実機で確かめる。直す場合は2へ戻る。
6. **出す**: `release/x.y`をmainへPRでマージし、同じcommitにtagを付けて上の表を更新する。`RELEASE_BRANCH`を空にするか次のリリースに変え、`release/x.y`を削除する。

決まりごと:

- リリースブランチは1〜2週間で切り上げる。入らなかった機能は次のリリースに回す。
- 緊急の修正はmainから切り、mainと進行中のリリースブランチの両方に入れる。
- リリースブランチの全部入りが赤い間は、原因のPRを特定して直すまで、次のPRをマージしない。
- mainと`release/*`は、Settings → Branchesのルールで直接pushを禁止し、PRとCIの成功を必須にする(エージェントのpre-pushフックも両方へのpushを拒否する)。

