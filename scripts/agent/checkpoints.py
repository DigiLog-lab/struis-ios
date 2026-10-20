"""Immutable, complete workspace/session checkpoints with a conditional pointer.

Only workspace.json is mutable. A failed upload or a concurrent writer never
publishes a partial save. The Worker deletion API cannot address other objects.
"""
import contextlib
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import secrets
import subprocess
import tarfile
import time

from agentlib import PreconditionFailed, agent_home, iso, session_key

FILES = ('work-items.json', 'local-verification.json', 'request-snapshot.json', 'run.json', 'session-id.json')


def workspace():
    return Path(os.environ.get('GITHUB_WORKSPACE', os.getcwd()))


def git(*args):
    return subprocess.check_output(['git', *args], cwd=workspace())


def digest(data):
    return hashlib.sha256(data).hexdigest()


@contextlib.contextmanager
def lock():
    with (agent_home() / 'checkpoint.lock').open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def tar_bytes(entries):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
        for name, data, mode in entries:
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(data), mode
            archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def working_copy():
    """Capture bytes, rather than asking tar to reread changing files later."""
    head = git('rev-parse', 'HEAD').decode().strip()
    patch = git('diff', '--binary', 'HEAD')
    entries = []
    for name in git('ls-files', '--others', '--exclude-standard', '-z').split(b'\0'):
        if not name:
            continue
        relative = os.fsdecode(name)
        path = workspace() / relative
        # Untracked links are not followed into a credential directory.
        if path.is_symlink():
            raise RuntimeError(f'Cannot checkpoint an untracked symlink: {relative}')
        entries.append((relative, path.read_bytes(), path.stat().st_mode & 0o777))
    signature = digest(json.dumps([head, digest(patch), [
        [name, mode, digest(data)] for name, data, mode in entries]], ensure_ascii=False).encode())
    return head, patch, entries, signature


def session_archive():
    projects = Path.home() / '.claude' / 'projects'
    entries = []
    if projects.exists():
        for path in sorted(projects.rglob('*')):
            if path.is_symlink() or not path.is_file():
                continue
            try:
                data = path.read_bytes()
            except FileNotFoundError:
                continue
            if path.suffix == '.jsonl':
                # Claude may currently be appending its final line.
                data = data[:data.rfind(b'\n') + 1]
            entries.append((str(Path('projects') / path.relative_to(projects)), data, 0o600))
    return tar_bytes(entries)


def save(store, number, run, periodic=False):
    home = agent_home()
    key = session_key(number, 'workspace.json')
    with lock():
        old, etag = store.get_json_with_etag(key)
        if old and old.get('closed'):
            return None
        head, patch, entries, signature = working_copy()
        remote = git('ls-remote', '--heads', 'origin', run['branch']).decode().split('\t')[0].strip()
        unpublished = head != remote
        save_id = (f'{os.environ.get("GITHUB_RUN_ID", "local")}-'
                   f'{os.environ.get("GITHUB_RUN_ATTEMPT", "1")}-{time.time_ns()}-{secrets.token_hex(4)}')
        prefix = session_key(number, f'checkpoints/{save_id}')
        components = {'changes.patch': patch, 'untracked.tar.gz': tar_bytes(entries),
                      'claude-projects.tar.gz': session_archive()}
        for name in FILES:
            path = home / name
            if path.exists():
                components[name] = path.read_bytes()
        if unpublished:
            bundle = home / f'{save_id}.bundle'
            subprocess.run(['git', 'bundle', 'create', str(bundle), 'HEAD'], cwd=workspace(), check=True,
                           stdout=subprocess.DEVNULL)
            components['commits.bundle'] = bundle.read_bytes()
            bundle.unlink()
        # Edits made during capture invalidate this save; leave the old pointer.
        if working_copy()[3] != signature:
            if periodic:
                print('Checkpoint deferred: workspace changed during capture', flush=True)
                return None
            raise RuntimeError('Workspace changed while saving its final checkpoint')
        record = {'schema': 2, 'saveId': save_id, 'prefix': prefix, 'createdAt': iso(),
                  'head': head, 'remoteHead': remote, 'branch': run['branch'], 'bundle': unpublished,
                  'components': {name: digest(data) for name, data in components.items()}}
        if 'session-id.json' in components:
            record['sessionId'] = json.loads(components['session-id.json'])['id']
        # Large session archives/bundles use the existing multipart implementation.
        for name, data in components.items():
            temporary = home / f'checkpoint-{save_id}-{name}'
            temporary.write_bytes(data)
            try:
                store.upload_file(f'{prefix}/{name}', temporary)
            finally:
                temporary.unlink(missing_ok=True)
        store.put_json(f'{prefix}/manifest.json', record)
        if old and old.get('schema') == 2 and old.get('saveId') and not old.get('closed'):
            record['previous'] = {k: v for k, v in old.items() if k != 'previous'}
        try:
            store.put_json(key, record, if_match=etag, if_none_match=not etag)
        except PreconditionFailed:
            print('Checkpoint pointer changed concurrently; retaining the newer pointer', flush=True)
            return None
        # Never delete an in-flight save from a different runner: only objects
        # older than the previous committed save can be garbage collected.
        previous = record.get('previous')
        if previous:
            try:
                store.prune_checkpoints(number, [save_id, previous['saveId']], previous['createdAt'])
            except Exception as error:
                print(f'Checkpoint pruning deferred: {type(error).__name__}', flush=True)
        return record


def load_components(store, record):
    result = {}
    for name, expected in record['components'].items():
        if name not in (*FILES, 'changes.patch', 'untracked.tar.gz', 'claude-projects.tar.gz', 'commits.bundle'):
            raise RuntimeError('Unknown checkpoint component')
        data = store.get(f'{record["prefix"]}/{name}')
        if data is None or digest(data) != expected:
            raise RuntimeError(f'Incomplete checkpoint component: {name}')
        result[name] = data
    return result


def restore(store, number, branch, restore_session=False):
    record = store.get_json(session_key(number, 'workspace.json')) or {}
    if record.get('schema') != 2 or record.get('closed') or not record.get('prefix'):
        return False
    if record['branch'] != branch:
        raise RuntimeError('Checkpoint branch differs; preserving it without changes')
    # Verify every byte before modifying the checkout.
    components = load_components(store, record)
    remote = git('ls-remote', '--heads', 'origin', branch).decode().split('\t')[0].strip()
    if remote != record['remoteHead']:
        raise RuntimeError('Remote changed after checkpoint; preserving the saved workspace')
    if record['bundle']:
        bundle = agent_home() / 'restore.bundle'
        bundle.write_bytes(components['commits.bundle'])
        subprocess.run(['git', 'fetch', str(bundle), 'HEAD'], cwd=workspace(), check=True,
                       stdout=subprocess.DEVNULL)
        subprocess.run(['git', 'checkout', '-B', branch, record['head']], cwd=workspace(), check=True)
        bundle.unlink()
    if git('rev-parse', 'HEAD').decode().strip() != record['head']:
        raise RuntimeError('Checkpoint HEAD differs')
    if components['changes.patch']:
        subprocess.run(['git', 'apply', '--index', '--binary', '-'], input=components['changes.patch'],
                       cwd=workspace(), check=True)
    with tarfile.open(fileobj=io.BytesIO(components['untracked.tar.gz']), mode='r:gz') as archive:
        archive.extractall(workspace(), filter='data')
    for name in FILES:
        if name in components:
            (agent_home() / ('checkpoint-run.json' if name == 'run.json' else name)).write_bytes(components[name])
    if restore_session:
        claude = Path.home() / '.claude'
        claude.mkdir(exist_ok=True)
        with tarfile.open(fileobj=io.BytesIO(components['claude-projects.tar.gz']), mode='r:gz') as archive:
            archive.extractall(claude, filter='data')
    return True


def clear(store, number, reason):
    """Tombstone first so a concurrent final save cannot resurrect a pointer."""
    store.update_json(session_key(number, 'workspace.json'),
                      lambda old: {'schema': 2, 'closed': True, 'reason': reason, 'at': iso()}, default={})
    store.prune_checkpoints(number, [], iso())
