import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { before, test } from 'node:test';
import worker from '../src/index.js';

if (!globalThis.crypto) Object.defineProperty(globalThis, 'crypto', { value: webcrypto });
const repository = 'owner/repo';
let keyPair;
let publicKey;

before(async () => {
  keyPair = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']);
  publicKey = { ...await crypto.subtle.exportKey('jwk', keyPair.publicKey), kid: 'test', alg: 'RS256', use: 'sig' };
  globalThis.fetch = async (url) => {
    assert.equal(url, 'https://token.actions.githubusercontent.com/.well-known/jwks');
    return Response.json({ keys: [publicKey] });
  };
});

async function token(workflow = 'agent.yml') {
  const now = Math.floor(Date.now() / 1000);
  const encode = (data) => Buffer.from(JSON.stringify(data)).toString('base64url');
  const header = encode({ alg: 'RS256', kid: 'test' });
  const payload = encode({ iss: 'https://token.actions.githubusercontent.com', aud: 'https://store.example',
    repository, repository_id: '123', exp: now + 300, nbf: now - 5, run_id: '42',
    job_workflow_ref: `${repository}/.github/workflows/${workflow}@refs/heads/main` });
  const input = `${header}.${payload}`;
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', keyPair.privateKey, new TextEncoder().encode(input));
  return `${input}.${Buffer.from(signature).toString('base64url')}`;
}

class Bucket {
  objects = new Map();
  deleted = [];
  multipart = 0;

  add(key, value, uploaded = '2026-10-01T00:00:00Z') {
    this.objects.set(key, { value, uploaded: new Date(uploaded) });
  }

  async get(key) {
    const object = this.objects.get(key);
    return object ? { body: JSON.stringify(object.value), json: async () => object.value, httpEtag: '"etag"' } : null;
  }

  async put(key, body) {
    this.add(key, await new Response(body).text());
    return { size: 1, etag: 'etag' };
  }

  async list({ prefix, cursor, limit }) {
    const keys = [...this.objects.keys()].sort().filter((key) => key.startsWith(prefix) && (!cursor || key > cursor));
    const page = keys.slice(0, limit);
    return { objects: page.map((key) => ({ key, ...this.objects.get(key), size: 1 })),
      truncated: keys.length > limit, cursor: page.at(-1) };
  }

  async delete(keys) {
    for (const key of keys) { this.deleted.push(key); this.objects.delete(key); }
  }

  async createMultipartUpload() {
    this.multipart += 1;
    return { uploadId: 'upload' };
  }
}

function environment() {
  return { STORE: new Bucket(), OIDC_AUDIENCE: 'https://store.example', GITHUB_REPOSITORY: repository,
    GITHUB_REPOSITORY_ID: '123', DEFAULT_BRANCH: 'main',
    ALLOWED_WORKFLOWS: '.github/workflows/agent.yml,.github/workflows/agent-gate.yml,.github/workflows/agent-cleanup.yml' };
}

async function request(env, path, method = 'GET', body, workflow) {
  return worker.fetch(new Request(`https://store.example${path}`, { method,
    headers: { authorization: `Bearer ${await token(workflow)}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body) }), env);
}

test('worker cannot forge gate results through direct PUT or multipart', async () => {
  const env = environment();
  assert.equal((await request(env, '/v1/objects/gates/pr-8.json', 'PUT', { success: true })).status, 403);
  assert.equal((await request(env, '/v1/multipart/gates/pr-8.json', 'POST')).status, 403);
  assert.equal(env.STORE.multipart, 0);
  assert.equal((await request(env, '/v1/objects/gates/pr-8.json', 'PUT', {}, 'agent-gate.yml')).status, 200);
});

test('deletion is restricted to numeric Issue checkpoint directories', async () => {
  const env = environment();
  env.STORE.add('sessions/4/state.json', { important: true });
  env.STORE.add('prototypes/4/app.ipa', 'keep');
  assert.equal((await request(env, '/v1/objects/sessions/4/state.json', 'DELETE')).status, 405);
  assert.equal((await request(env, '/v1/checkpoints/state.json', 'DELETE', {})).status, 404);
  assert.equal((await request(env, '/v1/checkpoints/4', 'DELETE', { keep: ['../state'], before: '2026-10-01' })).status, 400);
  assert.equal((await request(env, '/v1/checkpoints/4', 'DELETE', { keep: [], before: '2026-10-01' })).status, 409);
  assert.ok(env.STORE.objects.has('sessions/4/state.json'));
  assert.ok(env.STORE.objects.has('prototypes/4/app.ipa'));
});

test('prune keeps latest, previous and in-flight saves across more than one page', async () => {
  const env = environment();
  env.STORE.add('sessions/4/workspace.json', { saveId: 'current', previous: { saveId: 'previous' } });
  env.STORE.add('sessions/4/checkpoints/current/session', 'keep');
  env.STORE.add('sessions/4/checkpoints/previous/session', 'keep');
  env.STORE.add('sessions/4/checkpoints/inflight/session', 'keep', '2026-10-19T00:00:00Z');
  env.STORE.add('sessions/44/checkpoints/old/session', 'other issue');
  for (let i = 0; i < 1002; i++) env.STORE.add(`sessions/4/checkpoints/old-${i}/data`, 'delete');
  const result = await request(env, '/v1/checkpoints/4', 'DELETE', { keep: ['current', 'previous'], before: '2026-10-10' });
  assert.equal(result.status, 200);
  assert.equal((await result.json()).deleted, 1002);
  assert.equal(env.STORE.deleted.length, 1002);
  assert.ok(env.STORE.objects.has('sessions/4/checkpoints/inflight/session'));
  assert.ok(env.STORE.objects.has('sessions/44/checkpoints/old/session'));
});

test('stale prune cannot delete a new pointer, completion requires a tombstone', async () => {
  const env = environment();
  env.STORE.add('sessions/4/workspace.json', { saveId: 'new', previous: { saveId: 'current' } });
  env.STORE.add('sessions/4/checkpoints/new/session', 'keep');
  assert.equal((await request(env, '/v1/checkpoints/4', 'DELETE', { keep: ['current', 'old'], before: '2026-10-10' })).status, 409);
  env.STORE.add('sessions/4/workspace.json', { closed: true });
  assert.equal((await request(env, '/v1/checkpoints/4', 'DELETE', { keep: [], before: '2026-10-10' })).status, 200);
  assert.deepEqual(env.STORE.deleted, ['sessions/4/checkpoints/new/session']);
  assert.ok(env.STORE.objects.has('sessions/4/workspace.json'));
});
