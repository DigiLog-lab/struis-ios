import assert from 'node:assert/strict';
import { createHash, createPrivateKey, sign } from 'node:crypto';
import { test } from 'node:test';
import { AttestError, appIdHashes, verifyAssertion, verifyAttestation } from '../src/appattest.js';
import { allowedAppIds, handle, sanitize } from '../src/relay.js';
import { makeFixture } from './fixture.mjs';

const fixture = makeFixture();
const sha256 = (data) => createHash('sha256').update(data).digest();
const leafKey = createPrivateKey(fixture.leafKeyPem);

const env = {
  TEAM_ID: '4D4W8FMKMW', BUNDLE_IDS: 'com.digiloglab.strius', PREVIEW_PREFIX: 'com.digiloglab.strius.preview', PREVIEW_SLOTS: '3',
  ALLOWED_MODELS: 'claude-opus-5-5,claude-haiku-5-5', MAX_TOKENS: '64000', DAILY_REQUEST_LIMIT: '3', ANTHROPIC_API_KEY: 'sk-server',
};

/** 端末が作る assertion: CBOR {signature, authenticatorData}。 */
function assertion(body, counter, appId = fixture.appId) {
  const authenticatorData = Buffer.concat([sha256(appId), Buffer.from([0x40]), Buffer.from([0, 0, 0, counter])]);
  const nonce = sha256(Buffer.concat([authenticatorData, sha256(body)]));
  const signature = sign('sha256', nonce, leafKey); // DER ECDSA
  const head = (n) => (n < 24 ? Buffer.from([0x40 | n]) : n < 256 ? Buffer.from([0x58, n]) : Buffer.from([0x59, n >> 8, n & 255]));
  const text = (s) => Buffer.concat([Buffer.from([0x60 | s.length]), Buffer.from(s)]);
  return Buffer.concat([Buffer.from([0xa2]), text('signature'), head(signature.length), signature,
    Buffer.from([0x71]), Buffer.from('authenticatorData'), head(authenticatorData.length), authenticatorData]).toString('base64');
}

async function appIds() {
  return appIdHashes(allowedAppIds(env));
}

test('allowed app ids include production and the preview slots', () => {
  assert.deepEqual(allowedAppIds(env), [
    '4D4W8FMKMW.com.digiloglab.strius',
    '4D4W8FMKMW.com.digiloglab.strius.preview.s01',
    '4D4W8FMKMW.com.digiloglab.strius.preview.s02',
    '4D4W8FMKMW.com.digiloglab.strius.preview.s03',
  ]);
});

test('a valid attestation registers the device key', async () => {
  const record = await verifyAttestation({
    keyId: fixture.keyId, attestation: fixture.attestation, challenge: Buffer.from(fixture.challenge, 'base64'),
    appIds: await appIds(), rootPem: fixture.rootPem,
  });
  assert.equal(record.keyId, fixture.keyId);
  assert.equal(record.appId, fixture.appId);
  assert.equal(record.environment, 'development');
  assert.equal(record.counter, 0);
});

test('attestation checks: Apple root, challenge, key id and app id', async () => {
  const base = { keyId: fixture.keyId, attestation: fixture.attestation, challenge: Buffer.from(fixture.challenge, 'base64'), appIds: await appIds(), rootPem: fixture.rootPem };
  // テスト用の root で作った chain は、本物の Apple の root では通らない。
  await assert.rejects(verifyAttestation({ ...base, rootPem: undefined }), AttestError);
  await assert.rejects(verifyAttestation({ ...base, challenge: Buffer.from('other') }), /nonce does not match/);
  await assert.rejects(verifyAttestation({ ...base, keyId: Buffer.alloc(32).toString('base64') }), /key id does not match/);
  await assert.rejects(verifyAttestation({ ...base, appIds: await appIdHashes(['OTHER.app']) }), /app id is not allowed/);
});

test('assertions are bound to the body and the counter must increase', async () => {
  const key = { publicKey: (await verifyAttestation({ keyId: fixture.keyId, attestation: fixture.attestation, challenge: Buffer.from(fixture.challenge, 'base64'), appIds: await appIds(), rootPem: fixture.rootPem })).publicKey, appId: fixture.appId, counter: 0 };
  const body = Buffer.from('{"model":"claude-opus-5-5"}');
  assert.equal(await verifyAssertion({ assertion: assertion(body, 1), clientData: body, key, appIds: await appIds() }), 1);
  await assert.rejects(verifyAssertion({ assertion: assertion(body, 1), clientData: Buffer.from('{}'), key, appIds: await appIds() }), /signature is invalid/);
  await assert.rejects(verifyAssertion({ assertion: assertion(body, 1), clientData: body, key: { ...key, counter: 1 }, appIds: await appIds() }), /counter/);
  await assert.rejects(verifyAssertion({ assertion: assertion(body, 2, '4D4W8FMKMW.com.digiloglab.strius.preview.s01'), clientData: body, key, appIds: await appIds() }), /app id does not match/);
});

test('sanitize keeps Struis usage: allowed models, capped tokens, client tools only', () => {
  const body = sanitize({ model: 'claude-opus-5-5', max_tokens: 999999, tools: [{ name: 'struis__exec_command', input_schema: {} }, { type: 'web_search_20260209', name: 'web_search' }], mcp_servers: [] }, env);
  assert.equal(body.max_tokens, 64000);
  assert.deepEqual(body.tools.map((t) => t.name), ['struis__exec_command']);
  assert.equal(body.mcp_servers, undefined);
  assert.throws(() => sanitize({ model: 'claude-fable-5-1' }, env), /not allowed/);
});

// ---------------------------------------------------------- end to end ---

class MemoryState {
  constructor() { this.values = new Map(); }
  putChallenge(expiresAt) { this.values.set('challenge', { expiresAt }); }
  takeChallenge(now) { const v = this.values.get('challenge'); this.values.delete('challenge'); return Boolean(v && v.expiresAt >= now); }
  putKey(record) { this.values.set('key', record); }
  getKey() { return this.values.get('key') || null; }
  advanceCounter(counter) { const k = this.values.get('key'); if (!k || counter <= k.counter) return false; this.values.set('key', { ...k, counter }); return true; }
  countRequest(day, limit) { const u = this.values.get('usage'); const n = u && u.day === day ? u.count : 0; if (n >= limit) return false; this.values.set('usage', { day, count: n + 1 }); return true; }
}

function memoryEnv() {
  const objects = new Map();
  return {
    ...env,
    STATE: {
      idFromName: (name) => name,
      get: (name) => { if (!objects.has(name)) objects.set(name, new MemoryState()); return objects.get(name); },
    },
    objects,
  };
}

const post = (path, body, headers = {}) => new Request(`https://relay.test${path}`, { method: 'POST', body, headers });

test('register then relay streams Anthropic with the server key', async () => {
  const testEnv = memoryEnv();
  // テストの attestation のチャレンジを、発行済みとして置く。
  testEnv.STATE.get(`challenge:${fixture.challenge}`).putChallenge(Date.now() + 60000);
  const registered = await handle(post('/v1/app-attest/register', JSON.stringify({ key_id: fixture.keyId, attestation: fixture.attestation, challenge: fixture.challenge })), testEnv, { rootPem: fixture.rootPem });
  assert.equal(registered.status, 201);
  // 同じチャレンジは二度使えない。
  const again = await handle(post('/v1/app-attest/register', JSON.stringify({ key_id: fixture.keyId, attestation: fixture.attestation, challenge: fixture.challenge })), testEnv, { rootPem: fixture.rootPem });
  assert.equal(again.status, 401);

  let forwarded;
  const fakeFetch = async (url, init) => {
    forwarded = { url, init };
    return new Response('event: message_start\ndata: {}\n\n', { status: 200, headers: { 'content-type': 'text/event-stream' } });
  };
  const body = JSON.stringify({ model: 'claude-opus-5-5', max_tokens: 1000, stream: true, messages: [{ role: 'user', content: 'hi' }] });
  const headers = (counter) => ({ 'x-struis-app-attest-key-id': fixture.keyId, 'x-struis-app-attest-assertion': assertion(Buffer.from(body), counter), 'anthropic-version': '2023-06-01' });
  const ok = await handle(post('/v1/messages', body, headers(1)), testEnv, { fetch: fakeFetch });
  assert.equal(ok.status, 200);
  assert.equal(ok.headers.get('content-type'), 'text/event-stream');
  assert.match(await ok.text(), /message_start/);
  assert.equal(forwarded.init.headers['x-api-key'], 'sk-server');

  // 同じ assertion の再利用(counter が増えない)は拒む。
  const replay = await handle(post('/v1/messages', body, headers(1)), testEnv, { fetch: fakeFetch });
  assert.equal(replay.status, 401);
  assert.equal((await replay.json()).error.code, 'app_attest_assertion');
  // 鍵の無い要求・知らない鍵。
  assert.equal((await handle(post('/v1/messages', body), testEnv, { fetch: fakeFetch })).status, 401);
  const unknown = await handle(post('/v1/messages', body, { ...headers(2), 'x-struis-app-attest-key-id': 'AAAA' }), testEnv, { fetch: fakeFetch });
  assert.equal((await unknown.json()).error.code, 'app_attest_unknown_key');
  // 1 日の上限(テストでは 3 回)。
  assert.equal((await handle(post('/v1/messages', body, headers(2)), testEnv, { fetch: fakeFetch })).status, 200);
  assert.equal((await handle(post('/v1/messages', body, headers(3)), testEnv, { fetch: fakeFetch })).status, 200);
  const limited = await handle(post('/v1/messages', body, headers(4)), testEnv, { fetch: fakeFetch });
  assert.equal(limited.status, 429);
});

test('challenge endpoint issues a single-use challenge', async () => {
  const testEnv = memoryEnv();
  const response = await handle(post('/v1/app-attest/challenge', '{}'), testEnv);
  const { challenge } = await response.json();
  assert.equal(Buffer.from(challenge, 'base64').length, 32);
  assert.equal(testEnv.STATE.get(`challenge:${challenge}`).takeChallenge(Date.now()), true);
  assert.equal(testEnv.STATE.get(`challenge:${challenge}`).takeChallenge(Date.now()), false);
});
