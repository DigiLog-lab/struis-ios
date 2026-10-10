"""Git command adapter using Dulwich under its Apache-2.0 license option.

Unsupported options are errors; no command delegates to an external Git binary.
"""
import argparse
import os
import sys
from dulwich import porcelain
from dulwich.repo import Repo


def parser():
    p = argparse.ArgumentParser(prog="git")
    p.add_argument("--version", action="store_true")
    p.add_argument("-C", dest="directory")
    subs = p.add_subparsers(dest="command")
    init = subs.add_parser("init")
    init.add_argument("path", nargs="?", default=".")
    init.add_argument("-b", "--initial-branch", default="main")
    init.add_argument("--bare", action="store_true")
    config = subs.add_parser("config")
    config.add_argument("--global", dest="global_config", action="store_true")
    config.add_argument("--get", action="store_true")
    config.add_argument("key")
    config.add_argument("value", nargs="?")
    status = subs.add_parser("status")
    status.add_argument("--short", "-s", action="store_true")
    status.add_argument("--porcelain", nargs="?", const="1")
    status.add_argument("--branch", "-b", action="store_true")
    add = subs.add_parser("add")
    add.add_argument("paths", nargs="*")
    add.add_argument("--all", "-A", action="store_true")
    commit = subs.add_parser("commit")
    commit.add_argument("-m", "--message", required=True)
    commit.add_argument("--all", "-a", action="store_true")
    commit.add_argument("--amend", action="store_true")
    diff = subs.add_parser("diff")
    diff.add_argument("--cached", "--staged", dest="staged", action="store_true")
    diff.add_argument("--stat", action="store_true")
    diff.add_argument("paths", nargs="*")
    log = subs.add_parser("log")
    log.add_argument("--oneline", action="store_true")
    log.add_argument("-n", "--max-count", type=int, default=10)
    log.add_argument("ref", nargs="?", default="HEAD")
    clone = subs.add_parser("clone")
    clone.add_argument("source")
    clone.add_argument("target", nargs="?")
    clone.add_argument("--depth", type=int)
    for name in ("pull", "push", "fetch"):
        network = subs.add_parser(name)
        network.add_argument("remote", nargs="?", default="origin")
        network.add_argument("ref", nargs="?")
    branch = subs.add_parser("branch")
    branch.add_argument("name", nargs="?")
    checkout = subs.add_parser("checkout")
    checkout.add_argument("-b", dest="new_branch")
    checkout.add_argument("target", nargs="?")
    rev = subs.add_parser("rev-parse")
    rev.add_argument("--show-toplevel", action="store_true")
    rev.add_argument("--is-inside-work-tree", action="store_true")
    rev.add_argument("--abbrev-ref", action="store_true")
    rev.add_argument("ref", nargs="?", default="HEAD")
    return p


def main(argv):
    p = parser()
    args = p.parse_args(argv)
    if args.version:
        import dulwich
        print("git (Dulwich " + ".".join(map(str, dulwich.__version__)) + ")")
        return 0
    if not args.command:
        p.print_help()
        return 0
    previous = os.getcwd()
    try:
        if args.directory:
            os.chdir(args.directory)
        if args.command == "init":
            os.makedirs(args.path, exist_ok=True)
            repo = porcelain.init(args.path, bare=args.bare)
            repo.refs.set_symbolic_ref(b"HEAD", b"refs/heads/" + args.initial_branch.encode())
            print("Initialized Git repository in " + repo.path)
            repo.close()
            return 0
        if args.command == "clone":
            reject_external_transport(args.source)
            target = args.target or args.source.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")
            repo = porcelain.clone(args.source, target, depth=args.depth, errstream=sys.stderr.buffer)
            repo.close()
            return 0
        if args.command == "config" and args.global_config:
            from dulwich.config import ConfigFile
            location = os.path.join(os.environ["HOME"], ".gitconfig")
            config = ConfigFile.from_path(location) if os.path.exists(location) else ConfigFile()
            configure(config, args, location)
            return 0
        with Repo.discover() as repo:
            # CPython on iOS rejects subprocess creation before checking whether
            # a hook exists. Remove absent hooks without attempting a subprocess.
            for name, hook in list(repo.hooks.items()):
                path = getattr(hook, "filepath", None)
                if path and not os.path.exists(path):
                    del repo.hooks[name]
                elif path and args.command in ("commit", "pull", "push", "checkout"):
                    raise RuntimeError(f"Shell hooks are not supported: {path}")
            if args.command == "config":
                configure(repo.get_config(), args)
            elif args.command == "status":
                if args.branch:
                    print("## " + repo.refs.read_ref(b"HEAD").decode().removeprefix("ref: refs/heads/"))
                status = porcelain.status(repo, untracked_files="all")
                rows = {}
                for kind, paths in status.staged.items():
                    for path in paths:
                        rows.setdefault(path, [" ", " "])[0] = {"add": "A", "delete": "D", "modify": "M"}[kind]
                for path in status.unstaged:
                    rows.setdefault(path, [" ", " "])[1] = "M" if os.path.exists(os.path.join(repo.path, os.fsdecode(path))) else "D"
                for path in status.untracked:
                    rows[path] = ["?", "?"]
                for path, code in sorted(rows.items()):
                    print("".join(code) + " " + os.fsdecode(path))
                if not rows and not (args.short or args.porcelain):
                    print("nothing to commit, working tree clean")
            elif args.command == "add":
                if not args.paths and not args.all:
                    p.error("add requires paths or --all")
                porcelain.add(repo, paths=args.paths or None)
            elif args.command == "commit":
                sha = porcelain.commit(repo, message=args.message, all=args.all, amend=args.amend)
                print(sha.decode()[:12] + " " + args.message)
            elif args.command == "diff":
                if args.stat:
                    p.error("diff --stat is not supported")
                porcelain.diff(repo, staged=args.staged, paths=args.paths or None, outstream=sys.stdout.buffer)
            elif args.command == "log":
                from dulwich.objectspec import parse_commit
                start = parse_commit(repo, args.ref).id
                for entry in repo.get_walker(include=[start], max_entries=args.max_count):
                    commit = entry.commit
                    message = commit.message.decode("utf-8", "replace")
                    if args.oneline:
                        print(commit.id.decode()[:8] + " " + message.splitlines()[0])
                    else:
                        print("commit " + commit.id.decode())
                        print("Author: " + commit.author.decode("utf-8", "replace"))
                        print("\n    " + message + "\n")
            elif args.command == "branch":
                if args.name:
                    porcelain.branch_create(repo, args.name)
                else:
                    for name in porcelain.branch_list(repo):
                        print(name.decode())
            elif args.command == "checkout":
                if args.new_branch:
                    porcelain.branch_create(repo, args.new_branch)
                target = args.new_branch or args.target
                if not target:
                    p.error("checkout requires a branch or commit")
                porcelain.checkout(repo, target)
            elif args.command == "rev-parse":
                if args.show_toplevel:
                    print(os.path.abspath(repo.path))
                elif args.is_inside_work_tree:
                    print("false" if repo.bare else "true")
                elif args.abbrev_ref:
                    print(repo.refs.read_ref(b"HEAD").decode().removeprefix("ref: refs/heads/"))
                else:
                    from dulwich.objectspec import parse_object
                    print(parse_object(repo, args.ref).id.decode())
            elif args.command in ("push", "pull", "fetch"):
                remote = args.remote
                try:
                    remote = repo.get_config_stack().get((b"remote", remote.encode()), b"url").decode()
                except KeyError:
                    pass
                reject_external_transport(remote)
                if args.command == "fetch":
                    porcelain.fetch(repo, remote, errstream=sys.stderr.buffer)
                else:
                    getattr(porcelain, args.command)(repo, remote, refspecs=args.ref, errstream=sys.stderr.buffer)
        return 0
    finally:
        os.chdir(previous)


def configure(config, args, location=None):
    parts = args.key.split(".")
    if len(parts) < 2:
        raise ValueError("configuration key must contain a section")
    section = tuple(part.encode() for part in parts[:-1])
    key = parts[-1].encode()
    if args.value is None:
        print(config.get(section, key).decode())
    else:
        config.set(section, key, args.value.encode())
        if location:
            config.write_to_path(location)
        else:
            config.write_to_path()


def reject_external_transport(remote):
    if remote.startswith(("ssh://", "git+ssh://")) or (":" in remote and "://" not in remote):
        raise ValueError("SSH transport is not bundled; use an HTTPS URL or local path")
