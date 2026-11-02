"""An in-memory agent store for tests (keys checked like the Worker checks them)."""
import copy
import json
from pathlib import Path
import re

from agentlib import PreconditionFailed

PREFIXES = ('sessions/', 'prototypes/', 'media/', 'usage/')


def checked(key):
    if not key.startswith(PREFIXES) or '..' in key or re.search(r'[^A-Za-z0-9._/-]', key):
        raise ValueError(f'invalid store key {key}')
    return key


class MemoryStore:
    def __init__(self):
        self.data, self.versions = {}, {}

    def get(self, key):
        return self.data.get(checked(key))

    def get_json(self, key):
        data = self.get(key)
        return json.loads(data) if data is not None else None

    def get_json_with_etag(self, key):
        return self.get_json(key), str(self.versions[key]) if key in self.versions else None

    def put(self, key, data, content_type='application/octet-stream'):
        self.data[checked(key)] = data
        self.versions[key] = self.versions.get(key, 0) + 1
        return {'key': key}

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

    def upload_file(self, key, path, content_type='application/octet-stream'):
        self.data[checked(key)] = Path(path).read_bytes()

    def list(self, prefix):
        checked(prefix)
        return [{'key': key} for key in self.data if key.startswith(prefix)]
