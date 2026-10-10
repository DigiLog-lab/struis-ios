/* Apache-2.0. No model-facing capability is issued here. */
#include "CommandScope.h"
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <limits.h>
#define SLOTS 128
#define WAIT_SECONDS 10
/* IDs are never reused in a process: delayed PID requests cannot alias a new stage. */
typedef struct { pid_t id, parent; uint64_t owner; pthread_t thread; int state, result; } Slot;
static Slot slots[SLOTS];
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static pid_t next_id = 1;
static uint64_t next_owner = 1;
static __thread uint64_t owner;
static __thread pid_t pid;
static __thread int status;
static __thread pid_t active_pid;
static Slot *find(pid_t id) { for (int i=0;i<SLOTS;i++) if(slots[i].state && slots[i].id==id && slots[i].owner==owner) return &slots[i]; return NULL; }
static void unlock(void *unused) { (void)unused; pthread_mutex_unlock(&mutex); }
int StruisCommandScopeEnabled(void) { return owner != 0; }
pid_t *StruisCommandScopePidAddress(void) { return &pid; }
int StruisCommandScopeBegin(void) {
    if(owner) return EBUSY;
    pthread_mutex_lock(&mutex);
    if(next_owner==UINT64_MAX) { pthread_mutex_unlock(&mutex); return EOVERFLOW; }
    Slot *root=NULL;
    for(int i=1;i<SLOTS;i++) if(!slots[i].state) { root=&slots[i]; break; }
    if(!root || next_id==INT_MAX) { pthread_mutex_unlock(&mutex); return EAGAIN; }
    owner=next_owner++; pid=next_id++; active_pid=pid; status=0;
    *root=(Slot){.id=pid,.parent=0,.owner=owner,.thread=pthread_self(),.state=2};
    pthread_mutex_unlock(&mutex); return 0;
}
int StruisCommandScopeEnd(void) {
    if(!owner) return EINVAL;
    pthread_mutex_lock(&mutex);
    Slot *self=find(pid); if(!self || self->parent!=0 || !pthread_equal(self->thread,pthread_self())) { pthread_mutex_unlock(&mutex); return EINVAL; }
    for(int i=1;i<SLOTS;i++) if(slots[i].owner==owner && slots[i].state && slots[i].id!=pid) { pthread_mutex_unlock(&mutex); return EBUSY; }
    Slot *root=find(pid); if(root) memset(root,0,sizeof(*root));
    pthread_mutex_unlock(&mutex); owner=0; pid=0; active_pid=0; return 0;
}
pid_t StruisCommandScopeFork(void) {
    pthread_mutex_lock(&mutex);
    Slot *s=NULL;
    for(int i=1;i<SLOTS;i++) if(!slots[i].state) {s=&slots[i];break;}
    if(!owner || !s || next_id==INT_MAX) { pthread_mutex_unlock(&mutex); errno=EAGAIN; return -1; }
    *s=(Slot){.id=next_id++, .parent=pid, .owner=owner, .state=1, .result=127};
    pid=s->id;
    pthread_mutex_unlock(&mutex); return pid;
}
int StruisCommandScopeCapture(pid_t *child) {
    pthread_mutex_lock(&mutex);
    Slot *s=find(pid);
    if(!s || s->state!=1) { pthread_mutex_unlock(&mutex); return EINVAL; }
    *child=pid; pid=s->parent;
    pthread_mutex_unlock(&mutex); return 0;
}
int StruisCommandScopeAdopt(pid_t child) {
    pthread_mutex_lock(&mutex);
    Slot *s=NULL;
    for(int i=0;i<SLOTS;i++) if(slots[i].id==child && slots[i].state==1) {s=&slots[i];break;}
    if(!s) { pthread_mutex_unlock(&mutex); return ESRCH; }
    owner=s->owner; pid=child; active_pid=child; status=127; s->thread=pthread_self(); s->state=2;
    pthread_mutex_unlock(&mutex); return 0;
}
void StruisCommandScopeResult(int result) { status=result; }
void StruisCommandScopeFinish(void) {
    pthread_mutex_lock(&mutex);
    Slot *s=find(pid);
    if(s && s->state==2 && pthread_equal(s->thread,pthread_self())) { s->result=status; s->state=3; active_pid=0; pid=s->parent; pthread_cond_broadcast(&changed); }
    pthread_mutex_unlock(&mutex);
}
void StruisCommandScopeLaunchFailed(pid_t child, int error) {
    pthread_mutex_lock(&mutex);
    Slot *s=find(child);
    if(s && s->state==1) { s->result=error; s->state=3; if(pid==child) pid=s->parent; pthread_cond_broadcast(&changed); }
    pthread_mutex_unlock(&mutex);
}
int StruisCommandScopeWait(pid_t child, int nohang, int *result) {
    int error=0;
    struct timespec deadline; clock_gettime(CLOCK_REALTIME,&deadline); deadline.tv_sec+=WAIT_SECONDS;
    pthread_mutex_lock(&mutex);
    pthread_cleanup_push(unlock,NULL);
    Slot *s=find(child);
    if(!s || s->parent!=pid) error=ECHILD;
    else {
        while(s->state!=3 && !nohang && !error) error=pthread_cond_timedwait(&changed,&mutex,&deadline);
        if(!error && s->state==3) { status=s->result; if(result) *result=status; memset(s,0,sizeof(*s)); }
        else if(!error) error=EAGAIN;
    }
    pthread_cleanup_pop(1);
    return error;
}
int StruisCommandScopeStatus(void) { return status; }

pid_t StruisCommandScopeCurrentPid(void) { return pid; }

int StruisCommandScopeEnvironmentIndex(pid_t id) {
    pthread_mutex_lock(&mutex); Slot *s=find(id); int index=s?(int)(s-slots):-1; pthread_mutex_unlock(&mutex); return index;
}
int StruisCommandScopeObserve(pid_t child, int *running) {
    pthread_mutex_lock(&mutex); Slot *s=find(child); int error=s?0:ECHILD;
    if(s) *running=s->state!=3;
    pthread_mutex_unlock(&mutex); return error;
}

int StruisCommandScopeCanEnd(void) {
    if(!owner) return EINVAL;
    pthread_mutex_lock(&mutex); int error=0;
    for(int i=1;i<SLOTS;i++) if(slots[i].state && slots[i].owner==owner && slots[i].id!=pid) error=EBUSY;
    Slot *root=find(pid); if(!root || root->parent!=0 || !pthread_equal(root->thread,pthread_self())) error=EINVAL;
    pthread_mutex_unlock(&mutex); return error;
}

pthread_t StruisCommandScopeThread(pid_t child) {
    /* Own-thread introspection must remain lock-free for native signal handlers. */
    if(owner && child==active_pid) return pthread_self();
    pthread_mutex_lock(&mutex); Slot *s=find(child); pthread_t thread=(pthread_t)0;
    if(s && s->state==2) thread=s->thread;
    pthread_mutex_unlock(&mutex); return thread;
}
int StruisCommandScopeSignal(pid_t child, int signal) {
    pthread_mutex_lock(&mutex); Slot *s=find(child);
    int error=!s?ESRCH:s->state==1?EAGAIN:s->state!=2?ESRCH:pthread_kill(s->thread,signal);
    pthread_mutex_unlock(&mutex); return error;
}
