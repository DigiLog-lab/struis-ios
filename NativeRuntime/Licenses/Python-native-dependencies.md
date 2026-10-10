# CPythonバイナリの外部依存

取得物: Python-3.14-iOS-support.b11.tar.gz。SHA-256はdependencies.lock.jsonを参照。
同梱VERSIONSに記された部品の該当版のライセンス原文を取得し、下記を選択した。

| 部品 | 版 | 採用ライセンス | 通知ファイル |
| --- | --- | --- | --- |
| Python-Apple-support | 3.14-b11 | MIT | Python-Apple-support.txt |
| BZip2 | 1.0.8-2 | bzip2 | BZip2.txt |
| libFFI | 3.4.7-2 | MIT | libffi.txt |
| mpdecimal | 4.0.0-2 | BSD-2-Clause | mpdecimal.txt |
| OpenSSL | 3.5.8-1 | Apache-2.0 | OpenSSL.txt |
| liblzma | 5.6.4-2 | 0BSD | XZ-0BSD.txt、XZ.txt |
| Zstandard | 1.5.7-1 | BSD-3-Clauseを選択 | Zstandard.txt |

XZのGPLシェルスクリプトやコマンドラインツールは同梱しない。liblzmaのライセンスは0BSDであることを該当版のCOPYINGで確認した。GNU readlineとGDBMのPython拡張はこのsupport archiveに存在しない。

確認範囲は配布元の構成表、該当版の通知原文、拡張モジュールの一覧。Pythonのsupport archive自体は固定SHA-256の配布バイナリを使用しており、Hyotan側での全依存の再現ビルド・バイナリ一致検証は未実施。
