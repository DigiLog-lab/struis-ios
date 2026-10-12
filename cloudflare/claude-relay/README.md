# Struis Claude relay

設定の「AIモデル」で Claude を選んだときに、アプリが Anthropic の Messages API を呼ぶための中継です。Anthropic の API キーはこの Worker の secret にだけ置き、アプリには入れません。中継するのは、Apple の App Attest で「正規の Struis アプリ」と確認できた端末からの要求だけです。

| 経路 | 内容 |
|---|---|
| `POST /v1/app-attest/challenge` | 使い捨てのチャレンジ(5 分) |
| `POST /v1/app-attest/register` | attestation を Apple App Attestation Root CA まで検証し、端末の鍵(公開鍵)を登録 |
| `POST /v1/messages` | 要求本文の SHA-256 に対する assertion を検証して中継する。counter が増えない assertion(使い回し)は拒否する。SSE はそのまま流す |

- 受け付ける App ID: `TEAM_ID` + `BUNDLE_IDS`(本番)と、Ad Hoc プロトタイプの枠 `PREVIEW_PREFIX.s01`〜`sNN`(`PREVIEW_SLOTS`)。
- 中継できる内容: `ALLOWED_MODELS` のモデルだけ。`max_tokens` は `MAX_TOKENS` まで。server tool(web 検索など)と MCP は外す。
- 1 端末あたり 1 日 `DAILY_REQUEST_LIMIT` 回まで。
- 状態(チャレンジ・鍵・counter・使用回数)は Durable Object(SQLite)に置きます。D1 や KV を作る必要はありません。

## デプロイ

```sh
cd cloudflare/claude-relay
npm ci
npx wrangler secret put ANTHROPIC_API_KEY   # Anthropic の API キー
npx wrangler deploy                          # claude-struis.digiloglab.com
```

アプリの既定の送り先は `https://claude-struis.digiloglab.com` です(`ClaudeRelayConfig`)。

## テスト

```sh
npm test                     # 検証ロジック(テスト用の root で作った attestation・assertion)と中継
npx wrangler dev --local     # .dev.vars に ANTHROPIC_API_KEY と DEV_BYPASS_TOKEN
```

`DEV_BYPASS_TOKEN` は `wrangler dev` 専用です。App Attest を使えない Simulator からの確認に使います(アプリ側は DEBUG の Simulator で `STRUIS_CLAUDE_RELAY_URL` と `STRUIS_CLAUDE_RELAY_DEV_TOKEN` を指定)。デプロイした Worker には設定しないでください。
