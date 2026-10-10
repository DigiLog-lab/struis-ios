#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent fixed Git-history assets, only for the opt-in Simulator test bundle."""
import argparse,hashlib,json,os,shutil,tempfile,zipfile
from pathlib import Path,PurePosixPath
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'VirtualPythonGit'

def regular(path):
    if path.is_symlink()or not path.is_file()or not 0<=path.stat().st_size<=8*1024*1024:raise ValueError('fixed Git regular asset required')
    return path.read_bytes()

def generate(destination):
    pins=json.loads(regular(SOURCE/'pins.json'))
    names={'loader.js','packages.zip','hyotan_history.py','hyotan_virtual_git.py','Licenses/Dulwich.txt','Licenses/urllib3.txt'}
    if pins['format_version']!=1 or set(pins['files'])!=names or pins['packages']!={'dulwich':'1.2.15','urllib3':'2.8.0'}or pins['selected_licenses']!={'dulwich':'Apache-2.0','urllib3':'MIT'}:raise ValueError('Git pins mismatch')
    payload={}
    for name in sorted(names):
        data=regular(SOURCE/name);record=pins['files'][name]
        if set(record)!={'bytes','sha256'}or record['bytes']!=len(data)or record['sha256']!=hashlib.sha256(data).hexdigest():raise ValueError('Git asset pin mismatch: '+name)
        payload[name]=data
    manifest=json.loads(regular(SOURCE/'package-manifest.json'))
    with zipfile.ZipFile(SOURCE/'packages.zip')as archive:
        entries=archive.infolist()
        if len(entries)!=len(manifest)or len({e.filename for e in entries})!=len(entries):raise ValueError('Git package entries mismatch')
        for entry in entries:
            path=PurePosixPath(entry.filename)
            if path.is_absolute()or '..'in path.parts or path.parts[0]not in ('dulwich','urllib3')or path.suffix!='.py'or entry.file_size>2*1024*1024:raise ValueError('Git archive entry rejected')
            data=archive.read(entry)
            if hashlib.sha256(data).hexdigest()!=manifest[entry.filename]or data!=regular(ROOT/'PythonModules'/entry.filename):raise ValueError('Git package source pin mismatch')
    if destination.is_symlink():raise ValueError('Git test root cannot be symlink')
    destination.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='virtual-git-assets-',dir=destination.parent)as temporary:
        stage=Path(temporary)/'assets';stage.mkdir();(stage/'.gitkeep').touch()
        for name,data in payload.items():
            path=stage/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
        (stage/'manifest.json').write_text(json.dumps(pins,indent=2)+'\n')
        if destination.exists():shutil.rmtree(destination)
        os.replace(stage,destination)
    print('PASS independent test-only Git assets: six fixed hashes; Dulwich1.2.15 Apache-2.0 / urllib3 2.8.0 MIT; no stock-base pin/count changes')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--destination',type=Path,default=ROOT/'VirtualPythonGitTestAssets');generate(parser.parse_args().destination)
