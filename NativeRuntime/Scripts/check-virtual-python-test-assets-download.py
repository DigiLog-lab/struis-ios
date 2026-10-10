#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exercise exact asset download code with bounded public-response fixtures."""
import contextlib
import hashlib
import importlib.util
import io
import itertools
from pathlib import Path
import tempfile
from unittest.mock import patch

source = Path(__file__).with_name('prepare-virtual-python-test-assets.py')
spec = importlib.util.spec_from_file_location('asset_preparation', source)
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)

class Response:
    status = 200
    def __init__(self, data, declared=None, encoding='identity'):
        self.body = io.BytesIO(data)
        self.headers = {'Content-Length': str(len(data) if declared is None else declared), 'Content-Encoding': encoding}
    def __enter__(self): return self
    def __exit__(self, *args): return False
    def read1(self, size): return self.body.read(size)

valid = b'fixed public asset fixture'
expected = hashlib.sha256(valid).hexdigest()

def exercise(responses, success):
    calls = []
    def open_response(request, timeout):
        assert request.full_url == assets.CDN + 'fixture.whl'
        assert request.get_header('Accept-encoding') == 'identity' and timeout == 30
        calls.append(request)
        return responses[len(calls) - 1]
    log = io.StringIO()
    with patch.object(assets.urllib.request, 'urlopen', open_response), patch.object(assets.time, 'sleep') as sleep, contextlib.redirect_stdout(log):
        try:
            result = assets.download_verified('fixture.whl', expected)
            assert success and result == valid
        except ValueError:
            assert not success
    assert len(calls) == 3 and [c.args[0] for c in sleep.call_args_list] == [1, 2]
    assert log.getvalue().count('Pinned download rejected:') == (2 if success else 3)
    assert all('bytes=' in line and 'sha256=' in line and 'status=' in line for line in log.getvalue().splitlines())

exercise([Response(valid[:3], len(valid)), Response(b'x' * len(valid)), Response(valid)], True)
print('PASS partial then corrupt fresh response retries same URL/pin and accepts only exact bytes/hash')
exercise([Response(b'bad')] * 3, False)
print('PASS all bad responses stop after three attempts with finite byte/hash/status diagnostics')
exercise([Response(b'', assets.MAX_ASSET_BYTES + 1)] * 3, False)
exercise([Response(valid, encoding='gzip')] * 3, False)
print('PASS oversized declaration and unexpected content encoding rejected before acceptance')
with patch.object(assets.time, 'monotonic', side_effect=itertools.cycle((0, 31))):
    exercise([Response(valid)] * 3, False)
print('PASS elapsed download deadline prevents body acceptance and remains bounded to three attempts')

with tempfile.TemporaryDirectory(prefix='hyotan-download-failclosed-') as temporary:
    root = Path(temporary); name = 'fixture.whl'
    with patch.object(assets, 'inventory', return_value={name: expected}), patch.object(assets.urllib.request, 'urlopen', return_value=Response(b'bad')) as request, patch.object(assets.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
        try: assets.load_package_assets(root, {name: expected}, False); raise AssertionError('Bad fresh body accepted')
        except ValueError as error: assert 'bounded attempts' in str(error)
        assert request.call_count == 3 and not (root / name).exists()
    (root / name).write_bytes(b'corrupt cached fixture')
    with patch.object(assets.urllib.request, 'urlopen', side_effect=AssertionError('Corrupt cache refetched')) as request:
        try: assets.load_package_assets(root, {name: expected}, False); raise AssertionError('Corrupt cache accepted')
        except ValueError as error: assert 'SHA-256 mismatch' in str(error)
        assert request.call_count == 0 and (root / name).read_bytes() == b'corrupt cached fixture'
print('PASS no unverified cache write; corrupt existing cache fails immediately without network replacement')
print('LIMIT response simulation only; validate actual clean online cache separately; no Apple execution claim')
