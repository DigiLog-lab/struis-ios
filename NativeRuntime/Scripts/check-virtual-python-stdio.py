#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Linux preparation: actual browser CPython binary hooks and existing pure-C pipes.
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
        fs.Broker.checked(lib.StruisVPCreate(b'trusted-browser-worker',b'trusted-browser-job',generation,1,len(argv),args,inp,stdout,stderr,C.byref(self.instance),C.byref(self.context)))
        for fd in [inp,stdout,stderr]:os.close(fd)
        function=C.c_uint32();argc=C.c_size_t();fs.Broker.checked(lib.StruisVPDescribe(self.instance,C.byref(self.context),C.byref(function),C.byref(argc)));assert function.value==1 and argc.value==len(argv)
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
globalThis.run=argv=>{globalThis.cancelJob=new AbortController();return runVirtualPythonCommand(argv.map(a=>typeof a==='string'?a:Uint8Array.from(a)),provider,{signal:cancelJob.signal});};
</script>'''

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--assets',type=Path,default=Path('/tmp/hyotan-pyodide-feasibility/PythonResources'));ap.add_argument('--scratch',type=Path,default=Path('/workspace/hyotan-virtual-python-stdio'));args=ap.parse_args();args.scratch.mkdir(parents=True,exist_ok=True)
    subprocess.run(['cc','-shared','-fPIC','-O2','-pthread',str(ROOT/'Worker/VirtualPythonCommandBridge.c'),'-o',str(args.scratch/'libduplex.so')],check=True)
    subprocess.run(['cargo','rustc','--offline','--locked','--manifest-path',str(ROOT/'NativeCodex/Cargo.toml'),'--no-default-features','--features','operations','--lib','--crate-type','cdylib','--target-dir',str(args.scratch/'target')],check=True)
    lib=library(args.scratch/'libduplex.so');inventory=json.loads((ROOT/'VirtualPython/resources.js').read_text().split('export const resources = ',1)[1].strip().removesuffix(';'))
    assets={n:(args.assets/n).read_bytes()for n in inventory}
    for n,b in assets.items():assert hashlib.sha256(b).hexdigest()==inventory[n]
    scripts={n:(ROOT/'VirtualPython'/n).read_bytes()for n in ['main.js','worker.js','filesystem.js','stdio.js']};scripts['hyotan_runner.py']=(ROOT/'PythonModules/hyotan_runner.py').read_bytes()
    reports=[];servers=[];jobs=[]
    from playwright.sync_api import sync_playwright
    with tempfile.TemporaryDirectory(prefix='hyotan-stdio-')as directory, sync_playwright()as p:
        work=Path(directory)/'workspace';work.mkdir();(work/'sample.py').write_text("import sys; print('script:'+sys.argv[1])");(work/'modsample.py').write_text("import sys; print('module:'+sys.argv[1])")
        browser=p.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox','--disable-dev-shm-usage','--disable-background-networking'])
        def run(argv,data=b'',mode='normal',early=False,cancel=False):
            generation=len(jobs)+1;raw=[a.encode()if isinstance(a,str)else bytes(a)for a in argv];job=PipeJob(lib,raw,generation,mode);jobs.append(job)
            operations=fs.Broker(args.scratch/'target/debug/libhyotan_codex.so',work)
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
                    if self.path=='/':self.reply(PAGE,'text/html')
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
            report={'argv':argv[:2]if all(isinstance(a,str)for a in argv)else['binary argv'],'result':result,'native':job.result,'stdout':base64.b64encode(job.stdout).decode(),'stderr':base64.b64encode(job.stderr).decode(),'partial':job.partial,'eagain':job.empty_credit,'max_queue':job.maximum_queued,'early':job.early_time is not None and job.eof_time is not None and job.early_time<job.eof_time,'sequence':job.sequence};reports.append(report);page.close();print('STDIO_STAGE',len(reports),'exit',result.get('exitCode'),'native',job.result,'partial',job.partial,'eagain',job.empty_credit,flush=True);return job,result
        try:
            binary=bytes(range(256))*1024+b'\0'
            code="import sys;\nwhile True:\n b=sys.stdin.buffer.read1(4096)\n if not b:break\n sys.stdout.buffer.write(bytes(x^90 for x in b));sys.stdout.buffer.flush()\nsys.stderr.buffer.write(bytes([0,255,42]));sys.stderr.buffer.flush();raise SystemExit(42)"
            job,r=run(['python3','-c',code,'日本語'],binary,early=True);assert r['exitCode']==42 and job.result['exit_code']==42;assert job.stdout==bytes(x^90 for x in binary);assert job.stderr==bytes([0,255,42]);assert reports[-1]['early'];assert job.maximum_queued<=65536
            cases=[(['python3','--version'],b'',0,b'Python 3.14.2'),(['python3','-c'],b'',2,b''),(['python3','-m','modsample','日本語'],b'',0,'module:日本語'.encode()),(['python3','/workspace/sample.py','日本語'],b'',0,'script:日本語'.encode()),(['python3','-'],b"print('stdin-script')\n",0,b'stdin-script'),(['python3','-c',"import sys;print(sys.argv);raise SystemExit(42)",'quoted value','日本語'],b'',42,b'quoted value'),(['python3','-c','raise KeyboardInterrupt'],b'',130,b''),(['python3','-c',"raise ValueError('synthetic')"],b'',1,b''),(['python3','-c',"import os,sys;assert os.fsencode(sys.argv[1])==bytes([255]);print('binaryargv')",bytes([255])],b'',0,b'binaryargv')]
            for argv,inp,code,output in cases:
                job,r=run(argv,inp);assert r['exitCode']==code,(argv,r);assert output in job.stdout
            partial_data=bytes(range(256))*512
            job,r=run(['python3','-c',"import sys;sys.stdout.buffer.write(bytes(range(256))*512);sys.stdout.buffer.flush()"],mode='partial');assert r['exitCode']==0 and job.stdout==partial_data and job.partial>0
            job,r=run(['python3','-c',"from pathlib import Path;Path('/workspace/live.txt').write_text('native-visible');print('visible')"]);assert (work/'live.txt').read_text()=='native-visible'
            job,r=run(['python3','-c',"import sys;sys.stdout.buffer.write(b'x'*262144);sys.stdout.buffer.flush()"],mode='epipe');assert job.result['io_error']==errno.EPIPE and job.result['exit_code']==125 and r['success']is False
            job,r=run(['python3','-c',"print('tiny')"],mode='epipe');assert r['success']is False and r['exitCode']==125 and job.result['io_error']==errno.EPIPE
            for mode,code in [('blocked-input','import sys;sys.stdin.buffer.read(1)'),('blocked-output',"import sys;sys.stdout.buffer.write(b'x'*1048576);sys.stdout.buffer.flush()")]:
                job,r=run(['python3','-c',code],mode=mode,cancel=True);assert r.get('cancelled')is True and job.result['exit_code']==130,(r,job.result)
            old=jobs[-1].context;job,r=run(['python3','-c',"print('fresh')"]);assert r['exitCode']==0 and job.stdout==b'fresh\n'
            # Fresh context is now joined, so probe the old key before cleanup in a separate trusted invocation.
            probe=PipeJob(lib,[b'python3',b'--version'],999);jobs.append(probe);status=Status();assert lib.StruisVPStatusRead(probe.instance,C.byref(old),C.byref(status))==errno.EACCES;probe.terminal()
            args.scratch.joinpath('evidence.json').write_text(json.dumps({'actual_browser_python':True,'runner_sha256':hashlib.sha256(scripts['hyotan_runner.py']).hexdigest(),'resources':inventory,'source_sha256':{name:hashlib.sha256(content).hexdigest()for name,content in scripts.items()},'checker_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'partial_frame_budget':4093,'reports':reports,'old_context_denied':True,'apple_pending':True},ensure_ascii=False,indent=2)+'\n');print('PASS actual Pyodide binary stdio + real C pipes; evidence',args.scratch/'evidence.json')
        finally:
            for job in jobs:
                if not job.closed:job.terminal()
            browser.close()
            for server,operations in servers:server.shutdown();server.server_close();operations.stop()
if __name__=='__main__':main()
