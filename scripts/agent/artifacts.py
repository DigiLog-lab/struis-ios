"""GitHub Actions artifacts as the store for large checkpoint components.

Uploading uses the runner's artifact service (the same v4 protocol as
actions/upload-artifact), so it needs ACTIONS_RUNTIME_TOKEN and
ACTIONS_RESULTS_URL. Those are given only to JavaScript actions; the worker
exports them to a mode-0600 file with actions/github-script (see agent.yml).
Reading, listing and deleting use the REST API with the job's GITHUB_TOKEN
(actions: read to download, actions: write to delete).

Artifacts expire on their own after the retention period, so a checkpoint
that nothing deletes still disappears.
"""
import base64
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from agentlib import API_URL, GitHub, agent_home

SERVICE = 'twirp/github.actions.results.api.v1.ArtifactService'
RUNTIME_FILE = 'actions-runtime.json'
BLOCK = 32 * 1024 * 1024
TRUSTED_WORKFLOW = '.github/workflows/agent.yml'


class ArtifactError(RuntimeError):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # the caller follows it without credentials
        return None


def runtime():
    token, url = os.environ.get('ACTIONS_RUNTIME_TOKEN'), os.environ.get('ACTIONS_RESULTS_URL')
    if not (token and url):
        path = agent_home() / RUNTIME_FILE
        if path.exists():
            saved = json.loads(path.read_text())
            token, url = saved.get('token'), saved.get('resultsUrl')
    if not (token and url):
        raise ArtifactError('The artifact service is unavailable: ACTIONS_RUNTIME_TOKEN/ACTIONS_RESULTS_URL are missing')
    return token, url.rstrip('/') + '/'


def backend_ids(token):
    payload = token.split('.')[1]
    claims = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
    for scope in str(claims.get('scp', '')).split(' '):
        parts = scope.split(':')
        if parts[0] == 'Actions.Results' and len(parts) == 3:
            return parts[1], parts[2]
    raise ArtifactError('The runtime token has no Actions.Results scope')


def zip_bytes(files):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=(2000, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o600 << 16
            archive.writestr(info, files[name])
    return buffer.getvalue()


def unzip_bytes(data):
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        result = {}
        for info in archive.infolist():
            if info.is_dir():
                continue
            name = info.filename
            if name.startswith('/') or '..' in Path(name).parts:
                raise ArtifactError(f'Unsafe artifact entry: {name}')
            result[name] = archive.read(info)
        return result


class ArtifactClient:
    def __init__(self, gh=None):
        self._gh = gh

    @property
    def gh(self):
        if self._gh is None:
            self._gh = GitHub()
        return self._gh

    # ---------------------------------------------------------- upload ---
    def _twirp(self, method, body, token, base):
        request = urllib.request.Request(base + f'{SERVICE}/{method}', data=json.dumps(body).encode(), method='POST',
                                         headers={'Content-Type': 'application/json', 'Authorization': f'Bearer {token}',
                                                  'User-Agent': 'struis-agent-artifacts'})
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                result = json.loads(response.read() or b'{}')
        except urllib.error.HTTPError as error:
            raise ArtifactError(f'{method} failed: HTTP {error.code} {error.read()[:300]!r}') from None
        if not result.get('ok'):
            raise ArtifactError(f'{method} was not accepted')
        return result

    @staticmethod
    def _put(url, data, headers):
        request = urllib.request.Request(url, data=data, method='PUT', headers=headers)
        for attempt in range(4):
            try:
                with urllib.request.urlopen(request, timeout=600) as response:
                    response.read()
                    return
            except urllib.error.HTTPError as error:
                if error.code < 500 or attempt == 3:
                    raise ArtifactError(f'Blob upload failed: HTTP {error.code} {error.read()[:300]!r}') from None
            except urllib.error.URLError as error:
                if attempt == 3:
                    raise ArtifactError(f'Blob upload failed: {error}') from None

    def _upload_blob(self, url, data):
        if len(data) <= BLOCK:
            return self._put(url, data, {'x-ms-blob-type': 'BlockBlob', 'x-ms-blob-content-type': 'zip'})
        ids = []
        for index, start in enumerate(range(0, len(data), BLOCK)):
            block = base64.b64encode(f'{index:08d}'.encode()).decode()
            ids.append(block)
            self._put(f'{url}&comp=block&blockid={urllib.parse.quote(block, safe="")}', data[start:start + BLOCK], {})
        body = ('<?xml version="1.0" encoding="utf-8"?><BlockList>'
                + ''.join(f'<Latest>{block}</Latest>' for block in ids) + '</BlockList>').encode()
        self._put(f'{url}&comp=blocklist', body, {'Content-Type': 'application/xml', 'x-ms-blob-content-type': 'zip'})

    def upload(self, name, files, retention_days):
        """Upload {path: bytes} as one artifact of the current run; returns its reference."""
        token, base = runtime()
        run_backend, job_backend = backend_ids(token)
        expires = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=int(retention_days)))
        ids = {'workflow_run_backend_id': run_backend, 'workflow_job_run_backend_id': job_backend, 'name': name}
        created = self._twirp('CreateArtifact', dict(ids, version=4,
                              expires_at=expires.replace(microsecond=0).isoformat().replace('+00:00', 'Z')), token, base)
        data = zip_bytes(files)
        self._upload_blob(created['signed_upload_url'], data)
        finalized = self._twirp('FinalizeArtifact', dict(ids, size=str(len(data)),
                                hash='sha256:' + hashlib.sha256(data).hexdigest()), token, base)
        return {'id': int(finalized['artifact_id']), 'name': name, 'runId': int(os.environ.get('GITHUB_RUN_ID') or 0),
                'size': len(data)}

    # ------------------------------------------------------- read/list ---
    def metadata(self, artifact_id):
        return self.gh.get(f'/repos/{self.gh.repository}/actions/artifacts/{int(artifact_id)}')

    def trusted(self, metadata, expected_prefix):
        """An artifact written by main's agent.yml in this repository, never by a fork or a branch run."""
        run = metadata.get('workflow_run') or {}
        if not metadata.get('name', '').startswith(expected_prefix) or metadata.get('expired'):
            return False
        if run.get('head_repository_id') != run.get('repository_id') or run.get('head_branch') != 'main':
            return False
        detail = self.gh.get(f'/repos/{self.gh.repository}/actions/runs/{int(run["id"])}')
        path = (detail.get('path') or '').split('@')[0]
        return path == TRUSTED_WORKFLOW and detail.get('head_branch') == 'main'

    def download(self, artifact_id, expected_prefix, verify=True):
        metadata = self.metadata(artifact_id)
        if metadata.get('expired'):
            raise ArtifactExpired(f'Artifact {artifact_id} has expired')
        if verify and not self.trusted(metadata, expected_prefix):
            raise ArtifactError(f'Artifact {artifact_id} was not written by main\'s agent workflow')
        url = f'{API_URL}/repos/{self.gh.repository}/actions/artifacts/{int(artifact_id)}/zip'
        opener = urllib.request.build_opener(_NoRedirect)
        request = urllib.request.Request(url, headers={'Authorization': f'Bearer {self.gh.token}',
                                                       'Accept': 'application/vnd.github+json',
                                                       'X-GitHub-Api-Version': '2022-11-28',
                                                       'User-Agent': 'struis-agent-artifacts'})
        try:
            with opener.open(request, timeout=120) as response:
                data = response.read()
        except urllib.error.HTTPError as error:
            if error.code not in (301, 302, 303, 307, 308):
                if error.code == 410:
                    raise ArtifactExpired(f'Artifact {artifact_id} is gone') from None
                raise ArtifactError(f'Artifact download failed: HTTP {error.code}') from None
            location = error.headers['Location']
            with urllib.request.urlopen(urllib.request.Request(location, headers={'User-Agent': 'struis-agent-artifacts'}),
                                        timeout=600) as response:
                data = response.read()
        return unzip_bytes(data)

    def list(self, prefix, max_pages=10):
        found = []
        for page in range(1, max_pages + 1):
            listing = self.gh.get(f'/repos/{self.gh.repository}/actions/artifacts?per_page=100&page={page}')
            items = listing.get('artifacts', [])
            found.extend(item for item in items if item.get('name', '').startswith(prefix))
            if len(items) < 100:
                break
        return found

    def delete(self, artifact_id):
        try:
            self.gh.request('DELETE', f'/repos/{self.gh.repository}/actions/artifacts/{int(artifact_id)}')
        except RuntimeError as error:
            if 'HTTP 404' not in str(error):
                raise


class ArtifactExpired(ArtifactError):
    pass
