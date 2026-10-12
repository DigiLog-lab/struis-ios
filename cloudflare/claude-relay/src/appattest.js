// Apple App Attest の検証(attestation と assertion)。Workers と Node の WebCrypto だけで動く。
//
// https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server
// - attestation: x5c の証明書チェーンを Apple App Attestation Root CA まで検証し、nonce・rpIdHash・
//   counter・aaguid・credentialId を確かめて、端末の公開鍵を取り出す。
// - assertion: 保存した公開鍵で署名を検証し、rpIdHash と counter(単調増加)を確かめる。

export const APPLE_APP_ATTEST_ROOT_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

const AAGUID_DEVELOPMENT = 'appattestdevelop';
const AAGUID_PRODUCTION = 'appattest\0\0\0\0\0\0\0';
const NONCE_EXTENSION_OID = '1.2.840.113635.100.8.2';

export class AttestError extends Error {
  constructor(code, message) {
    super(message || code);
    this.code = code;
  }
}

// ------------------------------------------------------------------ bytes ---

export function base64ToBytes(text) {
  const normalized = text.replace(/-/g, '+').replace(/_/g, '/').replace(/\s+/g, '');
  const binary = atob(normalized + '='.repeat((4 - (normalized.length % 4)) % 4));
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

export function bytesToBase64(bytes) {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

export function pemToBytes(pem) {
  return base64ToBytes(pem.replace(/-----[^-]+-----/g, ''));
}

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function equal(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
}

// ------------------------------------------------------------------- CBOR ---

export function decodeCbor(bytes) {
  let offset = 0;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  function length(info) {
    if (info < 24) return info;
    if (info === 24) return view.getUint8(offset++);
    if (info === 25) { const v = view.getUint16(offset); offset += 2; return v; }
    if (info === 26) { const v = view.getUint32(offset); offset += 4; return v; }
    if (info === 27) { const v = Number(view.getBigUint64(offset)); offset += 8; return v; }
    throw new AttestError('cbor', 'unsupported CBOR length');
  }
  function item() {
    if (offset >= bytes.length) throw new AttestError('cbor', 'truncated CBOR');
    const initial = bytes[offset++];
    const major = initial >> 5;
    const info = initial & 31;
    switch (major) {
      case 0: return length(info);
      case 1: return -1 - length(info);
      case 2: { const n = length(info); const v = bytes.subarray(offset, offset + n); offset += n; return v; }
      case 3: { const n = length(info); const v = new TextDecoder().decode(bytes.subarray(offset, offset + n)); offset += n; return v; }
      case 4: { const n = length(info); const v = []; for (let i = 0; i < n; i++) v.push(item()); return v; }
      case 5: {
        const n = length(info);
        const v = new Map();
        for (let i = 0; i < n; i++) { const k = item(); v.set(k, item()); }
        return v;
      }
      case 7:
        if (info === 20) return false;
        if (info === 21) return true;
        if (info === 22) return null;
        throw new AttestError('cbor', 'unsupported CBOR simple value');
      default:
        throw new AttestError('cbor', 'unsupported CBOR type');
    }
  }
  const value = item();
  if (offset !== bytes.length) throw new AttestError('cbor', 'trailing CBOR data');
  return value;
}

// -------------------------------------------------------------------- DER ---

function derNode(bytes, offset) {
  const tag = bytes[offset];
  let length = bytes[offset + 1];
  let header = 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 4) throw new AttestError('der', 'unsupported DER length');
    length = 0;
    for (let i = 0; i < count; i++) length = (length << 8) | bytes[offset + 2 + i];
    header += count;
  }
  const start = offset + header;
  const end = start + length;
  if (end > bytes.length) throw new AttestError('der', 'truncated DER');
  return { tag, start, end, header, raw: bytes.subarray(offset, end), value: bytes.subarray(start, end) };
}

function derChildren(node) {
  const out = [];
  let offset = 0;
  while (offset < node.value.length) {
    const child = derNode(node.value, offset);
    out.push(child);
    offset = child.end;
  }
  return out;
}

function oidToString(bytes) {
  const parts = [Math.floor(bytes[0] / 40), bytes[0] % 40];
  let value = 0;
  for (let i = 1; i < bytes.length; i++) {
    value = (value << 7) | (bytes[i] & 0x7f);
    if (!(bytes[i] & 0x80)) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join('.');
}

function derTime(node) {
  const text = new TextDecoder().decode(node.value);
  const m = node.tag === 0x17
    ? text.match(/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/)
    : text.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/);
  if (!m) throw new AttestError('der', 'unsupported certificate time');
  let year = Number(m[1]);
  if (node.tag === 0x17) year += year < 50 ? 2000 : 1900;
  return Date.UTC(year, Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]));
}

export function parseCertificate(der) {
  const cert = derNode(der, 0);
  const [tbs, signatureAlgorithm, signatureValue] = derChildren(cert);
  const fields = derChildren(tbs);
  let index = 0;
  if (fields[0].tag === 0xa0) index++; // [0] version
  const serial = fields[index++];
  index++; // signature algorithm (repeated in the outer certificate)
  const issuer = fields[index++];
  const validity = derChildren(fields[index++]);
  const subject = fields[index++];
  const spki = fields[index++];
  const extensions = new Map();
  for (const field of fields.slice(index)) {
    if (field.tag !== 0xa3) continue;
    for (const extension of derChildren(derChildren(field)[0])) {
      const parts = derChildren(extension);
      const oid = oidToString(parts[0].value);
      extensions.set(oid, parts[parts.length - 1].value);
    }
  }
  const algorithm = derChildren(spki)[0];
  const [keyAlgorithm, curve] = derChildren(algorithm);
  return {
    tbs: tbs.raw,
    serial: serial.value,
    signatureAlgorithm: oidToString(derChildren(signatureAlgorithm)[0].value),
    signature: signatureValue.value.subarray(1), // BIT STRING: drop the unused-bits byte
    issuer: issuer.raw,
    subject: subject.raw,
    notBefore: derTime(validity[0]),
    notAfter: derTime(validity[1]),
    spki: spki.raw,
    keyAlgorithm: oidToString(keyAlgorithm.value),
    curve: curve ? oidToString(curve.value) : null,
    publicKey: derChildren(spki)[1].value.subarray(1),
    extensions,
  };
}

const CURVES = { '1.2.840.10045.3.1.7': ['P-256', 32], '1.3.132.0.34': ['P-384', 48] };
const SIGNATURE_HASHES = { '1.2.840.10045.4.3.2': 'SHA-256', '1.2.840.10045.4.3.3': 'SHA-384' };

/** ECDSA の DER 署名(SEQUENCE { r, s })を WebCrypto の r||s に直す。 */
export function derSignatureToRaw(signature, size) {
  const [r, s] = derChildren(derNode(signature, 0));
  const fit = (value) => {
    let bytes = value.value;
    while (bytes.length > size && bytes[0] === 0) bytes = bytes.subarray(1);
    if (bytes.length > size) throw new AttestError('der', 'bad ECDSA signature');
    return concat(new Uint8Array(size - bytes.length), bytes);
  };
  return concat(fit(r), fit(s));
}

async function importSpki(cert) {
  const curve = CURVES[cert.curve];
  if (cert.keyAlgorithm !== '1.2.840.10045.2.1' || !curve) throw new AttestError('certificate', 'unsupported key');
  return { key: await crypto.subtle.importKey('spki', cert.spki, { name: 'ECDSA', namedCurve: curve[0] }, false, ['verify']), size: curve[1] };
}

async function verifySignedBy(cert, issuer) {
  const hash = SIGNATURE_HASHES[cert.signatureAlgorithm];
  if (!hash) throw new AttestError('certificate', 'unsupported signature algorithm');
  if (!equal(cert.issuer, issuer.subject)) throw new AttestError('certificate', 'issuer does not match');
  const { key, size } = await importSpki(issuer);
  const ok = await crypto.subtle.verify({ name: 'ECDSA', hash }, key, derSignatureToRaw(cert.signature, size), cert.tbs);
  if (!ok) throw new AttestError('certificate', 'certificate signature is invalid');
}

// ---------------------------------------------------------- authenticator ---

export function parseAuthenticatorData(bytes) {
  if (bytes.length < 37) throw new AttestError('auth_data', 'authenticator data is too short');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const out = { rpIdHash: bytes.subarray(0, 32), flags: bytes[32], counter: view.getUint32(33) };
  if (bytes.length >= 55) {
    out.aaguid = bytes.subarray(37, 53);
    const idLength = view.getUint16(53);
    out.credentialId = bytes.subarray(55, 55 + idLength);
  }
  return out;
}

/** 受け付ける App ID(`TEAMID.bundleId`)ごとの rpIdHash。 */
export async function appIdHashes(appIds) {
  const out = new Map();
  for (const appId of appIds) out.set(bytesToBase64(await sha256(new TextEncoder().encode(appId))), appId);
  return out;
}

/**
 * attestation を検証して、登録する鍵の記録を返す。
 * @param {object} input { keyId(base64), attestation(base64), challenge(Uint8Array), appIds: Map<base64 hash, appId>, now, rootPem }
 */
export async function verifyAttestation({ keyId, attestation, challenge, appIds, now = Date.now(), rootPem = APPLE_APP_ATTEST_ROOT_PEM }) {
  const object = decodeCbor(base64ToBytes(attestation));
  if (!(object instanceof Map) || object.get('fmt') !== 'apple-appattest') throw new AttestError('attestation', 'not an App Attest attestation');
  const statement = object.get('attStmt');
  const authData = object.get('authData');
  const x5c = statement instanceof Map ? statement.get('x5c') : null;
  if (!Array.isArray(x5c) || x5c.length < 2 || !(authData instanceof Uint8Array)) throw new AttestError('attestation', 'malformed attestation');

  // 1. 証明書チェーン(credCert → intermediate → Apple root)と有効期間。
  const root = parseCertificate(pemToBytes(rootPem));
  const chain = x5c.map(parseCertificate);
  for (const cert of chain) {
    if (now < cert.notBefore || now > cert.notAfter) throw new AttestError('certificate', 'certificate is not valid now');
  }
  await verifySignedBy(chain[0], chain[1]);
  await verifySignedBy(chain[1], root);

  // 2-4. nonce = SHA256(authData || SHA256(challenge)) が credCert の拡張と一致する。
  const nonce = await sha256(concat(authData, await sha256(challenge)));
  const extension = chain[0].extensions.get(NONCE_EXTENSION_OID);
  if (!extension) throw new AttestError('attestation', 'nonce extension is missing');
  const [tagged] = derChildren(derNode(extension, 0));
  const embedded = derNode(tagged.value, 0).value;
  if (!equal(embedded, nonce)) throw new AttestError('attestation', 'nonce does not match');

  // 5. keyId = SHA256(credCert の公開鍵)。
  const publicKey = chain[0].publicKey;
  const keyIdBytes = base64ToBytes(keyId);
  if (!equal(await sha256(publicKey), keyIdBytes)) throw new AttestError('attestation', 'key id does not match the certificate');

  // 6-9. rpIdHash・counter・aaguid・credentialId。
  const parsed = parseAuthenticatorData(authData);
  const appId = appIds.get(bytesToBase64(parsed.rpIdHash));
  if (!appId) throw new AttestError('attestation', 'app id is not allowed');
  if (parsed.counter !== 0) throw new AttestError('attestation', 'counter must be zero');
  const aaguid = parsed.aaguid ? new TextDecoder().decode(parsed.aaguid) : '';
  const environment = aaguid === AAGUID_PRODUCTION ? 'production' : aaguid === AAGUID_DEVELOPMENT ? 'development' : null;
  if (!environment) throw new AttestError('attestation', 'unknown App Attest environment');
  if (!parsed.credentialId || !equal(parsed.credentialId, keyIdBytes)) throw new AttestError('attestation', 'credential id does not match');

  return {
    keyId: bytesToBase64(keyIdBytes),
    publicKey: bytesToBase64(chain[0].spki),
    appId,
    environment,
    counter: 0,
    receipt: statement.get('receipt') instanceof Uint8Array ? bytesToBase64(statement.get('receipt')) : null,
  };
}

/**
 * assertion を検証して、新しい counter を返す(呼び出し側が保存値より大きいことを保証して更新する)。
 * @param {object} input { assertion(base64), clientData(Uint8Array), key: { publicKey(base64 SPKI), appId, counter }, appIds }
 */
export async function verifyAssertion({ assertion, clientData, key, appIds }) {
  const object = decodeCbor(base64ToBytes(assertion));
  const signature = object instanceof Map ? object.get('signature') : null;
  const authenticatorData = object instanceof Map ? object.get('authenticatorData') : null;
  if (!(signature instanceof Uint8Array) || !(authenticatorData instanceof Uint8Array)) throw new AttestError('assertion', 'malformed assertion');
  const nonce = await sha256(concat(authenticatorData, await sha256(clientData)));
  const publicKey = await crypto.subtle.importKey('spki', base64ToBytes(key.publicKey), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
  const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, publicKey, derSignatureToRaw(signature, 32), nonce);
  if (!ok) throw new AttestError('assertion', 'assertion signature is invalid');
  const parsed = parseAuthenticatorData(authenticatorData);
  if (appIds.get(bytesToBase64(parsed.rpIdHash)) !== key.appId) throw new AttestError('assertion', 'app id does not match');
  if (parsed.counter <= key.counter) throw new AttestError('assertion', 'counter did not increase');
  return parsed.counter;
}
