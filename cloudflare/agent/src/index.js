// Struis agent store: session/prototype storage for GitHub Actions and
// Ad Hoc OTA distribution for prototype builds.
//
// CI requests authenticate with a GitHub Actions OIDC token. The token must be
// issued for this repository, the configured audience and an allowed workflow
// on the default branch, so no static storage credential lives in GitHub.
// Install pages, manifests and IPAs are served only through HMAC-signed,
// expiring URLs minted by CI through this Worker.
import qrcode from 'qrcode-generator';

const GITHUB_ISSUER = 'https://token.actions.githubusercontent.com';
const JWKS_URL = `${GITHUB_ISSUER}/.well-known/jwks`;
const KEY_PREFIXES = ['sessions/', 'prototypes/', 'media/', 'usage/'];
const MAX_TTL_SECONDS = 30 * 24 * 3600;
const CLOCK_SKEW_SECONDS = 60;

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

let jwksCache = { keys: new Map(), fetchedAt: 0 };

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (error) {
      if (error instanceof HttpError) {
        return new Response(`${error.message}\n`, { status: error.status });
      }
      console.error(error && error.stack ? error.stack : String(error));
      return new Response('Internal error\n', { status: 500 });
    }
  },
};

async function route(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;
  if (path === '/healthz') {
    return new Response('ok\n');
  }
  if (path.startsWith('/v1/')) {
    const claims = await authenticate(request, env);
    return handleApi(request, env, url, claims);
  }
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    throw new HttpError(405, 'Method not allowed');
  }
  let match;
  if ((match = path.match(/^\/p\/(\d+)\/([a-z0-9-]+)\/(\d+)$/))) {
    return installPage(env, url, match.slice(1));
  }
  if ((match = path.match(/^\/qr\/(\d+)\/([a-z0-9-]+)\/(\d+)\.svg$/))) {
    return qrImage(env, url, match.slice(1));
  }
  if ((match = path.match(/^\/m\/(\d+)\/([a-z0-9-]+)\/(\d+)\/manifest\.plist$/))) {
    return manifest(env, url, match.slice(1));
  }
  if ((match = path.match(/^\/d\/(\d+)\/([a-z0-9-]+)\/(\d+)\/app\.ipa$/))) {
    return ipa(request, env, url, match.slice(1));
  }
  if ((match = path.match(/^\/media\/([A-Za-z0-9_-]{16,})\/([A-Za-z0-9._-]+)$/))) {
    return media(request, env, `media/${match[1]}/${match[2]}`);
  }
  throw new HttpError(404, 'Not found');
}

// ---------------------------------------------------------------- CI API ---

async function handleApi(request, env, url, claims) {
  const path = url.pathname;
  if (path.startsWith('/v1/objects/')) {
    const key = objectKey(path.slice('/v1/objects/'.length));
    if (request.method === 'GET') {
      const object = await env.STORE.get(key);
      if (!object) throw new HttpError(404, 'No such object');
      return new Response(object.body, {
        headers: {
          'content-type': object.httpMetadata?.contentType || 'application/octet-stream',
          etag: object.httpEtag,
        },
      });
    }
    if (request.method === 'PUT') {
      const contentType = request.headers.get('content-type') || 'application/octet-stream';
      // If-Match / If-None-Match make read-modify-write updates (slot registry,
      // build numbers) safe when several workflow runs race.
      const conditional = request.headers.has('if-match') || request.headers.has('if-none-match');
      const stored = await env.STORE.put(key, request.body, {
        httpMetadata: { contentType },
        customMetadata: { writer: claims.job_workflow_ref, run: `${claims.run_id}` },
        ...(conditional ? { onlyIf: request.headers } : {}),
      });
      if (!stored) throw new HttpError(412, 'Precondition failed');
      return json({ key, size: stored.size, etag: stored.etag });
    }
    throw new HttpError(405, 'Method not allowed');
  }
  if (path === '/v1/list' && request.method === 'GET') {
    const prefix = objectKey(url.searchParams.get('prefix') || '');
    const listed = [];
    let cursor;
    do {
      const page = await env.STORE.list({ prefix, cursor, limit: 1000 });
      for (const object of page.objects) {
        listed.push({ key: object.key, size: object.size, uploaded: object.uploaded.toISOString() });
      }
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor && listed.length < 10000);
    return json({ objects: listed });
  }
  if (path.startsWith('/v1/multipart/')) {
    const key = objectKey(path.slice('/v1/multipart/'.length));
    const uploadId = url.searchParams.get('uploadId');
    if (request.method === 'POST' && !uploadId) {
      const contentType = url.searchParams.get('contentType') || 'application/octet-stream';
      const upload = await env.STORE.createMultipartUpload(key, { httpMetadata: { contentType } });
      return json({ key, uploadId: upload.uploadId });
    }
    if (!uploadId) throw new HttpError(400, 'uploadId is required');
    const upload = env.STORE.resumeMultipartUpload(key, uploadId);
    if (request.method === 'PUT') {
      const partNumber = Number(url.searchParams.get('part'));
      if (!Number.isInteger(partNumber) || partNumber < 1 || partNumber > 10000) {
        throw new HttpError(400, 'Invalid part number');
      }
      const part = await upload.uploadPart(partNumber, request.body);
      return json(part);
    }
    if (request.method === 'POST' && url.searchParams.has('complete')) {
      const { parts } = await request.json();
      const stored = await upload.complete(parts);
      return json({ key, size: stored.size, etag: stored.etag });
    }
    if (request.method === 'DELETE') {
      await upload.abort();
      return json({ key, aborted: true });
    }
    throw new HttpError(405, 'Method not allowed');
  }
  if (path === '/v1/sign' && request.method === 'POST') {
    const body = await request.json();
    const { issue, variant, build } = installCoordinates([body.issue, body.variant, body.build]);
    const ttl = Math.min(Number(body.ttlSeconds) || Number(env.DEFAULT_LINK_TTL_SECONDS), MAX_TTL_SECONDS);
    if (!(ttl > 0)) throw new HttpError(400, 'Invalid ttl');
    const record = await buildRecord(env, issue, variant, build);
    if (!record) throw new HttpError(404, 'No such build');
    const expires = Math.floor(Date.now() / 1000) + ttl;
    const base = publicBase(env, url);
    const signature = await sign(env, 'p', issue, variant, build, expires);
    const query = `e=${expires}&s=${signature}`;
    return json({
      installUrl: `${base}/p/${issue}/${variant}/${build}?${query}`,
      qrUrl: `${base}/qr/${issue}/${variant}/${build}.svg?${query}`,
      expiresAt: new Date(expires * 1000).toISOString(),
    });
  }
  throw new HttpError(404, 'Not found');
}

function objectKey(raw) {
  let key;
  try {
    key = decodeURIComponent(raw);
  } catch {
    throw new HttpError(400, 'Invalid key');
  }
  if (!KEY_PREFIXES.some((prefix) => key.startsWith(prefix))) {
    throw new HttpError(403, 'Key outside the agent namespaces');
  }
  if (key.split('/').some((part) => part === '..' || part === '.') || key.includes('//') || /[\0-\x1f]/.test(key)) {
    throw new HttpError(400, 'Invalid key');
  }
  return key;
}

// ------------------------------------------------------------ OIDC auth ---

async function authenticate(request, env) {
  const header = request.headers.get('authorization') || '';
  const match = header.match(/^Bearer ([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/);
  if (!match) throw new HttpError(401, 'Missing bearer token');
  const [, encodedHeader, encodedPayload, encodedSignature] = match;
  const jwtHeader = decodeJson(encodedHeader);
  if (jwtHeader.alg !== 'RS256' || !jwtHeader.kid) throw new HttpError(401, 'Unsupported token');
  const key = await signingKey(jwtHeader.kid);
  const verified = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    key,
    base64UrlBytes(encodedSignature),
    new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`),
  );
  if (!verified) throw new HttpError(401, 'Invalid token signature');
  const claims = decodeJson(encodedPayload);
  const now = Math.floor(Date.now() / 1000);
  if (claims.iss !== GITHUB_ISSUER) throw new HttpError(401, 'Unexpected issuer');
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(env.OIDC_AUDIENCE)) throw new HttpError(401, 'Unexpected audience');
  if (!(claims.exp > now - CLOCK_SKEW_SECONDS) || (claims.nbf && claims.nbf > now + CLOCK_SKEW_SECONDS)) {
    throw new HttpError(401, 'Expired token');
  }
  if (claims.repository !== env.GITHUB_REPOSITORY || `${claims.repository_id}` !== env.GITHUB_REPOSITORY_ID) {
    throw new HttpError(403, 'Repository not allowed');
  }
  const allowed = env.ALLOWED_WORKFLOWS.split(',').map((name) => `${env.GITHUB_REPOSITORY}/${name.trim()}@refs/heads/${env.DEFAULT_BRANCH}`);
  if (!allowed.includes(claims.job_workflow_ref)) {
    throw new HttpError(403, 'Workflow not allowed');
  }
  return claims;
}

async function signingKey(kid) {
  const stale = Date.now() - jwksCache.fetchedAt > 3600 * 1000;
  if (stale || !jwksCache.keys.has(kid)) {
    const response = await fetch(JWKS_URL, { cf: { cacheTtl: 300 } });
    if (!response.ok) throw new HttpError(503, 'Unable to fetch signing keys');
    const { keys } = await response.json();
    const imported = new Map();
    for (const jwk of keys) {
      if (jwk.kty !== 'RSA' || !jwk.kid) continue;
      imported.set(jwk.kid, await crypto.subtle.importKey(
        'jwk',
        { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: 'RS256', ext: true },
        { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
        false,
        ['verify'],
      ));
    }
    jwksCache = { keys: imported, fetchedAt: Date.now() };
  }
  const key = jwksCache.keys.get(kid);
  if (!key) throw new HttpError(401, 'Unknown signing key');
  return key;
}

function decodeJson(segment) {
  try {
    return JSON.parse(new TextDecoder().decode(base64UrlBytes(segment)));
  } catch {
    throw new HttpError(401, 'Malformed token');
  }
}

function base64UrlBytes(segment) {
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (segment.length % 4)) % 4);
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

// ------------------------------------------------------- Signed install ---

function installCoordinates([issue, variant, build]) {
  const values = { issue: `${issue}`, variant: `${variant}`, build: `${build}` };
  if (!/^\d+$/.test(values.issue) || !/^[a-z0-9-]+$/.test(values.variant) || !/^\d+$/.test(values.build)) {
    throw new HttpError(400, 'Invalid prototype coordinates');
  }
  return values;
}

async function sign(env, purpose, issue, variant, build, expires) {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(env.LINK_SECRET),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${purpose}|${issue}|${variant}|${build}|${expires}`));
  return btoa(String.fromCharCode(...new Uint8Array(mac))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function verifySigned(env, url, purpose, coordinates) {
  if (!env.LINK_SECRET) throw new HttpError(503, 'Distribution is not configured');
  const { issue, variant, build } = installCoordinates(coordinates);
  const expires = Number(url.searchParams.get('e'));
  const signature = url.searchParams.get('s') || '';
  if (!Number.isInteger(expires) || expires < Math.floor(Date.now() / 1000)) {
    throw new HttpError(410, 'This link has expired. Ask the agent to issue a new install link.');
  }
  const expected = await sign(env, purpose, issue, variant, build, expires);
  if (!timingSafeEqual(expected, signature)) throw new HttpError(403, 'Invalid link signature');
  return { issue, variant, build, expires };
}

function timingSafeEqual(left, right) {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return difference === 0;
}

async function buildRecord(env, issue, variant, build) {
  const object = await env.STORE.get(`prototypes/${issue}/${variant}/builds/${build}/build.json`);
  return object ? object.json() : null;
}

async function installPage(env, url, coordinates) {
  const { issue, variant, build, expires } = await verifySigned(env, url, 'p', coordinates);
  const record = await buildRecord(env, issue, variant, build);
  if (!record || record.result !== 'success') throw new HttpError(404, 'No installable build');
  const base = publicBase(env, url);
  const manifestUrl = `${base}/m/${issue}/${variant}/${build}/manifest.plist?e=${expires}&s=${await sign(env, 'm', issue, variant, build, expires)}`;
  const installHref = `itms-services://?action=download-manifest&url=${encodeURIComponent(manifestUrl)}`;
  // Direct IPA download for Apple Configurator / Xcode (Devices and Simulators) installs.
  const ipaHref = `${base}/d/${issue}/${variant}/${build}/app.ipa?e=${expires}&s=${await sign(env, 'd', issue, variant, build, expires)}`;
  const rows = [
    ['Issue', `#${record.issue}`],
    ['Prototype', record.prototypeId],
    ['Bundle ID', record.bundleId],
    ['Version', `${record.version} (${record.buildNumber})`],
    ['Commit', record.commit],
    ['Built', record.generatedAt],
    ['Link expires', new Date(expires * 1000).toISOString()],
  ];
  const page = `<!doctype html>
<html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>${escapeHtml(record.displayName)} を端末へインストール</title>
<style>
:root{color-scheme:light dark;--fg:#1d1d1f;--muted:#6e6e73;--bg:#fff;--line:#d2d2d7;--accent:#0071e3}
@media (prefers-color-scheme:dark){:root{--fg:#f5f5f7;--muted:#a1a1a6;--bg:#000;--line:#424245;--accent:#2997ff}}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Hiragino Sans",sans-serif}
main{max-width:560px;margin:0 auto;padding:32px 16px}
h1{font-size:24px;margin:0 0 4px}p{color:var(--muted);margin:0 0 24px}
a.install{display:block;text-align:center;background:var(--accent);color:#fff;text-decoration:none;font-weight:600;padding:14px;border-radius:12px}
p.alt{margin:12px 0 0;font-size:14px}p.alt a{color:var(--accent)}
dl{display:grid;grid-template-columns:max-content 1fr;gap:8px 16px;margin:24px 0 0;font-size:14px}
dt{color:var(--muted)}dd{margin:0;overflow-wrap:anywhere;font-family:ui-monospace,Menlo,monospace}
</style></head><body><main>
<h1>${escapeHtml(record.displayName)}</h1>
<p>${escapeHtml(record.summary || 'Ad Hoc 署名済みプロトタイプ')}</p>
<a class="install" href="${escapeHtml(installHref)}">インストール</a>
<p class="alt"><a href="${escapeHtml(ipaHref)}" download="${escapeHtml(`${record.displayName || 'prototype'}.ipa`)}">IPA をダウンロード</a>(Apple Configurator や Xcode で手動インストールする場合)</p>
<dl>${rows.map(([name, value]) => `<dt>${escapeHtml(name)}</dt><dd>${escapeHtml(`${value ?? ''}`)}</dd>`).join('')}</dl>
</main></body></html>`;
  return new Response(page, {
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'private, no-store',
      'referrer-policy': 'no-referrer',
      'x-robots-tag': 'noindex',
    },
  });
}

async function qrImage(env, url, coordinates) {
  const { issue, variant, build } = await verifySigned(env, url, 'p', coordinates);
  const target = `${publicBase(env, url)}/p/${issue}/${variant}/${build}?e=${url.searchParams.get('e')}&s=${url.searchParams.get('s')}`;
  const code = qrcode(0, 'M');
  code.addData(target);
  code.make();
  return new Response(code.createSvgTag({ cellSize: 6, margin: 4, scalable: true }), {
    headers: { 'content-type': 'image/svg+xml', 'cache-control': 'private, max-age=300' },
  });
}

async function manifest(env, url, coordinates) {
  const { issue, variant, build, expires } = await verifySigned(env, url, 'm', coordinates);
  const record = await buildRecord(env, issue, variant, build);
  if (!record || record.result !== 'success') throw new HttpError(404, 'No installable build');
  const ipaUrl = `${publicBase(env, url)}/d/${issue}/${variant}/${build}/app.ipa?e=${expires}&s=${await sign(env, 'd', issue, variant, build, expires)}`;
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${escapeHtml(ipaUrl)}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>${escapeHtml(record.bundleId)}</string>
        <key>bundle-version</key>
        <string>${escapeHtml(`${record.version}`)}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>${escapeHtml(record.displayName)}</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
`;
  return new Response(body, { headers: { 'content-type': 'text/xml; charset=utf-8', 'cache-control': 'private, no-store' } });
}

async function ipa(request, env, url, coordinates) {
  const { issue, variant, build } = await verifySigned(env, url, 'd', coordinates);
  const key = `prototypes/${issue}/${variant}/builds/${build}/app.ipa`;
  return serveObject(request, env, key, 'application/octet-stream', 'private, no-store');
}

async function media(request, env, key) {
  return serveObject(request, env, key, undefined, 'public, max-age=86400');
}

async function serveObject(request, env, key, contentType, cacheControl) {
  const range = request.headers.get('range');
  const object = await env.STORE.get(key, range ? { range: request.headers } : undefined);
  if (!object) throw new HttpError(404, 'Not found');
  const headers = new Headers({
    'content-type': contentType || object.httpMetadata?.contentType || 'application/octet-stream',
    'cache-control': cacheControl,
    'accept-ranges': 'bytes',
    etag: object.httpEtag,
  });
  if (range && object.range) {
    const start = object.range.offset ?? 0;
    const length = object.range.length ?? object.size - start;
    headers.set('content-range', `bytes ${start}-${start + length - 1}/${object.size}`);
    headers.set('content-length', `${length}`);
    return new Response(request.method === 'HEAD' ? null : object.body, { status: 206, headers });
  }
  headers.set('content-length', `${object.size}`);
  return new Response(request.method === 'HEAD' ? null : object.body, { headers });
}

// -------------------------------------------------------------- helpers ---

function publicBase(env, url) {
  return env.PUBLIC_BASE_URL || url.origin;
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } });
}

function escapeHtml(value) {
  return `${value ?? ''}`.replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]);
}
