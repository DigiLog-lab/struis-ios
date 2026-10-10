# SPDX-License-Identifier: Apache-2.0
"""Read-only Git history subset over the virtual workspace; no external Git."""
import argparse
from datetime import datetime, timezone
import os
import sys
import stat
from dulwich.repo import Repo
from dulwich.objects import Blob
from dulwich.objectspec import parse_commit
from dulwich.annotate import annotate_lines
from dulwich.config import ConfigFile, StackedConfig


class HistoryRepo(Repo):
    # History reads need object/ref data, not config, filters, credentials or
    # host/global environment. Do not use Repo's include-aware config readers.
    def get_config(self):
        return ConfigFile()

    def get_config_stack(self):
        return StackedConfig([self.get_config()])


def open_history_repo():
    root = os.getcwd()
    while root == '/workspace' or root.startswith('/workspace/'):
        control = os.path.join(root, '.git')
        try:
            mode = os.stat(control).st_mode
        except FileNotFoundError:
            parent = os.path.dirname(root)
            if parent == root:
                break
            root = parent
            continue
        if not stat.S_ISDIR(mode):
            raise ValueError('gitfile and linked-worktree layouts are unsupported')
        for name in ('commondir', 'objects/info/alternates', 'shallow', 'info/grafts'):
            try:
                os.stat(os.path.join(control, name))
            except FileNotFoundError:
                continue
            raise ValueError('alternate, linked-worktree, shallow and grafted histories are unsupported')
        repo = HistoryRepo(root, bare=False, commondir=control, alternates=[])
        repo.hooks.clear()
        return repo
    raise ValueError('no supported repository in the permitted workspace')


def main(argv):
    parser = argparse.ArgumentParser(prog='git')
    parser.add_argument('-C', dest='directory')
    sub = parser.add_subparsers(dest='command', required=True)
    log = sub.add_parser('log')
    log.add_argument('--oneline', action='store_true')
    log.add_argument('-n', '--max-count', type=int, default=10)
    log.add_argument('ref', nargs='?', default='HEAD')
    blame = sub.add_parser('blame')
    blame.add_argument('path')
    args = parser.parse_args(argv)
    before = os.getcwd()
    try:
        if args.directory:
            os.chdir(args.directory)
        with open_history_repo() as repo:
            if args.command == 'log':
                if not 0 <= args.max_count <= 1000:
                    raise ValueError('max-count must be between 0 and 1000')
                if args.max_count == 0:
                    return 0
                start = parse_commit(repo, args.ref)
                for entry in repo.get_walker(include=[start.id], max_entries=args.max_count):
                    commit = entry.commit
                    text = commit.message.decode('utf-8', 'replace')
                    if args.oneline:
                        print(commit.id.decode()[:8] + ' ' + text.splitlines()[0])
                    else:
                        print('commit ' + commit.id.decode())
                        print('Author: ' + commit.author.decode('utf-8', 'replace'))
                        print('\n    ' + text + '\n')
                return 0
            # Final reads still go through the operation broker. This syntax
            # constraint is an explicit supported subset, not an isolation claim.
            path = args.path
            if not path or os.path.isabs(path) or any(v in ('', '.', '..') for v in path.split('/')):
                raise ValueError('blame requires a repository-relative file path')
            relative = os.path.relpath(os.path.join(os.getcwd(), path), repo.path)
            if relative.startswith('../'):
                raise ValueError('blame requires a file in the repository')
            encoded = os.fsencode(relative)
            commit = parse_commit(repo, 'HEAD')
            tree = repo.object_store[commit.tree]
            mode, sha = tree.lookup_path(repo.object_store.__getitem__, encoded)
            if mode & 0o170000 != 0o100000:
                raise ValueError('blame requires a tracked regular file')
            blob = repo.object_store[sha]
            if not isinstance(blob, Blob):
                raise ValueError('blame requires a tracked regular file')
            with open(path, 'rb') as stream:
                if stream.read(16*1024*1024+1) != blob.data:
                    raise ValueError('working-tree blame is unsupported; use a clean tracked file')
            current = commit
            seen = set()
            while True:
                if current.id in seen or len(seen) >= 1000:
                    raise ValueError('blame history budget exceeded')
                seen.add(current.id)
                if len(current.parents) > 1:
                    raise ValueError('merge blame is unsupported')
                if not current.parents:
                    break
                current = repo.object_store[current.parents[0]]
            lines = annotate_lines(repo.object_store, commit.id, encoded)
            if len(lines) > 10000:
                raise ValueError('blame line budget exceeded')
            for number, ((origin, _), line) in enumerate(lines, 1):
                author = origin.author.decode('utf-8', 'replace').split(' <', 1)[0]
                stamp = datetime.fromtimestamp(origin.author_time, timezone.utc).strftime('%Y-%m-%d %H:%M:%S +0000')
                short = origin.id.decode()[:8]
                if not origin.parents:
                    short = '^' + short[:7]
                text = line.decode('utf-8', 'replace').rstrip('\n')
                print(f'{short} ({author} {stamp} {number}) {text}')
            return 0
    finally:
        os.chdir(before)
