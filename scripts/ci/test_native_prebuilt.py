import hashlib
import http.client
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import json
import unittest
from unittest import mock
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parent))
import native_prebuilt
import ui_test_plan


def archive(entries):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as package:
        for name, data in entries.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            package.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


class NativePrebuiltTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        subprocess.run(['git', 'init', '-q'], cwd=self.root, check=True)
        for name, text in [('NativeRuntime/dependencies.lock.json', '[]'), ('NativeRuntime/Scripts/build.py', 'x'),
                           ('NativeRuntime/README.md', 'docs'), ('NativeRuntime/Worker/App.swift', 'app'),
                           ('NativeRuntime/Shared/Thing.swift', 'shared')]:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        subprocess.run(['git', 'add', '.'], cwd=self.root, check=True)

    def test_key_covers_build_inputs_and_matches_the_cache_exclusions(self):
        self.assertEqual(native_prebuilt.tracked_inputs(self.root),
                         ['NativeRuntime/Scripts/build.py', 'NativeRuntime/dependencies.lock.json'])
        before = native_prebuilt.key(self.root)
        (self.root / 'NativeRuntime/README.md').write_text('changed docs')
        (self.root / 'NativeRuntime/Worker/App.swift').write_text('changed app')
        self.assertEqual(native_prebuilt.key(self.root), before)
        (self.root / 'NativeRuntime/Scripts/build.py').write_text('y')
        self.assertNotEqual(native_prebuilt.key(self.root), before)

    def fetcher(self, files):
        def fetch(url, timeout=0):
            name = url.rsplit('/', 1)[1]
            if name not in files:
                raise urllib.error.HTTPError(url, 404, 'Not Found', None, None)
            return files[name]
        return fetch

    def test_unpublished_inputs_fall_back_to_building(self):
        self.assertEqual(native_prebuilt.apply(self.root, self.fetcher({})), 3)
        self.assertFalse((self.root / native_prebuilt.MARKER).exists())

    def test_verified_archive_is_unpacked_and_marked(self):
        data = archive({'NativeRuntime/Vendor/X.xcframework/Info.plist': b'plist'})
        name = native_prebuilt.asset_name(native_prebuilt.key(self.root))
        fetch = self.fetcher({name: data, name + '.sha256': hashlib.sha256(data).hexdigest().encode() + b'  x\n'})
        self.assertEqual(native_prebuilt.apply(self.root, fetch), 0)
        self.assertEqual((self.root / 'NativeRuntime/Vendor/X.xcframework/Info.plist').read_bytes(), b'plist')
        self.assertTrue((self.root / native_prebuilt.MARKER).exists())

    def test_absolute_links_are_skipped_and_failures_leave_no_partial_tree(self):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w:gz') as package:
            for name, data in [('NativeRuntime/Vendor/X.xcframework/Info.plist', b'plist'),
                               ('NativeRuntime/Vendor/X.xcframework/lib/real', b'lib')]:
                info = tarfile.TarInfo(name)
                info.size = len(data)
                package.addfile(info, io.BytesIO(data))
            for name, target in [('NativeRuntime/Vendor/dash-source/missing', '/usr/local/share/automake-1.15/missing'),
                                 ('NativeRuntime/Vendor/X.xcframework/lib/alias', 'real')]:
                info = tarfile.TarInfo(name)
                info.type, info.linkname = tarfile.SYMTYPE, target
                package.addfile(info)
        data = buffer.getvalue()
        name = native_prebuilt.asset_name(native_prebuilt.key(self.root))
        fetch = self.fetcher({name: data, name + '.sha256': hashlib.sha256(data).hexdigest().encode()})
        self.assertEqual(native_prebuilt.apply(self.root, fetch), 0)
        self.assertFalse((self.root / 'NativeRuntime/Vendor/dash-source/missing').is_symlink())
        self.assertEqual((self.root / 'NativeRuntime/Vendor/X.xcframework/lib/alias').read_bytes(), b'lib')
        self.assertFalse((self.root / 'NativeRuntime/.prebuilt-staging').exists())

    def test_mismatched_hash_or_foreign_entry_is_rejected(self):
        name = native_prebuilt.asset_name(native_prebuilt.key(self.root))
        good = archive({'NativeRuntime/Vendor/A': b'a'})
        with self.assertRaises(SystemExit):
            native_prebuilt.apply(self.root, self.fetcher({name: good, name + '.sha256': b'0' * 64}))
        foreign = archive({'NativeRuntime/Vendor/B': b'b', 'strius/Injected.swift': b'x'})
        with self.assertRaises(SystemExit):
            native_prebuilt.apply(self.root, self.fetcher({name: foreign, name + '.sha256': hashlib.sha256(foreign).hexdigest().encode()}))
        self.assertFalse((self.root / 'strius').exists())
        self.assertFalse((self.root / 'NativeRuntime/Vendor').exists())
        self.assertFalse((self.root / native_prebuilt.MARKER).exists())


class TestFileSelectionTests(unittest.TestCase):
    def test_a_changed_file_selects_every_test_class_it_declares(self):
        tests = ui_test_plan.discover()
        plan = json.loads(ui_test_plan.PLAN.read_text())
        selected = ui_test_plan.select(tests, plan, 'pr', ['striusUITests/WorkbookE2EFixesUITests.swift'])
        self.assertEqual({test.split('/')[0] for test in selected},
                         {'WorkbookE2EFixesUITests', 'WorkbookLongConversationUITests', 'WorkbookOnboardingUITests'})
        support = ui_test_plan.select(tests, plan, 'pr', ['striusUITests/UITestDiagnosticsObserver.swift'])
        self.assertEqual(support, ui_test_plan.select(tests, plan, 'pr', None))


if __name__ == '__main__':
    unittest.main()


class DownloadTests(unittest.TestCase):
    """A dropped connection resumes with a Range request instead of building from source."""

    class Response:
        def __init__(self, body, status, headers, cut=None):
            self.body, self.status, self.headers, self.cut = body, status, headers, cut
            self.offset = 0

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def read(self, size):
            if self.cut is not None and self.offset >= self.cut:
                raise http.client.IncompleteRead(b'', len(self.body) - self.offset)
            end = len(self.body) if self.cut is None else min(self.cut, len(self.body))
            chunk = self.body[self.offset:min(self.offset + size, end)]
            self.offset += len(chunk)
            return chunk

    def test_resumes_after_the_connection_drops(self):
        asset = bytes(range(256)) * 4000
        requests = []
        def opener(request, timeout):
            requests.append(request.get_header('Range'))
            if len(requests) == 1:
                return self.Response(asset, 200, {'Content-Length': str(len(asset))}, cut=300_000)
            start = int(request.get_header('Range').split('=')[1].rstrip('-'))
            return self.Response(asset[start:], 206, {'Content-Range': f'bytes {start}-{len(asset) - 1}/{len(asset)}'})
        with mock.patch('builtins.print'):
            self.assertEqual(native_prebuilt.download('https://example.test/a', opener=opener), asset)
        self.assertEqual(requests, [None, 'bytes=300000-'])

    def test_a_short_body_without_an_error_is_not_accepted(self):
        asset = b'x' * 1000
        calls = []
        def opener(request, timeout):
            calls.append(request.get_header('Range'))
            body = asset[:400] if len(calls) == 1 else asset[400:]
            status = 200 if len(calls) == 1 else 206
            headers = ({'Content-Length': '1000'} if status == 200 else {'Content-Range': 'bytes 400-999/1000'})
            return self.Response(body, status, headers)
        with mock.patch('builtins.print'):
            self.assertEqual(native_prebuilt.download('https://example.test/a', opener=opener), asset)
        self.assertEqual(calls, [None, 'bytes=400-'])

    def test_a_server_that_ignores_the_range_starts_over(self):
        asset = b'y' * 1000
        calls = []
        def opener(request, timeout):
            calls.append(request.get_header('Range'))
            if len(calls) == 1:
                return self.Response(asset, 200, {'Content-Length': '1000'}, cut=500)
            return self.Response(asset, 200, {'Content-Length': '1000'})
        with mock.patch('builtins.print'):
            self.assertEqual(native_prebuilt.download('https://example.test/a', opener=opener), asset)

    def test_gives_up_after_the_attempts(self):
        def opener(request, timeout):
            raise ConnectionResetError('reset')
        with mock.patch('builtins.print'), self.assertRaises(ConnectionResetError):
            native_prebuilt.download('https://example.test/a', opener=opener, attempts=2)
