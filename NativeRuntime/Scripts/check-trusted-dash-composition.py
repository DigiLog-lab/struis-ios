#!/usr/bin/env python3
"""Real pinned dash images + production TrustedPipeline + exact scoped PID/FILE C.
Linux checks AST/state/thread ownership; Apple command resolver and dash stdio
interposition are explicitly pending, not simulated by an alternate evaluator.
"""
import argparse, importlib.util, pathlib, shutil, subprocess, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
def module(name):
    spec=importlib.util.spec_from_file_location(name, ROOT/'Scripts'/name)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
TEST=r'''
#include "TrustedPipeline.h"
#include <dlfcn.h>
typedef int (*Evaluate)(char *,int *,int);
static StruisDashEntry entry[8];
static int timeoutCase, pendingCase, aliasCase, failureCase, liveInput, liveOutput, liveError;
static atomic_uint starts;
static int fdcount(void) {int count=0;for(int n=0;n<1024;n++)if(fcntl(n,F_GETFD)>=0)count++;return count;}
static int ownedPipe(int *fds) {if(failureCase){errno=EIO;return -1;}return pipe(fds);}
static _Atomic(const struct StruisDashStageSnapshot *) liveSnapshot;
static const char *(*lookup[8])(const char *);
static int stage(unsigned n,const struct StruisDashStageSnapshot *s,int *code) {
    atomic_fetch_add(&starts,1);
    assert(StruisCommandScopeEnabled());
    assert(thread_stdin && thread_stdout && thread_stderr && currentSession);
    pid_t root=ios_currentPid(), child=ios_fork(), captured;
    assert(child>0 && StruisCommandScopeCapture(&captured)==0 && captured==child && ios_currentPid()==root);
    StruisCommandScopeLaunchFailed(child,73);int status;
    assert(ios_full_waitpid(child,&status,0)==child && WEXITSTATUS(status)==73);
    if (timeoutCase && n==0) {liveInput=fileno(thread_stdin);liveOutput=fileno(thread_stdout);liveError=fileno(thread_stderr);atomic_store(&liveSnapshot,s);}
    int error=entry[n](s,code);
    assert(!error && strcmp(lookup[n]("result"),"parent|日本語|locked|first|fixture-zero")==0);
    assert(strcmp(lookup[n]("secret"),"child")==0);
    if (pendingCase) {
        /* Native FILE operations are acceptance callers, not replacement
           shell commands. The AST above always runs the real evaluator. */
        assert(fgetc(thread_stdin)=='x');
        assert(fputc('x',thread_stdout)=='x');
        assert(fputc('e',thread_stderr)=='e');
        if (n==1 && aliasCase) assert(thread_stdout==thread_stderr);
    }
    return error;
}
#define STAGE(N) static int stage##N(const struct StruisDashStageSnapshot *s,int *c) {return stage(N,s,c);}
STAGE(0) STAGE(1) STAGE(2) STAGE(3) STAGE(4) STAGE(5) STAGE(6) STAGE(7)
static int streams(FILE **i,FILE **o,FILE **e,void **c) {return StruisIosCommandPipelineStreams(i,o,e,c);}
int main(int argc,char **argv) {
    assert(argc==10);
    timeoutCase=getenv("COMPOSITION_TIMEOUT")!=NULL;
    pendingCase=getenv("COMPOSITION_PENDING")!=NULL;
    aliasCase=getenv("COMPOSITION_ALIAS")!=NULL;
    failureCase=getenv("COMPOSITION_FAILURE")!=NULL;
    void *root=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);assert(root);
    struct StruisTrustedDashAPI api={.enter={stage0,stage1,stage2,stage3,stage4,stage5,stage6,stage7},
       .scopeBegin=StruisIosCommandScopeBegin,.scopeEnd=StruisIosCommandScopeEnd,.ownedPipe=ownedPipe,.streams=streams};
    api.retain=dlsym(root,"StruisDashSnapshotRetain");api.release=dlsym(root,"StruisDashSnapshotDestroy");
    for(unsigned n=0;n<8;n++) {void *image=dlopen(argv[n+2],RTLD_NOW|RTLD_LOCAL);assert(image);
       entry[n]=dlsym(image,"StruisDashStageEnter");lookup[n]=dlsym(image,"lookupvar");
       api.install[n]=dlsym(image,"StruisDashInstallPipelineLauncher");}
    assert(StruisTrustedDashConfigure(&api)==0);
    FILE *in=tmpfile(),*out=tmpfile();assert(in && out);
    assert(StruisIosCommandScopeBegin(in,out,out,NULL)==0);
    FILE *redirectIn=NULL,*redirectOut=NULL,*redirectErr=NULL;
    if (pendingCase) {
        redirectIn=tmpfile();redirectOut=tmpfile();redirectErr=aliasCase?redirectOut:tmpfile();
        assert(redirectIn && redirectOut && redirectErr);
        assert(fputs("x",redirectIn)>=0 && fflush(redirectIn)==0 && fseek(redirectIn,0,SEEK_SET)==0);
        assert(ios_dup2(dup(fileno(redirectIn)),0)==0);
        assert(ios_dup2(dup(fileno(redirectOut)),1)==1);
        assert(ios_dup2(aliasCase?1:dup(fileno(redirectErr)),2)==2);
        assert(child_stdin && child_stdout && child_stderr);
        assert(thread_stdin==in && thread_stdout==out && thread_stderr==out);
    }
    FILE *pendingIn=child_stdin,*pendingOut=child_stdout,*pendingErr=child_stderr;
    int (*install)(StruisDashPipelineLauncher,void*)=dlsym(root,"StruisDashInstallPipelineLauncher");
    Evaluate evaluate=dlsym(root,"StruisDashHostEvaluateFlags");assert(install && evaluate);
    assert(install(StruisTrustedDashPipeline,NULL)==0);
    int code=125;
    char script[]="secret=parent; readonly ro=locked; set -- first second; set -f; f() { result=\"$secret|日本語|$ro|$1|$0\"; secret=child; }; { f \"$1\"; } | { f \"$1\"; }";
    char blocked[]="secret=parent; readonly ro=locked; set -- first second; f() { result=\"$secret|日本語|$ro|$1|$0\"; secret=child; }; { while :; do :; done; } | { f \"$1\"; }";
    int before=fdcount();
    assert(evaluate(timeoutCase?blocked:script,&code,0)==0);
    if(failureCase) assert(code!=0 && atomic_load(&starts)==0 && fdcount()==before && StruisCompoundDashWorkerSpent()==1);
    assert(thread_stdin==in && thread_stdout==out && thread_stderr==out);
    assert(child_stdin==pendingIn && child_stdout==pendingOut && child_stderr==pendingErr);
    if (pendingCase) {
        if (!timeoutCase && !failureCase) {
            unsigned char bytes[8];
            ssize_t n=pread(fileno(redirectOut),bytes,sizeof(bytes),0);
            if (aliasCase) {assert(n==3);int xs=0,es=0;for(int j=0;j<n;j++){xs+=bytes[j]=='x';es+=bytes[j]=='e';}assert(xs==1 && es==2);}
            else {assert(n==1 && bytes[0]=='x');assert(pread(fileno(redirectErr),bytes,sizeof(bytes),0)==2 && bytes[0]=='e' && bytes[1]=='e');}
            assert(lseek(fileno(out),0,SEEK_END)==0);
        }
        /* Exact activation clears pending TLS, then the shell restores its
           borrowed outer tuple. Closing original redirects must not close a
           retained stage's independent descriptor on timeout. */
        FILE *oldIn=NULL,*oldOut=NULL,*oldErr=NULL;
        ios_activateChildStreams(&oldIn,&oldOut,&oldErr);
        assert(oldIn==in && oldOut==out && oldErr==out);
        FILE *activeIn=thread_stdin,*activeOut=thread_stdout,*activeErr=thread_stderr;
        thread_stdin=oldIn;thread_stdout=oldOut;thread_stderr=oldErr;
        fclose(activeIn);fclose(activeOut);if(activeErr!=activeOut)fclose(activeErr);
        fclose(redirectIn);fclose(redirectOut);if(redirectErr!=redirectOut)fclose(redirectErr);
    }
    if (timeoutCase) {
        assert(code!=0 && StruisCompoundDashWorkerSpent()==1);
        const struct StruisDashStageSnapshot *live=atomic_load(&liveSnapshot);
        assert(live && atomic_load(&live->references)==1 && fcntl(liveInput,F_GETFD)>=0 && fcntl(liveOutput,F_GETFD)>=0 && fcntl(liveError,F_GETFD)>=0);
        puts("PASS: real dash blocked evaluator timeout preserves retained snapshot and FILE descriptor; consumed worker/slots require physical exit");
        assert(StruisIosCommandScopeEnd()==0);fclose(in);fclose(out);
        assert(fcntl(liveInput,F_GETFD)>=0 && fcntl(liveOutput,F_GETFD)>=0 && fcntl(liveError,F_GETFD)>=0);
        /* Ordinary libc exit flushes all open FILEs and can wait on a live
           blocked reader's FILE lock. Physical worker termination must bypass
           in-process teardown of these deliberately retained evaluator tuples. */
        assert(fflush(stdout)==0);
        _exit(0);
    }
    assert(failureCase?code!=0:code==0);
    const char *(*parentLookup)(const char*)=dlsym(root,"lookupvar");
    assert(strcmp(parentLookup("secret"),"parent")==0 && parentLookup("result")==NULL);
    assert(StruisCompoundDashWorkerSpent()==1);
    assert(StruisIosCommandScopeEnd()==0);
    fclose(in);fclose(out);
    if (failureCase) {puts("PASS: reserved pipeline pipe failure closes owned capture tuple, leaves pending redirects unchanged, starts no evaluator, and reports spent");return 0;}
    if (pendingCase) puts("PASS: production launcher uses exact ios_dup2 pending enclosing stdin/stdout/stderr; aliases and targets preserved; activation/restoration leaves original output untouched");
    puts("PASS: real pinned dash parsed compound AST; production pthread launcher; ABI3 retained snapshots; isolated function/readonly/positional/options state; exact scoped FILE/PID begin/fork/wait/end; typed spent receipt");
}
'''
def main():
    p=argparse.ArgumentParser();p.add_argument('--dash-source',type=pathlib.Path,required=True);p.add_argument('--ios-source',type=pathlib.Path,required=True);a=p.parse_args()
    work=pathlib.Path(tempfile.mkdtemp(prefix='hyotan-trusted-composition-'))
    dash=module('check-dash-stage.py')
    clean=work/'source';shutil.copytree(a.dash_source,clean,symlinks=True,ignore=shutil.ignore_patterns('*.o','dash','mkinit','mknodes','mksyntax','host-fixture.c'))
    library=dash.build(clean,work/'dash')
    scope=module('prepare-ios-command-scope.py').prepare(a.ios_source,work/'scope')
    fixture=module('check-ios-command-scope.py')
    c=(scope/'libc_replacement.c').read_text();selected=c[c.index('// Fake process IDs'):c.index('\n//\nvoid vwarn',c.index('// Fake process IDs'))]
    m=(scope/'ios_system.m').read_text();session=m[m.index('typedef struct _sessionParameters {'):m.index('} sessionParameters;')+len('} sessionParameters;')]
    adapter=(ROOT/'CommandScopePreparation/SessionAdapter.inc').read_text()
    helpers=adapter[:adapter.index('static void StruisScopedCleanup')]
    begin=adapter[adapter.index('/* Trusted outer stage wraps'):]
    init='static void initSessionParameters(sessionParameters *s) {memset(s,0,sizeof(*s));s->numCommandsAllocated=1;s->commandName=calloc(1,sizeof(char*));s->commandName[0]=calloc(NAME_MAX,1);}\n'
    declarations=(ROOT/'CommandScopePreparation/SessionAdapterTestFixture.c').read_text()
    capture=m[m.index('static __thread FILE* child_stdin = NULL;'):m.index('\nFILE* ios_popen(')]
    redirect=m[m.index('int ios_dup2(int fd1, int fd2)'):m.index('\nint ios_kill(void)',m.index('int ios_dup2(int fd1, int fd2)'))]
    probe=work/'composition.c';probe.write_text(fixture.PREFIX+selected+declarations+session+'\nstatic __thread sessionParameters *currentSession;\n'+init+helpers+begin+capture+'\n#define NSLog(...) ((void)0)\n'+redirect+TEST)
    binary=work/'composition'
    subprocess.run(['cc','-std=c11','-fgnu89-inline','-Wno-attributes','-Wno-int-conversion','-Wno-deprecated-declarations','-pthread','-I',str(scope),'-I',str(ROOT/'DashPipelinePreparation'),str(probe),str(scope/'CommandScope.c'),str(ROOT/'DashPipelinePreparation/TrustedPipeline.c'),'-ldl','-o',str(binary)],check=True)
    images=[]
    for n in range(9):
        dest=work/f'image{n}.so';shutil.copy2(library,dest);images.append(str(dest))
    subprocess.run([str(binary),*images],check=True,timeout=15)
    import os
    for selectors in [dict(COMPOSITION_PENDING='1'),dict(COMPOSITION_PENDING='1',COMPOSITION_ALIAS='1'),dict(COMPOSITION_FAILURE='1',COMPOSITION_PENDING='1',COMPOSITION_ALIAS='1'),dict(COMPOSITION_TIMEOUT='1'),dict(COMPOSITION_TIMEOUT='1',COMPOSITION_PENDING='1',COMPOSITION_ALIAS='1')]:
        subprocess.run([str(binary),*images],env=dict(os.environ,**selectors),check=True,timeout=15)
    print('EVIDENCE',work)
    print('PENDING: Apple SDK compile/link/signing and actual ios_system resolver/stdio/provider duplex; Linux host stdio is not iOS evidence')
if __name__=='__main__':main()
