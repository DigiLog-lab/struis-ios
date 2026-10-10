#!/usr/bin/env python3
"""Precompile bundled Python without changing assertions or docstrings."""
import argparse
import compileall
from pathlib import Path
import py_compile
import re
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    if sys.version_info[:2] != (3, 14):
        raise SystemExit('The embedded CPython 3.14 requires a Python 3.14 bytecode compiler')
    app = args.app.resolve()
    for relative in ['python/lib/python3.14', 'PythonModules', 'PythonPackages']:
        source = app / relative
        if not source.is_dir():
            raise SystemExit(f'Missing bundled Python directory: {source}')
        # CPython's own test data deliberately contains invalid Python and
        # encodings. Preserve it as source, but exclude only this stdlib tree.
        excluded = (re.compile(r'^' + re.escape(str(source / 'test')) + r'(?:/|$)')
                    if relative == 'python/lib/python3.14' else None)
        # Hash-based caches survive rsync and bundle relocation. Keep optimize=0:
        # assertions and documentation must behave as they do with source imports.
        if not compileall.compile_dir(
            source, quiet=1, optimize=0, force=True,
            invalidation_mode=py_compile.PycInvalidationMode.CHECKED_HASH,
            stripdir=str(app), prependdir='/', rx=excluded,
        ):
            raise SystemExit(f'Python bytecode compilation failed: {source}')
        count = sum(1 for _ in source.rglob('*.pyc'))
        print(f'Precompiled {relative}: {count} caches (CPython 3.14, optimize=0, checked hash)')


if __name__ == '__main__':
    main()
