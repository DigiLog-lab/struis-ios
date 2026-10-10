#!/usr/bin/env python3
"""Finite exact-pinned ios_system scope overlay. Explicit trusted opt-in only.
No product default, parser replacement, or process cwd isolation is introduced.
"""
import argparse
import hashlib
import pathlib
import re
import shutil
PINNED = {
    'libc_replacement.c': '731f653325ddf9f994a6d8f46a98f5bc68546779902315c37718fc85574d4640',
    'ios_system.m': 'd78e20c066565959902e249b68aa7b0fe66bca11f2e1c1b4d51879cee0278964',
}
ROOT=pathlib.Path(__file__).resolve().parents[1]
SUPPORT=ROOT/'CommandScopePreparation'
def replace(text, before, after):
    count=text.count(before)
    if count!=1: raise ValueError(f'Pinned anchor count {count}: {before[:80]!r}')
    return text.replace(before,after,1)
def prepare(source, output):
    texts={name:(source/name).read_text() for name in PINNED}
    for name,digest in PINNED.items():
        if hashlib.sha256((source/name).read_bytes()).hexdigest()!=digest:
            raise ValueError(f'Unexpected pinned source: {name}')
    c=texts['libc_replacement.c']
    c='#include "CommandScope.h"\n'+c
    c=replace(c,'static pid_t current_pid = 0;', 'static pid_t legacy_current_pid = 0;\n#define current_pid (* (StruisCommandScopeEnabled() ? StruisCommandScopePidAddress() : &legacy_current_pid))')
    # Every environment/cwd array consumer receives an owner-validated slot;
    # monotonic public PID never indexes the upstream fixed arrays directly.
    arrays={'numVariablesSet':'int','environment':'char**','copyEnvironment':'char**','previousDirectory':'directory','previousPid':'int'}
    for array in arrays:
        c=re.sub(r'\b'+array+r'\[([^\[\]]+)\]',lambda m:m[0] if m[1]=='IOS_MAX_THREADS' else f'STRUIS_SLOT({array}, {m[1]})',c)
    marker='static int pid_overflow = 0;'
    storage='''static int scoped_numVariablesSet[IOS_MAX_THREADS];
static char** scoped_environment[IOS_MAX_THREADS];
static char** scoped_copyEnvironment[IOS_MAX_THREADS];
static char scoped_previousDirectory[IOS_MAX_THREADS][MAXPATHLEN];
static int scoped_previousPid[IOS_MAX_THREADS];
/* Only live trusted IDs are legal here. Scoped backing arrays never alias legacy arrays. */
#define STRUIS_SLOT(array, id) (*(StruisCommandScopeEnabled() ? scoped_##array + StruisCommandScopeEnvironmentIndex(id) : array + (id)))
'''
    c=replace(c,marker,storage+marker)
    c=replace(c,'static inline const pid_t ios_nextAvailablePid(void) {','''static inline const pid_t ios_nextAvailablePid(void) {
    if(StruisCommandScopeEnabled()) {
        pid_t parent=current_pid;
        char **parentEnvironment=environmentVariables(parent);
        pid_t child=StruisCommandScopeFork();
        if(child<0) return child;
        STRUIS_SLOT(previousPid,child)=parent;
        storeEnvironment(parentEnvironment);
        return child;
    }''')
    c=replace(c,'inline void ios_storeThreadId(pthread_t thread) {','''inline void ios_storeThreadId(pthread_t thread) {
    if(StruisCommandScopeEnabled()) {
        if(!thread) StruisCommandScopeLaunchFailed(ios_currentPid(),StruisCommandScopeStatus());
        return;
    }''')
    for signature in ['void ios_releaseThread(pthread_t thread) {','void ios_releaseBackgroundThread(pthread_t thread) {','void ios_releaseThreadId(pid_t pid) {']:
        c=replace(c,signature,signature+'\n    if(StruisCommandScopeEnabled()) return; /* child cleanup owns completion; never process chdir */')
    c=replace(c,'inline pthread_t ios_getThreadId(pid_t pid) {','''inline pthread_t ios_getThreadId(pid_t pid) {
    if(StruisCommandScopeEnabled()) return StruisCommandScopeThread(pid);''')
    c=replace(c,'__attribute__ ((optnone)) void ios_waitpid(pid_t pid) {','''__attribute__ ((optnone)) void ios_waitpid(pid_t pid) {
    if(StruisCommandScopeEnabled()) { int result; int error=StruisCommandScopeWait(pid,0,&result); if(error) {errno=error;StruisCommandScopeResult(error);} return; }''')
    for signature in ['__attribute__ ((optnone)) pid_t waitpid(pid_t pid, int *stat_loc, int options) {','__attribute__ ((optnone)) pid_t ios_full_waitpid(pid_t pid, int *stat_loc, int options) {']:
        c=replace(c,signature,signature+'''
    if(StruisCommandScopeEnabled()) {
        int result; int error=StruisCommandScopeWait(pid,(options&WNOHANG)!=0,&result);
        if(error==EAGAIN && (options&WNOHANG)) return 0;
        if(error) {errno=error;return -1;}
        if(stat_loc) *stat_loc=W_EXITCODE(result,0); return pid;
    }''')
    for signature in ['int ios_setenv_pid(const char* variableName, const char* value, int overwrite, int pid) {','int ios_unsetenv_pid(const char* variableName, int pid) {']:
        c=replace(c,signature,signature+'\n    if(StruisCommandScopeEnabled() && StruisCommandScopeEnvironmentIndex(pid)<0) {errno=ECHILD;return -1;}')
    c=replace(c,'void clearEnvironment(pid_t pid) {','void clearEnvironment(pid_t pid) {\n    if(StruisCommandScopeEnabled() && StruisCommandScopeEnvironmentIndex(pid)<0) return;')
    for signature in ['void makeGlobal(void) {','void makeLocal(void) {']:
        c=replace(c,signature,signature+'\n    if(StruisCommandScopeEnabled()) return; /* scope-local environment never becomes ambient */')
    # Public unknown/cross-owner environment PID cannot become an ambient array read.
    c=replace(c,'char** environmentVariables(pid_t pid) {','''char** environmentVariables(pid_t pid) {
    if(StruisCommandScopeEnabled() && StruisCommandScopeEnvironmentIndex(pid)<0) {errno=ECHILD;return NULL;}''')
    c=replace(c,'void resetEnvironment(pid_t pid) {','''void resetEnvironment(pid_t pid) {
    if(StruisCommandScopeEnabled() && StruisCommandScopeEnvironmentIndex(pid)<0) return;''')
    m=texts['ios_system.m']
    m='#include "CommandScope.h"\n#include "IosCommandScope.h"\n'+m
    m=replace(m,'static __thread FILE* child_stderr = NULL;',
              'static __thread FILE* child_stderr = NULL;\n'+(SUPPORT/'PipelineStreams.inc').read_text())
    m=replace(m,'    sessionParameters* session;\n} functionParameters;','''    sessionParameters* session;
    pid_t scopedPid;
    bool scopedOwnIn, scopedOwnOut, scopedOwnErr;
} functionParameters;''')
    m=replace(m,'static void cleanup_function(void* parameters) {',(SUPPORT/'SessionAdapter.inc').read_text()+'\nstatic void cleanup_function(void* parameters) {')
    m=replace(m,'int ios_getCommandStatus(void) {','int ios_getCommandStatus(void) {\n    if(StruisCommandScopeEnabled()) return StruisCommandScopeStatus();')
    m=replace(m,'int ios_killpid(pid_t pid, int sig) {','int ios_killpid(pid_t pid, int sig) {\n    if(StruisCommandScopeEnabled()) return StruisCommandScopeSignal(pid,sig);')
    for signature in ['void ios_exit(int n) {','void set_session_errno(int n) {']:
        m=replace(m,signature,signature+'\n    if(StruisCommandScopeEnabled()) StruisCommandScopeResult(n);')
    anchor='            if (currentSession->isMainThread) {\n                params->storeRootThread = true;'
    m=replace(m,anchor,'''            if(StruisCommandScopeEnabled()) {
                int error=StruisScopedLaunch(params);
                free(originalCommand);
                return error;
            }
'''+anchor)
    m=m.replace('ios_storeThreadId(0);', 'if(StruisCommandScopeEnabled()) StruisCommandScopeResult(currentSession->global_errno);\n        ios_storeThreadId(0);')
    # unknown command records its own reserved PID failure before legacy store(0).
    m=replace(m,'            currentSession->global_errno = 127;','            currentSession->global_errno = 127;')
    m=replace(m,'            if(StruisCommandScopeEnabled()) StruisCommandScopeResult(currentSession->global_errno);\n        ios_storeThreadId(0);\n            currentSession->global_errno = 127;', '            currentSession->global_errno = 127;\n            if(StruisCommandScopeEnabled()) StruisCommandScopeResult(127);\n            ios_storeThreadId(0);')
    output.mkdir(parents=True,exist_ok=True)
    (output/'libc_replacement.c').write_text(c)
    (output/'ios_system.m').write_text(m)
    for name in ['CommandScope.c','CommandScope.h','IosCommandScope.h']:
        shutil.copyfile(SUPPORT/name,output/name)
    return output
if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--source',type=pathlib.Path,required=True); parser.add_argument('--output',type=pathlib.Path,required=True)
    args=parser.parse_args(); prepare(args.source,args.output)
