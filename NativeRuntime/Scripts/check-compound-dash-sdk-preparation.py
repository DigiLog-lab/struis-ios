#!/usr/bin/env python3
"""Finite SDK source/header/export-plan preflight. Apple link/runtime are pending.
This executes the exact source selector used by build-bsd; it is not a compiler
or evaluator substitute and never reports a mocked Apple build as successful.
"""
import argparse
import hashlib
import importlib.util
import json
import re
import pathlib
import shutil
import subprocess
import tempfile
ROOT = pathlib.Path(__file__).resolve().parents[1]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def read_pinned_project(path):
    """Read the finite OpenStep source graph without requiring Apple's plutil.

    The production selector below receives this entire graph, not a synthetic
    list of three sources. Unknown syntax fails closed. On Apple we additionally
    compare this parse with plutil before passing it to the same selector.
    """
    token = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', re.S)
    tokens = [m[0] for m in token.finditer(path.read_text())
              if not m[0].isspace() and not m[0].startswith(('/*', '//'))]
    index = 0
    def take(expected=None):
        nonlocal index
        value = tokens[index]
        index += 1
        if expected is not None and value != expected:
            raise ValueError(f'Expected {expected!r}, got {value!r}')
        return value
    def value():
        item = take()
        if item == '{':
            result = {}
            while tokens[index] != '}':
                key = take()
                key = json.loads(key) if key.startswith('"') else key
                take('=')
                if key in result:
                    raise ValueError('Duplicate OpenStep key')
                result[key] = value()
                take(';')
            take('}')
            return result
        if item == '(':
            result = []
            while tokens[index] != ')':
                result.append(value())
                if tokens[index] != ')':
                    take(',')
            take(')')
            return result
        if item in ('}', ')', '=', ';', ','):
            raise ValueError('Unexpected OpenStep punctuation')
        return json.loads(item) if item.startswith('"') else item
    result = value()
    if index != len(tokens):
        raise ValueError('Trailing OpenStep tokens')
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=pathlib.Path, required=True)
    args = parser.parse_args()
    bsd = load('sdk_bsd_preparation', ROOT / 'Scripts/build-bsd.py')
    args.source = args.source.resolve()
    bsd.SOURCE = args.source
    revision = subprocess.check_output(['git', '-C', str(args.source), 'rev-parse', 'HEAD'], text=True).strip()
    assert revision == bsd.REVISIONS['ios-system-source'][1], 'unpinned source revision'
    project_path = args.source / 'ios_system.xcodeproj/project.pbxproj'
    project = read_pinned_project(project_path)
    # Apple can independently check the portable parse against its native parser.
    native = None
    if shutil.which('plutil'):
        native = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project_path)]))
    graphs = bsd.inputs(project)
    if native is not None:
        assert bsd.inputs(native) == graphs
    assert set(graphs) == {'ios_system', 'files', 'text', 'shell', 'awk'}
    assert {'ios_system.m', 'libc_replacement.c'}.issubset({relative for relative, _ in graphs['ios_system']})
    pinned_paths = {relative for entries in graphs.values() for relative, _ in entries}
    pinned_paths.update({'ios_system.xcodeproj/project.pbxproj', 'awk-awk-35/src/awkgram.y', 'bsd_find/getdate.y'})
    subprocess.run(['git', '-C', str(args.source), 'diff', '--exit-code', 'HEAD', '--', *sorted(pinned_paths)], check=True, stdout=subprocess.DEVNULL)
    print(f'PROJECT {hashlib.sha256(project_path.read_bytes()).hexdigest()} revision={revision}')
    assert not bsd.command_scope_enabled('iphonesimulator', {})
    assert not bsd.command_scope_enabled('iphoneos', {'STRUIS_COMPOUND_DASH_PREPARATION': '1'})
    assert not bsd.command_scope_enabled('iphonesimulator', {'STRUIS_COMPOUND_DASH_PREPARATION': '0'})
    assert bsd.command_scope_enabled('iphonesimulator', {'STRUIS_COMPOUND_DASH_PREPARATION': '1'})
    try:
        bsd.command_scope_enabled('iphonesimulator', {'STRUIS_COMPOUND_DASH_PREPARATION': 'invalid'})
    except RuntimeError:
        pass
    else:
        raise AssertionError('ambiguous preparation selector accepted')
    original = graphs['ios_system']
    with tempfile.TemporaryDirectory(prefix='hyotan-compound-sdk-') as directory:
        generated = pathlib.Path(directory)
        scope = bsd.prepare_command_scope(generated)
        baseline = bsd.command_scope_entries('ios_system', original, None)
        assert baseline == original
        assert bsd.source_for_entry('ios_system.m', generated, None) == args.source / 'ios_system.m'
        planned = bsd.command_scope_entries('ios_system', original, scope)
        assert sum(relative == bsd.COMMAND_SCOPE_SUPPORT for relative, _ in planned) == 1
        assert original == baseline  # no mutation of common device/default inputs
        assert bsd.command_scope_entries('files', [('dd.c', [])], scope) == [('dd.c', [])]
        assert bsd.source_for_entry('ios_system.m', generated, scope) == scope / 'ios_system.m'
        assert bsd.source_for_entry('libc_replacement.c', generated, scope) == scope / 'libc_replacement.c'
        assert bsd.source_for_entry('getopt.c', generated, scope) == args.source / 'getopt.c'
        assert bsd.source_for_entry(bsd.COMMAND_SCOPE_SUPPORT, generated, scope) == scope / 'CommandScope.c'
        try:
            bsd.source_for_entry(bsd.COMMAND_SCOPE_SUPPORT, generated, None)
        except RuntimeError:
            pass
        else:
            raise AssertionError('scope object entered default SDK graph')
        try:
            bsd.command_scope_entries('ios_system', [('ios_system.m', [])], scope)
        except RuntimeError:
            pass
        else:
            raise AssertionError('incomplete actual framework target accepted')
        # Compile the actual private header as C; full ObjC/Apple SDK remains pending.
        probe = generated / 'header.c'
        probe.write_text('#include "IosCommandScope.h"\n'
                         'typedef int (*Begin)(FILE *,FILE *,FILE *,void *);\n'
                         'typedef int (*End)(void);\n'
                         'typedef int (*Streams)(FILE **,FILE **,FILE **,void **);\n'
                         'Begin begin = StruisIosCommandScopeBegin;\n'
                         'End end = StruisIosCommandScopeEnd;\n'
                         'Streams streams = StruisIosCommandPipelineStreams;\n')
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsyntax-only', '-I', str(scope), str(probe)], check=True)
        # Every actual selected source and its per-file flags are covered. Parser
        # outputs are mapped to their real generator inputs; regeneration/compile
        # remain Apple build work, rather than fabricated generated bytes here.
        for name, original_entries in sorted(graphs.items()):
            assert len({relative for relative, _ in original_entries}) == len(original_entries)
            selected = bsd.command_scope_entries(name, original_entries, scope)
            if name != 'ios_system':
                assert selected == original_entries
            for relative, flags in selected:
                path = bsd.source_for_entry(relative, generated, scope)
                baseline_path = bsd.source_for_entry(relative, generated, None) if relative != bsd.COMMAND_SCOPE_SUPPORT else None
                if relative not in ('ios_system.m', 'libc_replacement.c', bsd.COMMAND_SCOPE_SUPPORT):
                    assert path == baseline_path
                if relative.startswith('awk-awk-35/src/'):
                    assert path == generated / 'awk' / pathlib.Path(relative).name
                    path = args.source / relative
                    kind = 'GENERATOR_INPUT' if relative.endswith(('awkgram.tab.c', 'awkgram.tab.h')) else 'COPIED_INPUT'
                    if kind == 'GENERATOR_INPUT':
                        path = args.source / 'awk-awk-35/src/awkgram.y'
                elif relative == 'bsd_find/y.tab.c':
                    assert path == generated / 'getdate.c'
                    path = args.source / 'bsd_find/getdate.y'
                    kind = 'GENERATOR_INPUT'
                else:
                    kind = 'SOURCE'
                assert path.is_file(), str(path)
                print(f'{kind} {name} {relative} {hashlib.sha256(path.read_bytes()).hexdigest()} flags={json.dumps(flags)}')
            print(f'GRAPH {name} sources={len(selected)}')
        for name in ('CommandScope.h', 'IosCommandScope.h'):
            print(f'HEADER {name} {hashlib.sha256((scope / name).read_bytes()).hexdigest()}')
        print('REQUIRED_EXPORTS ' + ' '.join(sorted(bsd.COMMAND_SCOPE_EXPORTS)))
    print('PASS: all five pinned framework source graphs; explicit simulator-only source plan; default/device inputs unchanged; one scope object; typed private header')
    print('PENDING: actual Berkeley Yacc regeneration and Apple C/Objective-C compile (including exception/TeX cleanup), xcrun nm export/link checks, signed Dash/provider composition and test-scheme runtime')
if __name__ == '__main__':
    main()
