/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE 1
#endif
#include "VirtualPythonCommandBridge.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

struct Queue {
    uint8_t bytes[STRUIS_VP_QUEUE_CAPACITY],tags[STRUIS_VP_QUEUE_CAPACITY];
    size_t head,count;
};
struct Thread {
    struct StruisVirtualPythonInvocation *invocation;
    pthread_t thread;
    int fd,index,created,done;
};
struct StruisVirtualPythonInvocation {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    StruisVPContext context;
    uint32_t function;
    size_t argc;
    char **argv;
    struct Queue queues[3];
    struct Thread threads[3];
    int merged,started,provider_finished,cancelled,stop_input,stdin_eof,io_error;
    size_t created,complete;
    int32_t exit_code;
    uint64_t input_bytes,output_bytes,error_bytes;
};
static pthread_mutex_t active_lock=PTHREAD_MUTEX_INITIALIZER;
static StruisVirtualPythonInvocation *active;
static uint64_t next_id=1;
static int key(const StruisVirtualPythonInvocation *i,const StruisVPContext *k) {
    return k && i->context.generation==k->generation && i->context.invocation_id==k->invocation_id && !memcmp(i->context.worker_id,k->worker_id,sizeof(k->worker_id)) && !memcmp(i->context.owner,k->owner,sizeof(k->owner));
}
static int enter(StruisVirtualPythonInvocation *i,const StruisVPContext *k) {
    if(!i||!k)return EINVAL;
    int error=pthread_mutex_lock(&i->lock);
    if(error)return error;
    if(!key(i,k)) {
        pthread_mutex_unlock(&i->lock);
        return EACCES;
    }
    return 0;
}
static int state_error(const StruisVirtualPythonInvocation *i) {
    if(i->io_error)return i->io_error;
    if(i->cancelled)return ECANCELED;
    return 0;
}
static int finish_ready(const StruisVirtualPythonInvocation *i) {
    return i->complete==i->created && (i->provider_finished||i->cancelled||i->io_error);
}
static void clear_queues(StruisVirtualPythonInvocation *i) {
    for(int n=0;n<3;n++) {
        i->queues[n].head=0;
        i->queues[n].count=0;
    }
}
static void request_cancel(StruisVirtualPythonInvocation *i,int input_only) {
    for(int n=0;n<3;n++)if(i->threads[n].created&&!i->threads[n].done && (!input_only||n==0))pthread_cancel(i->threads[n].thread);
    pthread_cond_broadcast(&i->changed);
}
static void failed(StruisVirtualPythonInvocation *i,int error) {
    if(!i->io_error)i->io_error=error?error:EIO;
    clear_queues(i);
    request_cancel(i,0);
}
static void push(struct Queue *q,const uint8_t *bytes,size_t n,uint8_t tag) {
    for(size_t p=0;p<n;p++) {
        size_t slot=(q->head+q->count+p)%STRUIS_VP_QUEUE_CAPACITY;
        q->bytes[slot]=bytes[p];
        q->tags[slot]=tag;
    }
    q->count+=n;
}
static size_t peek(const struct Queue *q,uint8_t *bytes,size_t limit,uint8_t *tag) {
    size_t n=q->count<limit?q->count:limit;
    if(n)*tag=q->tags[q->head];
    size_t p=0;
    for(;p<n;p++) {
        size_t slot=(q->head+p)%STRUIS_VP_QUEUE_CAPACITY;
        if(q->tags[slot]!=*tag)break;
        bytes[p]=q->bytes[slot];
    }
    return p;
}
static void pop(struct Queue *q,size_t n) {
    q->head=(q->head+n)%STRUIS_VP_QUEUE_CAPACITY;
    q->count-=n;
}
static void cleanup(void *raw) {
    struct Thread *t=raw;
    StruisVirtualPythonInvocation *i=t->invocation;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,NULL);
    if(t->fd>=0) {
        close(t->fd);
        t->fd=-1;
    }
    pthread_mutex_lock(&i->lock);
    t->done=1;
    i->complete++;
    pthread_cond_broadcast(&i->changed);
    pthread_mutex_unlock(&i->lock);
}
static void pause_fd(int fd,short events);
static void *input_thread(void *raw) {
    struct Thread *t=raw;
    StruisVirtualPythonInvocation *i=t->invocation;
    uint8_t bytes[STRUIS_VP_MAX_FRAME];
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,NULL);
    pthread_cleanup_push(cleanup,t);
    for(;;) {
        pthread_mutex_lock(&i->lock);
        while(!i->started&&!state_error(i)&&!i->stop_input)pthread_cond_wait(&i->changed,&i->lock);
        while(i->queues[0].count==STRUIS_VP_QUEUE_CAPACITY&&!state_error(i)&&!i->stop_input)pthread_cond_wait(&i->changed,&i->lock);
        if(state_error(i)||i->stop_input) {
            pthread_mutex_unlock(&i->lock);
            break;
        }
        size_t take=STRUIS_VP_QUEUE_CAPACITY-i->queues[0].count;
        if(take>sizeof(bytes))take=sizeof(bytes);
        pthread_mutex_unlock(&i->lock);
        pthread_setcancelstate(PTHREAD_CANCEL_ENABLE,NULL);
        ssize_t n=read(t->fd,bytes,take);
        int saved=errno;
        pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,NULL);
        pthread_mutex_lock(&i->lock);
        if(state_error(i)||i->stop_input) {
            pthread_mutex_unlock(&i->lock);
            break;
        }
        if(n>0) {
            push(&i->queues[0],bytes,(size_t)n,0);
            i->input_bytes+=(uint64_t)n;
            pthread_cond_broadcast(&i->changed);
        } else if(n==0) {
            i->stdin_eof=1;
            pthread_cond_broadcast(&i->changed);
            pthread_mutex_unlock(&i->lock);
            break;
        } else if(saved!=EINTR&&saved!=EAGAIN&&saved!=EWOULDBLOCK) {
            failed(i,saved);
            pthread_mutex_unlock(&i->lock);
            break;
        }
        pthread_mutex_unlock(&i->lock);
        if(n<0&&(saved==EAGAIN||saved==EWOULDBLOCK))pause_fd(t->fd,POLLIN);
    }
    pthread_cleanup_pop(1);
    return NULL;
}
static void *output_thread(void *raw) {
    struct Thread *t=raw;
    StruisVirtualPythonInvocation *i=t->invocation;
    uint8_t bytes[STRUIS_VP_MAX_FRAME];
    sigset_t blocked;
    sigemptyset(&blocked);
    sigaddset(&blocked,SIGPIPE);
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,NULL);
    int mask_error=pthread_sigmask(SIG_BLOCK,&blocked,NULL);
    pthread_cleanup_push(cleanup,t);
    if(mask_error) {
        pthread_mutex_lock(&i->lock);
        failed(i,mask_error);
        pthread_mutex_unlock(&i->lock);
    }
    for(;;) {
        pthread_mutex_lock(&i->lock);
        while((!i->started||i->queues[t->index].count==0)&&!state_error(i)&&!i->provider_finished)pthread_cond_wait(&i->changed,&i->lock);
        if(state_error(i)|| (i->provider_finished&&i->queues[t->index].count==0)) {
            pthread_mutex_unlock(&i->lock);
            break;
        }
        uint8_t tag=0;
        size_t take=peek(&i->queues[t->index],bytes,sizeof(bytes),&tag);
        pthread_mutex_unlock(&i->lock);
        pthread_setcancelstate(PTHREAD_CANCEL_ENABLE,NULL);
        ssize_t n=write(t->fd,bytes,take);
        int saved=errno;
        pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,NULL);
        pthread_mutex_lock(&i->lock);
        if(state_error(i)) {
            pthread_mutex_unlock(&i->lock);
            break;
        }
        if(n>0) {
            pop(&i->queues[t->index],(size_t)n);
            if(tag==STRUIS_VP_STDERR)i->error_bytes+=(uint64_t)n;
            else i->output_bytes+=(uint64_t)n;
            pthread_cond_broadcast(&i->changed);
        } else if(n==0 || (saved!=EINTR&&saved!=EAGAIN&&saved!=EWOULDBLOCK)) {
            failed(i,n==0?EIO:saved);
            pthread_mutex_unlock(&i->lock);
            break;
        }
        pthread_mutex_unlock(&i->lock);
        if(n<0&&(saved==EAGAIN||saved==EWOULDBLOCK))pause_fd(t->fd,POLLOUT);
    }
    pthread_cleanup_pop(1);
    return NULL;
}
static void deadline(struct timespec *time,uint32_t ms) {
    clock_gettime(CLOCK_MONOTONIC,time);
    time->tv_sec+=ms/1000;
    time->tv_nsec+=(long)(ms%1000)*1000000;
    if(time->tv_nsec>=1000000000) {
        time->tv_sec++;
        time->tv_nsec-=1000000000;
    }
}
static int condition_init(pthread_cond_t *condition) {
#ifdef __APPLE__
    return pthread_cond_init(condition,NULL);
#else
    pthread_condattr_t attr;
    int e=pthread_condattr_init(&attr);
    if(e)return e;
    e=pthread_condattr_setclock(&attr,CLOCK_MONOTONIC);
    if(!e)e=pthread_cond_init(condition,&attr);
    pthread_condattr_destroy(&attr);
    return e;
#endif
}
static int wait_until(StruisVirtualPythonInvocation *i,const struct timespec *until) {
#ifdef __APPLE__
    struct timespec now,relative;
    clock_gettime(CLOCK_MONOTONIC,&now);
    relative.tv_sec=until->tv_sec-now.tv_sec;
    relative.tv_nsec=until->tv_nsec-now.tv_nsec;
    if(relative.tv_nsec<0) {
        relative.tv_sec--;
        relative.tv_nsec+=1000000000;
    }
    if(relative.tv_sec<0)return ETIMEDOUT;
    return pthread_cond_timedwait_relative_np(&i->changed,&i->lock,&relative);
#else
    return pthread_cond_timedwait(&i->changed,&i->lock,until);
#endif
}
static void pause_fd(int fd,short events) {
    struct pollfd ready= {
        .fd=fd,.events=events
    };
    poll(&ready,1,10);
}
static void release_memory(StruisVirtualPythonInvocation *i) {
    for(size_t n=0;n<i->argc;n++)free(i->argv[n]);
    free(i->argv);
    pthread_cond_destroy(&i->changed);
    pthread_mutex_destroy(&i->lock);
    free(i);
}
int StruisVPCreate(const char *worker,const char *owner,uint64_t generation,uint32_t function,int argc,const char *const *argv,int input,int output,int error,StruisVirtualPythonInvocation **out,StruisVPContext *out_key) {
    if(!out||!out_key)return EINVAL;
    *out=NULL;
    memset(out_key,0,sizeof(*out_key));
    if(!worker||!owner||!argv||argc<1||argc>(int)STRUIS_VP_MAX_ARGC || (function!=STRUIS_VP_PYTHON_MAIN&&function!=STRUIS_VP_GIT_MAIN))return EINVAL;
    size_t wl=strnlen(worker,sizeof(out_key->worker_id));
    size_t ol=strnlen(owner,sizeof(out_key->owner));
    if(!wl||wl>=sizeof(out_key->worker_id)||!ol||ol>=sizeof(out_key->owner))return EINVAL;
    size_t total=0;
    for(int n=0;n<argc;n++) {
        if(!argv[n])return EINVAL;
        size_t len=strnlen(argv[n],STRUIS_VP_MAX_ARG_LENGTH+1);
        if(len>STRUIS_VP_MAX_ARG_LENGTH||len+1>STRUIS_VP_MAX_ARG_BYTES-total)return E2BIG;
        total+=len+1;
    }
    pthread_mutex_lock(&active_lock);
    if(active) {
        pthread_mutex_unlock(&active_lock);
        return EBUSY;
    }
    if(next_id==UINT64_MAX) {
        pthread_mutex_unlock(&active_lock);
        return EOVERFLOW;
    }
    StruisVirtualPythonInvocation *i=calloc(1,sizeof(*i));
    if(!i) {
        pthread_mutex_unlock(&active_lock);
        return ENOMEM;
    }
    for(int n=0;n<3;n++) {
        i->threads[n].fd=-1;
        i->threads[n].index=n;
        i->threads[n].invocation=i;
    }
    int code=pthread_mutex_init(&i->lock,NULL);
    if(code) {
        free(i);
        pthread_mutex_unlock(&active_lock);
        return code;
    }
    code=condition_init(&i->changed);
    if(code) {
        pthread_mutex_destroy(&i->lock);
        free(i);
        pthread_mutex_unlock(&active_lock);
        return code;
    }
    i->argv=calloc((size_t)argc,sizeof(char*));
    if(!i->argv) {
        release_memory(i);
        pthread_mutex_unlock(&active_lock);
        return ENOMEM;
    }
    for(int n=0;n<argc;n++) {
        i->argv[n]=strdup(argv[n]);
        if(!i->argv[n]) {
            i->argc=(size_t)n;
            release_memory(i);
            pthread_mutex_unlock(&active_lock);
            return ENOMEM;
        }
    }
    i->argc=(size_t)argc;
    int fds[3]= {
        input,output,error
    };
    i->merged=output==error;
    for(int n=0;n<3;n++) {
        if(n==2&&i->merged)continue;
        i->threads[n].fd=fcntl(fds[n],F_DUPFD_CLOEXEC,0);
        code=i->threads[n].fd<0?errno:0;
#ifdef __APPLE__
        /* Darwin write(2) signals the process, not just this writer thread.
         * F_SETNOSIGPIPE changes the shared fileglob: dup does not isolate it.
         * The trusted owner must protect a newly-created exclusive output pipe
         * before sharing it. Never mutate inherited descriptors here. See
         * Apple XNU xnu-12377.121.6 sys_generic.c / kern_descrip.c. */
        if(!code&&n>0) {
            struct stat metadata;
            if(fstat(i->threads[n].fd,&metadata)<0)code=errno;
            else if(S_ISREG(metadata.st_mode)) {
                /* Captured regular-file redirection cannot take the pipe
                 * SIGPIPE path. Preserve its shared flags unchanged. */
            } else if(S_ISFIFO(metadata.st_mode)||S_ISSOCK(metadata.st_mode)) {
                int protected_output=fcntl(i->threads[n].fd,F_GETNOSIGPIPE);
                if(protected_output<0)code=errno;
                else if(protected_output!=1)code=ENOTSUP;
            } else code=ENOTSUP;
        }
#endif
        if(code) {
            for(int p=0;p<=n;p++)if(i->threads[p].fd>=0)close(i->threads[p].fd);
            release_memory(i);
            pthread_mutex_unlock(&active_lock);
            return code;
        }
    }
    memcpy(i->context.worker_id,worker,wl);
    memcpy(i->context.owner,owner,ol);
    i->context.generation=generation;
    i->context.invocation_id=next_id++;
    i->function=function;
    active=i;
    *out=i;
    *out_key=i->context;
    pthread_mutex_unlock(&active_lock);
    return 0;
}
int StruisVPStart(StruisVirtualPythonInvocation *i,const StruisVPContext *k) {
    int e=enter(i,k);
    if(e)return e;
    if(i->started||state_error(i)||i->provider_finished) {
        e=state_error(i);
        pthread_mutex_unlock(&i->lock);
        return e?e:EALREADY;
    }
    for(int n=0;n<3;n++) {
        if(n==2&&i->merged)continue;
        e=pthread_create(&i->threads[n].thread,NULL,n==0?input_thread:output_thread,&i->threads[n]);
        if(e) {
            failed(i,e);
            pthread_mutex_unlock(&i->lock);
            return e;
        }
        i->threads[n].created=1;
        i->created++;
    }
    i->started=1;
    pthread_cond_broadcast(&i->changed);
    pthread_mutex_unlock(&i->lock);
    return 0;
}
int StruisVPDescribe(StruisVirtualPythonInvocation *i,const StruisVPContext *k,uint32_t *function,size_t *argc) {
    if(!function||!argc)return EINVAL;
    *function=0;
    *argc=0;
    int e=enter(i,k);
    if(e)return e;
    e=state_error(i);
    if(!e) {
        *function=i->function;
        *argc=i->argc;
    }
    pthread_mutex_unlock(&i->lock);
    return e;
}
int StruisVPArgument(StruisVirtualPythonInvocation *i,const StruisVPContext *k,size_t index,uint8_t *out,size_t capacity,size_t *required) {
    if(!required||capacity>STRUIS_VP_MAX_ARG_LENGTH+1 || (capacity&&!out))return EINVAL;
    *required=0;
    int e=enter(i,k);
    if(e)return e;
    e=state_error(i);
    if(!e) {
        if(index>=i->argc)e=EINVAL;
        else {
            *required=strlen(i->argv[index])+1;
            if(capacity<*required)e=ERANGE;
            else memcpy(out,i->argv[index],*required);
        }
    }
    pthread_mutex_unlock(&i->lock);
    return e;
}
int StruisVPStatusRead(StruisVirtualPythonInvocation *i,const StruisVPContext *k,StruisVPStatus *out) {
    if(!out)return EINVAL;
    memset(out,0,sizeof(*out));
    int e=enter(i,k);
    if(e)return e;
    out->started=(uint32_t)i->started;
    out->provider_finished=(uint32_t)i->provider_finished;
    out->cancelled=(uint32_t)i->cancelled;
    out->threads_complete=(uint32_t)(i->complete==i->created);
    out->stdin_eof=(uint32_t)(i->stdin_eof&&!i->queues[0].count);
    out->merged_output=(uint32_t)i->merged;
    out->io_error=i->io_error;
    out->stdin_available=i->queues[0].count;
    out->stdout_credit=STRUIS_VP_QUEUE_CAPACITY-i->queues[1].count;
    out->stderr_credit=STRUIS_VP_QUEUE_CAPACITY-i->queues[i->merged?1:2].count;
    pthread_mutex_unlock(&i->lock);
    return 0;
}
int StruisVPPullStdin(StruisVirtualPythonInvocation *i,const StruisVPContext *k,uint8_t *out,size_t capacity,size_t *count,uint32_t *eof) {
    if(!count||!eof)return EINVAL;
    *count=0;
    *eof=0;
    if(!out||!capacity||capacity>STRUIS_VP_MAX_FRAME)return EINVAL;
    int e=enter(i,k);
    if(e)return e;
    e=state_error(i);
    if(!e&&i->provider_finished)e=EPIPE;
    if(!e) {
        struct Queue *q=&i->queues[0];
        uint8_t tag=0;
        *count=peek(q,out,capacity,&tag);
        pop(q,*count);
        *eof=(uint32_t)(i->stdin_eof&&!q->count);
        if(!*count&&!*eof)e=EAGAIN;
        pthread_cond_broadcast(&i->changed);
    }
    pthread_mutex_unlock(&i->lock);
    return e;
}
int StruisVPPushOutput(StruisVirtualPythonInvocation *i,const StruisVPContext *k,uint32_t stream,const uint8_t *input,size_t length,size_t *accepted) {
    if(!accepted)return EINVAL;
    *accepted=0;
    if(stream<1||stream>2||length>STRUIS_VP_MAX_FRAME||(length&&!input))return EINVAL;
    int e=enter(i,k);
    if(e)return e;
    e=state_error(i);
    if(!e&&i->provider_finished)e=EPIPE;
    if(!e&&!i->started)e=EAGAIN;
    if(!e) {
        struct Queue *q=&i->queues[i->merged?1:(int)stream];
        size_t free=STRUIS_VP_QUEUE_CAPACITY-q->count;
        size_t take=length<free?length:free;
        if(take) {
            push(q,input,take,(uint8_t)stream);
            *accepted=take;
            pthread_cond_broadcast(&i->changed);
        } else if(length)e=EAGAIN;
    }
    pthread_mutex_unlock(&i->lock);
    return e;
}
int StruisVPFinished(StruisVirtualPythonInvocation *i,const StruisVPContext *k,int32_t code) {
    int e=enter(i,k);
    if(e)return e;
    e=state_error(i);
    if(!e&&i->provider_finished)e=EALREADY;
    if(!e&&!i->started)e=EINVAL;
    if(!e) {
        i->provider_finished=1;
        i->exit_code=code;
        i->stop_input=1;
        request_cancel(i,1);
    }
    pthread_mutex_unlock(&i->lock);
    return e;
}
int StruisVPCancel(StruisVirtualPythonInvocation *i,const StruisVPContext *k) {
    int e=enter(i,k);
    if(e)return e;
    if(finish_ready(i)&&!i->cancelled) {
        pthread_mutex_unlock(&i->lock);
        return EALREADY;
    }
    i->cancelled=1;
    i->stop_input=1;
    clear_queues(i);
    request_cancel(i,0);
    pthread_mutex_unlock(&i->lock);
    return 0;
}
int StruisVPAwait(StruisVirtualPythonInvocation *i,const StruisVPContext *k,uint32_t ms,StruisVPResult *out) {
    if(!out)return EINVAL;
    memset(out,0,sizeof(*out));
    if(ms>STRUIS_VP_MAX_WAIT_MS)return EINVAL;
    int e=enter(i,k);
    if(e)return e;
    struct timespec until;
    deadline(&until,ms);
    while(!finish_ready(i)) {
        if(!ms) {
            e=ETIMEDOUT;
            break;
        }
        e=wait_until(i,&until);
        if(e)break;
    }
    if(!e) {
        out->exit_code=i->io_error?125:i->cancelled?130:i->exit_code;
        out->reason=i->io_error?STRUIS_VP_EXIT_IO_ERROR:i->cancelled?STRUIS_VP_EXIT_CANCELLED:STRUIS_VP_EXIT_NORMAL;
        out->io_error=i->io_error;
        out->stdin_bytes=i->input_bytes;
        out->stdout_bytes=i->output_bytes;
        out->stderr_bytes=i->error_bytes;
    }
    pthread_mutex_unlock(&i->lock);
    return e;
}
int StruisVPDestroy(StruisVirtualPythonInvocation *i,const StruisVPContext *k) {
    int e=enter(i,k);
    if(e)return e;
    if(i->created&&!finish_ready(i)) {
        pthread_mutex_unlock(&i->lock);
        return EBUSY;
    }
    pthread_mutex_unlock(&i->lock);
    for(int n=0;n<3;n++) {
        if(i->threads[n].created) {
            e=pthread_join(i->threads[n].thread,NULL);
            if(e)return e;
        } else if(i->threads[n].fd>=0) {
            close(i->threads[n].fd);
            i->threads[n].fd=-1;
        }
    }
    pthread_mutex_lock(&active_lock);
    if(active!=i) {
        pthread_mutex_unlock(&active_lock);
        return EACCES;
    }
    active=NULL;
    release_memory(i);
    pthread_mutex_unlock(&active_lock);
    return 0;
}
