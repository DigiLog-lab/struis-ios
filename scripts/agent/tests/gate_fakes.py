import copy
import json
from pathlib import Path
import re

from agentlib import PreconditionFailed, StoreError
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


# Same rule as the store Worker (cloudflare/agent/src/index.js KEY_PREFIXES): any other key is 403.
STORE_PREFIXES = ('sessions/', 'prototypes/', 'media/', 'usage/')


def checked(key):
    if not key.startswith(STORE_PREFIXES):
        raise StoreError(f'HTTP 403 Key outside the agent namespaces: {key}')
    return key


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
        return self.data.get(checked(key))

    def get_json(self, key):
        data = self.get(key)
        return json.loads(data) if data is not None else None

    def get_json_with_etag(self, key):
        return self.get_json(key), str(self.versions[key]) if key in self.versions else None

    def put_json(self, key, value, if_match=None, if_none_match=False):
        checked(key)
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
        self.data[checked(key)] = Path(path).read_bytes()

    def list(self, prefix):
        checked(prefix)
        return [{'key': key} for key in self.data if key.startswith(prefix)]


class FakeStatuses:
    """Commit statuses kept by SHA, newest first, as the GitHub API lists them."""

    def __init__(self):
        self.by_sha = {}

    def post(self, sha, body, login='github-actions[bot]'):
        self.by_sha.setdefault(sha, []).insert(0, dict(body, creator={'login': login}))

    def list(self, sha):
        return copy.deepcopy(self.by_sha.get(sha, []))


WORKFLOWS = Path(__file__).resolve().parents[3] / '.github' / 'workflows'


def job_permissions(workflow, job):
    """The `permissions:` of one job in a workflow file (no YAML dependency)."""
    result, inside, block = {}, False, False
    for line in (WORKFLOWS / workflow).read_text().splitlines():
        if re.match(r'^  [A-Za-z0-9_-]+:\s*$', line):
            inside, block = line.strip() == f'{job}:', False
            continue
        if inside and re.match(r'^    permissions:\s*$', line):
            block = True
            continue
        if inside and block:
            match = re.match(r'^      ([a-z-]+): (read|write|none)\s*(#.*)?$', line)
            if match:
                result[match[1]] = match[2]
            elif not line.strip().startswith('#'):
                block = False
    return result


def required_permission(method, path):
    """The GITHUB_TOKEN permission a GitHub REST call made by the controller needs."""
    if method == 'comment':
        return 'issues'
    if path == '/graphql' or (method == 'PATCH' and '/pulls/' in path):
        return 'pull-requests'
    if method == 'POST' and '/statuses/' in path:
        return 'statuses'
    if method == 'POST' and re.search(r'/actions/workflows/[^/]+/dispatches$', path):
        return 'actions'
    if method == 'POST' and re.fullmatch(r'/repos/[^/]+/[^/]+/dispatches', path):
        return 'contents'
    if method in ('POST', 'PATCH', 'PUT', 'DELETE'):
        raise AssertionError(f'Unknown write {method} {path}')
    return None
