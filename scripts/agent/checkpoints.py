"""Immutable, complete workspace/session checkpoints with a conditional pointer.

The components of one save are one GitHub Actions artifact of the worker run
(see artifacts.py); only the small pointer sessions/{Issue}/workspace.json is
kept in the store and updated with CAS. A failed upload or a concurrent writer
never publishes a partial save. Artifacts that the pointer no longer names are
deleted by Linux jobs (prune); the retention period removes anything missed.
"""
import contextlib
import datetime
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

from agentlib import PreconditionFailed, agent_home, gate_config, iso, session_key
import artifacts as artifact_store

SCHEMA = 3
FILES = ('work-items.json', 'local-verification.json', 'request-snapshot.json', 'run.json', 'session-id.json')
COMPONENTS = (*FILES, 'changes.patch', 'untracked.tar.gz', 'claude-projects.tar.gz', 'commits.bundle')


def artifact_prefix(number):
    return f'agent-ckpt-{int(number)}-'


def client(store, given=None):
    """Tests attach an in-memory artifact client to their store."""
    return given or getattr(store, 'artifacts', None) or artifact_store.ArtifactClient()


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


def save(store, number, run, periodic=False, artifacts=None):
    home = agent_home()
    key = session_key(number, 'workspace.json')
    blobs = client(store, artifacts)
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
        record = {'schema': SCHEMA, 'saveId': save_id, 'prefix': prefix, 'createdAt': iso(),
                  'head': head, 'remoteHead': remote, 'branch': run['branch'], 'bundle': unpublished,
                  'components': {name: digest(data) for name, data in components.items()}}
        if 'session-id.json' in components:
            record['sessionId'] = json.loads(components['session-id.json'])['id']
        manifest = json.dumps(record, ensure_ascii=False, indent=2).encode()
        record['artifact'] = blobs.upload(artifact_prefix(number) + save_id, dict(components, **{'manifest.json': manifest}),
                                          gate_config()['checkpointRetentionDays'])
        if old and old.get('schema') == SCHEMA and old.get('saveId') and not old.get('closed'):
            record['previous'] = {k: v for k, v in old.items() if k != 'previous'}
        try:
            store.put_json(key, record, if_match=etag, if_none_match=not etag)
        except PreconditionFailed:
            print('Checkpoint pointer changed concurrently; retaining the newer pointer', flush=True)
            return None
        # Older artifacts are deleted by the Linux job after this worker (prune):
        # the worker has no actions: write.
        return record


def load_components(store, record, names=None, artifacts=None):
    if record.get('schema') != SCHEMA or not record.get('artifact'):
        raise RuntimeError('Checkpoint predates artifact storage; it cannot be restored')
    number = int(record['prefix'].split('/')[1])
    wanted = list(record['components'] if names is None else names)
    if any(name not in COMPONENTS for name in wanted):
        raise RuntimeError('Unknown checkpoint component')
    try:
        files = client(store, artifacts).download(record['artifact']['id'], artifact_prefix(number))
    except artifact_store.ArtifactExpired:
        raise CheckpointExpired('The checkpoint artifact has expired') from None
    result = {}
    for name in wanted:
        expected = record['components'].get(name)
        data = files.get(name)
        if not expected or data is None or digest(data) != expected:
            raise RuntimeError(f'Incomplete checkpoint component: {name}')
        result[name] = data
    return result


class CheckpointExpired(RuntimeError):
    pass


def restore(store, number, branch, restore_session=False, artifacts=None):
    record = store.get_json(session_key(number, 'workspace.json')) or {}
    if record.get('schema') != SCHEMA or record.get('closed') or not record.get('prefix'):
        return False
    if record['branch'] != branch:
        raise RuntimeError('Checkpoint branch differs; preserving it without changes')
    # Verify every byte before modifying the checkout.
    components = load_components(store, record, artifacts=artifacts)
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
    """Tombstone first so a concurrent final save cannot resurrect a pointer.

    The artifacts themselves are deleted by prune in a job with actions: write.
    """
    store.update_json(session_key(number, 'workspace.json'),
                      lambda old: {'schema': SCHEMA, 'closed': True, 'reason': reason, 'at': iso()}, default={})


def prune(store, number, artifacts=None, settle_seconds=600):
    """Delete this Issue's checkpoint artifacts that the pointer does not name.

    Keeps the latest and the previous save; a closed pointer keeps nothing.
    Artifacts younger than settle_seconds are kept unless the pointer is closed,
    so a save uploaded just before its pointer update is never removed.
    """
    blobs = client(store, artifacts)
    pointer = store.get_json(session_key(number, 'workspace.json')) or {}
    keep = set()
    if not pointer.get('closed'):
        for record in (pointer, pointer.get('previous') or {}):
            if (record.get('artifact') or {}).get('id'):
                keep.add(int(record['artifact']['id']))
    now = time.time()
    removed = 0
    for item in blobs.list(artifact_prefix(number)):
        if int(item['id']) in keep:
            continue
        created = item.get('created_at')
        if created and not pointer.get('closed'):
            age = now - datetime.datetime.fromisoformat(created.replace('Z', '+00:00')).timestamp()
            if age < settle_seconds:
                continue
        blobs.delete(item['id'])
        removed += 1
    return removed
