import copy
import json
from pathlib import Path

from agentlib import PreconditionFailed


class MemoryStore:
    def __init__(self):
        self.data, self.versions, self.pruned = {}, {}, []
        self.fail_upload = False

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
        if self.fail_upload:
            raise RuntimeError('Connection lost during upload')
        self.data[key] = Path(path).read_bytes()

    def prune_checkpoints(self, issue, keep, before):
        self.pruned.append((issue, keep, before))
        return {'deleted': 0}

    def list(self, prefix):
        return [{'key': key} for key in self.data if key.startswith(prefix)]
