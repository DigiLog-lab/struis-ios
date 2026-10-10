#!/usr/bin/env python3
"""Run fixed-source real dash AST/state isolation on Linux, without enabling product mode."""
import argparse
import ctypes
import hashlib
import importlib.util
import json
import pathlib
import shutil
import signal
import subprocess
import tempfile
import os
import sys
import select
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]

def command(args, cwd, log):
    with log.open('ab') as stream:
        subprocess.run([str(x) for x in args], cwd=cwd, stdout=stream, stderr=stream, check=True)

def build(source, work):
    spec = importlib.util.spec_from_file_location('dash_stage', ROOT / 'Scripts/prepare-dash-stage.py')
    prepare = importlib.util.module_from_spec(spec); spec.loader.exec_module(prepare)
    prepare.prepare(source, work)
    (work / 'TargetConditionals.h').write_text('#define TARGET_OS_IPHONE 0\n#define TARGET_OS_SIMULATOR 0\n')
    for name, body in {'compile': 'exec "$@"', 'missing': '[ "$1" = -- ] && shift; exec "$@"', 'install-sh': 'exec /usr/bin/install "$@"'}.items():
        helper = work / name
        if helper.is_symlink(): helper.unlink()
        helper.write_text('#!/bin/sh\n' + body + '\n'); helper.chmod(0o755)
    # Dormant upstream host branch has a missing parenthesis. This compiler-only
    # repair does not change the iOS stage or pipeline branches.
    evaluation = work / 'src/eval.c'
    evaluation.write_text(evaluation.read_text().replace('evaltreenr(n->nredir.n, flags;', 'evaltreenr(n->nredir.n, flags);'))
    log = work / 'host-build.log'
    command(['./configure', '--without-libedit', '--disable-dependency-tracking',
             'CFLAGS=-O0 -g -fPIC -I. -I.. -DJOBS=0'], work, log)
    makefile = work / 'src/Makefile'
    text = makefile.read_text()
    text = text.replace('HELPERS = mkinit mksyntax mknodes mksignames', 'HELPERS = mkinit mksyntax mknodes')
    text = text.replace('signames.c: mksignames\n\t$(AM_V_GEN)./$^', 'signames.c:\n\t@test -f signames.c')
    text = text.replace('dash_LDADD = builtins.o init.o nodes.o signames.o syntax.o',
                        'dash_LDADD = builtins.o init.o nodes.o signames.o syntax.o stage.o')
    makefile.write_text(text)
    # Independent signal constants; do not compile or execute GPL mksignames.
    names = ['EXIT'] + ['UNKNOWN'] * (signal.NSIG - 1)
    for item in signal.Signals:
        if item.value < len(names): names[item.value] = item.name.removeprefix('SIG')
    (work / 'src/signames.c').write_text('#include <signal.h>\nconst char *const signal_names[NSIG+1]={' + ','.join('"' + x + '"' for x in names) + ',0};\n')
    exclusions = ['-o', 'Makefile.in', '-o', 'aclocal.m4', '-o', 'configure', '-o', 'config.h.in']
    command(['make', '-j4', *exclusions, 'builtins.h', 'nodes.h', 'syntax.h', 'token.h'], work / 'src', log)
    command(['cc', '-O0', '-g', '-fPIC', '-I.', '-I..', '-include', '../config.h', '-DJOBS=0', '-c', 'stage.c', '-o', 'stage.o'], work / 'src', log)
    command(['make', '-j4', *exclusions], work / 'src', log)
    shutil.copy2(ROOT / 'DashPipelinePreparation/host-fixture.c', work / 'src/host-fixture.c')
    command(['cc', '-O0', '-g', '-fPIC', '-I.', '-I..', '-include', '../config.h', '-DJOBS=0', '-c', 'host-fixture.c', '-o', 'host-fixture.o'], work / 'src', log)
    objects = sorted((work / 'src').glob('*.o')) + sorted((work / 'src/bltin').glob('*.o'))
    library = work / 'dash-stage.so'
    # Bind each image's real shell functions/state to that image. Linux's host
    # loader is evidence machinery only; signed Darwin images remain pending.
    command(['cc', '-shared', '-Wl,-Bsymbolic', *objects, '-o', library], work, log)
    return library

def image(library, name):
    destination = library.with_name(name + '.so'); shutil.copy2(library, destination)
    result = ctypes.CDLL(str(destination), mode=ctypes.RTLD_LOCAL)
    result.lookupvar.argtypes = [ctypes.c_char_p]; result.lookupvar.restype = ctypes.c_char_p
    result.StruisDashHostSnapshot.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    result.StruisDashStageEnter.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    result.StruisDashSnapshotDestroy.argtypes = [ctypes.c_void_p]
    return result

def exercise(library):
    root, child = image(library, 'state-root'), image(library, 'state-child')
    snapshot, code = ctypes.c_void_p(), ctypes.c_int()
    setup = '''secret=parent; export public=visible; readonly ro=locked; export removed; unset removed; set -- first second; set -f; f() { result="$secret|$1|$ro|$public|$2"; }; alias assign='alias_result=ok';'''.encode()
    script = '''f 日本語 ARG2; eval assign; secret=child; shift; stage_arg="$1"; stage_zero="$0"; stage_flags="$-";'''.encode()
    assert root.StruisDashHostSnapshot(setup, script, ctypes.byref(snapshot)) == 0
    try:
        assert child.StruisDashStageEnter(snapshot, ctypes.byref(code)) == 0 and code.value == 0
        assert root.lookupvar(b'secret') == b'parent' and child.lookupvar(b'secret') == b'child'
        assert child.lookupvar(b'result') == 'parent|日本語|locked|visible|ARG2'.encode()
        assert child.lookupvar(b'alias_result') == b'ok'
        assert child.lookupvar(b'stage_arg') == b'second' and child.lookupvar(b'stage_zero') == b'fixture-zero'
        assert b'f' in child.lookupvar(b'stage_flags') and child.lookupvar(b'removed') is None
        assert child.StruisDashStageEnter(snapshot, ctypes.byref(code)) == 16
    finally: root.StruisDashSnapshotDestroy(snapshot)
    # Independent images retain readonly flags, real shell exit semantics, and
    # explicit capacity failure. These run actual parser/evaluator operations.
    for name, setup, script, expected in [
        ('readonly', b'readonly ro=locked', b'ro=changed', 2),
        ('exit42', b'x=parent', b'exit 42', 42),
        ('getopts', b'set -- -a value; getopts a first; ', b'getopts a next; result="$next|$OPTIND"', 0),
    ]:
        root, child = image(library, name + '-root'), image(library, name + '-child')
        assert root.StruisDashHostSnapshot(setup, script, ctypes.byref(snapshot)) == 0
        try:
            error = child.StruisDashStageEnter(snapshot, ctypes.byref(code))
            assert error == 0 and code.value == expected, (name, error, code.value, expected)
            if name == 'getopts': assert child.lookupvar(b'result') == b'?|2'
        finally: root.StruisDashSnapshotDestroy(snapshot)
    root = image(library, 'bounded-root')
    assert root.StruisDashHostSnapshot(';'.join('v%d=x' % n for n in range(257)).encode(), b':', ctypes.byref(snapshot)) == 7
    assert snapshot.value is None
    for name, setup, script in [
        ('bounded-bytes', b"large='" + b'x' * (1024 * 1024) + b"'", b':'),
        ('bounded-depth', b'x=ok', b';'.join([b':'] * 200)),
    ]:
        root = image(library, name + '-root')
        assert root.StruisDashHostSnapshot(setup, script, ctypes.byref(snapshot)) == 7
        assert snapshot.value is None
    return {'variables': True, 'readonly': True, 'unset': True, 'functions': True, 'aliases': True,
            'japanese': True, 'positionalParameters': True, 'getopts': True, 'options': True,
            'parentIsolation': True, 'exit42': True, 'oneShot': True, 'boundedRejection': True}

def differential_execution(library, script, installed, flags):
    root = image(library, 'differential-root')
    code = ctypes.c_int()
    if installed:
        children = [image(library, 'differential-child-%d' % i) for i in range(8)]
        entries = (ctypes.c_void_p * 8)(*[ctypes.cast(x.StruisDashStageEnter, ctypes.c_void_p).value for x in children])
        root.StruisDashHostPipelineRunFlags.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p), ctypes.c_size_t, ctypes.POINTER(ctypes.c_int), ctypes.c_int]
        error = root.StruisDashHostPipelineRunFlags(script.encode(), entries, 8, ctypes.byref(code), flags)
    else:
        root.StruisDashHostEvaluateFlags.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int), ctypes.c_int]
        error = root.StruisDashHostEvaluateFlags(script.encode(), ctypes.byref(code), flags)
    assert error == 0, error
    os.write(1, ('\n' + json.dumps({'exit': code.value}) + '\n').encode())

def exercise_evaluation_flags(library):
    cases = [
        ('if-tested', 'set -e; if { false; printf survived; } | cat; then printf condition-ok; fi', 'survivedcondition-ok'),
        ('untested', 'set -e; { false; printf wrong; } | cat; printf next', 'next'),
        ('negated', 'set -e; ! { false; printf survived; } | cat; printf after', 'survivedafter'),
        ('or-tested', 'set -e; { false; printf survived; } | cat || printf fallback; printf next', 'survivednext'),
        ('and-tested', 'set -e; { false; printf survived; } | cat && printf and-ok', 'survivedand-ok'),
        ('function-tested', 'set -e; f() { false; printf survived; }; if f | cat; then printf function-ok; fi', 'survivedfunction-ok'),
    ]
    cases = [(name, script, expected, 0) for name, script, expected in cases]
    cases.append(('last-stage-exit42', "set -e; printf x | /bin/sh -c 'cat >/dev/null; exit 42'; printf wrong", '', 42))
    reports = []
    for name, script, expected, expected_code in cases:
        for flags in [0, 1]:
            actual = []
            for installed in [False, True]:
                result = subprocess.run([sys.executable, str(pathlib.Path(__file__).resolve()), '--differential-execution', str(library), script, str(int(installed)), str(flags)],
                                        capture_output=True, text=True, timeout=4, check=True)
                prefix, tail = result.stdout.rstrip('\n').rsplit('\n', 1)
                actual.append((prefix, json.loads(tail)['exit']))
            assert actual[0] == actual[1] == (expected, expected_code), (name, actual)
            reports.append({'case': name, 'flags': flags, 'nativeMatchesPrepared': True, 'exit': expected_code})
    return reports

def pipeline_execution(library, workspace, cancel=False):
    root = image(library, 'pipeline-root')
    children = [image(library, 'pipeline-child-%d' % i) for i in range(3)]
    entries = (ctypes.c_void_p * 3)(*[ctypes.cast(x.StruisDashStageEnter, ctypes.c_void_p).value for x in children])
    root.StruisDashHostPipelineRun.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p), ctypes.c_size_t, ctypes.POINTER(ctypes.c_int)]
    os.chdir(workspace)
    code = ctypes.c_int()
    command_text = """{ dd if=input.bin bs=1024 count=1 2>/dev/null; i=0; while [ ! -f early.flag ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done; [ -f early.flag ] || exit 91; dd if=input.bin bs=1024 skip=1 2>/dev/null; touch producer.done; } | python3 work.py 日本語 2>errors.bin | { dd of=first.bin bs=1024 count=1 2>/dev/null; if [ -f producer.done ]; then printf late >timing; else printf early >timing; fi; touch early.flag; cat >rest.bin; }
"""
    if cancel:
        command_text = "sleep 15 | python3 -c 'import sys;sys.stdout.buffer.write(b\"READY\");sys.stdout.buffer.flush();sys.stdin.buffer.read()' | { cat; }"
    error = root.StruisDashHostPipelineRun(command_text.encode(), entries, 3, ctypes.byref(code))
    if cancel:
        assert error == 0 and code.value == 130, (error, code.value)
        assert root.StruisDashHasPipelineLauncher() == 0
        print(json.dumps({'cancelled': True, 'allStageParentsJoined': True})); return
    assert error == 0 and code.value == 0, (error, code.value)
    assert root.StruisDashHasPipelineLauncher() == 0
    data = (workspace / 'input.bin').read_bytes()
    assert (workspace / 'first.bin').read_bytes() + (workspace / 'rest.bin').read_bytes() == bytes(x ^ 0x55 for x in data)
    assert (workspace / 'errors.bin').read_bytes() == bytes(x ^ 0xaa for x in data)
    assert (workspace / 'timing').read_text() == 'early'
    assert (workspace / 'argv.txt').read_text() == '日本語'
    assert (workspace / 'python-exit.txt').read_text() == '42'
    print(json.dumps({'bytes': len(data), 'binary': True, 'earlyBeforeEOF': True, 'stderr': True, 'argv': True, 'pythonExit42': True, 'compoundStages': 2, 'realDashAST': True}))

def exercise_pipeline(library):
    workspace = library.parent / 'pipeline-workspace'; workspace.mkdir()
    count = 65536 * 5 + 237
    (workspace / 'input.bin').write_bytes(bytes((i * 37) % 251 for i in range(count)))
    (workspace / 'work.py').write_text("""import sys
import select
import time
assert sys.argv[1] == '日本語'
open('argv.txt','w').write(sys.argv[1])
first=sys.stdin.buffer.read(1024)
sys.stdout.buffer.write(bytes(x^0x55 for x in first));sys.stdout.buffer.flush()
sys.stderr.buffer.write(bytes(x^0xaa for x in first));sys.stderr.buffer.flush()
while True:
    b=sys.stdin.buffer.read(16384)
    if not b: break
    sys.stdout.buffer.write(bytes(x^0x55 for x in b));sys.stdout.buffer.flush()
    sys.stderr.buffer.write(bytes(x^0xaa for x in b));sys.stderr.buffer.flush()
open('python-exit.txt','w').write('42')
sys.exit(42)
""")
    result = subprocess.run([sys.executable, str(pathlib.Path(__file__).resolve()), '--pipeline-execution', str(library), str(workspace)],
                            capture_output=True, text=True, timeout=8, check=True)
    report = json.loads(result.stdout)
    blocked = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).resolve()), '--pipeline-cancellation', str(library), str(workspace)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        ready = b''; deadline = time.monotonic() + 4
        while len(ready) < 5 and time.monotonic() < deadline:
            if select.select([blocked.stdout], [], [], .1)[0]: ready += os.read(blocked.stdout.fileno(), 5 - len(ready))
        assert ready == b'READY', ready
        started = time.monotonic(); os.kill(blocked.pid, signal.SIGUSR1)
        output, errors = blocked.communicate(timeout=2)
        assert blocked.returncode == 0, errors
        cancellation = json.loads(output)
        assert cancellation['cancelled'] and cancellation['allStageParentsJoined']
        report['cancellationSeconds'] = round(time.monotonic() - started, 3)
    finally:
        if blocked.poll() is None: blocked.kill(); blocked.communicate()
    # A distinct captured invocation succeeds after teardown with fresh images
    # and files. It must not reuse a consumed mutable interpreter.
    fresh = library.parent / 'fresh-pipeline-workspace'; fresh.mkdir()
    shutil.copy2(workspace / 'input.bin', fresh / 'input.bin'); shutil.copy2(workspace / 'work.py', fresh / 'work.py')
    subprocess.run([sys.executable, str(pathlib.Path(__file__).resolve()), '--pipeline-execution', str(library), str(fresh)], capture_output=True, text=True, timeout=8, check=True)
    report['freshAfterCancellation'] = True
    return report

if __name__ == '__main__':
    if len(sys.argv) == 6 and sys.argv[1] == '--differential-execution':
        differential_execution(pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4] == '1', int(sys.argv[5])); sys.exit(0)
    if len(sys.argv) == 4 and sys.argv[1] in ['--pipeline-execution', '--pipeline-cancellation']:
        pipeline_execution(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[1] == '--pipeline-cancellation'); sys.exit(0)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    work = pathlib.Path(tempfile.mkdtemp(prefix='hyotan-dash-stage-', dir='/tmp'))
    report = {'scope': 'Linux real fixed dash AST/state and native host-fork compound pipeline; not ios_system, Apple SDK or product enablement',
              'work': str(work), 'sourceEvalSHA256': hashlib.sha256((args.source / 'src/eval.c').read_bytes()).hexdigest()}
    library = build(args.source, work)
    report['checks'] = exercise(library)
    report['pipeline'] = exercise_pipeline(library)
    report['evaluationFlags'] = exercise_evaluation_flags(library)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
