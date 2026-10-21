import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
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

    def test_mismatched_hash_or_foreign_entry_is_rejected(self):
        name = native_prebuilt.asset_name(native_prebuilt.key(self.root))
        good = archive({'NativeRuntime/Vendor/A': b'a'})
        with self.assertRaises(SystemExit):
            native_prebuilt.apply(self.root, self.fetcher({name: good, name + '.sha256': b'0' * 64}))
        foreign = archive({'strius/Injected.swift': b'x'})
        with self.assertRaises(SystemExit):
            native_prebuilt.apply(self.root, self.fetcher({name: foreign, name + '.sha256': hashlib.sha256(foreign).hexdigest().encode()}))
        self.assertFalse((self.root / 'strius').exists())
        self.assertFalse((self.root / native_prebuilt.MARKER).exists())


class TestFileSelectionTests(unittest.TestCase):
    def test_a_changed_file_selects_every_test_class_it_declares(self):
        tests = ui_test_plan.discover()
        plan = {'pr': [], 'paths': {}}
        selected = ui_test_plan.select(tests, plan, 'pr', ['striusUITests/WorkbookE2EFixesUITests.swift'])
        self.assertEqual({test.split('/')[0] for test in selected},
                         {'WorkbookE2EFixesUITests', 'WorkbookLongConversationUITests', 'WorkbookOnboardingUITests'})
        support = ui_test_plan.select(tests, plan, 'pr', ['striusUITests/UITestDiagnosticsObserver.swift'])
        self.assertEqual(support, tests)


if __name__ == '__main__':
    unittest.main()
