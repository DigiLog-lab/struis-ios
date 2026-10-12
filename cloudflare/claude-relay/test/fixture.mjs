// テスト用の App Attest attestation を作る(Apple の代わりの root・intermediate を openssl で作る)。
// テストの実行時に作る(鍵をリポジトリに置かない)。openssl が要る。
import { execFileSync } from 'node:child_process';
import { createHash, createPrivateKey } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export function makeFixture() {
const dir = mkdtempSync(join(tmpdir(), 'appattest-'));
const path = (name) => join(dir, name);
const openssl = (...args) => execFileSync('openssl', args, { stdio: ['ignore', 'pipe', 'pipe'] });
const sha256 = (data) => createHash('sha256').update(data).digest();

const appId = '4D4W8FMKMW.com.digiloglab.strius';
const challenge = Buffer.from('struis-test-challenge-0123456789');

// root(P-384)→ intermediate(P-384)→ credCert(P-256)。
openssl('ecparam', '-name', 'secp384r1', '-genkey', '-noout', '-out', path('root.key'));
openssl('req', '-x509', '-new', '-key', path('root.key'), '-sha384', '-days', '36500', '-subj', '/CN=Test App Attestation Root CA', '-out', path('root.pem'));
openssl('ecparam', '-name', 'secp384r1', '-genkey', '-noout', '-out', path('ca.key'));
openssl('req', '-new', '-key', path('ca.key'), '-subj', '/CN=Test App Attestation CA 1', '-out', path('ca.csr'));
writeFileSync(path('ca.ext'), 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n');
openssl('x509', '-req', '-in', path('ca.csr'), '-CA', path('root.pem'), '-CAkey', path('root.key'), '-CAcreateserial', '-sha384', '-days', '36500', '-extfile', path('ca.ext'), '-out', path('ca.pem'));
openssl('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', path('leaf.key'));

const leafKey = createPrivateKey(readFileSync(path('leaf.key')));
const jwk = leafKey.export({ format: 'jwk' });
const point = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]);
const keyId = sha256(point);

// authData: rpIdHash | flags | counter(0) | aaguid | credentialIdLength | credentialId
const authData = Buffer.concat([
  sha256(appId), Buffer.from([0x40]), Buffer.alloc(4),
  Buffer.from('appattestdevelop'), Buffer.from([0, 32]), keyId,
]);
const nonce = sha256(Buffer.concat([authData, sha256(challenge)]));
const extension = Buffer.concat([Buffer.from('3024a1220420', 'hex'), nonce]).toString('hex').toUpperCase().match(/../g).join(':');
writeFileSync(path('leaf.ext'), `1.2.840.113635.100.8.2=DER:${extension}\n`);
openssl('req', '-new', '-key', path('leaf.key'), '-subj', `/CN=${keyId.toString('hex')}`, '-out', path('leaf.csr'));
openssl('x509', '-req', '-in', path('leaf.csr'), '-CA', path('ca.pem'), '-CAkey', path('ca.key'), '-CAcreateserial', '-sha256', '-days', '36500', '-extfile', path('leaf.ext'), '-out', path('leaf.pem'));

const der = (pem) => openssl('x509', '-in', pem, '-outform', 'DER');

// CBOR: {"fmt": "apple-appattest", "attStmt": {"x5c": [leaf, ca], "receipt": h''}, "authData": authData}
function cbor(value) {
  const head = (major, n) => {
    if (n < 24) return Buffer.from([(major << 5) | n]);
    if (n < 256) return Buffer.from([(major << 5) | 24, n]);
    if (n < 65536) return Buffer.from([(major << 5) | 25, n >> 8, n & 255]);
    const b = Buffer.alloc(5); b[0] = (major << 5) | 26; b.writeUInt32BE(n, 1); return b;
  };
  if (Buffer.isBuffer(value)) return Buffer.concat([head(2, value.length), value]);
  if (typeof value === 'string') return Buffer.concat([head(3, Buffer.byteLength(value)), Buffer.from(value)]);
  if (Array.isArray(value)) return Buffer.concat([head(4, value.length), ...value.map(cbor)]);
  const entries = Object.entries(value);
  return Buffer.concat([head(5, entries.length), ...entries.flatMap(([k, v]) => [cbor(k), cbor(v)])]);
}
const attestation = cbor({ fmt: 'apple-appattest', attStmt: { x5c: [der(path('leaf.pem')), der(path('ca.pem'))], receipt: Buffer.from('receipt') }, authData });

return {
  appId,
  rootPem: readFileSync(path('root.pem'), 'utf8'),
  challenge: challenge.toString('base64'),
  keyId: keyId.toString('base64'),
  attestation: attestation.toString('base64'),
  leafKeyPem: readFileSync(path('leaf.key'), 'utf8'),
};
}
