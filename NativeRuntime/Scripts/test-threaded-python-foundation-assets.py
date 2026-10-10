#!/usr/bin/env python3
"""Offline rejection checks for the fixed threaded test asset validator."""
import contextlib
import importlib.util
import io
import json
import shutil
import tempfile
from pathlib import Path

SOURCE = Path(__file__).with_name('check-threaded-python-foundation-assets.py')
spec = importlib.util.spec_from_file_location('threaded_assets', SOURCE)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
root = checker.ROOT / 'ThreadedPythonFoundationTestAssets'
policy = json.loads((checker.ROOT / 'threaded-foundation-policy.json').read_text())
checker.validate(root, policy)
for case in ('corrupt', 'missing', 'symlink', 'ancestor-symlink', 'directory', 'manifest', 'inventory', 'policy'):
    with tempfile.TemporaryDirectory(prefix='threaded-assets-rejection-') as temporary:
        copy = Path(temporary) / 'assets'
        shutil.copytree(root, copy)
        candidate_policy = dict(policy)
        target = copy / {'manifest':'manifest.json', 'inventory':'inventory.json'}.get(case, 'worker.js')
        if case == 'policy': candidate_policy['manifest_sha256'] = '0' * 64
        elif case == 'missing': target.unlink()
        elif case == 'symlink': target.unlink(); target.symlink_to(root.resolve() / 'worker.js')
        elif case == 'directory': target.unlink(); target.mkdir()
        elif case == 'ancestor-symlink':
            shutil.rmtree(copy / 'native'); (copy / 'native').symlink_to(root.resolve() / 'native', target_is_directory=True)
        else: target.write_bytes(target.read_bytes() + b'corrupt')
        try:
            with contextlib.redirect_stdout(io.StringIO()): checker.validate(copy, candidate_policy)
        except (ValueError, FileNotFoundError, KeyError, OSError): pass
        else: raise RuntimeError('validator accepted ' + case)
        print('PASS rejected ' + case)
