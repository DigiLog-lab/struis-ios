#!/usr/bin/env python3
"""Report Actions cache usage without restoring or creating a macOS cache."""
import json
import os
from pathlib import Path
import re
import urllib.request


def main():
    repository = os.environ['GITHUB_REPOSITORY']
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid GITHUB_REPOSITORY')
    request = urllib.request.Request(
        f'https://api.github.com/repos/{repository}/actions/cache/usage',
        headers={'Authorization': f'Bearer {os.environ["GITHUB_TOKEN"]}',
                 'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'})
    with urllib.request.urlopen(request, timeout=30) as response:
        usage = json.load(response)
    size, count = usage['active_caches_size_in_bytes'], usage['active_caches_count']
    if type(size) is not int or type(count) is not int or min(size, count) < 0:
        raise ValueError('Unexpected Actions cache usage response')
    print(json.dumps({'repository': repository, 'bytes': size, 'count': count}))
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with Path(summary).open('a') as stream:
            stream.write(f'### Actions cache使用量\n\n- 合計: {size / 1024 ** 3:.2f} GiB ({size:,} bytes)\n- 件数: {count}\n')


if __name__ == '__main__':
    main()
