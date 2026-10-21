"""Temporary: download the PR Gate 156 test result bundle and crash logs (read-only)."""
import os
from pathlib import Path
import sys
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'agent'))
from appstoreconnect import from_environment  # noqa: E402

BUILD = 'b7da65de-f371-45a8-abdb-2fdad80aa90f'


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    client = from_environment(os.environ['APP_STORE_CONNECT_KEY_PATH'])
    for action in client.paginate(f'/v1/ciBuildRuns/{BUILD}/actions?limit=200'):
        for artifact in client.paginate(f'/v1/ciBuildActions/{action["id"]}/artifacts?limit=200'):
            f = artifact['attributes']
            name = f.get('fileName') or ''
            print(action['attributes'].get('actionType'), f.get('fileType'), name, f.get('fileSize'), flush=True)
            if f.get('fileType') == 'RESULT_BUNDLE' and ('test-without-building' in name or 'crash_log' in name):
                safe = ''.join(c if c.isalnum() or c in '.-' else '-' for c in name)
                with urllib.request.urlopen(f['downloadUrl'], timeout=900) as response, (out / safe).open('wb') as file:
                    while chunk := response.read(1 << 20):
                        file.write(chunk)
                print('downloaded', safe, flush=True)


if __name__ == '__main__':
    main()
