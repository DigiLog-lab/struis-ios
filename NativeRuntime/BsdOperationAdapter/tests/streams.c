/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#define _GNU_SOURCE
#include "HyotanBsdStreams.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#define OK(x) assert((x)==0)
#define P(x) (const uint8_t *)(x),strlen(x)
static HyotanBsdScope scope={"stream-owner",27,99};
static HyotanBsdDescriptors *table;
static HyotanBsdStreams *streams;
static int rootfd;
static unsigned char binary[262144];
static void start(uint64_t instance) {
  if(instance<=scope.instance)instance=scope.instance+1;
  scope.instance=instance;HyotanBsdScope s=scope;
  OK(hyotan_bsd_descriptors_create(rootfd,&s,2,1048576,1048576,&table));
  OK(hyotan_bsd_streams_create(table,&s,&streams));
  HyotanBsdStreams *second=NULL;
  assert(hyotan_bsd_streams_create(table,&s,&second)==EBUSY && !second);
}
static void end(void) {
  OK(hyotan_bsd_streams_destroy(streams));
  HyotanBsdStreams *next=NULL;
  int e=hyotan_bsd_streams_create(table,&scope,&next);
  assert((e==EBUSY || e==EACCES) && !next);
  OK(hyotan_bsd_descriptors_destroy(table));
}
static void close_handle(HyotanBsdStream h) {OK(hyotan_bsd_streams_close(streams,&scope,h));}
static void regular(void) {
  start(scope.instance);
  int fd;size_t n;uint64_t offset;
  OK(hyotan_bsd_open(table,&scope,P("日本語.bin"),HYOTAN_OPEN_CREATE|HYOTAN_OPEN_WRITE|HYOTAN_OPEN_READ,&fd));
  OK(hyotan_bsd_write(table,&scope,fd,binary,8192,&n));assert(n==8192);
  OK(hyotan_bsd_seek(table,&scope,fd,0,SEEK_SET,&offset));
  HyotanBsdStream h,d;OK(hyotan_bsd_streams_adopt_regular(streams,&scope,fd,"rb",&h));
  assert(hyotan_bsd_descriptors_destroy(table)==EBUSY);
  OK(hyotan_bsd_streams_dup(streams,&scope,h,&d));
  unsigned char b[8];OK(hyotan_bsd_streams_read(streams,&scope,h,b,1,&n));assert(n==1 && b[0]==binary[0]);
  OK(hyotan_bsd_streams_read(streams,&scope,d,b,1,&n));assert(n==1 && b[0]==binary[1]);
  int kind;OK(hyotan_bsd_streams_class(streams,&scope,d,&kind));assert(kind==HYOTAN_BSD_STREAM_REGULAR);
  HyotanBsdScope foreign=scope;foreign.instance++;
  memset(b,0x33,sizeof(b));assert(hyotan_bsd_streams_read(streams,&foreign,d,b,1,&n)==EACCES && n==0 && b[0]==0x33);
  HyotanBsdRefusalStatus receipt;OK(hyotan_bsd_refusal_status(table,&scope,&receipt));assert(!receipt.count);
  OK(hyotan_bsd_revoke(table,&scope));
  assert(hyotan_bsd_streams_read(streams,&scope,h,b,1,&n)==EACCES && n==0 && b[0]==0x33);
  OK(hyotan_bsd_refusal_status(table,&scope,&receipt));assert(receipt.error==EACCES && receipt.operation==HYOTAN_BSD_REPORT_READ);
  close_handle(h);assert(hyotan_bsd_streams_close(streams,&scope,d)==EACCES);end();
  puts("PASS: actual Core regular cookie adoption/shared buffered dup; revoked cached bytes denied untouched; exact foreign scope cannot alter receipt; pins/cleanup");
  start(scope.instance);
  OK(hyotan_bsd_open(table,&scope,P("append.bin"),HYOTAN_OPEN_CREATE|HYOTAN_OPEN_WRITE|HYOTAN_OPEN_READ|HYOTAN_OPEN_APPEND,&fd));
  OK(hyotan_bsd_streams_adopt_regular(streams,&scope,fd,"ab",&h));OK(hyotan_bsd_streams_dup(streams,&scope,h,&d));
  OK(hyotan_bsd_streams_write(streams,&scope,h,binary,4,&n));assert(n==4);
  OK(hyotan_bsd_streams_write(streams,&scope,d,binary+4,4,&n));OK(hyotan_bsd_streams_flush(streams,&scope,h));close_handle(h);close_handle(d);
  OK(hyotan_bsd_open(table,&scope,P("append.bin"),HYOTAN_OPEN_READ,&fd));unsigned char copy[8];OK(hyotan_bsd_read(table,&scope,fd,copy,8,&n));assert(n==8 && !memcmp(copy,binary,8));OK(hyotan_bsd_close(table,&scope,fd));
  HyotanBsdStream denied=0;assert(hyotan_bsd_streams_dup(streams,&scope,999999,&denied)==EACCES && !denied);
  OK(hyotan_bsd_refusal_status(table,&scope,&receipt));assert(receipt.count && receipt.error==EACCES);end();
  start(scope.instance+1);HyotanBsdScope fresh=scope;
  OK(hyotan_bsd_refusal_status(table,&fresh,&receipt));assert(!receipt.count);end();
  puts("PASS: shared append bytes/persistence; unknown handle fixed refusal; fresh command table receipt clear");
  start(scope.instance);
  OK(hyotan_bsd_open(table,&scope,P("pending.bin"),HYOTAN_OPEN_CREATE|HYOTAN_OPEN_WRITE,&fd));
  assert(hyotan_bsd_streams_adopt_regular(streams,&scope,fd,"r+b",&h)==EACCES && !h);
  uint32_t flags;OK(hyotan_bsd_descriptor_flags(table,&scope,fd,&flags)); /* failed adoption kept descriptor */
  OK(hyotan_bsd_streams_adopt_regular(streams,&scope,fd,"wb",&h));
  OK(hyotan_bsd_streams_write(streams,&scope,h,binary,4,&n));assert(n==4);
  OK(hyotan_bsd_revoke(table,&scope));
  assert(hyotan_bsd_streams_flush(streams,&scope,h)==EACCES);
  assert(hyotan_bsd_streams_close(streams,&scope,h)==EACCES);end();
  struct stat st;assert(fstatat(rootfd,"pending.bin",&st,0)==0 && st.st_size==0);
  start(scope.instance);OK(hyotan_bsd_open(table,&scope,P("append.bin"),HYOTAN_OPEN_READ,&fd));
  OK(hyotan_bsd_streams_adopt_regular(streams,&scope,fd,"rb",&h));
  HyotanBsdStream handles[64];handles[0]=h;
  for(int i=1;i<64;i++)OK(hyotan_bsd_streams_dup(streams,&scope,h,&handles[i]));
  HyotanBsdStream overflow=1;assert(hyotan_bsd_streams_dup(streams,&scope,h,&overflow)==EMFILE && !overflow);
  for(int i=0;i<64;i++)close_handle(handles[i]);
  assert(hyotan_bsd_streams_dup(streams,&scope,h,&overflow)==EACCES && !overflow);end();
  puts("PASS: failed adoption retains logical descriptor; revoked pending output not persisted; finite64 handle bound; closed handle never reused");

}
static void borrowed(void) {
  start(scope.instance);FILE *in=tmpfile(),*out=tmpfile();assert(in && out);
  assert(fwrite(binary,1,8,in)==8 && fflush(in)==0 && fseek(in,0,SEEK_SET)==0);
  int infd=fileno(in),outfd=fileno(out),flags=fcntl(outfd,F_GETFL);
  HyotanBsdStream tuple[3];OK(hyotan_bsd_streams_capture_stdio(streams,&scope,in,out,out,tuple));
  size_t n;unsigned char b[8];OK(hyotan_bsd_streams_read(streams,&scope,tuple[0],b,8,&n));assert(n==8 && !memcmp(b,binary,8));
  OK(hyotan_bsd_streams_read(streams,&scope,tuple[0],b,1,&n));assert(!n);
  assert(hyotan_bsd_streams_read(streams,&scope,tuple[1],b,1,&n)==EACCES && !n);
  OK(hyotan_bsd_streams_write(streams,&scope,tuple[1],binary,4,&n));OK(hyotan_bsd_streams_write(streams,&scope,tuple[2],binary+4,4,&n));
  OK(hyotan_bsd_streams_flush(streams,&scope,tuple[2]));
  assert(pread(outfd,b,8,0)==8 && !memcmp(b,binary,8));
  for(int i=0;i<3;i++)close_handle(tuple[i]);
  end();
  assert(fcntl(infd,F_GETFD)>=0 && fcntl(outfd,F_GETFL)==flags && fputs("live",out)>=0);
  start(scope.instance);assert(fseek(in,0,SEEK_SET)==0);
  OK(hyotan_bsd_streams_capture_stdio(streams,&scope,in,out,out,tuple));
  OK(hyotan_bsd_streams_read(streams,&scope,tuple[0],b,1,&n));assert(n==1);
  OK(hyotan_bsd_revoke(table,&scope));memset(b,0x55,sizeof(b));
  assert(hyotan_bsd_streams_read(streams,&scope,tuple[0],b,1,&n)==EACCES && !n && b[0]==0x55);
  for(int i=0;i<3;i++)close_handle(tuple[i]);
  end();fclose(in);fclose(out);
  start(scope.instance);FILE *all=tmpfile();assert(all);
  OK(hyotan_bsd_streams_capture_stdio(streams,&scope,all,all,all,tuple));
  for(int i=0;i<3;i++)close_handle(tuple[i]);
  end();assert(fputc(7,all)==7);fclose(all);
  start(scope.instance);int fd[2];assert(pipe(fd)==0);FILE *pipein=fdopen(fd[0],"r"),*normal=tmpfile();assert(pipein && normal);
  assert(hyotan_bsd_streams_capture_stdio(streams,&scope,pipein,normal,normal,tuple)==ENOTSUP && !tuple[0] && !tuple[1] && !tuple[2]);
  assert(fcntl(fd[0],F_GETFD)>=0);fclose(pipein);close(fd[1]);fclose(normal);end();
  start(scope.instance);int sock[2];assert(socketpair(AF_UNIX,SOCK_STREAM,0,sock)==0);FILE *socketfile=fdopen(sock[0],"r"),*special=fopen("/dev/null","w"),*input=tmpfile();assert(socketfile && special && input);
  assert(hyotan_bsd_streams_capture_stdio(streams,&scope,socketfile,special,special,tuple)==ENOTSUP);
  assert(hyotan_bsd_streams_capture_stdio(streams,&scope,input,special,special,tuple)==ENOTSUP);
  fclose(socketfile);close(sock[1]);fclose(special);fclose(input);end();
  puts("PASS: exact captured borrowed stdio directions/binary/EOF/aliases; parent FILE lifetime/status flags preserved; unprepared FIFO/socket/special rejected");
}
typedef struct {HyotanBsdStream handle;int write,error;size_t total;unsigned char *data;size_t length;} Task;
static void *transfer(void *argument) {
  Task *t=argument;
  while(t->total<t->length) {
    size_t n=0,len=t->length-t->total;if(len>16384)len=16384;
    t->error=t->write?hyotan_bsd_streams_write(streams,&scope,t->handle,t->data+t->total,len,&n):hyotan_bsd_streams_read(streams,&scope,t->handle,t->data+t->total,len,&n);
    if(t->error || !n)break;
    t->total+=n;
  }
  return NULL;
}
static void join(pthread_t thread,void **result) {
  struct timespec deadline;assert(clock_gettime(CLOCK_REALTIME,&deadline)==0);deadline.tv_sec+=3;
  assert(pthread_timedjoin_np(thread,result,&deadline)==0);
}
static void wait_active(void) {
  unsigned pending=0;struct timespec pause={0,1000000};
  for(int i=0;i<1000;i++) {OK(hyotan_bsd_streams_pending(streams,&scope,&pending));if(pending)return;nanosleep(&pause,NULL);}
  assert(!"I/O did not enter");
}
static void pipes(void) {
  start(scope.instance);HyotanBsdStream r,w;OK(hyotan_bsd_streams_pipe(streams,&scope,&r,&w));
  unsigned char output[sizeof(binary)];Task write={w,1,0,0,binary,sizeof(binary)},read={r,0,0,0,output,sizeof(output)};
  pthread_t writer,reader;assert(pthread_create(&writer,NULL,transfer,&write)==0);wait_active();
  assert(pthread_create(&reader,NULL,transfer,&read)==0);join(writer,NULL);close_handle(w);join(reader,NULL);
  assert(!write.error && !read.error && write.total==sizeof(binary) && read.total==sizeof(binary) && !memcmp(binary,output,sizeof(binary)));
  size_t n;OK(hyotan_bsd_streams_read(streams,&scope,r,output,1,&n));assert(!n);close_handle(r);end();
  puts("PASS: actual prepared POSIX pipe capacity/backpressure with concurrent threads; 256KiB binary exact; EOF");
  start(scope.instance);OK(hyotan_bsd_streams_pipe(streams,&scope,&r,&w));close_handle(r);
  sigset_t before,after;struct sigaction action_before,action_after;assert(!pthread_sigmask(SIG_SETMASK,NULL,&before));assert(!sigaction(SIGPIPE,NULL,&action_before));
  assert(hyotan_bsd_streams_write(streams,&scope,w,binary,1,&n)==EPIPE && !n);
  assert(!pthread_sigmask(SIG_SETMASK,NULL,&after));assert(!sigaction(SIGPIPE,NULL,&action_after));assert(sigismember(&before,SIGPIPE)==sigismember(&after,SIGPIPE) && action_before.sa_handler==action_after.sa_handler);
  sigset_t set,previous,pending;sigemptyset(&set);sigaddset(&set,SIGPIPE);
  assert(!pthread_sigmask(SIG_BLOCK,&set,&previous) && !raise(SIGPIPE));
  assert(hyotan_bsd_streams_write(streams,&scope,w,binary,1,&n)==EPIPE && !n);
  assert(!sigpending(&pending) && sigismember(&pending,SIGPIPE));
  struct timespec zero={0};assert(sigtimedwait(&set,NULL,&zero)==SIGPIPE);assert(!pthread_sigmask(SIG_SETMASK,&previous,NULL));
  close_handle(w);end();
  for(int blocked_write=0;blocked_write<2;blocked_write++) {
    start(scope.instance);OK(hyotan_bsd_streams_pipe(streams,&scope,&r,&w));
    Task blocked={blocked_write?w:r,blocked_write,0,0,output,sizeof(output)};pthread_t thread;assert(pthread_create(&thread,NULL,transfer,&blocked)==0);wait_active();
    HyotanBsdScope wrong=scope;wrong.generation++;
    assert(hyotan_bsd_streams_cancel(streams,&wrong)==EACCES);
    unsigned retained=0;OK(hyotan_bsd_streams_pending(streams,&scope,&retained));assert(retained);
    assert(hyotan_bsd_streams_destroy(streams)==EBUSY && hyotan_bsd_descriptors_destroy(table)==EBUSY);
    close_handle(blocked.handle); /* in-flight object pin survives logical close */
    assert(hyotan_bsd_streams_destroy(streams)==EBUSY);
    OK(hyotan_bsd_streams_cancel(streams,&scope));void *result=NULL;join(thread,&result);assert(result==PTHREAD_CANCELED);
    unsigned pending=99;OK(hyotan_bsd_streams_pending(streams,&scope,&pending));assert(!pending);
    close_handle(blocked_write?r:w);end();
  }
  start(scope.instance);OK(hyotan_bsd_streams_pipe(streams,&scope,&r,&w));OK(hyotan_bsd_streams_write(streams,&scope,w,binary,1,&n));assert(n==1);unsigned char byte=7;OK(hyotan_bsd_streams_read(streams,&scope,r,&byte,1,&n));assert(n==1 && byte==binary[0]);close_handle(r);close_handle(w);end();
  puts("PASS: real EPIPE with original mask/disposition restored; blocked read/write deferred cancellation pins/EBUSY, actual thread join and next context success");
}
int main(int argc,char **argv) {
  assert(argc==2);rootfd=open(argv[1],O_RDONLY|O_DIRECTORY);assert(rootfd>=0);
  for(size_t i=0;i<sizeof(binary);i++)binary[i]=(unsigned char)(i*37u);
  regular();borrowed();pipes();
  scope.instance++;
  OK(hyotan_bsd_descriptors_create(rootfd,&scope,2,1048576,1048576,&table));
  OK(hyotan_bsd_report_refusal(table,&scope,HYOTAN_BSD_REPORT_READ,EACCES));
  OK(hyotan_bsd_streams_create(table,&scope,&streams));
  HyotanBsdRefusalStatus existing;OK(hyotan_bsd_refusal_status(table,&scope,&existing));
  assert(existing.error==EACCES && existing.operation==HYOTAN_BSD_REPORT_READ && existing.count==1);end();
  puts("PASS: captured context preserves earlier same-command immutable refusal receipt without reset");
  close(rootfd);return 0;
}
