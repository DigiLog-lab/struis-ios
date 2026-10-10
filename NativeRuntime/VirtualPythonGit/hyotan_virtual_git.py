# SPDX-License-Identifier: Apache-2.0
"""Test-only actual CPython Git history entry; canonical native runner unchanged."""
import sys

def git_main(args):
    from hyotan_history import main
    try:
        return main(args)
    except SystemExit as error:
        return error.code or 0
    except KeyboardInterrupt:
        print('KeyboardInterrupt', file=sys.stderr)
        return 130
    except Exception as error:
        print(f'git: {error}', file=sys.stderr)
        return 1
