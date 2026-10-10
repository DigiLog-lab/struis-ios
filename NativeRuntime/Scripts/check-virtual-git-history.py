#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Linux preparation: actual CPython Git history, binary C pipes and descriptor broker.
No own evaluator/shell parser; trusted synthetic FDs/scopes, never product activation.
"""
import sys
sys.dont_write_bytecode=True
import argparse,base64,ctypes as C,errno,hashlib,importlib.util,json,os,subprocess,tempfile,threading,time
from pathlib import Path
from http.server import BaseHTTPRequestHandler
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('filesystem_check',ROOT/'Scripts/check-virtual-python-filesystem.py')
fs=importlib.util.module_from_spec(spec);spec.loader.exec_module(fs)
class Context(C.Structure):
    _fields_=[('worker',C.c_char*128),('owner',C.c_char*256),('generation',C.c_uint64),('invocation',C.c_uint64)]
class Status(C.Structure):
    _fields_=[(n,C.c_uint32)for n in ['started','finished','cancelled','complete','eof','merged']]+[('io_error',C.c_int32)]+[(n,C.c_size_t)for n in ['available','stdout_credit','stderr_credit']]
class Result(C.Structure):
    _fields_=[('exit_code',C.c_int32),('reason',C.c_uint32),('io_error',C.c_int32)]+[(n,C.c_uint64)for n in ['stdin_bytes','stdout_bytes','stderr_bytes']]
class PipeJob:
    def __init__(self,lib,argv,generation,mode='normal'):
        self.lib=lib;self.lock=threading.Lock();self.instance=C.c_void_p();self.context=Context();self.stdout=bytearray();self.stderr=bytearray();self.output_early=threading.Event();self.ready=threading.Event();self.mode=mode;self.closed=False;self.terminal_lock=threading.Lock();self.requested=threading.Event();self.producing=False;self.eof_time=None;self.early_time=None;self.partial=0;self.empty_credit=0;self.sequence=0;self.maximum_queued=0;self.result=None;self.thread_errors=[]
        inp,producer=os.pipe();out,stdout=os.pipe();err,stderr=os.pipe();self.producer=producer;self.consumers=[out,err]
        args=(C.c_char_p*len(argv))(*argv)
        fs.Broker.checked(lib.StruisVPCreate(b'trusted-browser-worker',b'trusted-browser-job',generation,2 if argv[0]==b'git' else 1,len(argv),args,inp,stdout,stderr,C.byref(self.instance),C.byref(self.context)))
        for fd in [inp,stdout,stderr]:os.close(fd)
        function=C.c_uint32();argc=C.c_size_t();fs.Broker.checked(lib.StruisVPDescribe(self.instance,C.byref(self.context),C.byref(function),C.byref(argc)));assert function.value==(2 if argv[0]==b'git' else 1) and argc.value==len(argv)
        for index,argument in enumerate(argv):
            output=C.create_string_buffer(16385);required=C.c_size_t();fs.Broker.checked(lib.StruisVPArgument(self.instance,C.byref(self.context),index,output,len(output),C.byref(required)));assert required.value==len(argument)+1 and output.raw[:required.value]==argument+b"\0"
        fs.Broker.checked(lib.StruisVPStart(self.instance,C.byref(self.context)))
        self.threads=[]
        if mode=='epipe':os.close(out);self.consumers[0]=None
        else:self.spawn(self.drain,out,self.stdout,True)
        self.spawn(self.drain,err,self.stderr,False)
    def spawn(self,fn,*args):
        def work():
            try:fn(*args)
            except BaseException as error:self.thread_errors.append(type(error).__name__)
        thread=threading.Thread(target=work,daemon=True);thread.start();self.threads.append(thread)
    def drain(self,fd,destination,is_stdout):
        try:
            if self.mode=='blocked-output'and is_stdout:self.ready.wait(20);return
            while True:
                data=os.read(fd,4096)
                if not data:break
                destination.extend(data)
                if len(destination)>2_097_152:raise AssertionError('test sink bound')
                if is_stdout and self.early_time is None:self.early_time=time.monotonic();self.output_early.set()
        finally:os.close(fd)
    def feed(self,data,early=False):
        self.producing=True;producer_fd=self.producer
        def producer():
            try:
                cursor=0
                if early:
                    cursor=os.write(producer_fd,data[:4096]);assert self.output_early.wait(20),'no early output'
                    if self.closed:return
                while cursor<len(data):cursor+=os.write(producer_fd,data[cursor:cursor+4096])
                self.eof_time=time.monotonic()
            except BrokenPipeError:
                if not self.closed:raise
            finally:os.close(producer_fd);self.producer=None;self.producing=False
        self.spawn(producer)
    def exchange(self,r):
        if set(r)!={'stdout','stderr','capacity'}or type(r['capacity'])is not int or not 0<=r['capacity']<=16384:raise ValueError('stdio schema')
        outputs=[]
        for key in ['stdout','stderr']:
            if not isinstance(r[key],str)or len(r[key])>21848:raise ValueError('stdio frame')
            data=base64.b64decode(r[key],validate=True)
            if len(data)>16384:raise ValueError('stdio frame')
            outputs.append(data)
        with self.lock:
            if self.closed:return {'errno':'EACCES','stdin':'','eof':False,'stdoutAccepted':0,'stderrAccepted':0}
            self.sequence+=1;accepted=[];code=0
            if r["capacity"]or any(outputs):self.requested.set()
            for stream,data in enumerate(outputs,1):
                # Trusted adapter may grant a smaller per-exchange frame budget.
                offered=data[:4093]if self.mode=='partial'else data
                n=C.c_size_t();e=self.lib.StruisVPPushOutput(self.instance,C.byref(self.context),stream,offered,len(offered),C.byref(n));accepted.append(n.value)
                if e==errno.EAGAIN:self.empty_credit+=1;e=0
                if 0<n.value<len(data):self.partial+=1
                if e:code=e;break
            while len(accepted)<2:accepted.append(0)
            size=r['capacity'];b=C.create_string_buffer(size);n=C.c_size_t();eof=C.c_uint32()
            if not code and size:
                code=self.lib.StruisVPPullStdin(self.instance,C.byref(self.context),b,size,C.byref(n),C.byref(eof))
                if code==errno.EAGAIN:code=0
            status=Status();self.lib.StruisVPStatusRead(self.instance,C.byref(self.context),C.byref(status));self.maximum_queued=max(self.maximum_queued,65536-status.stdout_credit,65536-status.stderr_credit,status.available)
            return {'stdin':base64.b64encode(b.raw[:n.value]).decode(),'eof':bool(eof.value),'stdoutAccepted':accepted[0],'stderrAccepted':accepted[1],'stdoutCredit':status.stdout_credit,'stderrCredit':status.stderr_credit,**({'errno':errno.errorcode.get(code,'EIO')}if code else {})}
    def terminal(self,code=None):
        with self.terminal_lock:return self._terminal(code)
    def _terminal(self,code=None):
        with self.lock:
            if self.closed:return
            e=self.lib.StruisVPCancel(self.instance,C.byref(self.context))if code is None else self.lib.StruisVPFinished(self.instance,C.byref(self.context),code)
            # EPIPE remains a failed execution; still join and destroy the invocation.
            if e not in (0,errno.EALREADY,errno.EPIPE):fs.Broker.checked(e)
        result=Result();fs.Broker.checked(self.lib.StruisVPAwait(self.instance,C.byref(self.context),2000,C.byref(result)))
        with self.lock:
            fs.Broker.checked(self.lib.StruisVPDestroy(self.instance,C.byref(self.context)));self.closed=True;self.result={name:getattr(result,name)for name,_ in Result._fields_}
        self.ready.set();self.output_early.set()
        if self.producer is not None and not self.producing:
            try:os.close(self.producer)
            except OSError:pass
            self.producer=None
        for thread in self.threads:thread.join(2)
        assert all(not t.is_alive()for t in self.threads),'native test helper not joined'
        assert not self.thread_errors,self.thread_errors

def library(path):
    lib=C.CDLL(str(path));V=C.c_void_p;P=C.POINTER;S=C.c_size_t
    definitions={'Create':[C.c_char_p,C.c_char_p,C.c_uint64,C.c_uint32,C.c_int,P(C.c_char_p),C.c_int,C.c_int,C.c_int,P(V),P(Context)],'Describe':[V,P(Context),P(C.c_uint32),P(S)],'Argument':[V,P(Context),S,V,S,P(S)],'Start':[V,P(Context)],'StatusRead':[V,P(Context),P(Status)],'PullStdin':[V,P(Context),V,S,P(S),P(C.c_uint32)],'PushOutput':[V,P(Context),C.c_uint32,V,S,P(S)],'Finished':[V,P(Context),C.c_int32],'Cancel':[V,P(Context)],'Await':[V,P(Context),C.c_uint32,P(Result)],'Destroy':[V,P(Context)]}
    for name,args in definitions.items():getattr(lib,'StruisVP'+name).argtypes=args;getattr(lib,'StruisVP'+name).restype=C.c_int
    return lib

PAGE=b'''<!doctype html><script type=module>
import{runVirtualPythonCommand}from'./main.js';
const encode=b=>{let s='';for(const n of b)s+=String.fromCharCode(n);return btoa(s);};
const decode=s=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
async function post(path,body,signal){const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),signal});if(!r.ok)throw Error('trusted transport rejected');const length=Number(r.headers.get('Content-Length'));if(!Number.isInteger(length)||length<1||length>65536)throw Error('reply bound');const bytes=await r.arrayBuffer();if(bytes.byteLength!==length)throw Error('reply length');return JSON.parse(new TextDecoder().decode(bytes));}
const provider={functionID:1,exchange:async(r,signal)=>{const a=await post('./stdio',{stdout:encode(r.stdoutData),stderr:encode(r.stderrData),capacity:r.stdinCapacity},signal);return{...a,stdinData:decode(a.stdin),stdinEOF:a.eof};},finish:async(code,signal)=>post('./finish',{exitCode:code},signal),cancel:async()=>post('./cancel',{})};
globalThis.run=argv=>{globalThis.cancelJob=new AbortController();return runVirtualPythonCommand(argv.map(a=>typeof a==='string'?a:Uint8Array.from(a)),provider,{signal:cancelJob.signal,gitHistoryTestOnly:provider.functionID===2});};
</script>'''

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--assets',type=Path,default=Path('/tmp/hyotan-pyodide-feasibility/PythonResources'));ap.add_argument('--scratch',type=Path,default=Path('/workspace/hyotan-virtual-git-apple-proof'));args=ap.parse_args();args.scratch.mkdir(parents=True,exist_ok=True)
    subprocess.run(['cc','-shared','-fPIC','-O2','-pthread',str(ROOT/'Worker/VirtualPythonCommandBridge.c'),'-o',str(args.scratch/'libduplex.so')],check=True)
    subprocess.run(['cargo','rustc','--offline','--locked','--manifest-path',str(ROOT/'NativeCodex/Cargo.toml'),'--no-default-features','--features','operations','--lib','--crate-type','cdylib','--target-dir',str(args.scratch/'target')],check=True)
    lib=library((args.scratch/'libduplex.so'));inventory=json.loads((ROOT/'VirtualPython/resources.js').read_text().split('export const resources = ',1)[1].strip().removesuffix(';'))
    assets={n:(args.assets/n).read_bytes()for n in inventory}
    for n,b in assets.items():assert hashlib.sha256(b).hexdigest()==inventory[n]
    scripts={n:((ROOT/'VirtualPython')/n).read_bytes()for n in ['main.js','worker.js','filesystem.js','stdio.js']};scripts['hyotan_runner.py']=(ROOT/'PythonModules/hyotan_runner.py').read_bytes()
    scripts.update({'git/'+name:(ROOT/'VirtualPythonGit'/name).read_bytes()for name in ['loader.js','packages.zip','hyotan_history.py','hyotan_virtual_git.py','Licenses/Dulwich.txt','Licenses/urllib3.txt']})
    reports=[];servers=[];jobs=[]
    from playwright.sync_api import sync_playwright
    with tempfile.TemporaryDirectory(prefix='hyotan-stdio-')as directory, sync_playwright()as p:
        work=Path(directory)/'workspace';work.mkdir();(work/'sample.py').write_text("import sys; print('script:'+sys.argv[1])");(work/'modsample.py').write_text("import sys; print('module:'+sys.argv[1])")
        import zlib
        def object_file(kind,data):
            raw=kind.encode()+b' '+str(len(data)).encode()+b'\0'+data;sha=hashlib.sha1(raw).hexdigest();location=work/'.git/objects'/sha[:2]/sha[2:];location.parent.mkdir(parents=True,exist_ok=True);location.write_bytes(zlib.compress(raw));return sha
        def commit(content,parent,author,stamp,message):
            blob=object_file('blob',content)
            bulk=object_file('blob',('大量の履歴出力\n'*1000).encode())
            tree=object_file('tree',b'100644 many.txt\0'+bytes.fromhex(bulk)+b'100644 '+ '日本語.txt'.encode()+b'\0'+bytes.fromhex(blob))
            data=f'tree {tree}\n'+(f'parent {parent}\n'if parent else'')+f'author {author} <probe@example.invalid> {stamp} +0000\ncommitter {author} <probe@example.invalid> {stamp} +0000\n\n{message}\n'
            return object_file('commit',data.encode())
        initial='保持\n親\n'.encode();second='保持\n子\n追加\n'.encode();final='保持\n子\n追加\n末尾\n'.encode()
        first=commit(initial,None,'Root',1700000000,'initial Japanese')
        middle=commit(second,first,'Parent',1700000100,'parent changes')
        latest=commit(final,middle,'Child',1700000200,'child append')
        (work/'.git/refs/heads').mkdir(parents=True);(work/'.git/refs/heads/main').write_text(latest+'\n');(work/'.git/HEAD').write_text('ref: refs/heads/main\n');(work/'.git/config').write_text('[core]\nrepositoryformatversion = 0\nbare = false\n')
        (work/'日本語.txt').write_bytes(final);(work/'many.txt').write_bytes(('大量の履歴出力\n'*1000).encode())
        private=Path(directory)/'private-canary';private.write_bytes(b'synthetic private')
        browser=p.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox','--disable-dev-shm-usage','--disable-background-networking'])
        def run(argv,data=b'',mode='normal',early=False,cancel=False):
            generation=len(jobs)+1;raw=[a.encode()if isinstance(a,str)else bytes(a)for a in argv];job=PipeJob(lib,raw,generation,mode);jobs.append(job)
            operations=fs.Broker((args.scratch/'target/debug/libhyotan_codex.so'),work)
            operations.synthetic_denials=[]
            class Handler(BaseHTTPRequestHandler):
                def setup(self):self.request.settimeout(3);super().setup()
                def log_message(self,*a):pass
                def reply(self,b,mime='application/json'):
                    self.send_response(200)
                    for k,v in {'Content-Type':mime,'Content-Length':str(len(b)),'Connection':'close','Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp','Cross-Origin-Resource-Policy':'same-origin','Content-Security-Policy':"default-src 'none'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; worker-src 'self'; connect-src 'self'"}.items():self.send_header(k,v)
                    self.end_headers();self.wfile.write(b)
                def host(self):return self.headers.get('Host')==f'127.0.0.1:{self.server.server_port}'
                def do_GET(self):
                    if not self.host():self.send_error(403);return
                    if self.path=='/':self.reply(PAGE.replace(b'functionID:1',b'functionID:2')if raw[0]==b'git' else PAGE,'text/html')
                    elif self.path[1:]in scripts:self.reply(scripts[self.path[1:]],'application/javascript'if self.path.endswith('.js')else'application/octet-stream')
                    elif self.path.startswith('/py/')and self.path[4:]in assets:self.reply(assets[self.path[4:]],'application/javascript'if self.path.endswith(('.js','.mjs'))else'application/wasm'if self.path.endswith('.wasm')else'application/octet-stream')
                    else:self.send_error(404)
                def do_POST(self):
                    try:
                        length=int(self.headers.get('Content-Length','0'))
                        if not self.host()or self.headers.get('Origin')!=f'http://127.0.0.1:{self.server.server_port}'or self.headers.get('Content-Type')!='application/json'or self.headers.get('Transfer-Encoding')or not 1<=length<=65536:raise ValueError('HTTP envelope')
                        r=json.loads(self.rfile.read(length),object_pairs_hook=fs.unique_keys)
                        if not isinstance(r,dict):raise ValueError()
                        if self.path=='/stdio':answer=job.exchange(r)
                        elif self.path=='/broker':
                            with operations.lock:answer=operations.execute(operations.instance,r)
                            if answer.get('errno')=='EACCES':operations.synthetic_denials.append(r.get('path','descriptor'))
                        elif self.path in ['/finish','/cancel']:
                            if self.path=='/finish':
                                if set(r)!={'exitCode'}or type(r['exitCode'])is not int or not -(2**31)<=r['exitCode']<2**31:raise ValueError()
                                job.terminal(r['exitCode'])
                            else:
                                if r:raise ValueError()
                                job.terminal()
                            with operations.lock:
                                if not getattr(operations,'revoked_stdio',False):
                                    operations.checked(operations.lib.hyotan_operations_revoke(operations.instance));operations.revoked_stdio=True
                            answer={'completed':True,'exitCode':job.result['exit_code']}
                        else:raise ValueError('operation')
                        out=json.dumps(answer).encode();assert len(out)<=65536;self.reply(out)
                    except (ValueError,UnicodeError,RecursionError):self.send_error(400)
            server=fs.BoundedServer(('127.0.0.1',0),Handler);servers.append((server,operations));threading.Thread(target=server.serve_forever,daemon=True).start()
            page=browser.new_page();page.on('console',lambda m:print(m.text,flush=True));page.goto(f'http://127.0.0.1:{server.server_port}/');page.wait_for_function('typeof run === "function"')
            if mode=='blocked-input':pass
            else:job.feed(data,early)
            payload=[a if isinstance(a,str)else list(a)for a in argv]
            if cancel:
                page.evaluate('args=>{globalThis.jobResult=undefined;run(args).then(r=>jobResult=r).catch(e=>jobResult={error:String(e)});}',payload)
                page.wait_for_function("typeof cancelJob==='object'");assert job.requested.wait(20),'Python never reached blocking I/O';time.sleep(.1 if mode=='blocked-input'else .5);page.evaluate('cancelJob.abort()');page.wait_for_function('jobResult !== undefined',timeout=10000);result=page.evaluate('jobResult')
            else:result=page.evaluate('args=>run(args)',payload)
            if not job.closed:job.terminal()
            report={'synthetic_denied_paths':list(operations.synthetic_denials),'argv':argv[:2]if all(isinstance(a,str)for a in argv)else['binary argv'],'result':result,'native':job.result,'stdout':base64.b64encode(job.stdout).decode(),'stderr':base64.b64encode(job.stderr).decode(),'partial':job.partial,'eagain':job.empty_credit,'max_queue':job.maximum_queued,'early':job.early_time is not None and job.eof_time is not None and job.early_time<job.eof_time,'sequence':job.sequence};reports.append(report);page.close();print('STDIO_STAGE',len(reports),'exit',result.get('exitCode'),'native',job.result,'partial',job.partial,'eagain',job.empty_credit,flush=True);return job,result
        try:
            cases=[
                (['python3','--version'],0,b'Python 3.14.2'),
                (['python3','-c','raise SystemExit(42)'],42,b''),
                (['git','log'],0,b'child append'),
                (['git','blame','many.txt'],0,'大量の履歴出力'.encode()),
                (['git','log','--oneline','-n','2'],0,b'parent changes'),
                (['git','log',middle],0,b'parent changes'),
                (['git','blame','日本語.txt'],0,'保持'.encode()),
                (['git','blame','--','日本語.txt'],0,'保持'.encode()),
                (['git','blame','--porcelain','日本語.txt'],2,b''),
                (['git','log','--graph'],2,b''),
                (['git','log','-n','1001'],1,b''),
                (['git','log','-n','0'],0,b''),
                (['git','log','-n','-1'],1,b''),
                (['git','log','no-such-ref'],1,b''),
                (['git','blame','missing.txt'],1,b''),
                (['git','blame','../private-canary'],1,b''),
                (['git','blame','/private-canary'],1,b''),
            ]
            for argv,status,output in cases:
                job,r=run(argv);assert r['exitCode']==status,(argv,r,bytes(job.stderr));assert output in job.stdout
                if argv==['git','log']:assert all(sha.encode() in job.stdout for sha in (latest,middle,first))
                if argv==['git','blame','many.txt']:assert job.stdout.count(b'\n')==1000 and len(job.stdout)>16384 and job.maximum_queued<=65536
                if argv==['git','blame','日本語.txt']:
                    lines=job.stdout.decode().splitlines();assert len(lines)==4,lines
                    assert lines[0].startswith('^'+first[:7])and'Root'in lines[0],lines
                    assert lines[1].startswith(middle[:8])and'Parent'in lines[1],lines
                    assert lines[2].startswith(middle[:8])and'Parent'in lines[2],lines
                    assert lines[3].startswith(latest[:8])and'Child'in lines[3],lines
            (work/'.git/config').unlink();os.symlink(private,work/'.git/config')
            job,r=run(['git','log']);assert r['exitCode']==0 and not r['deniedOperations'],r
            (work/'.git/config').unlink()
            for marker in ['commondir','objects/info/alternates']:
                target=work/'.git'/marker;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(str(private))
                job,r=run(['git','log']);assert r['exitCode']==1 and b'unsupported'in job.stderr
                target.unlink();os.symlink(private,target)
                job,r=run(['git','log']);assert r['exitCode']==1 and r['deniedOperations'] and '.git/'+marker in reports[-1]['synthetic_denied_paths'],r
                target.unlink()
            (work/'.git/HEAD').unlink();os.symlink(private,work/'.git/HEAD')
            job,r=run(['git','log']);assert r['exitCode']==1 and r['deniedOperations'] and '.git/HEAD' in reports[-1]['synthetic_denied_paths'],r
            (work/'.git/HEAD').unlink();(work/'.git/HEAD').write_text('ref: refs/heads/main\n')
            (work/'日本語.txt').write_bytes(b'dirty')
            job,r=run(['git','blame','日本語.txt']);assert r['exitCode']==1 and b'working-tree blame is unsupported'in job.stderr
            (work/'日本語.txt').write_bytes(final)
            # Descriptor broker denial rather than parser validation: linked tracked regular-file path.
            (work/'日本語.txt').unlink();os.symlink(private,work/'日本語.txt')
            job,r=run(['git','blame','日本語.txt']);assert r['exitCode']==1 and r['deniedOperations'] and '日本語.txt' in reports[-1]['synthetic_denied_paths'],r
            (work/'日本語.txt').unlink();os.link(private,work/'日本語.txt')
            job,r=run(['git','blame','日本語.txt']);assert r['exitCode']==1 and r['deniedOperations'] and '日本語.txt' in reports[-1]['synthetic_denied_paths'],r
            (work/'日本語.txt').unlink();(work/'日本語.txt').write_bytes(final)
            job,r=run(['git','blame','日本語.txt']);assert r['exitCode']==0
            assert private.read_bytes()==b'synthetic private'
            args.scratch.joinpath('evidence.json').write_text(json.dumps({'actual_browser_cpython':True,'trusted_git_entry':2,'product_switch':False,'apple_pending':True,'fixture':{'root':first,'parent':middle,'head':latest},'resources':inventory,'source_sha256':{n:hashlib.sha256(b).hexdigest()for n,b in scripts.items()},'core_sha256':{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for folder in ['OperationHarness/src','NativeCodex/src']for f in (ROOT/folder).glob('*.rs')},'binary_sha256':{n:hashlib.sha256((args.scratch/n).read_bytes()).hexdigest()for n in ['libduplex.so','target/debug/libhyotan_codex.so']},'probe_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'private_canary_unchanged':True,'reports':reports},ensure_ascii=False,indent=2)+'\n')
            print('GIT PREPARATION EVIDENCE',args.scratch/'evidence.json')
        finally:
            for job in jobs:
                if not job.closed:job.terminal()
            browser.close()
            for server,operations in servers:server.shutdown();server.server_close();operations.stop()
if __name__=='__main__':main()
