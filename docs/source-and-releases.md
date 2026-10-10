# 公開ソースと配布版の対応

この独立リポジトリは、統合リポジトリ`DigiLog-lab/struis`のcommit
`99ed86e0a6bc6b7063d6512069d5ebaf7c920413`にある`ios/strius/`をルートへ配置して、新しい履歴として開始しました。旧iSH/rootfs資源、backend、Web、配信本文、内部資料、個人の学習データ、取得cache、生成frameworkは含みません。

学習規則、モデル設定、画面、Bundle ID、App Groups、台帳形式、現行サーバーとの通信契約は抽出元に対応します。独立配置に必要な参照、公開用設定、説明、テスト入力の扱いが異なります。共有の合成JSONは同じbytesで収録し、個人の答案画像は生成画像に置き換えています。

従来の配布版は統合リポジトリから作られています。この独立リポジトリからの配布は、次の表へversion・build・commitまたはtag・CI実archiveを対応づけて記録します。まだ登録されていない配布版を、このソースからビルドしたものとは扱いません。

| version | build | 公開commitまたはtag | CI archive |
|---|---|---|---|

配布版ごとに、CIが取得したcommitとarchiveの元commitを照合し、同じcommitへtagを付けて表を更新します。署名・認証値・端末の会話・写真は公開する対応記録へ含めません。
