#!/usr/bin/env python3
"""Opt-in preparation of fixed native AST-stage hooks; does not build or enable product mode."""
import argparse
import hashlib
import pathlib
import shutil
import subprocess
REVISION = '3da49bb7ac15458ea4f554b589dde5197816f6ba'
# Exact pinned iOS stream activation slices replaced by redirection.inc.
BUILTIN_STREAMS_SHA256 = '1b9a5ee49bc8634380e4383dcb20b8c4b4c1c9737c78ba2598a81a0835ef12ff'
BAIL_STREAMS_SHA256 = 'cd9dd7c69cc768aebe0d62fff9feea9260c29539287a4bb31234e1afafaa6143'
ROOT = pathlib.Path(__file__).resolve().parents[1]

def ast_validator(source):
    # The pinned schema defines the actual AST ABI. This validates/copies no
    # command text and implements no parser or evaluator.
    groups, fields = {}, {}
    current = None
    for raw in (source / 'src/nodetypes').read_text().splitlines():
        line = raw.split('#', 1)[0].rstrip()
        if not line.strip(): continue
        words = line.split()
        if not line[0].isspace():
            kind, current = words
            groups.setdefault(current, []).append(kind)
            fields.setdefault(current, [])
        elif len(words) >= 2 and words[1] in ['nodeptr', 'nodelist', 'string']:
            fields[current].append((words[0], words[1]))
    text = """/* Generated from fixed BSD dash nodetypes; validation only. */
static int StruisDashASTAdd(size_t *bytes, size_t amount) {
    if (amount > STRUIS_DASH_STAGE_BYTES - *bytes) return 0;
    *bytes += amount; return 1;
}
static int StruisDashValidateNode(union node *n, size_t *bytes, size_t *nodes, unsigned depth) {
    if (!n) return 1;
    if (depth > 128 || ++*nodes > 4096 || n->type < 0 ||
        (size_t)n->type >= sizeof(nodesize)/sizeof(nodesize[0]) ||
        !StruisDashASTAdd(bytes, nodesize[n->type])) return 0;
    switch (n->type) {
"""
    for structure, kinds in groups.items():
        text += ''.join('    case ' + kind + ':\n' for kind in kinds)
        for field, kind in fields[structure]:
            value = 'n->' + structure + '.' + field
            if kind == 'nodeptr':
                text += '        if (!StruisDashValidateNode(' + value + ', bytes, nodes, depth + 1)) return 0;\n'
            elif kind == 'string':
                text += '        if (!' + value + ' || !StruisDashASTAdd(bytes, strnlen(' + value + ', STRUIS_DASH_STAGE_BYTES) + 1)) return 0;\n'
            else:
                text += '        for (struct nodelist *p = ' + value + '; p; p = p->next) {\n'
                text += '            if (++*nodes > 4096 || !StruisDashASTAdd(bytes, SHELL_ALIGN(sizeof(*p))) || !StruisDashValidateNode(p->n, bytes, nodes, depth + 1)) return 0;\n        }\n'
        text += '        break;\n'
    return text + '    default: return 0;\n    }\n    return 1;\n}\n'

def prepare(source, destination, copy_source=True):
    actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != REVISION:
        raise RuntimeError('dash source differs from fixed revision')
    if destination.resolve() == source.resolve():
        raise RuntimeError('preparation must use a separate output directory')
    if copy_source:
        shutil.copytree(source, destination, symlinks=True, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('.git', '*.zip', '*.xcframework', 'missing', 'compile', 'install-sh'))
    inputs = ROOT / 'DashPipelinePreparation'
    (destination / 'src/stage_ast_validate.inc').write_text(ast_validator(source))
    for original, fragment in [('var.c', 'variables.inc'), ('exec.c', 'functions.inc'),
                               ('alias.c', 'aliases.inc'), ('nodes.c.pat', 'nodes.inc')]:
        text = (destination / 'src' / original).read_text()
        (destination / 'src' / original).write_text(text + '\n' + (inputs / fragment).read_text())
    evaluation = (destination / 'src/eval.c').read_text()
    marker = 'evalpipe(union node *n, int flags)\n{'
    if evaluation.count(marker) != 1:
        raise RuntimeError('pinned pipeline entry changed')
    evaluation = evaluation.replace(marker, marker + '\n\tif (StruisDashHasPipelineLauncher()) return StruisDashPipeline(n, flags);', 1)
    # Keep an NREDIR selection active for every command in its body on the
    # iOS branch; the non-iOS branch keeps upstream descriptor redirection.
    redirected = ('\t\tstatus = redirectsafe(n->nredir.redirect, REDIR_PUSH) ?:\n'
                  '\t\t\t evaltree(n->nredir.n, flags & EV_TESTED);\n')
    definition = 'int\nevaltree(union node *n, int flags)\n{'
    if ('StruisDashEvalRedirected' in evaluation or evaluation.count(redirected) != 1 or
            evaluation.count(definition) != 1):
        raise RuntimeError('pinned redirection evaluation changed')
    evaluation = evaluation.replace(redirected, '#if TARGET_OS_IPHONE\n'
        '\t\tstatus = StruisDashEvalRedirected(n, flags & EV_TESTED);\n#else\n' + redirected + '#endif\n', 1)
    evaluation = evaluation.replace(definition, (inputs / 'redirection.inc').read_text() + '\n' + definition, 1)
    simple = '\tstatus = redirectsafe(cmd->ncmd.redirect, REDIR_PUSH|REDIR_SAVEFD2);\n'
    if evaluation.count(simple) != 1:
        raise RuntimeError('pinned simple command redirection changed')
    evaluation = evaluation.replace(simple, simple + '#if TARGET_OS_IPHONE\n'
        '\tStruisDashNoteBorrowed(cmd->ncmd.redirect);\n#endif\n', 1)
    function = '\tcase CMDFUNCTION:\n\t\tif (evalfun(cmdentry.u.func, argc, argv, flags))\n\t\t\tgoto raise;\n'
    if evaluation.count(function) != 1:
        raise RuntimeError('pinned function evaluation changed')
    evaluation = evaluation.replace(function, '\tcase CMDFUNCTION:\n#if TARGET_OS_IPHONE\n'
        '\t\tif (StruisDashEvalFunction(cmdentry.u.func, argc, argv, flags))\n#else\n'
        '\t\tif (evalfun(cmdentry.u.func, argc, argv, flags))\n#endif\n\t\t\tgoto raise;\n', 1)
    # Builtins and eval use the same exception-safe scope. The pinned iOS
    # restore leaked the selection when a builtin raised and closed a parent
    # stream that a redirection aliased (2>&1 >&2).
    entry = '\tsavehandler = handler;\n\tif ((i = setjmp(jmploc.loc)))\n\t\tgoto cmddone;\n'
    start = evaluation.find('\tif (cmd == EVALCMD)\n\t\tstatus = evalcmd(argc, argv, flags);\n')
    end = evaluation.find('\tflushall();\n\tif (outerr(out1))', start)
    done = 'cmddone:\n\tfreestdout();\n'
    if (evaluation.count(entry) != 1 or evaluation.count(done) != 1 or start < 0 or end < 0 or
            hashlib.sha256(evaluation[start:end].encode()).hexdigest() != BUILTIN_STREAMS_SHA256):
        raise RuntimeError('pinned builtin stream activation changed')
    evaluation = (evaluation[:start] + '\tif (cmd == EVALCMD)\n\t\tstatus = evalcmd(argc, argv, flags);\n'
        '\telse\n\t\tstatus = (*cmd->builtin)(argc, argv);\n#if TARGET_OS_IPHONE\n'
        '\tStruisDashRedirectionEnd(&redirection);\n\trestored = 1;\n#endif\n' + evaluation[end:])
    evaluation = evaluation.replace(entry, '\tsavehandler = handler;\n#if TARGET_OS_IPHONE\n'
        '\tstruct StruisDashRedirection redirection;\n\tvolatile int restored = 0;\n'
        '\tStruisDashRedirectionBegin(&redirection);\n#endif\n'
        '\tif ((i = setjmp(jmploc.loc)))\n\t\tgoto cmddone;\n', 1)
    evaluation = evaluation.replace(done, 'cmddone:\n#if TARGET_OS_IPHONE\n'
        '\tif (!restored)\n\t\tStruisDashRedirectionEnd(&redirection);\n#endif\n\tfreestdout();\n', 1)
    # build-dash.py's port preparation adds this redirection-error release.
    # Raw-source preparation checks have no iOS port block to replace.
    bail = evaluation.find('bail:\n\t\texitstatus = status;\n#if TARGET_OS_IPHONE\n\t\t{\n')
    if bail >= 0:
        close = evaluation.index('\t\t}\n#endif\n', bail) + len('\t\t}\n#endif\n')
        if hashlib.sha256(evaluation[bail:close].encode()).hexdigest() != BAIL_STREAMS_SHA256:
            raise RuntimeError('port redirection-error release changed')
        evaluation = (evaluation[:bail] + 'bail:\n\t\texitstatus = status;\n#if TARGET_OS_IPHONE\n\t\t{\n'
            '\t\t\tstruct StruisDashRedirection failed;\n\t\t\tStruisDashRedirectionBegin(&failed);\n'
            '\t\t\tStruisDashRedirectionEnd(&failed);\n\t\t}\n#endif\n' + evaluation[close:])
    evaluation = '#include "StageSnapshot.h"\n' + evaluation
    (destination / 'src/eval.c').write_text(evaluation)
    # The iOS port keeps fd 0-2 as ios_system FILE selections and never
    # restores the saved descriptor, but savefd still duplicated it. Release
    # that private copy; fd 3+ keeps the pinned iOS behavior.
    redirections = (destination / 'src/redir.c').read_text()
    saved = ('\t\tdefault:\n#if !TARGET_OS_IPHONE\n\t\t\t// And dup2 is going to create issues too.\n'
             '\t\t\tif (!drop)\n\t\t\t\tdup2(rp->renamed[i], i);\n\t\t\tclose(rp->renamed[i]);\n#endif\n')
    if redirections.count(saved) != 1:
        raise RuntimeError('pinned redirection restore changed')
    (destination / 'src/redir.c').write_text(redirections.replace(saved, saved[:-len('#endif\n')] +
        '#else\n\t\t\tif (i <= STDERR_FILENO)\n\t\t\t\tclose(rp->renamed[i]);\n#endif\n', 1))
    # The isolated preparation entry must not replace the process SIGCHLD
    # disposition while another real interpreter is running.
    trap = (source / 'src/trap.c').read_text()
    marker = '\tsigmode[SIGCHLD - 1] = S_DFL;\n\tsetsignal(SIGCHLD);'
    if trap.count(marker) != 1:
        raise RuntimeError('pinned initialization shape changed')
    trap = trap.replace('INCLUDE "trap.h"', 'INCLUDE "trap.h"\nINCLUDE "StageSnapshot.h"', 1)
    trap = trap.replace(marker, '\tsigmode[SIGCHLD - 1] = S_DFL;\n\tif (!StruisDashStageInitializing) setsignal(SIGCHLD);', 1)
    (destination / 'src/trap.c').write_text(trap)
    for name in ['StageSnapshot.h', 'stage.c']:
        shutil.copy2(inputs / name, destination / 'src' / name)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    prepare(args.source, args.output)
