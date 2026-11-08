"""scripts/package_python_stamp.py (Issue #93): when the "Package Python" build phase may be skipped.

    python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v
"""
from __future__ import annotations

import contextlib
import io
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

ROOT: pathlib.Path = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import package_python_stamp as stamp  # noqa: E402


class StampTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = pathlib.Path(temp.name)
        self.src = self.base / "src"
        self.app = self.base / "strius.app"
        for relative in ("NativeRuntime/Vendor/Python.xcframework", "NativeRuntime/Scripts",
                         "NativeRuntime/PythonPackages/iphonesimulator/pkg", "scripts"):
            (self.src / relative).mkdir(parents=True)
        (self.src / "NativeRuntime/Vendor/Python.xcframework/Info.plist").write_text("plist")
        (self.src / "NativeRuntime/PythonPackages/iphonesimulator/pkg/__init__.py").write_text("")
        (self.src / "scripts/package_compound_dash_preparation.py").write_text("")
        for relative in ("Frameworks/x.framework", "python/lib", "PythonPackages", "PythonModules"):
            (self.app / relative).mkdir(parents=True)
        (self.app / "Frameworks/x.framework/x").write_text("binary")
        (self.app / "PythonModules/hyotan_runner.py").write_text("print(1)\n")
        self.script = self.base / "Script-phase.sh"
        self.script.write_text("echo phase\n")
        self.record = self.base / "intermediates/package-python.stamp"
        env = {"SRCROOT": str(self.src), "CODESIGNING_FOLDER_PATH": str(self.app), "PLATFORM_NAME": "iphonesimulator",
               "EXPANDED_CODE_SIGN_IDENTITY": "-", "PATH": ""}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)

    def check(self) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = stamp.main(["check", str(self.record), str(self.script)])
        return code, out.getvalue()

    def written(self) -> None:
        self.assertEqual(stamp.main(["write", str(self.record), str(self.script)]), 0)

    def test_runs_without_a_record_and_is_skipped_after_one(self) -> None:
        self.assertEqual(self.check()[0], 1)
        self.written()
        self.assertEqual(self.check(), (0, ""))

    def test_a_changed_input_says_what_changed(self) -> None:
        self.written()
        package = self.src / "NativeRuntime/PythonPackages/iphonesimulator/pkg/__init__.py"
        package.write_text("x = 1\n")
        code, said = self.check()
        self.assertEqual(code, 1)
        self.assertIn("pkg/__init__.py", said)

    def test_an_output_another_phase_rewrote_runs_it(self) -> None:
        self.written()
        (self.app / "Frameworks/x.framework/x").write_text("copied again by Embed Frameworks")
        self.assertEqual(self.check()[0], 1)

    def test_a_new_signing_identity_or_script_runs_it(self) -> None:
        self.written()
        with mock.patch.dict(os.environ, {"EXPANDED_CODE_SIGN_IDENTITY": "Apple Development"}):
            self.assertEqual(self.check()[0], 1)
        self.script.write_text("echo phase, changed\n")
        self.assertEqual(self.check()[0], 1)

    def test_python_modules_copied_again_by_resources_does_not_run_it(self) -> None:
        self.written()
        (self.app / "PythonModules/hyotan_runner.py").write_text("print(1)\n")
        (self.app / "PythonModules/__pycache__").mkdir()
        self.assertEqual(self.check()[0], 0)

    def test_an_extension_module_in_python_modules_runs_it(self) -> None:
        self.written()
        (self.app / "PythonModules/_speedups.so").write_text("")
        code, said = self.check()
        self.assertEqual(code, 1)
        self.assertIn("_speedups.so", said)


class SameScriptTests(unittest.TestCase):
    def test_the_project_and_its_generator_have_the_same_phase(self) -> None:
        """scripts/sync_native_runtime.rb rewrites the phase when the project is synchronized."""
        import re
        generator = (ROOT / "scripts/sync_native_runtime.rb").read_text()
        heredoc = generator.split("package.shell_script = <<~SH\n", 1)[1].split("\nSH\n", 1)[0] + "\n"
        project = (ROOT / "strius.xcodeproj/project.pbxproj").read_text()
        start = project.index("/* Package Python */ = {")
        quoted = re.compile(r'shellScript = "((?:[^"\\]|\\.)*)";').search(project, start)
        assert quoted is not None
        script = re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t"}.get(m[1], m[1]), quoted[1])
        self.assertEqual(script, heredoc)

    def test_the_signing_defaults_are_set_before_the_check(self) -> None:
        """Unsigned builds (CODE_SIGNING_ALLOWED=NO) leave the identity empty: check and write must see the same."""
        generator = (ROOT / "scripts/sync_native_runtime.rb").read_text()
        self.assertLess(generator.index('export EXPANDED_CODE_SIGN_IDENTITY_NAME="${'),
                        generator.index('"$stamp_tool" check'))


class SameCompilationTests(unittest.TestCase):
    def test_compile_modules_uses_the_settings_of_compile_python(self) -> None:
        theirs = (ROOT / "NativeRuntime/Scripts/compile-python.py").read_text()
        ours = (ROOT / "scripts/package_python_stamp.py").read_text()
        for setting in ("optimize=0", "force=True", "PycInvalidationMode.CHECKED_HASH", "(3, 14)"):
            self.assertIn(setting, theirs)
            self.assertIn(setting, ours)
        self.assertIn("stripdir=str(app), prependdir='/'", theirs)
        self.assertIn('stripdir=str(app), prependdir="/"', ours)
        self.assertIn("'PythonModules'", theirs)


if __name__ == "__main__":
    unittest.main()
