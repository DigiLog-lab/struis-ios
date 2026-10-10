#!/usr/bin/env python3
"""Build the selected BSD command frameworks from auditable source inputs.

Regenerate parsers using public-domain Berkeley Yacc; do not compile the
upstream Bison skeletons. Build tools stay outside the application bundle.
"""
import concurrent.futures
import hashlib
import importlib.util
import os
import json
import pathlib
import plistlib
import re
import shlex
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'Vendor'
SOURCE = VENDOR / 'ios-system-source'
BUILD = ROOT / '.build' / 'bsd'
REVISIONS = {
    'ios-system-source': ('https://github.com/holzschu/ios_system.git', 'ebc045299e56edaf3509144d43a7f7348af400a7'),
    'byacc-source': ('https://github.com/ThomasDickey/byacc-snapshots.git', '7856d035dd27104782612818630adc5011214c31'),
}

def run(args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)

def prepare():
    VENDOR.mkdir(exist_ok=True)
    BUILD.mkdir(parents=True, exist_ok=True)
    for name, (url, revision) in REVISIONS.items():
        folder = VENDOR / name
        if not folder.exists():
            run(['git', 'init', folder])
            run(['git', '-C', folder, 'remote', 'add', 'origin', url])
        head = subprocess.run(['git', '-C', folder, 'rev-parse', 'HEAD'], text=True, capture_output=True)
        if head.returncode or head.stdout.strip() != revision:
            run(['git', '-C', folder, '-c', 'http.version=HTTP/1.1', 'fetch', '--depth', '1', 'origin', revision])
            run(['git', '-C', folder, 'checkout', '--detach', revision])
        actual = subprocess.check_output(['git', '-C', folder, 'rev-parse', 'HEAD'], text=True).strip()
        if actual != revision:
            raise RuntimeError(f'Unexpected source revision: {name}: {actual}')
    yacc_build = BUILD / 'byacc'
    if not yacc_build.exists():
        shutil.copytree(VENDOR / 'byacc-source', yacc_build, ignore=shutil.ignore_patterns('.git'))
    if not (yacc_build / 'yacc').exists():
        run(['./configure'], cwd=yacc_build)
        run(['make', '-j4'], cwd=yacc_build)
    if hashlib.sha256((SOURCE / 'shell_cmds/sleep/sleep.c').read_bytes()).hexdigest() != '1facf2eff0835204c223169c09d0c49f69f260f72065854656d33aa82ae1008d':
        raise RuntimeError('pinned BSD sleep source changed')
    generated = BUILD / 'generated'
    generated.mkdir(exist_ok=True)
    shutil.copytree(SOURCE / 'awk-awk-35/src', generated / 'awk', dirs_exist_ok=True)
    grammar = (SOURCE / 'awk-awk-35/src/awkgram.y').read_text()
    # Preserve the numeric token ABI used by awk's operation table. These are
    # interface constants, not the Bison parser implementation.
    token_ids = dict(re.findall(r'\b(\w+) = (\d+)', (SOURCE / 'awk-awk-35/src/awkgram.tab.h').read_text()))
    grammar = '\n'.join(re.sub(r'\b[A-Z][A-Z0-9_]*\b', lambda m: m[0] + (' ' + token_ids[m[0]] if m[0] in token_ids else ''), line) if line.startswith(('%token', '%left', '%right', '%nonassoc')) else line for line in grammar.splitlines()) + '\n'
    for declaration in ['Node\t*beginloc', 'Node\t*endloc', 'bool\tinfunc', 'int\tinloop', 'char\t*curfname', 'Node\t*arglist']:
        grammar = grammar.replace(declaration, '__thread ' + declaration)
    (generated / 'awk/awkgram.y').write_text(grammar)
    run([yacc_build / 'yacc', '-d', '-o', 'awkgram.tab.c', 'awkgram.y'], cwd=generated / 'awk')
    run([yacc_build / 'yacc', '-o', 'getdate.c', SOURCE / 'bsd_find/getdate.y'], cwd=generated)
    for name in ['awkgram.tab.c', 'awkgram.tab.h']:
        path = generated / 'awk' / name
        text = path.read_text()
        text = re.sub(r'(?m)^(extern )?YYSTYPE\s+yylval;', lambda m: (m[1] or '') + '__thread YYSTYPE yylval;', text)
        for variable in ['yychar', 'yynerrs', 'yyerrflag', 'yydebug']:
            text = re.sub(r'(?m)^(extern )?int\s+' + variable + r'\b', lambda m: (m[1] or '') + '__thread int ' + variable, text)
        if name.endswith('.c'):
            text = '#include "ios_error.h"\n' + text
        path.write_text(text)
    return generated


def inputs(project=None):
    if project is None:
        manifest = json.loads((ROOT / 'bsd-sources.lock.json').read_text())
        if manifest['sourceRevision'] != REVISIONS['ios-system-source'][1]:
            raise RuntimeError('BSD source manifest revision mismatch')
        return manifest['targets']
    objects = project['objects']
    paths = {}
    def visit(key, base):
        obj = objects[key]
        path = ((SOURCE if obj.get('sourceTree') == 'SOURCE_ROOT' else base) / obj.get('path', '')).resolve()
        paths[key] = path
        for child in obj.get('children', []):
            visit(child, path)
    visit(objects[project['rootObject']]['mainGroup'], SOURCE)
    result = {}
    for target in objects.values():
        if target.get('isa') != 'PBXNativeTarget' or target.get('name') not in ('ios_system', 'files', 'text', 'shell', 'awk'):
            continue
        source_files = []
        for phase in target['buildPhases']:
            phase = objects[phase]
            if phase['isa'] != 'PBXSourcesBuildPhase':
                continue
            for key in phase['files']:
                item = objects[key]
                path = paths[item['fileRef']]
                relative = path.relative_to(SOURCE).as_posix()
                # JavaScript and WebAssembly runtimes are not part of this toolset.
                if relative.startswith('wasm3/') or path.name in ('wasm3.c', 'source.swift', 'jsc.swift'):
                    continue
                source_files.append((relative, shlex.split(item.get('settings', {}).get('COMPILER_FLAGS', ''))))
        result[target['name']] = source_files
    if 'shell_cmds/sleep/sleep.c' not in {relative for relative, _ in result['shell']}:
        raise RuntimeError('pinned shell target lacks BSD sleep')
    return result


COMMAND_SCOPE_SUPPORT = '__struis_command_scope_support__.c'
COMMAND_SCOPE_EXPORTS = {'_StruisIosCommandScopeBegin', '_StruisIosCommandScopeEnd', '_StruisIosCommandPipelineStreams'} | {
    '_' + symbol for symbol in re.findall(r'\b(StruisCommandScope\w+)\(',
        (ROOT / 'CommandScopePreparation/CommandScope.h').read_text())
}

def command_scope_enabled(sdk, environment=None):
    """Explicit build preparation; device/default never acquire scoped code."""
    environment = os.environ if environment is None else environment
    value = environment.get('STRUIS_COMPOUND_DASH_PREPARATION', '')
    if value not in ('', '0', '1'):
        raise RuntimeError('STRUIS_COMPOUND_DASH_PREPARATION must be 0 or 1')
    return sdk == 'iphonesimulator' and value == '1'

def prepare_command_scope(generated):
    script = ROOT / 'Scripts/prepare-ios-command-scope.py'
    spec = importlib.util.spec_from_file_location('hyotan_ios_command_scope', script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.prepare(SOURCE, generated / 'command-scope')

def command_scope_entries(name, entries, scope):
    result = list(entries)
    if scope is not None and name == 'ios_system':
        required = {'ios_system.m', 'libc_replacement.c'}
        if not required.issubset({relative for relative, _ in result}):
            raise RuntimeError('ios_system target lacks the pinned command-scope sources')
        result.append((COMMAND_SCOPE_SUPPORT, []))
    return result

def source_for_entry(relative, generated, scope=None):
    if scope is not None and relative in ('ios_system.m', 'libc_replacement.c'):
        return scope / relative
    if relative == COMMAND_SCOPE_SUPPORT:
        if scope is None:
            raise RuntimeError('Command scope support cannot enter a default SDK graph')
        return scope / 'CommandScope.c'
    if relative.startswith('awk-awk-35/src/'):
        return generated / 'awk' / pathlib.Path(relative).name
    if relative == 'bsd_find/y.tab.c':
        return generated / 'getdate.c'
    return SOURCE / relative

def verify_command_scope_exports(binary, enabled):
    output = subprocess.check_output(['xcrun', 'nm', '-gU', str(binary)], text=True)
    symbols = {line.split()[-1] for line in output.splitlines() if line.split()}
    present = {symbol for symbol in symbols
               if symbol.startswith(('_StruisCommandScope', '_StruisIosCommand'))}
    if (enabled and present != COMMAND_SCOPE_EXPORTS) or (not enabled and present):
        raise RuntimeError('ios_system command-scope export graph does not match SDK preparation mode')
    return sorted(present)

def build(sdk, target, generated, source_files):
    enabled = command_scope_enabled(sdk)
    scope = prepare_command_scope(generated) if enabled else None
    sdkroot = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
    destination = BUILD / sdk
    destination.mkdir(exist_ok=True)
    for name in ('ios_system', 'files', 'text', 'shell', 'awk'):
        framework = destination / (name + '.framework')
        framework.mkdir(exist_ok=True)
        flags = ['clang', '-target', target, '-isysroot', sdkroot, '-O2', '-fPIC', '-fobjc-arc', '-fmodules', '-fmodules-cache-path=' + str(BUILD / 'ModuleCache'), '-I', generated, '-I', SOURCE, '-I', SOURCE / 'ios_system', '-I', SOURCE / 'libutil', '-I', SOURCE / 'awk-awk-35/src', '-Wno-error=implicit-function-declaration', '-Wno-error=int-conversion', '-F', destination]
        if scope is not None:
            flags.extend(['-I', scope])
        entries = command_scope_entries(name, source_files[name], scope)
        objects = []
        def compile_source(entry):
            relative, extra = entry
            source = source_for_entry(relative, generated, scope)
            output = destination / (name + '-' + hashlib.sha256(relative.encode()).hexdigest()[:16] + '.o')
            run(flags + extra + ['-c', source, '-o', output], cwd=SOURCE)
            return output
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            objects = list(pool.map(compile_source, entries))
        links = [] if name == 'ios_system' else ['-framework', 'ios_system']
        run(['clang', '-target', target, '-isysroot', sdkroot, '-dynamiclib', '-install_name', f'@rpath/{name}.framework/{name}', '-F', destination, *objects, *links, '-framework', 'Foundation', '-framework', 'UIKit', '-framework', 'AVFoundation', '-framework', 'AudioToolbox', '-lcurses', '-lz', '-lbz2', '-lresolv', '-liconv', '-o', framework / name])
        (framework / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': name, 'CFBundleIdentifier': 'org.digiloglab.hyotan.' + name.replace('_','-'), 'CFBundleName': name, 'CFBundlePackageType': 'FMWK', 'CFBundleShortVersionString': '0.1', 'CFBundleVersion': '1', 'MinimumOSVersion': '18.4', 'CFBundleSupportedPlatforms': ['iPhoneSimulator' if sdk == 'iphonesimulator' else 'iPhoneOS']}))
        if name == 'ios_system':
            headers = framework / 'Headers'
            headers.mkdir(exist_ok=True)
            shutil.copy2(SOURCE / 'ios_system/ios_system.h', headers)
            scope_header = headers / 'IosCommandScope.h'
            if scope is not None:
                shutil.copy2(scope / 'IosCommandScope.h', scope_header)
            elif scope_header.exists():
                scope_header.unlink()  # never retain a header from a previous opt-in build
            exports = verify_command_scope_exports(framework / name, enabled)
            source_hashes = {
                relative: hashlib.sha256(source_for_entry(relative, generated, scope).read_bytes()).hexdigest()
                for relative, _ in entries
            }
            metadata = {'sdk': sdk, 'enabled': enabled, 'exports': exports, 'source_sha256': source_hashes}
            if enabled:
                metadata['support_license_sha256'] = hashlib.sha256((ROOT / 'CommandScopePreparation/LICENSE').read_bytes()).hexdigest()
                metadata['private_header_sha256'] = hashlib.sha256(scope_header.read_bytes()).hexdigest()
            (destination / 'command-scope-preparation.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
            modules = framework / 'Modules'
            modules.mkdir(exist_ok=True)
            extra_header = ' header "IosCommandScope.h"' if enabled else ''
            (modules / 'module.modulemap').write_text('framework module ios_system { umbrella header "ios_system.h"' + extra_header + ' export * }\n')
    return destination

if __name__ == '__main__':
    generated = prepare()
    source_files = inputs()
    device = build('iphoneos', 'arm64-apple-ios18.4', generated, source_files)
    simulator = build('iphonesimulator', 'arm64-apple-ios18.4-simulator', generated, source_files)
    for name in source_files:
        output = VENDOR / (name + '-native.xcframework')
        if output.exists():
            shutil.rmtree(output)
        run(['xcodebuild', '-create-xcframework', '-framework', device / (name + '.framework'), '-framework', simulator / (name + '.framework'), '-output', output])
    (BUILD / 'sources.json').write_text(json.dumps(source_files, indent=2) + '\n')
