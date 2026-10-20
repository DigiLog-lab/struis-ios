import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import Mock

from prefetch_native import prefetch


class PrefetchNativeTests(unittest.TestCase):
    def fixture(self, root):
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:gz") as tar:
            entry = tarfile.TarInfo("Python.xcframework/Info.plist")
            entry.size = 4
            tar.addfile(entry, io.BytesIO(b"test"))
        bodies = {"python-support": archive.getvalue(), "shared.whl": b"shared",
                  "device.whl": b"device", "simulator.whl": b"simulator"}
        digest = lambda name: hashlib.sha256(bodies[name]).hexdigest()
        (root / "dependencies.lock.json").write_text(json.dumps([
            {"name": "Python", "url": "python-support", "sha256": digest("python-support")}]))
        (root / "python-packages.lock.json").write_text(json.dumps([
            {"filename": name, "platform": platform, "sha256": digest(name)}
            for name, platform in [("shared.whl", "all"), ("device.whl", "iphoneos"),
                                   ("simulator.whl", "iphonesimulator")]]))
        return bodies

    def test_both_platforms_use_verified_inputs_and_reuse_existing_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bodies = self.fixture(root)
            download = Mock(side_effect=lambda url: bodies[url])
            prefetch(root, "both", lambda package: package["filename"], download)
            self.assertEqual((root / "Vendor/Python.xcframework/Info.plist").read_bytes(), b"test")
            for name in ["shared.whl", "device.whl", "simulator.whl"]:
                self.assertEqual((root / "PackageCache" / name).read_bytes(), bodies[name])
            self.assertEqual(download.call_count, 4)
            download.reset_mock()
            prefetch(root, "both", lambda package: package["filename"], download)
            download.assert_not_called()

    def test_simulator_does_not_download_device_package(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bodies = self.fixture(root)
            prefetch(root, "simulator", lambda package: package["filename"], lambda url: bodies[url])
            self.assertFalse((root / "PackageCache/device.whl").exists())
            self.assertTrue((root / "PackageCache/simulator.whl").exists())

    def test_invalid_download_is_not_written_or_unpacked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            with self.assertRaisesRegex(ValueError, "Hash mismatch"):
                prefetch(root, "both", lambda package: package["filename"], lambda url: b"truncated")
            self.assertFalse((root / "Vendor/Python.xcframework").exists())

    def test_corrupted_cached_wheel_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bodies = self.fixture(root)
            cache = root / "PackageCache"
            cache.mkdir()
            (cache / "shared.whl").write_bytes(b"wrong")
            with self.assertRaisesRegex(ValueError, "Hash mismatch: shared.whl"):
                prefetch(root, "both", lambda package: package["filename"], lambda url: bodies[url])
            self.assertFalse((cache / "device.whl").exists())

    def test_interrupted_package_does_not_leave_a_cache_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bodies = self.fixture(root)
            (root / "Vendor/Python.xcframework").mkdir(parents=True)
            def download(url):
                raise OSError("connection lost")
            with self.assertRaises(OSError):
                prefetch(root, "device", lambda package: package["filename"], download)
            self.assertEqual(list((root / "PackageCache").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
