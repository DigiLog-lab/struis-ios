"""Shared helpers for the Issue agent workflows.

The agent store is the Cloudflare Worker in cloudflare/agent. CI authenticates
with the job's GitHub OIDC token, so the workflows need `id-token: write` and
no storage credential is kept in GitHub.
"""
import datetime
import json
import os
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request

STORE_URL = os.environ.get('AGENT_STORE_URL', 'https://agent-struis.digiloglab.com').rstrip('/')
OIDC_AUDIENCE = os.environ.get('AGENT_OIDC_AUDIENCE', STORE_URL)
API_URL = os.environ.get('GITHUB_API_URL', 'https://api.github.com').rstrip('/')
ALLOWED_ASSOCIATIONS = {'OWNER', 'MEMBER', 'COLLABORATOR'}
REPLY_MARKER = '<!-- struis-agent:reply -->'
PROTOTYPE_MARKER = '<!-- struis-agent:prototype -->'
SINGLE_PUT_LIMIT = 64 * 1024 * 1024
PART_SIZE = 64 * 1024 * 1024
JST = datetime.timezone(datetime.timedelta(hours=9))
PROTOTYPE_STATES = ('draft', 'building', 'ready', 'testing', 'selected', 'archived', 'failed')


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def iso(moment=None):
    return (moment or utc_now()).isoformat(timespec='seconds').replace('+00:00', 'Z')


def agent_home():
    home = Path(os.environ.get('AGENT_HOME') or Path(os.environ.get('RUNNER_TEMP', '/tmp')) / 'agent')
    home.mkdir(parents=True, exist_ok=True)
    return home


def write_output(name, value):
    path = os.environ.get('GITHUB_OUTPUT')
    value = '' if value is None else str(value)
    if not path:
        print(f'{name}={value}')
        return
    with open(path, 'a', encoding='utf-8') as stream:
        if '\n' in value:
            delimiter = f'EOF_{os.urandom(8).hex()}'
            stream.write(f'{name}<<{delimiter}\n{value}\n{delimiter}\n')
        else:
            stream.write(f'{name}={value}\n')


def append_summary(markdown):
    path = os.environ.get('GITHUB_STEP_SUMMARY')
    if path:
        with open(path, 'a', encoding='utf-8') as stream:
            stream.write(markdown.rstrip() + '\n\n')
    else:
        print(markdown)


def run_url():
    server = os.environ.get('GITHUB_SERVER_URL', 'https://github.com')
    return f"{server}/{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}"


class StoreError(RuntimeError):
    pass


class Store:
    """Client for the agent store Worker."""

    def __init__(self):
        self._token = None
        self._token_time = 0.0

    def _oidc_token(self, refresh=False):
        if self._token and not refresh and time.time() - self._token_time < 240:
            return self._token
        request_url = os.environ.get('ACTIONS_ID_TOKEN_REQUEST_URL')
        request_token = os.environ.get('ACTIONS_ID_TOKEN_REQUEST_TOKEN')
        if not request_url or not request_token:
            raise StoreError('OIDC is unavailable; the job needs permissions: id-token: write')
        separator = '&' if '?' in request_url else '?'
        url = f'{request_url}{separator}audience={urllib.parse.quote(OIDC_AUDIENCE, safe="")}'
        request = urllib.request.Request(url, headers={'Authorization': f'Bearer {request_token}'})
        with urllib.request.urlopen(request, timeout=30) as response:
            self._token = json.load(response)['value']
        self._token_time = time.time()
        return self._token

    def request(self, method, path, data=None, headers=None, allow_missing=False):
        last_error = None
        for attempt in range(5):
            request = urllib.request.Request(
                STORE_URL + path, data=data, method=method,
                headers={'Authorization': f'Bearer {self._oidc_token(refresh=attempt > 0 and last_error == 401)}',
                         'User-Agent': 'struis-agent-ci', **(headers or {})})
            try:
                with urllib.request.urlopen(request, timeout=600) as response:
                    return response.read()
            except urllib.error.HTTPError as error:
                body = error.read()[:300].decode(errors='replace').strip()
                if error.code == 404 and allow_missing:
                    return None
                last_error = error.code
                if error.code == 401 and attempt == 0:
                    continue
                if error.code >= 500 and attempt < 4:
                    time.sleep(2 ** attempt)
                    continue
                raise StoreError(f'{method} {path} failed: HTTP {error.code} {body}') from None
            except (urllib.error.URLError, TimeoutError) as error:
                last_error = str(error)
                if attempt < 4:
                    time.sleep(2 ** attempt)
                    continue
                raise StoreError(f'{method} {path} failed: {error}') from None
        raise StoreError(f'{method} {path} failed: {last_error}')

    @staticmethod
    def _key_path(key):
        return urllib.parse.quote(key, safe='/')

    def get(self, key):
        return self.request('GET', f'/v1/objects/{self._key_path(key)}', allow_missing=True)

    def get_json(self, key):
        data = self.get(key)
        return None if data is None else json.loads(data)

    def put(self, key, data, content_type='application/octet-stream'):
        return json.loads(self.request('PUT', f'/v1/objects/{self._key_path(key)}', data=data,
                                       headers={'Content-Type': content_type}))

    def put_json(self, key, value):
        return self.put(key, json.dumps(value, ensure_ascii=False, indent=2).encode(), 'application/json')

    def upload_file(self, key, path, content_type='application/octet-stream'):
        path = Path(path)
        size = path.stat().st_size
        if size <= SINGLE_PUT_LIMIT:
            return self.put(key, path.read_bytes(), content_type)
        query = urllib.parse.urlencode({'contentType': content_type})
        upload_id = json.loads(self.request('POST', f'/v1/multipart/{self._key_path(key)}?{query}'))['uploadId']
        parts = []
        try:
            with path.open('rb') as stream:
                number = 1
                while chunk := stream.read(PART_SIZE):
                    query = urllib.parse.urlencode({'uploadId': upload_id, 'part': number})
                    part = json.loads(self.request('PUT', f'/v1/multipart/{self._key_path(key)}?{query}', data=chunk))
                    parts.append({'partNumber': part['partNumber'], 'etag': part['etag']})
                    number += 1
            query = urllib.parse.urlencode({'uploadId': upload_id, 'complete': '1'})
            return json.loads(self.request('POST', f'/v1/multipart/{self._key_path(key)}?{query}',
                                           data=json.dumps({'parts': parts}).encode(),
                                           headers={'Content-Type': 'application/json'}))
        except Exception:
            query = urllib.parse.urlencode({'uploadId': upload_id})
            try:
                self.request('DELETE', f'/v1/multipart/{self._key_path(key)}?{query}')
            except StoreError:
                pass
            raise

    def list(self, prefix):
        query = urllib.parse.urlencode({'prefix': prefix})
        return json.loads(self.request('GET', f'/v1/list?{query}'))['objects']

    def sign_install(self, issue, variant, build, ttl_seconds=None):
        body = {'issue': issue, 'variant': variant, 'build': build}
        if ttl_seconds:
            body['ttlSeconds'] = ttl_seconds
        return json.loads(self.request('POST', '/v1/sign', data=json.dumps(body).encode(),
                                       headers={'Content-Type': 'application/json'}))


class GitHub:
    """Minimal REST client authenticated with the workflow token."""

    def __init__(self, token=None, repository=None):
        self.token = token or os.environ.get('GH_TOKEN') or os.environ['GITHUB_TOKEN']
        self.repository = repository or os.environ['GITHUB_REPOSITORY']

    def request(self, method, path, body=None, accept='application/vnd.github+json'):
        url = path if path.startswith('https://') else f'{API_URL}{path}'
        data = None if body is None else json.dumps(body).encode()
        for attempt in range(4):
            request = urllib.request.Request(url, data=data, method=method, headers={
                'Authorization': f'Bearer {self.token}', 'Accept': accept,
                'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'struis-agent-ci',
                **({'Content-Type': 'application/json'} if data is not None else {})})
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    payload = response.read()
                    link = response.headers.get('Link', '')
                    return (json.loads(payload) if payload else None), link
            except urllib.error.HTTPError as error:
                if error.code >= 500 and attempt < 3:
                    time.sleep(2 ** attempt)
                    continue
                raise RuntimeError(f'GitHub {method} {path}: HTTP {error.code} {error.read()[:300]!r}') from None
            except urllib.error.URLError:
                if attempt < 3:
                    time.sleep(2 ** attempt)
                    continue
                raise

    def get(self, path):
        return self.request('GET', path)[0]

    def paginate(self, path):
        items = []
        url = path + ('&' if '?' in path else '?') + 'per_page=100'
        while url:
            page, link = self.request('GET', url)
            items.extend(page)
            match = re.search(r'<([^>]+)>;\s*rel="next"', link or '')
            url = match.group(1) if match else None
        return items

    def issue(self, number):
        return self.get(f'/repos/{self.repository}/issues/{number}')

    def comments(self, number):
        return self.paginate(f'/repos/{self.repository}/issues/{number}/comments')

    def comment(self, number, body):
        return self.request('POST', f'/repos/{self.repository}/issues/{number}/comments', {'body': body})[0]


def is_bot(user):
    return (user or {}).get('type') == 'Bot' or (user or {}).get('login', '').endswith('[bot]')


def allowed_author(login, association):
    explicit = [name.strip().lower() for name in os.environ.get('AGENT_ALLOWED_USERS', '').split(',') if name.strip()]
    if explicit:
        return (login or '').lower() in explicit
    return association in ALLOWED_ASSOCIATIONS


def has_label(issue, label):
    return any((entry.get('name') if isinstance(entry, dict) else entry) == label for entry in issue.get('labels', []))


def pending_comments(comments, state):
    """Comments from allowed people that the session has not processed yet."""
    last = int((state or {}).get('lastCommentId') or 0)
    pending = []
    for comment in comments:
        if comment['id'] <= last or is_bot(comment.get('user')):
            continue
        body = comment.get('body') or ''
        if REPLY_MARKER in body or PROTOTYPE_MARKER in body:
            continue
        if allowed_author(comment['user']['login'], comment.get('author_association')):
            pending.append(comment)
    return pending


def issue_is_pending(issue, state):
    return not (state or {}).get('issueBodyProcessed') and allowed_author(
        issue['user']['login'], issue.get('author_association'))


def session_key(issue, name):
    return f'sessions/{issue}/{name}'
