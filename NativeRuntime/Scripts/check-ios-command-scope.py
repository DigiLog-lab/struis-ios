#!/usr/bin/env python3
"""Run finite Linux C lifecycle and exact generated pinned libc sections.
Does not claim Objective-C/iOS compilation or native Dash composition.
"""
import argparse
import importlib.util
import pathlib
import subprocess
import tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
SUPPORT=ROOT/'CommandScopePreparation'
PREFIX=r'''
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include "CommandScope.h"
#define MAXPATHLEN PATH_MAX
#ifndef W_EXITCODE
#define W_EXITCODE(ret,sig) ((ret)<<8|(sig))
#endif
static __thread FILE *thread_stdout,*thread_stderr;
char **environmentVariables(pid_t);
pid_t ios_currentPid(void);
int ios_getCommandStatus(void) {return StruisCommandScopeStatus();}
pthread_t ios_getLastThreadId(void) {return 0;}
void executeWebAssemblyCommandsInOrder(void) {}
void set_session_errno(int n) {StruisCommandScopeResult(n);}
static int chdir_calls;
int chdir_nolock(const char *path) {(void)path;__atomic_add_fetch(&chdir_calls,1,__ATOMIC_SEQ_CST);return 0;}
'''
TEST=r'''
typedef struct {pid_t id; char value[24];} Task;
static void done(void *unused) {
    (void)unused;resetEnvironment(ios_currentPid());
    ios_releaseThread(pthread_self()); /* must not chdir or release before cleanup */
    StruisCommandScopeFinish();
}
static void *child(void *argument) {
    Task *t=argument;assert(StruisCommandScopeAdopt(t->id)==0);
    assert(ios_currentPid()==t->id);
    assert(strcmp(libc_getenv("SCOPE_TEST"),t->value)==0);
    assert(ios_setenv("SCOPE_TEST","child",1)==0);
    assert(strcmp(libc_getenv("SCOPE_TEST"),"child")==0);
    pthread_cleanup_push(done,NULL);
    StruisCommandScopeResult(strcmp(t->value,"first")==0?42:73);
    pthread_cleanup_pop(1);return NULL;
}
static void *owner(void *argument) {
    char *value=argument;assert(StruisCommandScopeBegin()==0);storeEnvironment(environ);
    assert(ios_setenv("SCOPE_TEST",value,1)==0);
    for(int n=0;n<150;n++) {
        pid_t root=ios_currentPid(),id=ios_fork(),captured;
        assert(id>0 && ios_currentPid()==id);
        assert(StruisCommandScopeCapture(&captured)==0 && captured==id && ios_currentPid()==root);
        Task t={.id=id};snprintf(t.value,sizeof(t.value),"%s",value);
        pthread_t thread;assert(pthread_create(&thread,NULL,child,&t)==0);
        int status;assert(ios_full_waitpid(id,&status,0)==id && WEXITSTATUS(status)==(strcmp(value,"first")==0?42:73));
        assert(pthread_join(thread,NULL)==0);
        assert(strcmp(libc_getenv("SCOPE_TEST"),value)==0);
        assert(ios_full_waitpid(id,&status,WNOHANG)==-1 && errno==ECHILD);
    }
    resetEnvironment(ios_currentPid());assert(StruisCommandScopeEnd()==0);return NULL;
}
int main(void) {
    pthread_t a,b;assert(pthread_create(&a,NULL,owner,"first")==0);assert(pthread_create(&b,NULL,owner,"second")==0);
    assert(pthread_join(a,NULL)==0);assert(pthread_join(b,NULL)==0);
    assert(chdir_calls==0);assert(getenv("SCOPE_TEST")==NULL);
    puts("PASS: actual pinned generated libc fork/env/wait/release; 300 launches beyond fixed array size; two owners; no ambient env/cwd mutation; stale wait rejection");
}
'''
def run(args):
    subprocess.run([str(a) for a in args],check=True)
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--source',type=pathlib.Path,required=True);args=parser.parse_args()
    spec=importlib.util.spec_from_file_location('scope_generator',ROOT/'Scripts/prepare-ios-command-scope.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    with tempfile.TemporaryDirectory(prefix='hyotan-ios-scope-') as directory:
        tmp=pathlib.Path(directory);generated=module.prepare(args.source,tmp/'generated')
        rejected=tmp/'tampered';rejected.mkdir()
        for name in module.PINNED: (rejected/name).write_bytes((args.source/name).read_bytes())
        (rejected/'ios_system.m').write_text((rejected/'ios_system.m').read_text()+'\n')
        try: module.prepare(rejected,tmp/'should-not-exist')
        except ValueError: pass
        else: raise AssertionError('changed pinned source accepted')
        assert not (tmp/'should-not-exist').exists()
        first={p.name:p.read_bytes() for p in generated.iterdir()};module.prepare(args.source,generated)
        assert first=={p.name:p.read_bytes() for p in generated.iterdir()}
        run(['cc','-std=c11','-Wall','-Wextra','-Werror','-pthread',SUPPORT/'CommandScope.c',SUPPORT/'CommandScopeTests.c','-o',tmp/'lifecycle']);run([tmp/'lifecycle'])
        c=(generated/'libc_replacement.c').read_text();start=c.index('// Fake process IDs');end=c.index('\n//\nvoid vwarn',start)
        probe=tmp/'pinned-libc.c';probe.write_text(PREFIX+c[start:end]+TEST)
        run(['cc','-std=c11','-fgnu89-inline','-Wno-attributes','-Wno-int-conversion','-Wno-deprecated-declarations','-pthread','-I',SUPPORT,probe,SUPPORT/'CommandScope.c','-o',tmp/'pinned-libc']);run([tmp/'pinned-libc'])
        m=(generated/'ios_system.m').read_text()
        capture=m[m.index('static __thread FILE* child_stdin = NULL;'):m.index('\nFILE* ios_popen(')]
        redirect=m[m.index('int ios_dup2(int fd1, int fd2)'):m.index('\nint ios_kill(void)',m.index('int ios_dup2(int fd1, int fd2)'))]
        test=(SUPPORT/'PipelineStreamsTests.c').read_text().replace('/* SELECTED_CAPTURE_INSERT */',capture).replace('/* SELECTED_REDIRECT_INSERT */',redirect)
        probe=tmp/'pipeline-streams.c';probe.write_text(test)
        run(['cc','-std=c11','-Wall','-Wextra','-Werror','-Wno-misleading-indentation','-pthread','-I',SUPPORT,probe,SUPPORT/'CommandScope.c','-o',tmp/'pipeline-streams']);run([tmp/'pipeline-streams'])
        session=m[m.index('typedef struct _sessionParameters {'):m.index('} sessionParameters;')+len('} sessionParameters;')]
        parameters=m[m.index('typedef struct _functionParameters {'):m.index('} functionParameters;')+len('} functionParameters;')]
        adapter=(SUPPORT/'SessionAdapter.inc').read_text()
        # The ObjC scoped runner is replaced by a C replica below; require the
        # real one to reset the parser after adoption and before the command.
        runner=adapter[adapter.index('static void *StruisScopedRun('):adapter.index('static void StruisScopedDiscard(')]
        assert runner.index('StruisCommandScopeAdopt(')<runner.index('StruisScopedResetParser();')<runner.index('p->function(')
        selected=adapter[:adapter.index('static void *StruisScopedRun(')]+adapter[adapter.index('static void StruisScopedDiscard('):]
        objc_line='    else if([TeXcommands containsObject:[NSString stringWithUTF8String:command]]) TeXIsRunning[p->numInterpreter]=false;\n'
        assert selected.count(objc_line)==1
        selected=selected.replace(objc_line,'') # interpreter-only ObjC lookup cannot compile on Linux
        fixture=(SUPPORT/'SessionAdapterTestFixture.c').read_text()
        test=(SUPPORT/'SessionAdapterTestMain.c').read_text().replace('/* SELECTED_ADAPTER_INSERT */',selected)
        probe=tmp/'session-adapter.c';probe.write_text(PREFIX+c[start:end]+fixture+session+'\nstatic __thread sessionParameters *currentSession;\n'+parameters+m[m.index('int ios_killpid(pid_t pid, int sig) {'):m.index('\n\nvoid ios_switchSession',m.index('int ios_killpid(pid_t pid, int sig) {'))]+test)
        # Pinned BSD getopt used by selected commands. Its only stream use is the
        # illegal-option message, which this probe does not exercise; the probe's
        # thread_stderr is static, so getopt gets its own unused TLS stream.
        getopt=tmp/'getopt.o';(tmp/'getopt-stream.c').write_text('#include <stdio.h>\n__thread FILE *thread_stderr;\n')
        run(['cc','-c','-D__dead2=__attribute__((noreturn))','-include','stdio.h','-I',args.source,args.source/'getopt.c','-o',getopt])
        run(['cc','-c',tmp/'getopt-stream.c','-o',tmp/'getopt-stream.o'])
        run(['cc','-std=c11','-fgnu89-inline','-Wno-attributes','-Wno-int-conversion','-Wno-deprecated-declarations','-pthread','-I',SUPPORT,probe,getopt,tmp/'getopt-stream.o',SUPPORT/'CommandScope.c','-ldl','-o',tmp/'session-adapter']);run([tmp/'session-adapter'])
        print('PASS: exact-input hash rejection and deterministic generation checked; Apple Objective-C compile and full native Dash composition remain unverified')
if __name__=='__main__':main()
