#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Actual Pyodide/Worker/SAB/C descriptor policy preparation; no product toggle."""
import argparse,hashlib,json,os,runpy,tempfile,threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler
ROOT=Path(__file__).resolve().parents[1]
SUPPORT=runpy.run_path(str(ROOT/'Scripts/check-virtual-python-filesystem.py'))
Broker,Server,unique_keys=(SUPPORT[k] for k in ('Broker','BoundedServer','unique_keys'))
LARGE=4*1024**3
LARGE_CODE=r'''
import os,json,errno,js
p='/workspace/日本語-large.bin'
fd=os.open(p,os.O_RDWR|os.O_CREAT|os.O_EXCL,0o600)
os.ftruncate(fd,4*1024**3)
assert os.fstat(fd).st_size==4*1024**3
assert os.stat(p).st_size==4*1024**3
payload=bytes([0,255,42,65])
positions=[2*1024**3+3,4*1024**3-4]
for position in positions:
 assert os.lseek(fd,position,os.SEEK_SET)==position
 assert os.write(fd,payload)==len(payload)
 assert os.lseek(fd,position,os.SEEK_SET)==position
 assert os.read(fd,4)==payload
assert os.lseek(fd,0,os.SEEK_END)==4*1024**3
assert os.read(fd,16384)==b''
assert os.lseek(fd,-4,os.SEEK_END)==4*1024**3-4
assert os.read(fd,16384)==payload
try:os.lseek(fd,4*1024**3+1,os.SEEK_SET);raise AssertionError('seek past policy')
except OSError as e:assert e.errno==errno.EINVAL
for operation in [lambda:os.ftruncate(fd,4*1024**3+1),lambda:os.write(fd,b'x')]:
 try:operation();raise AssertionError('write extent widened')
 except PermissionError:pass
request=lambda r:js.virtualFSRequest(js.JSON.parse(json.dumps(r)))
foreign=request({'operation':'read','handle':'FOREIGN','offset':'0','length':1});assert foreign.errno=='EACCES'
for path in ['escape','hard','../private-canary','/private-canary']:
 assert request({'operation':'open','path':path,'flags':1}).errno=='EACCES'
for op in [{'operation':'descriptorPolicy','readExtent':'9999999999'},{'operation':'create','readExtent':'9999999999'},{'operation':'descriptorPolicy','owner':'guest'}]:
 assert request(op).errno=='EINVAL'
assert request({'operation':'read','handle':'0','offset':'18446744073709551615','length':1}).errno=='EACCES'
policy=request({'operation':'descriptorPolicy'}).policy
assert policy.readExtent=='4294967296' and policy.writeExtent=='4294967296' and policy.configured is True
os.close(fd)
json.dumps({'size':os.stat(p).st_size,'positions':positions,'binary':list(payload),'policy':{'read':str(policy.readExtent),'write':str(policy.writeExtent)},'large_i64':True})
'''
ASYMMETRIC_CODE=r'''
import os,errno,json
fd=os.open('/workspace/asym.bin',os.O_RDWR|os.O_CREAT|os.O_EXCL,0o600)
os.ftruncate(fd,64);assert os.fstat(fd).st_size==64
assert os.lseek(fd,63,os.SEEK_SET)==63;assert os.write(fd,b'z')==1
assert os.lseek(fd,15,os.SEEK_SET)==15;assert os.read(fd,16)==b'\0';assert os.read(fd,16)==b''
assert os.lseek(fd,17,os.SEEK_SET)==17
try:os.read(fd,1);raise AssertionError('read exceeded own extent')
except PermissionError:pass
os.lseek(fd,64,os.SEEK_SET)
try:os.write(fd,b'z');raise AssertionError('write exceeded own extent')
except PermissionError:pass
os.close(fd)
json.dumps({'read_extent':16,'write_extent':64,'separate_bounds':True})
'''
def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--library',type=Path,required=True,help='Actual operations C ABI shared library compiled from current source')
 parser.add_argument('--assets',type=Path,default=Path('/tmp/hyotan-pyodide-feasibility/PythonResources'))
 parser.add_argument('--evidence',type=Path,default=Path('/workspace/hyotan-configured-browser-prep/browser-policy-evidence.json'))
 args=parser.parse_args();inventory=json.loads((ROOT/'VirtualPython/resources.js').read_text().split('export const resources = ',1)[1].rstrip(';\n'))
 for name,expected in inventory.items():
  if hashlib.sha256((args.assets/name).read_bytes()).hexdigest()!=expected:raise RuntimeError('pinned runtime asset mismatch')
 scripts={name:(ROOT/'VirtualPython'/name).read_bytes() for name in ['main.js','worker.js','filesystem.js']}
 html=b"<!doctype html><script type=module>import{runVirtualPython}from'./main.js';globalThis.run=runVirtualPython;</script>"
 servers=[];brokers=[];origins=set()
 with tempfile.TemporaryDirectory(prefix='hyotan-browser-policy-',dir='/workspace')as directory:
  base=Path(directory);work=base/'work';work.mkdir();private=base/'private-canary';private.write_bytes(b'synthetic private');os.symlink(private,work/'escape');os.link(private,work/'hard')
  def serve(broker,instance=None):
   captured=instance if instance is not None else broker.instance
   class Handler(BaseHTTPRequestHandler):
    def setup(self):self.request.settimeout(3);super().setup()
    def log_message(self,*args):pass
    def valid_host(self):return self.headers.get_all('Host')==[f'127.0.0.1:{self.server.server_port}']
    def reply(self,data,kind):
     self.send_response(200)
     for name,value in {'Content-Type':kind,'Content-Length':str(len(data)),'Connection':'close','Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp','Cross-Origin-Resource-Policy':'same-origin','Cache-Control':'no-store'}.items():self.send_header(name,value)
     self.end_headers();self.wfile.write(data)
    def do_GET(self):
     if not self.valid_host():self.send_error(403);return
     if self.path=='/':self.reply(html,'text/html')
     elif self.path[1:]in scripts:self.reply(scripts[self.path[1:]],'application/javascript')
     elif self.path.startswith('/py/')and self.path[4:]in inventory:self.reply((args.assets/self.path[4:]).read_bytes(),'application/javascript' if self.path.endswith(('.js','.mjs'))else'application/wasm' if self.path.endswith('.wasm')else'application/octet-stream')
     else:self.send_error(404)
    def do_POST(self):
     try:
      origin=f'http://127.0.0.1:{self.server.server_port}'
      lengths=self.headers.get_all('Content-Length',[])
      if not self.valid_host()or self.headers.get_all('Origin')!=[origin]or self.headers.get_all('Content-Type')!=['application/json']or len(lengths)!=1 or self.headers.get('Transfer-Encoding')or self.path!='/broker':raise ValueError()
      if not lengths[0].isascii()or not lengths[0].isdigit()or not 1<=int(lengths[0])<=65536:raise ValueError()
      length=int(lengths[0]);raw=self.rfile.read(length)
      if len(raw)!=length:raise ValueError()
      request=json.loads(raw.decode('utf8'),object_pairs_hook=unique_keys)
      if not isinstance(request,dict):raise ValueError()
      with broker.lock:result=broker.execute(captured,request)
      data=json.dumps(result,ensure_ascii=False).encode('utf8')
      if len(data)>65536:raise ValueError()
      self.reply(data,'application/json')
     except (ValueError,UnicodeError,RecursionError):self.send_error(400)
   server=Server(('127.0.0.1',0),Handler);servers.append(server);threading.Thread(target=server.serve_forever,daemon=True).start()
   origin=f'http://127.0.0.1:{server.server_port}';origins.add(origin);return origin
  try:
   from playwright.sync_api import sync_playwright
   with sync_playwright()as pw:
    browser=pw.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox','--disable-dev-shm-usage','--disable-background-networking'])
    context=browser.new_context();context.route('**/*',lambda route:route.continue_()if any(route.request.url.startswith(origin+'/')for origin in origins)else route.abort())
    def page_for(broker,instance=None):
     page=context.new_page();page.goto(serve(broker,instance));page.wait_for_function("typeof globalThis.run==='function'");return page
    def run(page,code):
     result=page.evaluate('code=>globalThis.run(code)',code);print('actual Python result:',result.get('success'),flush=True);return result
    configured=Broker(args.library,work,(LARGE,LARGE));brokers.append(configured);page=page_for(configured)
    result=run(page,LARGE_CODE.replace('FOREIGN',configured.foreign));assert result['success'],result
    sparse=os.stat(work/'日本語-large.bin');assert sparse.st_size==LARGE and sparse.st_blocks*512<1024**2
    assert private.read_bytes()==b'synthetic private'
    # Trusted driver revokes a live captured instance. The old origin is never rebound.
    with configured.lock:
     opened=configured.execute(configured.instance,{'sequence':1,'operation':'open','path':'日本語-large.bin','flags':1});old_handle=opened['handle'];configured.checked(configured.lib.hyotan_operations_revoke(configured.instance))
     getter=configured.execute(configured.instance,{'sequence':2,'operation':'descriptorPolicy'});assert getter['errno']=='EACCES'
    revoked=run(page,"import os; os.stat('/workspace')");assert not revoked['success']and any(d['operation']=='metadata'and 'active workspace'in d['message']for d in revoked['deniedOperations']),revoked
    with configured.lock:fresh_instance=configured.create(work,3)
    fresh_page=page_for(configured,fresh_instance)
    fresh=run(fresh_page,"import os,js,json; p='/workspace/日本語-large.bin'; f=os.open(p,os.O_RDONLY); assert os.lseek(f,4*1024**3-4,os.SEEK_SET)==4*1024**3-4; assert os.read(f,4)==bytes([0,255,42,65]); os.close(f); assert js.virtualFSRequest(js.JSON.parse("+repr(json.dumps({'operation':'read','handle':old_handle,'offset':'0','length':1}))+")).errno=='EACCES'; 'fresh'");assert fresh['success'],fresh
    stale=run(page,"import os; os.stat('/workspace')");assert not stale['success'],stale
    legacy=Broker(args.library,work);brokers.append(legacy);legacy_page=page_for(legacy)
    legacy_result=run(legacy_page,"import os,errno; f=os.open('/workspace/legacy.bin',os.O_RDWR|os.O_CREAT,0o600);\ntry: os.lseek(f,16*1024**2+1,os.SEEK_SET); raise AssertionError('legacy seek widened')\nexcept OSError as e: assert e.errno==errno.EINVAL\nos.close(f); 'legacy'");assert legacy_result['success'],legacy_result
    asym=Broker(args.library,work,(16,64));brokers.append(asym);asym_page=page_for(asym);asymmetric=run(asym_page,ASYMMETRIC_CODE);assert asymmetric['success'],asymmetric
    # C accepts signed-off_tMAX; JS must reject its unrepresentable boot policy,
    # never round it into a guest extent or silently revert to a larger default.
    unsafe=Broker(args.library,work,(2**63-1,LARGE));brokers.append(unsafe);unsafe_page=page_for(unsafe);unsafe_result=run(unsafe_page,"'unreachable'");assert not unsafe_result['success']and 'safe integer'in unsafe_result['error'],unsafe_result
    assert private.read_bytes()==b'synthetic private'
    browser.close()
    args.evidence.parent.mkdir(parents=True,exist_ok=True);args.evidence.write_text(json.dumps({'large':result,'native_sparse':{'logical_bytes':sparse.st_size,'allocated_bytes':sparse.st_blocks*512},'revoked':revoked,'fresh':fresh,'old_origin_after_fresh':stale,'legacy':legacy_result,'asymmetric':asymmetric,'unsafe_boot_rejected':unsafe_result,'private_unchanged':True,'resources':inventory,'source_sha256':{name:hashlib.sha256(data).hexdigest()for name,data in scripts.items()},'library_sha256':hashlib.sha256(args.library.read_bytes()).hexdigest(),'apple_pending':True},ensure_ascii=False,indent=2)+'\n')
    print('PASS actual Pyodide/C configured descriptor policy; evidence',args.evidence)
  finally:
   if 'browser'in locals():
    try:browser.close()
    except Exception:pass
   for server in servers:server.shutdown();server.server_close()
   for broker in brokers:broker.stop()
if __name__=='__main__':main()
