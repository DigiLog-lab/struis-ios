#!/usr/bin/env python3
"""Execute the configured pinned Dash make graph that failed in Cloud120.
Linux host compiler/evaluator branch only; Apple SDK linking remains pending.
No stage object is manually compiled or substituted: make owns every compile.
"""
import argparse
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import shutil
import signal
import subprocess
import tarfile
import tempfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
EXCLUSIONS = ['-o', 'Makefile.in', '-o', 'aclocal.m4', '-o', 'configure', '-o', 'config.h.in']
HEADERS = ['builtins.h', 'nodes.h', 'syntax.h', 'token.h', 'token_vars.h']

def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'Scripts' / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def signals(work):
    names = ['EXIT'] + ['UNKNOWN'] * (signal.NSIG - 1)
    for item in signal.Signals:
        if item.value < len(names): names[item.value] = item.name.removeprefix('SIG')
    (work / 'src/signames.c').write_text('#include <signal.h>\nconst char *const signal_names[NSIG+1]={' + ','.join('"' + x + '"' for x in names) + ',0};\n')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    builder, overlay = load('build-dash.py'), load('prepare-dash-stage.py')
    assert subprocess.check_output(['git', '-C', str(args.source), 'rev-parse', 'HEAD'], text=True).strip() == builder.REVISION
    work = pathlib.Path(tempfile.mkdtemp(prefix='hyotan-cloud120-dash-graph-'))
    # Export only the pinned tracked tree, excluding every stale host/Mach-O
    # object and generated file that might hide a scheduling defect.
    archive = subprocess.check_output(['git', '-C', str(args.source), 'archive', builder.REVISION])
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(work, members=[m for m in source.getmembers() if m.name not in ('compile', 'missing', 'install-sh')], filter='data')
    overlay.prepare(args.source, work, copy_source=False)
    (work / 'TargetConditionals.h').write_text('#define TARGET_OS_IPHONE 0\n#define TARGET_OS_SIMULATOR 0\n')
    evaluation = work / 'src/eval.c'
    evaluation.write_text(evaluation.read_text().replace('evaltreenr(n->nredir.n, flags;', 'evaltreenr(n->nredir.n, flags);'))
    for name, body in {'compile': 'exec "$@"', 'missing': '[ "$1" = -- ] && shift; exec "$@"', 'install-sh': 'exec /usr/bin/install "$@"'}.items():
        path = work / name
        if path.is_symlink(): path.unlink()
        path.write_text('#!/bin/sh\n' + body + '\n'); path.chmod(0o755)
    events = work / 'compiler-events.jsonl'
    compiler = work / 'record-compiler.py'
    compiler.write_text('''#!/usr/bin/env python3
import json,os,pathlib,subprocess,sys
args=sys.argv[1:]
output=args[args.index('-o')+1] if '-o' in args else ''
stage=output=='stage.o'
link=output=='dash'
if stage or link:
    record=dict(phase='begin',stage=stage,link=link,args=args,
        stageExists=pathlib.Path('stage.o').exists(),
        headers={h:pathlib.Path(h).exists() for h in ['builtins.h','nodes.h','syntax.h','token.h','token_vars.h']})
    with open(os.environ['DASH_GRAPH_EVENTS'],'a') as f:f.write(json.dumps(record)+'\\n')
result=subprocess.run(['cc',*args])
if stage or link:
    with open(os.environ['DASH_GRAPH_EVENTS'],'a') as f:f.write(json.dumps(dict(phase='end',stage=stage,link=link,exit=result.returncode))+'\\n')
sys.exit(result.returncode)
'''); compiler.chmod(0o755)
    flags = '-O0 -g -fPIC -I. -I.. -DJOBS=0 -DSTRUIS_BUILD_GRAPH_CFLAG=120'
    env = dict(os.environ, CC=str(compiler), CFLAGS=flags,
               CPPFLAGS='-DSTRUIS_BUILD_GRAPH_CPPFLAG=120', CC_FOR_BUILD='cc -DJOBS=0',
               DASH_GRAPH_EVENTS=str(events))
    log = work / 'make.log'
    def execute(command, cwd=work, success=True):
        with log.open('ab') as stream:
            stream.write(('COMMAND ' + ' '.join(str(x) for x in command) + '\n').encode())
            result = subprocess.run([str(x) for x in command], cwd=cwd, env=env, stdout=stream, stderr=stream, timeout=60)
        if success: assert result.returncode == 0, (command, str(log))
        return result
    execute(['./configure', '--without-libedit', '--disable-dependency-tracking'])
    makefile = work / 'src/Makefile'
    configured = makefile.read_text()
    # The original opt-in modification passed stage.o to the linker alone.
    broken = builder.prepare_makefile(configured, False).replace(
        'dash_LDADD = builtins.o init.o nodes.o signames.o syntax.o\n',
        'dash_LDADD = builtins.o init.o nodes.o signames.o syntax.o stage.o\n')
    assert not (work / 'src/stage.o').exists()
    makefile.write_text(broken); signals(work); events.write_text('')
    failure = execute(['make', '-j4', *EXCLUSIONS, 'V=1'], success=False)
    broken_events = [json.loads(x) for x in events.read_text().splitlines()]
    assert failure.returncode != 0 and not (work / 'src/stage.o').exists()
    assert any(x['phase'] == 'begin' and x['link'] and not x['stageExists'] for x in broken_events)
    assert not any(x['stage'] for x in broken_events)
    assert 'stage.o' in log.read_text() and ('cannot find stage.o' in log.read_text() or 'no such file or directory' in log.read_text())
    fixed = builder.prepare_makefile(configured, True)
    # Default/device configured graph remains exactly its previous source plan.
    assert 'stage.o' not in builder.prepare_makefile(configured, False)
    makefile.write_text(fixed)
    def check(label, full=True):
        events.write_text('')
        execute(['make', '-j4', *EXCLUSIONS, 'V=1'] if full else ['make', '-j4', *EXCLUSIONS, 'V=1', 'stage.o'], cwd=work if full else work / 'src')
        records = [json.loads(x) for x in events.read_text().splitlines()]
        starts = [i for i,x in enumerate(records) if x['stage'] and x['phase'] == 'begin']
        ends = [i for i,x in enumerate(records) if x['stage'] and x['phase'] == 'end' and x['exit'] == 0]
        assert len(starts) == len(ends) == 1 and starts[0] < ends[0], records
        compile = records[starts[0]]
        assert all(compile['headers'].values()), compile
        assert '-DSTRUIS_BUILD_GRAPH_CFLAG=120' in compile['args'] and '-DSTRUIS_BUILD_GRAPH_CPPFLAG=120' in compile['args']
        assert (work / 'src/stage.o').is_file()
        if full:
            links = [i for i,x in enumerate(records) if x['link'] and x['phase'] == 'begin']
            assert len(links) == 1 and ends[0] < links[0] and records[links[0]]['stageExists'], records
            assert (work / 'src/dash').is_file()
        print('PASS:', label)
        shutil.copy2(events, work / (label.replace(' ', '-') + '.jsonl'))
    check('fixed graph compiles real stage before link')
    stage_source = hashlib.sha256((work / 'src/stage.c').read_bytes()).hexdigest()
    execute(['make', *EXCLUSIONS, 'clean'])
    assert (work / 'src/stage.c').is_file() and hashlib.sha256((work / 'src/stage.c').read_bytes()).hexdigest() == stage_source
    assert not (work / 'src/stage.o').exists()
    assert all(not (work / 'src' / h).exists() for h in HEADERS)
    signals(work)
    check('direct stage target generates every required header', full=False)
    execute(['make', *EXCLUSIONS, 'clean']); signals(work)
    check('clean parallel rebuild preserves stage source and links')
    # Public ABI is still the actual implementation, not a placeholder object.
    symbols = subprocess.check_output(['nm', '-g', str(work / 'src/dash')], text=True)
    for name in ['StruisDashStageEnter', 'StruisDashSnapshotRetain', 'StruisDashInstallPipelineLauncher']:
        assert name in symbols
    report = dict(scope='Linux actual pinned configured make graph; no Apple SDK claim',
                  sourceRevision=builder.REVISION, work=str(work), cloud120FailureReproduced=True,
                  stageScheduledBeforeLink=True, configuredFlagsUsed=True, generatedHeadersOrdered=True,
                  directStageTarget=True, cleanSourcePreserved=True, cleanParallelRebuild=True,
                  realStageObjectSHA256=hashlib.sha256((work / 'src/stage.o').read_bytes()).hexdigest(),
                  buildScriptSHA256=hashlib.sha256((ROOT / 'Scripts/build-dash.py').read_bytes()).hexdigest())
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
    print('PENDING: Apple compile/link and signed SDK/runtime composition must be rerun after fresh review')
if __name__ == '__main__': main()
