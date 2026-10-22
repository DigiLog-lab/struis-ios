"""Integration check of artifacts.py against the real Actions artifact service.

Run by agent-tests.yml (not by unittest discovery). Uploads a small and a
multi-block artifact, reads them back through the REST API, checks that the
provenance check rejects an artifact that main's agent.yml did not write, and
deletes them when the token may.
"""
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import artifacts  # noqa: E402


def main():
    client = artifacts.ArtifactClient()
    run = f'{os.environ["GITHUB_RUN_ID"]}-{os.environ.get("GITHUB_RUN_ATTEMPT", "1")}'
    prefix = f'agent-ckpt-0-roundtrip-{run}-'
    large = os.urandom(artifacts.BLOCK + 3 * 1024 * 1024)
    cases = {'small': {'manifest.json': b'{"ok": true}', 'changes.patch': b''},
             'large': {'commits.bundle': large, 'manifest.json': b'{}'}}
    uploaded = []
    for label, files in cases.items():
        reference = client.upload(prefix + label, files, 1)
        uploaded.append(reference)
        print(f'uploaded {label}: id={reference["id"]} size={reference["size"]}', flush=True)
        back = client.download(reference['id'], prefix, verify=False)
        assert back == files, f'{label}: downloaded bytes differ'
        metadata = client.metadata(reference['id'])
        assert not client.trusted(metadata, prefix), 'a pull_request/branch run must not count as main agent.yml'
    listed = {item['id'] for item in client.list(prefix, max_pages=3)}
    assert {reference['id'] for reference in uploaded} <= listed, 'uploaded artifacts are not listed'
    if os.environ.get('ARTIFACT_DELETE') == 'true':
        for reference in uploaded:
            client.delete(reference['id'])
        print('deleted the round-trip artifacts', flush=True)
    print('artifact round trip: OK', flush=True)


if __name__ == '__main__':
    main()
