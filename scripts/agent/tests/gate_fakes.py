import copy
import json
from pathlib import Path

from agentlib import PreconditionFailed
import artifacts as artifact_store


class MemoryArtifacts:
    """In-memory stand-in for artifacts.ArtifactClient (the Actions artifact service)."""

    def __init__(self):
        self.items, self.deleted = {}, []
        self.next_id = 1
        self.fail_upload = False

    def upload(self, name, files, retention_days):
        if self.fail_upload:
            raise RuntimeError('Connection lost during upload')
        identifier, self.next_id = self.next_id, self.next_id + 1
        self.items[identifier] = {'name': name, 'files': copy.deepcopy(files), 'retention': retention_days,
                                  'created_at': '2000-01-01T00:00:00Z'}
        return {'id': identifier, 'name': name, 'runId': 0, 'size': sum(len(data) for data in files.values())}

    def download(self, artifact_id, expected_prefix, verify=True):
        item = self.items.get(int(artifact_id))
        if item is None:
            raise artifact_store.ArtifactExpired(f'Artifact {artifact_id} is gone')
        if not item['name'].startswith(expected_prefix):
            raise artifact_store.ArtifactError('not a checkpoint of this Issue')
        return copy.deepcopy(item['files'])

    def list(self, prefix, max_pages=10):
        return [{'id': identifier, 'name': item['name'], 'created_at': item['created_at']}
                for identifier, item in self.items.items() if item['name'].startswith(prefix)]

    def delete(self, artifact_id):
        self.items.pop(int(artifact_id), None)
        self.deleted.append(int(artifact_id))

    def all_bytes(self):
        return b''.join(data for item in self.items.values() for data in item['files'].values())


class MemoryStore:
    def __init__(self):
        self.data, self.versions = {}, {}
        self.artifacts = MemoryArtifacts()

    @property
    def fail_upload(self):
        return self.artifacts.fail_upload

    @fail_upload.setter
    def fail_upload(self, value):
        self.artifacts.fail_upload = value

    def get(self, key):
        return self.data.get(key)

    def get_json(self, key):
        data = self.get(key)
        return json.loads(data) if data is not None else None

    def get_json_with_etag(self, key):
        return self.get_json(key), str(self.versions[key]) if key in self.versions else None

    def put_json(self, key, value, if_match=None, if_none_match=False):
        if if_match is not None and str(self.versions.get(key)) != if_match:
            raise PreconditionFailed('CAS conflict')
        if if_none_match and key in self.data:
            raise PreconditionFailed('Already exists')
        self.data[key] = json.dumps(value, ensure_ascii=False, indent=2).encode()
        self.versions[key] = self.versions.get(key, 0) + 1

    def update_json(self, key, change, default=None):
        updated = change(self.get_json(key) or copy.deepcopy(default))
        self.put_json(key, updated)
        return updated

    def upload_file(self, key, path):
        self.data[key] = Path(path).read_bytes()

    def list(self, prefix):
        return [{'key': key} for key in self.data if key.startswith(prefix)]


class FakeStatuses:
    """Commit statuses kept by SHA, newest first, as the GitHub API lists them."""

    def __init__(self):
        self.by_sha = {}

    def post(self, sha, body, login='github-actions[bot]'):
        self.by_sha.setdefault(sha, []).insert(0, dict(body, creator={'login': login}))

    def list(self, sha):
        return copy.deepcopy(self.by_sha.get(sha, []))
