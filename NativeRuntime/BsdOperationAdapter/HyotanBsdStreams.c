/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#define _GNU_SOURCE
#include "HyotanBsdStreams.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#define MAX_HANDLES 64
#define MAX_BYTES (1024u*1024u)
typedef struct Object Object;
typedef struct Active Active;
struct Object { pthread_mutex_t io; FILE *file; int fd,kind,access,refs; };
struct Active { struct HyotanBsdStreams *context; Object *object; pthread_t thread; int pipe,mask_saved,pending_pipe; sigset_t mask; Active *next; };
struct HyotanBsdStreams {
  pthread_mutex_t lock;
  HyotanBsdDescriptors *table;
  HyotanBsdScope scope;
  int cancelled,captured;
  struct { HyotanBsdStream id; Object *object; } entries[MAX_HANDLES];
  Active *active;
  unsigned active_count;
};
static pthread_mutex_t ids_lock=PTHREAD_MUTEX_INITIALIZER;
static uint64_t next_id=1;
static int same(HyotanBsdStreams *c,const HyotanBsdScope *s) {
  return c && s && memchr(s->owner,0,sizeof(s->owner)) && s->generation==c->scope.generation && s->instance==c->scope.instance && !strcmp(s->owner,c->scope.owner);
}
static int report(HyotanBsdStreams *c,const HyotanBsdScope *s,unsigned op,int e) {
  if(same(c,s))hyotan_bsd_report_refusal(c->table,&c->scope,op,e);
  return e;
}
static int live(HyotanBsdStreams *c) {
  if(c->cancelled)return EACCES;
  int e=hyotan_bsd_descriptors_retain(c->table,&c->scope);
  if(!e)hyotan_bsd_descriptors_release(c->table);
  return e;
}
static int enter(HyotanBsdStreams *c,const HyotanBsdScope *s,int check) {
  if(!same(c,s))return EACCES;
  pthread_mutex_lock(&c->lock);
  int e=check?live(c):0;
  if(e)pthread_mutex_unlock(&c->lock);
  return e;
}
static Object *object(int kind,int access,FILE *file,int fd) {
  Object *o=calloc(1,sizeof(*o));if(!o)return NULL;
  if(pthread_mutex_init(&o->io,NULL)) {free(o);return NULL;}
  o->kind=kind;o->access=access;o->file=file;o->fd=fd;return o;
}
static int release(HyotanBsdStreams *c,Object *o) {
  int e=0;
  if(o->kind==HYOTAN_BSD_STREAM_REGULAR)e=hyotan_bsd_fclose(o->file,&c->scope);
  else if(o->kind==HYOTAN_BSD_STREAM_PIPE && close(o->fd))e=errno;
  pthread_mutex_destroy(&o->io);free(o);return e;
}
static int issue(HyotanBsdStreams *c,Object *o,HyotanBsdStream *out) {
  int slot=-1;for(int i=0;i<MAX_HANDLES;i++)if(!c->entries[i].id){slot=i;break;}
  if(slot<0)return EMFILE;
  pthread_mutex_lock(&ids_lock);
  if(next_id==UINT64_MAX) {pthread_mutex_unlock(&ids_lock);return EMFILE;}
  *out=next_id++;pthread_mutex_unlock(&ids_lock);
  c->entries[slot].id=*out;c->entries[slot].object=o;o->refs++;return 0;
}
static int find(HyotanBsdStreams *c,HyotanBsdStream h) {
  for(int i=0;i<MAX_HANDLES;i++)if(h && c->entries[i].id==h)return i;
  return -1;
}
int hyotan_bsd_streams_create(HyotanBsdDescriptors *t,const HyotanBsdScope *s,HyotanBsdStreams **out) {
  if(!out)return EINVAL;
  *out=NULL;
  int e=hyotan_bsd_descriptors_retain(t,s);if(e)return e;
  HyotanBsdStreams *c=calloc(1,sizeof(*c));
  if(!c) {hyotan_bsd_descriptors_release(t);return ENOMEM;}
  e=pthread_mutex_init(&c->lock,NULL);
  if(e) {free(c);hyotan_bsd_descriptors_release(t);return e;}
  e=hyotan_bsd_descriptors_claim_stream_context(t,s);
  if(e) {pthread_mutex_destroy(&c->lock);free(c);hyotan_bsd_descriptors_release(t);return e;}
  c->table=t;c->scope=*s;*out=c;return 0;
}
int hyotan_bsd_streams_capture_stdio(HyotanBsdStreams *c,const HyotanBsdScope *s,FILE *in,FILE *out,FILE *err,HyotanBsdStream handles[3]) {
  if(!handles)return EINVAL;
  memset(handles,0,3*sizeof(*handles));
  int e=enter(c,s,1);if(e)return report(c,s,HYOTAN_BSD_REPORT_ADOPT,e);
  FILE *files[3]={in,out,err};Object *objects[3]={0};int access[3]={1,2,2};
  if(c->captured)e=ENOTSUP;
  for(int i=0;i<3 && !e;i++) {
    if(!files[i]) {e=EINVAL;break;}
    /* Trusted tuple capture, not a guest FILE registry or grant discovery. */
    struct stat st;int fd=fileno(files[i]),flags=fd<0?-1:fcntl(fd,F_GETFL);
    if(fd<0 || flags<0 || fstat(fd,&st) || !S_ISREG(st.st_mode)) {e=ENOTSUP;break;}
    int mode=flags&O_ACCMODE;
    if((access[i]==1 && mode==O_WRONLY)||(access[i]==2 && mode==O_RDONLY)) {e=EACCES;break;}
    for(int j=0;j<i;j++)if(files[i]==files[j]) {objects[i]=objects[j];objects[i]->access|=access[i];break;}
    if(!objects[i] && !(objects[i]=object(HYOTAN_BSD_STREAM_STDIO,access[i],files[i],-1)))e=ENOMEM;
  }
  for(int i=0;i<3 && !e;i++)e=issue(c,objects[i],&handles[i]);
  if(e) {
    for(int i=0;i<3;i++)if(handles[i]) {int slot=find(c,handles[i]);c->entries[slot].id=0;objects[i]->refs--;handles[i]=0;}
    for(int i=0;i<3;i++)if(objects[i]) {int prior=0;for(int j=0;j<i;j++)if(objects[j]==objects[i])prior=1;if(!prior)release(c,objects[i]);}
  } else c->captured=1;
  pthread_mutex_unlock(&c->lock);return report(c,s,HYOTAN_BSD_REPORT_ADOPT,e);
}
int hyotan_bsd_streams_adopt_regular(HyotanBsdStreams *c,const HyotanBsdScope *s,int fd,const char *mode,HyotanBsdStream *out) {
  if(!out)return EINVAL;
  *out=0;int e=enter(c,s,1);if(e)return report(c,s,HYOTAN_BSD_REPORT_ADOPT,e);
  Object *o=object(HYOTAN_BSD_STREAM_REGULAR,3,NULL,-1);
  if(!o)e=ENOMEM;
  /* Reserve logical handle before adoption so failure never consumes caller FD. */
  if(!e)e=issue(c,o,out);
  if(!e)e=hyotan_bsd_fdopen(c->table,&c->scope,fd,mode,&o->file);
  if(e && o) {if(*out){int slot=find(c,*out);c->entries[slot].id=0;*out=0;}pthread_mutex_destroy(&o->io);free(o);}
  pthread_mutex_unlock(&c->lock);return report(c,s,HYOTAN_BSD_REPORT_ADOPT,e);
}
int hyotan_bsd_streams_pipe(HyotanBsdStreams *c,const HyotanBsdScope *s,HyotanBsdStream *read_handle,HyotanBsdStream *write_handle) {
  if(!read_handle || !write_handle || read_handle==write_handle)return EINVAL;
  *read_handle=*write_handle=0;int e=enter(c,s,1);if(e)return report(c,s,HYOTAN_BSD_REPORT_ADOPT,e);
  int fd[2]={-1,-1};Object *o[2]={NULL,NULL};
  if(pipe(fd))e=errno;
#ifdef __APPLE__
  if(!e && fcntl(fd[1],F_SETNOSIGPIPE,1)<0)e=errno;
  if(!e && fcntl(fd[1],F_GETNOSIGPIPE)!=1)e=ENOTSUP;
#endif
  if(!e && !(o[0]=object(HYOTAN_BSD_STREAM_PIPE,1,NULL,fd[0])))e=ENOMEM;
  if(!e && !(o[1]=object(HYOTAN_BSD_STREAM_PIPE,2,NULL,fd[1])))e=ENOMEM;
  if(!e)e=issue(c,o[0],read_handle);
  if(!e)e=issue(c,o[1],write_handle);
  if(e) {
    if(*read_handle){c->entries[find(c,*read_handle)].id=0;*read_handle=0;}
    for(int i=0;i<2;i++)if(o[i])release(c,o[i]);else if(fd[i]>=0)close(fd[i]);
  }
  pthread_mutex_unlock(&c->lock);return report(c,s,HYOTAN_BSD_REPORT_ADOPT,e);
}
int hyotan_bsd_streams_dup(HyotanBsdStreams *c,const HyotanBsdScope *s,HyotanBsdStream h,HyotanBsdStream *out) {
  if(!out)return EINVAL;
  *out=0;int e=enter(c,s,1);if(e)return report(c,s,HYOTAN_BSD_REPORT_ADOPT,e);
  int slot=find(c,h);e=slot<0?EACCES:issue(c,c->entries[slot].object,out);
  pthread_mutex_unlock(&c->lock);return report(c,s,HYOTAN_BSD_REPORT_ADOPT,e);
}
int hyotan_bsd_streams_class(HyotanBsdStreams *c,const HyotanBsdScope *s,HyotanBsdStream h,int *out) {
  if(!out)return EINVAL;
  *out=0;int e=enter(c,s,1);if(e)return report(c,s,HYOTAN_BSD_REPORT_QUERY,e);
  int slot=find(c,h);if(slot<0)e=EACCES;else *out=c->entries[slot].object->kind;
  pthread_mutex_unlock(&c->lock);return report(c,s,HYOTAN_BSD_REPORT_QUERY,e);
}
static void finish_active(void *argument) {
  Active *a=argument;HyotanBsdStreams *c=a->context;Object *o=a->object;
  if(a->mask_saved) {
#ifndef __APPLE__
    if(!a->pending_pipe) {sigset_t set;sigemptyset(&set);sigaddset(&set,SIGPIPE);struct timespec zero={0};sigtimedwait(&set,NULL,&zero);}
#endif
    pthread_sigmask(SIG_SETMASK,&a->mask,NULL);
  }
  pthread_mutex_unlock(&o->io);
  pthread_mutex_lock(&c->lock);
  Active **link=&c->active;while(*link!=a)link=&(*link)->next;*link=a->next;c->active_count--;
  int last=!--o->refs;
  /* Keep context active until last-object close and cookie pin release finish. */
  if(last)release(c,o);
  pthread_mutex_unlock(&c->lock);
}
static int io(HyotanBsdStreams *c,const HyotanBsdScope *s,HyotanBsdStream h,void *buffer,size_t len,size_t *count,int operation) {
  if(count)*count=0;
  if(!count || (len && !buffer) || len>MAX_BYTES)return EINVAL;
  int oldstate;pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,&oldstate);
  unsigned diagnostic=operation==0?HYOTAN_BSD_REPORT_READ:(operation==1?HYOTAN_BSD_REPORT_WRITE:HYOTAN_BSD_REPORT_FLUSH);
  int e=enter(c,s,1);
  if(e) {pthread_setcancelstate(oldstate,NULL);return report(c,s,diagnostic,e);}
  int slot=find(c,h);Object *o=slot<0?NULL:c->entries[slot].object;
  if(!o)e=EACCES;
  else if(c->active_count>=MAX_HANDLES)e=EAGAIN;
  else if(operation<2 && !(o->access&(operation?2:1)))e=EACCES;
  if(e) {pthread_mutex_unlock(&c->lock);report(c,s,diagnostic,e);pthread_setcancelstate(oldstate,NULL);return e;}
  Active active={.context=c,.object=o,.thread=pthread_self(),.pipe=o->kind==HYOTAN_BSD_STREAM_PIPE};
  o->refs++;c->active_count++;active.next=c->active;c->active=&active;pthread_mutex_unlock(&c->lock);
  pthread_mutex_lock(&o->io);
  pthread_cleanup_push(finish_active,&active);
  /* Revalidate after waiting for shared stream engine. No cached byte access on
   * revoked regular or borrowed authority; regular callback repeats Core check. */
  pthread_mutex_lock(&c->lock);e=live(c);pthread_mutex_unlock(&c->lock);
  if(!e && o->kind==HYOTAN_BSD_STREAM_REGULAR) {
    if(operation==0)e=hyotan_bsd_fread(o->file,&c->scope,buffer,len,count);
    else if(operation==1)e=hyotan_bsd_fwrite(o->file,&c->scope,buffer,len,count);
    else e=hyotan_bsd_fflush(o->file,&c->scope);
  } else if(!e && o->kind==HYOTAN_BSD_STREAM_STDIO) {
    if(operation==0) { *count=fread(buffer,1,len,o->file);if(ferror(o->file))e=errno?errno:EIO; }
    else if(operation==1) { *count=fwrite(buffer,1,len,o->file);if(*count<len)e=errno?errno:EIO; }
    else if(fflush(o->file))e=errno?errno:EIO;
  } else if(!e && operation<2) {
#ifndef __APPLE__
    int pending_pipe=0;
    if(operation==1) {
      sigset_t blocked,pending;sigemptyset(&blocked);sigaddset(&blocked,SIGPIPE);
      e=pthread_sigmask(SIG_BLOCK,&blocked,&active.mask);
      if(!e){active.mask_saved=1;sigpending(&pending);pending_pipe=sigismember(&pending,SIGPIPE);active.pending_pipe=pending_pipe;}
    }
#endif
    if(!e) {
      pthread_setcancelstate(PTHREAD_CANCEL_ENABLE,NULL);
      ssize_t n=operation?write(o->fd,buffer,len):read(o->fd,buffer,len);
      e=n<0?errno:0;if(n>=0)*count=(size_t)n;
      pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,NULL);
#ifndef __APPLE__
      if(operation==1 && e==EPIPE && !pending_pipe) {sigset_t set;sigemptyset(&set);sigaddset(&set,SIGPIPE);struct timespec zero={0};sigtimedwait(&set,NULL,&zero);}
#endif
    }
  }
  report(c,s,diagnostic,e);
  pthread_cleanup_pop(1);
  pthread_setcancelstate(oldstate,NULL);return e;
}
int hyotan_bsd_streams_read(HyotanBsdStreams *c,const HyotanBsdScope *s,HyotanBsdStream h,void *b,size_t len,size_t *n) {return io(c,s,h,b,len,n,0);}
int hyotan_bsd_streams_write(HyotanBsdStreams *c,const HyotanBsdScope *s,HyotanBsdStream h,const void *b,size_t len,size_t *n) {return io(c,s,h,(void *)b,len,n,1);}
int hyotan_bsd_streams_flush(HyotanBsdStreams *c,const HyotanBsdScope *s,HyotanBsdStream h) {size_t n;return io(c,s,h,NULL,0,&n,2);}
int hyotan_bsd_streams_close(HyotanBsdStreams *c,const HyotanBsdScope *s,HyotanBsdStream h) {
  int old;pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,&old);
  int e=enter(c,s,0);if(e){pthread_setcancelstate(old,NULL);return e;}
  int slot=find(c,h);if(slot<0)e=EACCES;
  else {Object *o=c->entries[slot].object;c->entries[slot].id=0;if(!--o->refs)e=release(c,o);}
  pthread_mutex_unlock(&c->lock);report(c,s,HYOTAN_BSD_REPORT_CLOSE,e);pthread_setcancelstate(old,NULL);return e;
}
int hyotan_bsd_streams_cancel(HyotanBsdStreams *c,const HyotanBsdScope *s) {
  int e=enter(c,s,0);if(e)return e;
  c->cancelled=1;
  e=hyotan_bsd_revoke(c->table,&c->scope);
  for(Active *a=c->active;a;a=a->next)if(a->pipe){int error=pthread_cancel(a->thread);if(!e)e=error;}
  pthread_mutex_unlock(&c->lock);return e;
}
int hyotan_bsd_streams_destroy(HyotanBsdStreams *c) {
  if(!c)return EINVAL;
  pthread_mutex_lock(&c->lock);
  int busy=c->active!=NULL;for(int i=0;i<MAX_HANDLES;i++)busy|=c->entries[i].id!=0;
  if(busy){pthread_mutex_unlock(&c->lock);return EBUSY;}
  int e=hyotan_bsd_descriptors_release(c->table);
  pthread_mutex_unlock(&c->lock);pthread_mutex_destroy(&c->lock);free(c);return e;
}

int hyotan_bsd_streams_pending(HyotanBsdStreams *c,const HyotanBsdScope *s,unsigned *out) {
  if(!out)return EINVAL;
  *out=0;int e=enter(c,s,0);if(e)return e;
  *out=c->active_count;pthread_mutex_unlock(&c->lock);return 0;
}
