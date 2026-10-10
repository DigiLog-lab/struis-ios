/* Apache-2.0. Real pthread/pipe lifecycle verification, not a shell substitute. */
#define _POSIX_C_SOURCE 200809L
#include "CommandScope.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
static pthread_barrier_t owners_ready;
static pid_t owner_ids[2];
typedef struct {pid_t id; int result; int input; int output; int nested;} Task;
static void cleanup(void *unused) {(void)unused;StruisCommandScopeFinish();}
static void *child(void *argument) {
    Task *t=argument;
    assert(StruisCommandScopeAdopt(t->id)==0);
    assert(pthread_equal(StruisCommandScopeThread(t->id),pthread_self()));
    pthread_cleanup_push(cleanup,NULL);
    if(t->nested) {
        pid_t n=StruisCommandScopeFork(), captured; assert(n>0); assert(StruisCommandScopeCapture(&captured)==0 && captured==n);
        Task task={.id=n,.result=61,.input=-1,.output=-1}; pthread_t thread;
        assert(pthread_create(&thread,NULL,child,&task)==0);
        int result; assert(StruisCommandScopeWait(n,0,&result)==0 && result==61); assert(pthread_join(thread,NULL)==0);
    }
    if(t->input>=0) { char byte; assert(read(t->input,&byte,1)==1); assert(write(t->output,&byte,1)==1); }
    StruisCommandScopeResult(t->result);
    pthread_cleanup_pop(1);
    return NULL;
}
static void *owner(void *argument) {
    int expected=*(int*)argument;
    assert(StruisCommandScopeBegin()==0);
    int index=expected==42?0:1;owner_ids[index]=StruisCommandScopeCurrentPid();(void)pthread_barrier_wait(&owners_ready);
    int foreignResult;
    assert(StruisCommandScopeWait(owner_ids[1-index],1,&foreignResult)==ECHILD);
    assert(!StruisCommandScopeThread(owner_ids[1-index]));
    assert(StruisCommandScopeSignal(owner_ids[1-index],0)==ESRCH);
    assert(StruisCommandScopeEnvironmentIndex(owner_ids[1-index])<0);
    assert(StruisCommandScopeSignal(owner_ids[index],0)==0);
    for(int iteration=0;iteration<200;iteration++) {
        pid_t root=StruisCommandScopeCurrentPid(); int rootIndex=StruisCommandScopeEnvironmentIndex(root);
        pid_t id=StruisCommandScopeFork(), captured; assert(id>0); assert(!StruisCommandScopeThread(id) && StruisCommandScopeSignal(id,0)==EAGAIN); int childIndex=StruisCommandScopeEnvironmentIndex(id); assert(rootIndex!=childIndex);
        assert(StruisCommandScopeCapture(&captured)==0 && captured==id && StruisCommandScopeCurrentPid()==root);
        int descriptors[2]; assert(pipe(descriptors)==0);
        Task task={.id=id,.result=expected,.input=descriptors[0],.output=descriptors[1],.nested=1};
        pthread_t thread; assert(pthread_create(&thread,NULL,child,&task)==0);
        assert(StruisCommandScopeCanEnd()==EBUSY);
        char byte='x';assert(write(descriptors[1],&byte,1)==1);
        int result;assert(StruisCommandScopeWait(id,0,&result)==0 && result==expected);
        assert(StruisCommandScopeStatus()==expected);
        assert(pthread_join(thread,NULL)==0); close(descriptors[0]);close(descriptors[1]);
        assert(StruisCommandScopeWait(id,1,&result)==ECHILD); /* no stale PID reuse */
    }
    pid_t failed=StruisCommandScopeFork(), captured; assert(StruisCommandScopeCapture(&captured)==0);
    StruisCommandScopeLaunchFailed(failed,EAGAIN);
    int result; assert(StruisCommandScopeWait(failed,0,&result)==0 && result==EAGAIN);
    assert(StruisCommandScopeCanEnd()==0 && StruisCommandScopeEnd()==0);
    return NULL;
}
static void *blocked(void *argument) {
    Task *task=argument; assert(StruisCommandScopeAdopt(task->id)==0);
    pthread_cleanup_push(cleanup,NULL);
    char byte; (void)read(task->input,&byte,1);
    pthread_cleanup_pop(1); return NULL;
}
int main(void) {
    int first=42,second=73;pthread_t a,b;assert(pthread_barrier_init(&owners_ready,NULL,2)==0);
    assert(pthread_create(&a,NULL,owner,&first)==0);assert(pthread_create(&b,NULL,owner,&second)==0);
    assert(pthread_join(a,NULL)==0);assert(pthread_join(b,NULL)==0);assert(pthread_barrier_destroy(&owners_ready)==0);
    assert(StruisCommandScopeBegin()==0);
    int descriptors[2];assert(pipe(descriptors)==0);
    pid_t id=StruisCommandScopeFork(), captured;assert(StruisCommandScopeCapture(&captured)==0);
    Task task={.id=id,.input=descriptors[0]};pthread_t thread;assert(pthread_create(&thread,NULL,blocked,&task)==0);
    /* Wait until adoption using synchronized state, without sleeps. */
    int running=0;do { assert(StruisCommandScopeObserve(id,&running)==0); } while(StruisCommandScopeEnvironmentIndex(id)<0);
    assert(pthread_cancel(thread)==0); assert(pthread_join(thread,NULL)==0);
    int result;assert(StruisCommandScopeWait(id,0,&result)==0 && result==127);
    close(descriptors[0]);close(descriptors[1]);assert(StruisCommandScopeEnd()==0);
    assert(StruisCommandScopeBegin()==0 && StruisCommandScopeEnd()==0);
    puts("PASS: concurrent owners; 400 nested launches; 800 child waits; owned results; monotonic stale rejection; simulated creation failure; real pipe cancellation; next scope");
}
