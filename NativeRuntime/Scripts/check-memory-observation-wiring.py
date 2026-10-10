#!/usr/bin/env python3
"""Execute actual project generation in a disposable copy; no Apple build claim."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
INSPECT = r'''require 'xcodeproj'
require 'json'
p = Xcodeproj::Project.open(ARGV.fetch(0))
puts JSON.generate(p.targets.to_h { |t| [t.name, {
  sources: t.source_build_phase.files.map { |f| (f.file_ref&.path || f.product_ref&.product_name) }.compact.sort,
  frameworks: t.frameworks_build_phase.files.map { |f| (f.file_ref&.path || f.product_ref&.product_name) }.compact.sort
}] })
'''
REMOVE = r'''require 'xcodeproj'
p = Xcodeproj::Project.open(ARGV.fetch(0))
p.targets.find { |t| t.name == 'strius' }.source_build_phase.files.to_a.each do |f|
  f.remove_from_project if f.file_ref.path == 'Worker/NativeMemory.m'
end
p.save
'''


def run(args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ruby', default=shutil.which('ruby'))
    args = parser.parse_args()
    if not args.ruby:
        raise SystemExit('Ruby + xcodeproj are required; no fake generator fallback')
    scheme = ET.parse(ROOT / 'strius.xcodeproj/xcshareddata/xcschemes/StruisNativeRuntimeTests.xcscheme')
    selected = {test.attrib['Identifier'] for test in scheme.findall('.//SelectedTests/Test')}
    assert {'NativeMemoryObservationTests', 'NativeRuntimeLiveTests'} <= selected
    with tempfile.TemporaryDirectory(prefix='hyotan-memory-wiring-') as temporary:
        project_root = pathlib.Path(temporary)
        project = project_root / 'strius.xcodeproj'
        shutil.copytree(ROOT / 'strius.xcodeproj', project)
        scripts = project_root / 'scripts'
        scripts.mkdir()
        generator = scripts / 'sync_native_runtime.rb'
        shutil.copyfile(ROOT / 'scripts/sync_native_runtime.rb', generator)
        before = json.loads(run([args.ruby, '-e', INSPECT, str(project)]))
        # Exercise missing membership repair, rather than merely re-save a prepared project.
        run([args.ruby, '-e', REMOVE, str(project)])
        run([args.ruby, str(generator)])
        first = (project / 'project.pbxproj').read_bytes()
        after = json.loads(run([args.ruby, '-e', INSPECT, str(project)]))
        for name in ('strius', 'StruisRuntime', 'StruisExec'):
            assert after[name]['sources'].count('Worker/NativeMemory.m') == 1, name
            assert before[name]['frameworks'] == after[name]['frameworks'], name
            assert before[name]['sources'] == after[name]['sources'], name
        run([args.ruby, str(generator)])
        assert first == (project / 'project.pbxproj').read_bytes(), 'generator not idempotent'
        print('PASS actual Ruby generator repairs host telemetry membership; one source in host/Codex/Exec')
        print('PASS regenerated source and framework memberships unchanged; no model/command dependency added to host')
        print('PASS second generation byte-identical SHA256=' + hashlib.sha256(first).hexdigest())
    print('PASS dedicated scheme selects compatibility/identity fixtures and live endpoint tests')
    print('LIMIT Swift/Mach/XPC execution and real-device memory evidence not performed on Linux')


if __name__ == '__main__':
    main()
