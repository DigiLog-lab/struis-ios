#!/usr/bin/env python3
"""Encode the pinned CDLA-Permissive-2.0 webpki certificates as PEM for OpenSSL."""
import ast
import hashlib
import json
import pathlib
import re
import ssl
import sys

root = pathlib.Path(__file__).resolve().parents[1]
metadata = json.loads(pathlib.Path(sys.argv[1]).read_text())
packages = [p for p in metadata['packages'] if p['name'] == 'webpki-root-certs']
if len(packages) != 1 or packages[0]['license'] != 'CDLA-Permissive-2.0':
    raise SystemExit('Review the trust bundle version and license before building')
package = packages[0]
source = pathlib.Path(package['manifest_path']).parent
rust = (source / 'src/lib.rs').read_text()
certificates = re.findall(r'CertificateDer::from_slice\((b"[^"\n]+")\)', rust)
if not certificates: raise SystemExit('Certificate source format changed')
pem = ''.join(ssl.DER_cert_to_PEM_cert(ast.literal_eval(certificate)) for certificate in certificates)
ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).load_verify_locations(cadata=pem)
destination = root / 'Resources/cacert.pem'
destination.write_text(pem)
(root / 'Licenses/CA-bundle.txt').write_text((source / 'LICENSE').read_text())
(root / 'ca-bundle.lock.json').write_text(json.dumps({'name':package['name'], 'version':package['version'], 'source':package['source'], 'selectedLicense':package['license'], 'certificateCount':len(certificates), 'sourceSHA256':hashlib.sha256(rust.encode()).hexdigest(), 'pemSHA256':hashlib.sha256(pem.encode()).hexdigest()},indent=2)+'\n')
print(f'Encoded and parsed {len(certificates)} pinned trust anchors; certificate verification remains enabled.')
