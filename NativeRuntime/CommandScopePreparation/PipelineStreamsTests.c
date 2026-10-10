/* Apache-2.0. Actual selected ios_system TLS/ios_dup2 plus capture helper.
   Linux C composition evidence only; Objective-C/Apple runtime remain pending. */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "CommandScope.h"
#define NSLog(...) ((void)0)
static __thread FILE *thread_stdin,*thread_stdout,*thread_stderr;
static __thread void *thread_context;
static int duplicate_count,fail_duplicate,last_duplicate;
static int capture_dup(int fd) {
    duplicate_count++;
    if(fail_duplicate && duplicate_count==fail_duplicate) { errno=EMFILE;return -1; }
    last_duplicate=dup(fd);return last_duplicate;
}
#define dup capture_dup
/* SELECTED_CAPTURE_INSERT */
#undef dup
/* SELECTED_REDIRECT_INSERT */
static void release(FILE *i,FILE *o,FILE *e) {
    if(i)fclose(i);if(o && o!=i)fclose(o);if(e && e!=i && e!=o)fclose(e);
}
int main(void) {
    FILE *baseIn=tmpfile(),*baseOut=tmpfile(),*baseErr=tmpfile();
    FILE *targetIn=tmpfile(),*targetOut=tmpfile(),*targetErr=tmpfile();
    assert(baseIn && baseOut && baseErr && targetIn && targetOut && targetErr);
    thread_stdin=baseIn;thread_stdout=baseOut;thread_stderr=baseErr;
    int context=7;thread_context=&context;
    assert(StruisCommandScopeBegin()==0);
    assert(fputs("input",targetIn)>=0 && fflush(targetIn)==0 && fseek(targetIn,0,SEEK_SET)==0);
    assert(ios_dup2(dup(fileno(targetIn)),0)==0);
    assert(ios_dup2(dup(fileno(targetOut)),1)==1);
    assert(ios_dup2(1,2)==2 && child_stderr==child_stdout);
    FILE *pendingIn=child_stdin,*pendingOut=child_stdout;
    int inputFlags=fcntl(fileno(pendingIn),F_GETFL),outputFlags=fcntl(fileno(pendingOut),F_GETFL);
    FILE *i,*o,*e;void *captured;
    duplicate_count=0;assert(StruisIosCommandPipelineStreams(&i,&o,&e,&captured)==0);
    assert(duplicate_count==2 && i!=pendingIn && o!=pendingOut && o==e && captured==&context);
    assert(child_stdin==pendingIn && child_stdout==pendingOut && child_stderr==pendingOut);
    assert(thread_stdin==baseIn && thread_stdout==baseOut && thread_stderr==baseErr);
    assert(fcntl(fileno(pendingIn),F_GETFL)==inputFlags && fcntl(fileno(pendingOut),F_GETFL)==outputFlags);
    char bytes[6]={0};assert(fread(bytes,1,5,i)==5 && strcmp(bytes,"input")==0);
    assert(fputs("A",o)>=0 && fputs("B",e)>=0 && fflush(o)==0);
    char visible[4]={0};assert(pread(fileno(targetOut),visible,2,0)==2 && strcmp(visible,"AB")==0);
    assert(ftell(baseOut)==0 && ftell(baseErr)==0);
    FILE *oldIn=NULL,*oldOut=NULL,*oldErr=NULL;
    ios_activateChildStreams(&oldIn,&oldOut,&oldErr);
    assert(oldIn==baseIn && oldOut==baseOut && oldErr==baseErr);
    thread_stdin=oldIn;thread_stdout=oldOut;thread_stderr=oldErr;
    fclose(pendingIn);fclose(pendingOut); /* parent restore/cleanup before retained stage finishes */
    assert(fputs("C",o)>=0 && fflush(o)==0);
    memset(visible,0,sizeof(visible));assert(pread(fileno(targetOut),visible,3,0)==3 && strcmp(visible,"ABC")==0);
    release(i,o,e);
    assert(ios_dup2(dup(fileno(targetOut)),1)==1 && ios_dup2(dup(fileno(targetErr)),2)==2);
    pendingOut=child_stdout;FILE *pendingErr=child_stderr;
    assert(StruisIosCommandPipelineStreams(&i,&o,&e,&captured)==0 && o!=e);
    assert(fputs("E",e)>=0 && fflush(e)==0 && pread(fileno(targetErr),visible,1,0)==1 && visible[0]=='E');
    release(i,o,e);
    duplicate_count=0;fail_duplicate=2;
    assert(StruisIosCommandPipelineStreams(&i,&o,&e,&captured)==EMFILE);
    assert(!i && !o && !e && !captured && fcntl(last_duplicate,F_GETFD)==-1 && errno==EBADF);
    assert(child_stdout==pendingOut && child_stderr==pendingErr);
    assert(fcntl(fileno(pendingOut),F_GETFD)>=0 && fcntl(fileno(pendingErr),F_GETFD)>=0);
    fail_duplicate=0;child_stdout=child_stderr=NULL;fclose(pendingOut);fclose(pendingErr);
    thread_stdin=thread_stdout=thread_stderr=baseOut;duplicate_count=0;
    assert(StruisIosCommandPipelineStreams(&i,&o,&e,&captured)==0 && i==o && o==e && duplicate_count==1);
    release(i,o,e);
    assert(StruisCommandScopeEnd()==0);
    assert(StruisIosCommandPipelineStreams(&i,&o,&e,&captured)==EINVAL && !i && !o && !e && !captured);
    fclose(baseIn);fclose(baseOut);fclose(baseErr);fclose(targetIn);fclose(targetOut);fclose(targetErr);
    puts("PASS: exact selected ios_dup2 pending stdin/stdout/stderr capture; 2>&1 and all-pointer aliases; parent TLS/flags untouched; redirected bytes reach targets; retained duplicates survive parent restore/close; partial duplicate failure cleanup; unscoped rejection");
}
