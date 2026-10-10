#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Actual browser Pyodide -> SAB -> async HTTP -> trusted operations C ABI check.

Linux preparation only. No app configuration, credentials or production toggle.
"""
import argparse,base64,ctypes as C,errno,hashlib,json,os,subprocess,tempfile,threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
ROOT=Path(__file__).resolve().parents[1]
if not os.environ.get('STRUIS_TEST_DELEGATE_FILE'):
    raise SystemExit('SKIP: STRUIS_TEST_DELEGATE_FILE is unset; shipped delegate.py is an external input')
class Metadata(C.Structure):
    _fields_=[('bytes',C.c_uint64),('created',C.c_uint64),('modified',C.c_uint64),('flags',C.c_uint32),('reserved',C.c_uint32)]
class Broker:
    def __init__(self,library,root,descriptor_limits=None):
        self.descriptor_limits=descriptor_limits
        self.lib=C.CDLL(str(library));self.lock=threading.Lock();self.events=[];self.instances=[];self.revoke_open=None;self.revoke_done=threading.Event();self.revoked_handle=None
        V=C.c_void_p;U=C.c_uint64;S=C.c_size_t;P=C.POINTER
        signatures={'create_with_descriptor_limits':[C.c_int,C.c_char_p,U,C.c_uint32,U,U,P(V)],'descriptor_limits':[V,P(U),P(U),P(C.c_uint32)],'create':[C.c_int,C.c_char_p,U,C.c_uint32,P(V)],'revoke':[V],'destroy':[V],'open':[V,V,S,C.c_uint32,P(U)],'read_at':[V,U,U,S,V,S,P(S)],'write_at':[V,U,U,V,S,P(S)],'truncate':[V,U,U],'stat':[V,U,P(Metadata)],'close':[V,U],'metadata':[V,V,S,P(Metadata)],'list':[V,V,S,V,S,P(S),P(S),P(S)],'mkdir':[V,V,S],'remove':[V,V,S,C.c_uint32],'rename':[V,V,S,V,S]}
        for name,sig in signatures.items():
            f=getattr(self.lib,'hyotan_operations_'+name);f.argtypes=sig;f.restype=C.c_int
        self.lib.hyotan_operations_error_message.argtypes=[C.c_int];self.lib.hyotan_operations_error_message.restype=C.c_char_p
        self.instance=self.create(root,1);self.other=self.create(root,2)
        h=U();p=b'foreign';self.checked(self.lib.hyotan_operations_open(self.other,p,len(p),2|4,h));self.foreign=str(h.value)
    def create(self,root,generation):
        fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);instance=C.c_void_p()
        try:
            if self.descriptor_limits is None:self.checked(self.lib.hyotan_operations_create(fd,b'trusted-browser-fixture',generation,2,C.byref(instance)))
            else:self.checked(self.lib.hyotan_operations_create_with_descriptor_limits(fd,b'trusted-browser-fixture',generation,2,*self.descriptor_limits,C.byref(instance)))
        finally:os.close(fd)
        self.instances.append(instance);return instance
    @staticmethod
    def checked(code):
        if code:raise OSError(code,'operations failure')
    def stop(self):
        
        for instance in self.instances:self.lib.hyotan_operations_destroy(instance)
    @staticmethod
    def number(v):
        if not isinstance(v,str) or not v.isascii() or not v.isdigit() or len(v)>20 or int(v)>2**64-1:raise ValueError('integer envelope')
        return int(v)
    def execute(self,instance,r):
        seq=r.get('sequence');out={'sequence':seq};code=0
        try:
            if type(seq)is not int or not 1<=seq<2**31:raise ValueError('sequence')
            op=r.get('operation');allowed={'descriptorPolicy':set(),'open':{'path','flags'},'metadata':{'path'},'list':{'path'},'mkdir':{'path'},'remove':{'path','recursive'},'rename':{'source','destination'},'read':{'handle','offset','length'},'write':{'handle','offset','data'},'truncate':{'handle','length'},'stat':{'handle'},'close':{'handle'}}
            if op not in allowed or set(r)!={'sequence','operation'}|allowed[op]:raise ValueError('operation envelope')
            p=None
            if 'path'in r:
                if not isinstance(r['path'],str):raise ValueError('path')
                p=r['path'].encode('utf-8')
                if len(p)>4096:raise ValueError('path budget')
            rename_paths=[]
            for key in ('source','destination') if op=='rename' else ():
                if not isinstance(r[key],str):raise ValueError('path')
                encoded=r[key].encode('utf-8')
                if len(encoded)>4096:raise ValueError('path budget')
                rename_paths.append(encoded)
            h=self.number(r['handle']) if 'handle'in r else None
            n=C.c_size_t();m=Metadata()
            if op=='descriptorPolicy':
                read=C.c_uint64();write=C.c_uint64();configured=C.c_uint32();code=self.lib.hyotan_operations_descriptor_limits(instance,C.byref(read),C.byref(write),C.byref(configured));out['policy']={'readExtent':str(read.value),'writeExtent':str(write.value),'configured':bool(configured.value)}
            elif op=='open':
                if type(r['flags'])is not int or not 0<r['flags']<64:raise ValueError('flags')
                handle=C.c_uint64();code=self.lib.hyotan_operations_open(instance,p,len(p),r['flags'],C.byref(handle));out['handle']=str(handle.value)
            elif op=='metadata':code=self.lib.hyotan_operations_metadata(instance,p,len(p),C.byref(m))
            elif op=='stat':code=self.lib.hyotan_operations_stat(instance,h,C.byref(m))
            elif op=='close':code=self.lib.hyotan_operations_close(instance,h)
            elif op=='truncate':code=self.lib.hyotan_operations_truncate(instance,h,self.number(r['length']))
            elif op=='read':
                length=r['length']
                if type(length)is not int or not 0<=length<=16384:raise ValueError('chunk')
                b=C.create_string_buffer(length);code=self.lib.hyotan_operations_read_at(instance,h,self.number(r['offset']),length,b,length,C.byref(n));out['data']=base64.b64encode(b.raw[:n.value]).decode('ascii')
            elif op=='write':
                if not isinstance(r['data'],str) or len(r['data'])>21848:raise ValueError('chunk')
                data=base64.b64decode(r['data'],validate=True)
                if len(data)>16384:raise ValueError('chunk')
                code=self.lib.hyotan_operations_write_at(instance,h,self.number(r['offset']),data,len(data),C.byref(n));out['written']=n.value
            elif op=='list':
                b=C.create_string_buffer(32768);entries=C.c_size_t();needed=C.c_size_t();code=self.lib.hyotan_operations_list(instance,p,len(p),b,len(b),C.byref(n),C.byref(entries),C.byref(needed));out['names']=[s.decode('utf8') for s in b.raw[:n.value].split(b'\0') if s]
            elif op=='rename':
                source,destination=rename_paths
                code=self.lib.hyotan_operations_rename(instance,source,len(source),destination,len(destination))
            elif op=='mkdir':code=self.lib.hyotan_operations_mkdir(instance,p,len(p))
            elif op=='remove':
                if r['recursive']is not False:raise ValueError('recursive unsupported')
                code=self.lib.hyotan_operations_remove(instance,p,len(p),0)
            if op in ('metadata','stat'):out['metadata']={'directory':bool(m.flags&1),'bytes':m.bytes,'created':m.created if m.flags&2 else None,'modified':m.modified if m.flags&4 else None}
        except (ValueError,UnicodeError,TypeError,OverflowError):code=errno.EINVAL
        if code:
            out={'sequence':seq,'errno':errno.errorcode.get(code,'EIO'),'message':self.lib.hyotan_operations_error_message(code).decode('utf8')}
        self.events.append({'operation':r.get('operation'),'errno':out.get('errno',0)})
        return out

def unique_keys(pairs):
    result={}
    for key,value in pairs:
        if key in result:raise ValueError('duplicate JSON key')
        result[key]=value
    return result
class BoundedServer(ThreadingHTTPServer):
    daemon_threads=False
    def __init__(self,*args):
        self.slots=threading.BoundedSemaphore(16);super().__init__(*args)
    def process_request(self,request,address):
        if not self.slots.acquire(blocking=False):self.shutdown_request(request);return
        try:super().process_request(request,address)
        except BaseException:self.slots.release();raise
    def process_request_thread(self,request,address):
        try:super().process_request_thread(request,address)
        finally:self.slots.release()

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--library',type=Path,help='Use an already compiled actual operations C ABI for isolated preparation');parser.add_argument('--assets',type=Path,default=Path('/tmp/hyotan-pyodide-feasibility/PythonResources'));parser.add_argument('--target-dir',type=Path,default=Path('/workspace/hyotan-virtual-python-check/target'));parser.add_argument('--evidence',type=Path,default=Path('/workspace/hyotan-virtual-python-check/evidence.json'));args=parser.parse_args()
    if args.library is None:subprocess.run(['cargo','rustc','--offline','--locked','--manifest-path',str(ROOT/'NativeCodex/Cargo.toml'),'--no-default-features','--features','operations','--lib','--crate-type','cdylib','--target-dir',str(args.target_dir)],check=True)
    inventory=json.loads((ROOT/'VirtualPython/resources.js').read_text().split('export const resources = ',1)[1].rstrip(';\n'))
    for name,expected in inventory.items():
        if hashlib.sha256((args.assets/name).read_bytes()).hexdigest()!=expected:raise RuntimeError('pinned resource mismatch: '+name)
    with tempfile.TemporaryDirectory(prefix='hyotan-virtual-fs-')as directory:
        base=Path(directory);work=base/'workspace';work.mkdir();private=base/'private-canary';private.write_bytes(b'synthetic private');os.symlink(private,work/'escape');os.link(private,work/'hard');os.symlink(base,work/'ancestor')
        broker=Broker(args.library or args.target_dir/'debug/libhyotan_codex.so',work)
        scripts={name:(ROOT/'VirtualPython'/name).read_bytes() for name in ['main.js','worker.js','filesystem.js']}
        html=b'''<!doctype html><pre id=result>RUNNING</pre><script type=module>import{runVirtualPython}from'./main.js';globalThis.run=async code=>{const r=await runVirtualPython(code);document.querySelector('#result').textContent=JSON.stringify(r);return r;};</script>'''
        class Handler(BaseHTTPRequestHandler):
            native_instance=broker.instance
            def setup(self):
                self.request.settimeout(3);super().setup()
            def origin(self):return f'http://127.0.0.1:{self.server.server_port}'
            def host_valid(self):return self.headers.get('Host')==f'127.0.0.1:{self.server.server_port}'
            def log_message(self,*a):pass
            def respond(self,data,kind='application/json'):
                self.send_response(200)
                for k,v in {'Content-Type':kind,'Content-Length':str(len(data)),'Connection':'close','Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp','Cross-Origin-Resource-Policy':'same-origin','Cache-Control':'no-store','Content-Security-Policy':"default-src 'none'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; worker-src 'self'; connect-src 'self'"}.items():self.send_header(k,v)
                self.end_headers();self.wfile.write(data)
            def do_GET(self):
                if not self.host_valid():self.send_error(403);return
                if self.path=='/':self.respond(html,'text/html')
                elif self.path[1:]in scripts:self.respond(scripts[self.path[1:]],'application/javascript')
                elif self.path.startswith('/py/')and self.path[4:]in inventory:self.respond((args.assets/self.path[4:]).read_bytes(),'application/javascript' if self.path.endswith(('.js','.mjs')) else 'application/wasm' if self.path.endswith('.wasm')else 'application/octet-stream')
                else:self.send_error(404)
            def do_POST(self):
                try:
                    if not self.host_valid() or self.headers.get('Origin')!=self.origin() or self.headers.get('Content-Type')!='application/json':raise ValueError()
                    length=int(self.headers.get('Content-Length','0'))
                    if self.path!='/broker' or not 1<=length<=65536 or self.headers.get('Transfer-Encoding'):raise ValueError()
                    r=json.loads(self.rfile.read(length).decode('utf8'),object_pairs_hook=unique_keys)
                    if not isinstance(r,dict):raise ValueError()
                    with broker.lock:result=broker.execute(self.native_instance,r)
                    if broker.revoke_open is not None and r.get('operation')=='open' and r.get('path')=='日本語.bin' and 'handle'in result:
                        broker.revoked_handle=result['handle'];broker.revoke_open.set()
                        if not broker.revoke_done.wait(3):raise ValueError('trusted revoke timeout')
                    data=json.dumps(result,ensure_ascii=False).encode('utf8')
                    if len(data)>65536:raise ValueError()
                    self.respond(data)
                except (ValueError,UnicodeError,RecursionError):self.send_error(400)
        server=BoundedServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        servers=[server]
        try:
            from playwright.sync_api import sync_playwright
            with sync_playwright()as p:
                browser=p.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox','--disable-dev-shm-usage','--disable-background-networking']);page=browser.new_page();page.on('console',lambda message:print(message.text,flush=True));page.goto(f'http://127.0.0.1:{server.server_port}/');page.wait_for_function('typeof globalThis.run === "function"')
                delegate_path=os.environ.get('STRUIS_TEST_DELEGATE_FILE')
                if not delegate_path:raise SystemExit('SKIP: STRUIS_TEST_DELEGATE_FILE is unset; shipped delegate.py is an external input')
                delegate_source=Path(delegate_path).read_text()
                publication=delegate_source.split('    deadline =',1)[0]
                # Execute the shipped parsing/confinement/publication source itself;
                # only the polling suffix is excluded from this filesystem check.
                code=TEST_CODE.replace('FOREIGN_HANDLE',broker.foreign).replace('DELEGATE_PUBLICATION',repr(publication))
                result=page.evaluate('code=>globalThis.run(code)',code)
                if not result['success']:raise RuntimeError(result)
                report=json.loads(result['value']);assert report['foreign']=='EACCES';assert all(v in ['PermissionError','FileNotFoundError']for v in report['escapes'].values());assert private.read_bytes()==b'synthetic private';assert (work/'計算.yaml').exists();assert report['solve']==[1.6,1.8];assert report['bridge_denials']==['EACCES']*4;assert report['envelope_denials']==['EINVAL']*3
                assert result['deniedOperations'] and len(result['deniedOperations'])<=16
                assert all(set(d)=={'operation','errno','message'} and d['errno']=='EACCES' and 'active workspace'in d['message'] for d in result['deniedOperations'])
                # Trusted driver arms a one-shot barrier; no guest request can mint authority.
                broker.revoke_open=threading.Event()
                def revoke_open_handle():
                    if broker.revoke_open.wait(20):
                        with broker.lock:broker.checked(broker.lib.hyotan_operations_revoke(broker.instance))
                        broker.revoke_done.set()
                revoker=threading.Thread(target=revoke_open_handle);revoker.start()
                denied=page.evaluate('code=>globalThis.run(code)',"import os\nfrom pathlib import Path\ntarget=Path('/workspace/rename-dest'); target.stat()\nf=Path('/workspace/日本語.bin').open('rb')\ntry:f.read(1)\nexcept PermissionError:pass\nos.replace(target,target)")
                revoker.join(21);assert not revoker.is_alive();assert broker.revoke_done.is_set();broker.revoke_open=None
                assert not denied['success'] and 'PermissionError'in denied['error'] and 'active workspace'in denied['error'],denied
                same_path=page.evaluate('code=>globalThis.run(code)',"import os; os.replace('/workspace/rename-dest','/workspace/rename-dest')");assert not same_path['success'],same_path
                assert denied['deniedOperations'] and any(d['operation']=='rename' for d in denied['deniedOperations']) and all(set(d)=={'operation','errno','message'} for d in denied['deniedOperations']),denied
                with broker.lock:fresh_instance=broker.create(work,3)
                class FreshHandler(Handler):native_instance=fresh_instance
                fresh_server=BoundedServer(('127.0.0.1',0),FreshHandler);servers.append(fresh_server);threading.Thread(target=fresh_server.serve_forever,daemon=True).start()
                fresh_page=browser.new_page();fresh_page.goto(f'http://127.0.0.1:{fresh_server.server_port}/');fresh_page.wait_for_function('typeof globalThis.run === "function"')
                fresh_code="from pathlib import Path; import js; Path('/workspace/next.txt').write_text('next'); assert js.virtualFSRequest(js.JSON.parse("+repr(json.dumps({'operation':'read','handle':broker.revoked_handle,'offset':'0','length':1}))+")).errno == 'EACCES'; 'fresh'"
                fresh=fresh_page.evaluate('code=>globalThis.run(code)',fresh_code)
                assert fresh['success'],fresh
                stale=page.evaluate('code=>globalThis.run(code)',"import os; os.stat('/workspace')");assert not stale['success']
                assert (work/'next.txt').read_text()=='next';assert private.read_bytes()==b'synthetic private'
                browser.close();args.evidence.parent.mkdir(parents=True,exist_ok=True);args.evidence.write_text(json.dumps({'actual_python':report,'browser':result['browser'],'resources':inventory,'limits':{'sab_payload':65536,'chunk':16384,'connections':16,'request_timeout_seconds':3,'worker_deadline_seconds':25},'revoked':denied,'fresh':fresh,'old_epoch_after_fresh':stale,'operations':broker.events,'private_unchanged':True,'apple_pending':True},ensure_ascii=False,indent=2)+'\n');print('PASS actual Pyodide Worker -> SAB -> C descriptor operations; evidence',args.evidence)
        finally:
            if 'browser'in locals():
                try:browser.close()
                except Exception:pass
            for listener in servers:listener.shutdown();listener.server_close()
            broker.stop()

TEST_CODE=r'''
import os,json,errno
from pathlib import Path
import numpy as np,sympy as sp,yaml,sys
p=Path('/workspace/日本語.bin')
with p.open('w+b')as f:
 f.write(bytes(range(256))*257);f.seek(123);f.write(b'changed');f.seek(123);assert f.read(7)==b'changed';f.truncate(8193);assert os.fstat(f.fileno()).st_size==8193
assert p.stat().st_size==8193
Path('/workspace/資料').mkdir();assert os.listdir('/workspace/資料')==[]
q=Path('/workspace/資料/erase');q.write_bytes(b'delete');q.unlink();Path('/workspace/資料').rmdir()
r={'solve':np.linalg.solve([[2.,1.],[1.,3.]],[5.,7.]).tolist(),'integral':str(sp.integrate(sp.Symbol('x')**2,(sp.Symbol('x'),0,3)))}
Path('/workspace/計算.yaml').write_text(yaml.safe_dump(r,allow_unicode=True));assert yaml.safe_load(Path('/workspace/計算.yaml').read_text())==r
with open('/workspace/配列.npy','wb')as f:np.save(f,np.arange(100,dtype=np.int64))
with open('/workspace/配列.npy','rb')as f:assert np.array_equal(np.load(f),np.arange(100))
Path('/workspace/数式.txt').write_text(str(sp.expand((sp.Symbol('x')+1)**4)))
assert not os.path.samefile('/workspace/配列.npy','/workspace/数式.txt');assert not os.path.samefile('/workspace','/')
r['versions']={'python':sys.version,'numpy':np.__version__,'sympy':sp.__version__,'yaml':yaml.__version__}
r['escapes']={}
for key,path in [('absolute','/private-canary'),('parent','/workspace/../private-canary'),('symlink','/workspace/escape'),('hardlink','/workspace/hard'),('ancestor','/workspace/ancestor/private-canary')]:
 try:Path(path).read_bytes();raise AssertionError('escaped')
 except (PermissionError,FileNotFoundError)as e:r['escapes'][key]=type(e).__name__
try:os.listdir('/workspace');raise AssertionError('unsupported protected-entry list unexpectedly succeeded')
except PermissionError:r['root_list_with_protected_entries']='denied'
import js
r['bridge_denials']=[js.virtualFSRequest(js.JSON.parse(json.dumps({'operation':'open','path':v,'flags':1}))).errno for v in ['/private-canary','../private-canary','escape','hard']]
r['envelope_denials']=[js.virtualFSRequest(js.JSON.parse(json.dumps(v))).errno for v in [{'operation':'revoke'},{'operation':'read','handle':1,'offset':'0','length':1},{'operation':'metadata','path':'','owner':'guest'}]]
r['foreign']=js.virtualFSRequest(js.JSON.parse('{"operation":"read","handle":"FOREIGN_HANDLE","offset":"0","length":1}')).errno
try:Path('/lib/forbidden-write').write_bytes(b'bad');raise AssertionError('system write allowed')
except OSError as e:assert e.errno==errno.EROFS
# Replacement preserves open source and overwritten destination objects.
a=Path('/workspace/rename-source');b=Path('/workspace/rename-dest');a.write_bytes(b'new');b.write_bytes(b'old')
with a.open('r+b')as source,b.open('r+b')as replaced:
 os.replace(a,b);assert b.read_bytes()==b'new';assert source.read()==b'new';assert replaced.read()==b'old'
 assert os.fstat(source.fileno()).st_ino!=os.fstat(replaced.fileno()).st_ino
 replaced.seek(0);replaced.write(b'OLD');replaced.flush();assert os.fstat(replaced.fileno()).st_size==3;assert b.read_bytes()==b'new'
assert not a.exists();assert b.read_bytes()==b'new';os.replace(b,b)
Path('/workspace/move-dir').mkdir();Path('/workspace/move-dir/child').write_bytes(b'child');Path('/workspace/empty-dir').mkdir()
os.replace('/workspace/move-dir','/workspace/empty-dir');assert Path('/workspace/empty-dir/child').read_bytes()==b'child'
# A failed replacement must keep both cached nodes and their data intact.
Path('/workspace/nonempty').mkdir();Path('/workspace/nonempty/child').write_bytes(b'keep')
try:os.replace('/workspace/empty-dir','/workspace/nonempty');raise AssertionError('nonempty replacement allowed')
except OSError as e:assert e.errno==errno.ENOTEMPTY
assert Path('/workspace/empty-dir/child').read_bytes()==b'child';assert Path('/workspace/nonempty/child').read_bytes()==b'keep'
for path in ['escape','hard','ancestor/private-canary','../private-canary','/private-canary']:
 for src,dst in [(path,'rename-dest'),('rename-dest',path)]:
  denied=js.virtualFSRequest(js.JSON.parse(json.dumps({'operation':'rename','source':src,'destination':dst})))
  assert denied.errno=='EACCES'
assert b.read_bytes()==b'new'
try:os.replace(b,'/lib/forbidden-rename');raise AssertionError('system rename allowed')
except OSError as e:assert e.errno==errno.EROFS
# Run the actual distributed delegate's atomic publication prefix.
import io
inbox=Path('/workspace/.struis_delegations/test');inbox.mkdir(parents=True)
saved_argv,saved_stdin=sys.argv,sys.stdin
try:
 sys.argv=['delegate.py',str(inbox)];sys.stdin=io.StringIO(json.dumps({'task':'filesystem publication'}))
 namespace={};exec(DELEGATE_PUBLICATION,namespace);namespace['main']()
finally:sys.argv,sys.stdin=saved_argv,saved_stdin
pending=list(inbox.glob('*.request.json'));assert len(pending)==1 and not list(inbox.glob('*.tmp'))
assert json.loads(pending[0].read_text())['task']=='filesystem publication'
r['atomic_publication']=True
json.dumps(r)
'''
if __name__=='__main__':main()
