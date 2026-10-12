// Struis Claude relay の要求処理(Durable Object は index.js)。
// App Attest で正規の Struis アプリだと確かめた要求だけを Anthropic の Messages API に中継する。
//
// - POST /v1/app-attest/challenge  → 使い捨てのチャレンジ(5 分)
// - POST /v1/app-attest/register   → attestation を検証して端末の鍵を登録
// - POST /v1/messages              → assertion(要求本文に対する署名)を検証して中継(SSE はそのまま流す)
//
// Anthropic の API キーは Worker の secret(ANTHROPIC_API_KEY)にだけ置く。端末・アプリには入らない。
// 状態(チャレンジ・鍵・counter・1 日の使用回数)は Durable Object(SQLite)に置く。D1 や KV の作成は要らない。
import { AttestError, appIdHashes, base64ToBytes, bytesToBase64, verifyAssertion, verifyAttestation } from './appattest.js';

const ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages';
const CHALLENGE_TTL_MS = 5 * 60 * 1000;
const MAX_BODY_BYTES = 32 * 1024 * 1024;

class HttpError extends Error {
  constructor(status, code, message) {
    super(message || code);
    this.status = status;
    this.code = code;
  }
}

export async function handle(request, env, deps = {}) {
  try {
    const url = new URL(request.url);
    if (url.pathname === '/healthz') return new Response('ok\n');
    if (request.method !== 'POST') throw new HttpError(405, 'method_not_allowed');
    switch (url.pathname) {
      case '/v1/app-attest/challenge': return await challenge(env);
      case '/v1/app-attest/register': return await register(request, env, deps);
      case '/v1/messages': return await relay(request, env, deps);
      default: throw new HttpError(404, 'not_found');
    }
  } catch (error) {
    if (error instanceof HttpError) return json(error.status, { type: 'error', error: { type: errorType(error.status), code: error.code, message: error.message } });
    if (error instanceof AttestError) return json(401, { type: 'error', error: { type: 'authentication_error', code: `app_attest_${error.code}`, message: error.message } });
    console.error(error && error.stack ? error.stack : String(error));
    return json(500, { type: 'error', error: { type: 'api_error', code: 'internal', message: 'Internal error' } });
  }
}

function errorType(status) {
  if (status === 401 || status === 403) return 'authentication_error';
  if (status === 429) return 'rate_limit_error';
  if (status >= 500) return 'api_error';
  return 'invalid_request_error';
}

function json(status, body, headers = {}) {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...headers } });
}

function state(env, name) {
  return env.STATE.get(env.STATE.idFromName(name));
}

/** 受け付ける App ID: 本番と Ad Hoc プロトタイプの枠(`<prefix>.s01`〜)。 */
export function allowedAppIds(env) {
  const team = env.TEAM_ID;
  const ids = (env.BUNDLE_IDS || '').split(',').map((s) => s.trim()).filter(Boolean);
  const slots = Number(env.PREVIEW_SLOTS || 0);
  for (let i = 1; i <= slots; i++) ids.push(`${env.PREVIEW_PREFIX}.s${String(i).padStart(2, '0')}`);
  return ids.map((id) => `${team}.${id}`);
}

async function challenge(env) {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const value = bytesToBase64(bytes);
  await state(env, `challenge:${value}`).putChallenge(Date.now() + CHALLENGE_TTL_MS);
  return json(200, { challenge: value, expires_in: CHALLENGE_TTL_MS / 1000 });
}

async function register(request, env, deps) {
  const body = await request.json().catch(() => null);
  if (!body || typeof body.key_id !== 'string' || typeof body.attestation !== 'string' || typeof body.challenge !== 'string') {
    throw new HttpError(400, 'invalid_request', 'key_id, attestation and challenge are required');
  }
  if (!(await state(env, `challenge:${body.challenge}`).takeChallenge(Date.now()))) throw new HttpError(401, 'app_attest_challenge', 'challenge is unknown or expired');
  const record = await verifyAttestation({
    keyId: body.key_id,
    attestation: body.attestation,
    challenge: base64ToBytes(body.challenge),
    appIds: await appIdHashes(allowedAppIds(env)),
    now: Date.now(),
    rootPem: deps.rootPem,
  });
  await state(env, `key:${record.keyId}`).putKey(record);
  return json(201, { key_id: record.keyId, environment: record.environment });
}

async function relay(request, env, deps) {
  const keyId = request.headers.get('x-struis-app-attest-key-id');
  const assertion = request.headers.get('x-struis-app-attest-assertion');
  const raw = new Uint8Array(await request.arrayBuffer());
  if (raw.length > MAX_BODY_BYTES) throw new HttpError(413, 'too_large');

  const devToken = env.DEV_BYPASS_TOKEN && request.headers.get('x-struis-dev-token');
  let owner;
  if (devToken && devToken === env.DEV_BYPASS_TOKEN) {
    // ローカル開発(`wrangler dev`)専用。本番の環境変数には設定しない。
    owner = 'dev';
  } else {
    if (!keyId || !assertion) throw new HttpError(401, 'app_attest_required', 'App Attest assertion is required');
    const stub = state(env, `key:${keyId}`);
    const key = await stub.getKey();
    if (!key) throw new HttpError(401, 'app_attest_unknown_key', 'App Attest key is not registered');
    const counter = await verifyAssertion({ assertion, clientData: raw, key, appIds: await appIdHashes(allowedAppIds(env)) });
    if (!(await stub.advanceCounter(counter))) throw new AttestError('assertion', 'counter did not increase');
    owner = keyId;
  }

  const limit = Number(env.DAILY_REQUEST_LIMIT || 0);
  if (limit > 0 && !(await state(env, `usage:${owner}`).countRequest(new Date().toISOString().slice(0, 10), limit))) {
    throw new HttpError(429, 'daily_limit', 'The daily request limit for this device was reached');
  }

  const body = sanitize(JSON.parse(new TextDecoder().decode(raw)), env);
  const upstream = await (deps.fetch || fetch)(ANTHROPIC_URL, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'anthropic-version': request.headers.get('anthropic-version') || '2023-06-01',
      'x-api-key': env.ANTHROPIC_API_KEY,
      accept: request.headers.get('accept') || 'application/json',
    },
    body: JSON.stringify(body),
  });
  const headers = new Headers({ 'content-type': upstream.headers.get('content-type') || 'application/json' });
  for (const name of ['retry-after', 'request-id']) {
    const value = upstream.headers.get(name);
    if (value) headers.set(name, value);
  }
  return new Response(upstream.body, { status: upstream.status, headers });
}

/** Struis の使い方に限る: 許可したモデル、出力上限、サーバー側の tool は使わない。 */
export function sanitize(body, env) {
  if (!body || typeof body !== 'object') throw new HttpError(400, 'invalid_request', 'body must be a JSON object');
  const models = (env.ALLOWED_MODELS || '').split(',').map((s) => s.trim()).filter(Boolean);
  if (!models.includes(body.model)) throw new HttpError(400, 'model_not_allowed', `model ${body.model} is not allowed`);
  const maxTokens = Number(env.MAX_TOKENS || 64000);
  body.max_tokens = Math.min(Number(body.max_tokens) || maxTokens, maxTokens);
  if (Array.isArray(body.tools)) {
    // client tool(type なし・"custom")だけを通す。web 検索などの server tool は Struis では使わない。
    body.tools = body.tools.filter((tool) => !tool.type || tool.type === 'custom');
    if (body.tools.length === 0) {
      delete body.tools;
      delete body.tool_choice;
    }
  }
  for (const key of ['mcp_servers', 'container']) delete body[key];
  return body;
}

