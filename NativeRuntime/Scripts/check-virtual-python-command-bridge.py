#!/usr/bin/env python3
"""Compile pure-C bridge and exercise actual concurrent native pipes on Linux.

This tests the shuttle foundation; it does not evaluate Python or claim actual
Swift XPC, WK/Pyodide, Apple pthread cancellation or product routing.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = r'''
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "VirtualPythonCommandBridge.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/ioctl.h>
#include <unistd.h>
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void tick(void){struct timespec t={.tv_nsec=1000000};nanosleep(&t,NULL);}
static uint8_t value(size_t index){return (uint8_t)((index*37)%251);}
static void write_all(int fd,const uint8_t *bytes,size_t size){while(size){ssize_t n=write(fd,bytes,size);if(n<0&&errno==EINTR)continue;assert(n>0);bytes+=n;size-=(size_t)n;}}
static void pipe_pair(int p[2]){assert(pipe(p)==0);}
static const char *const argv_test[]={"python3","-c","print('日本語')"};
static void make(int input,int output,int error,StruisVirtualPythonInvocation **i,StruisVPContext *k){assert(StruisVPCreate("worker-1","owner-parent",9,STRUIS_VP_PYTHON_MAIN,3,argv_test,input,output,error,i,k)==0);}
struct Producer {int fd;size_t count;atomic_int *early,*finished;};
static void *produce(void *raw){struct Producer *p=raw;uint8_t bytes[4096];size_t at=0;size_t first=1024;for(size_t n=0;n<first;n++)bytes[n]=value(n);write_all(p->fd,bytes,first);at=first;double end=now()+5;while(!atomic_load(p->early)){assert(now()<end);tick();}
 while(at<p->count){size_t take=p->count-at;if(take>sizeof(bytes))take=sizeof(bytes);for(size_t n=0;n<take;n++)bytes[n]=value(at+n);write_all(p->fd,bytes,take);at+=take;}close(p->fd);atomic_store(p->finished,1);return NULL;}
struct Consumer {int fd;size_t expected;uint8_t mask;atomic_int *early,*input_finished;};
static void *consume(void *raw){struct Consumer *c=raw;uint8_t bytes[997];size_t at=0;for(;;){ssize_t n=read(c->fd,bytes,sizeof(bytes));if(n<0&&errno==EINTR)continue;assert(n>=0);if(!n)break;for(ssize_t p=0;p<n;p++){assert(at<c->expected);assert(bytes[p]==(uint8_t)(value(at)^c->mask));at++;}if(c->early&&!atomic_load(c->early)){assert(!atomic_load(c->input_finished));atomic_store(c->early,1);}}
 assert(at==c->expected);close(c->fd);return NULL;}
static void push_all(StruisVirtualPythonInvocation *i,const StruisVPContext *k,uint32_t stream,uint8_t *bytes,size_t count){double end=now()+5;size_t at=0;while(at<count){size_t accepted=0;int e=StruisVPPushOutput(i,k,stream,bytes+at,count-at,&accepted);assert(e==0||e==EAGAIN);assert(accepted<=count-at);at+=accepted;if(!accepted){assert(now()<end);tick();}}}
static void transfer(void){int in[2],out[2],err[2];pipe_pair(in);pipe_pair(out);pipe_pair(err);int input_flags=fcntl(in[0],F_GETFL),output_flags=fcntl(out[1],F_GETFL),error_flags=fcntl(err[1],F_GETFL);
 StruisVirtualPythonInvocation *i=NULL;StruisVPContext k;make(in[0],out[1],err[1],&i,&k);assert(fcntl(in[0],F_GETFL)==input_flags&&fcntl(out[1],F_GETFL)==output_flags&&fcntl(err[1],F_GETFL)==error_flags);assert(StruisVPStart(i,&k)==0);assert(fcntl(in[0],F_GETFL)==input_flags&&fcntl(out[1],F_GETFL)==output_flags&&fcntl(err[1],F_GETFL)==error_flags);close(in[0]);close(out[1]);close(err[1]);
 const size_t count=STRUIS_VP_QUEUE_CAPACITY*5+237;atomic_int early=0,finished=0;struct Producer producer={in[1],count,&early,&finished};struct Consumer stdout_reader={out[0],count,0x55,&early,&finished},stderr_reader={err[0],count,0xaa,NULL,NULL};pthread_t prod,readout,readerr;assert(pthread_create(&prod,NULL,produce,&producer)==0);assert(pthread_create(&readout,NULL,consume,&stdout_reader)==0);assert(pthread_create(&readerr,NULL,consume,&stderr_reader)==0);
 uint8_t bytes[8192],errors[8192];size_t seen=0;double end=now()+8;for(;;){size_t n=999;uint32_t eof=999;int e=StruisVPPullStdin(i,&k,bytes,sizeof(bytes),&n,&eof);assert(e==0||e==EAGAIN);if(e==EAGAIN){assert(n==0&&!eof);assert(now()<end);tick();continue;}for(size_t p=0;p<n;p++){assert(bytes[p]==value(seen+p));errors[p]=(uint8_t)(bytes[p]^0xaa);bytes[p]^=0x55;}push_all(i,&k,STRUIS_VP_STDOUT,bytes,n);push_all(i,&k,STRUIS_VP_STDERR,errors,n);seen+=n;if(eof)break;}
 assert(seen==count&&atomic_load(&early));assert(StruisVPFinished(i,&k,42)==0);StruisVPResult result;assert(StruisVPAwait(i,&k,2000,&result)==0);assert(result.exit_code==42&&result.reason==STRUIS_VP_EXIT_NORMAL&&result.stdin_bytes==count&&result.stdout_bytes==count&&result.stderr_bytes==count);assert(pthread_join(prod,NULL)==0&&pthread_join(readout,NULL)==0&&pthread_join(readerr,NULL)==0);assert(StruisVPDestroy(i,&k)==0);puts("PASS concurrent real pipes: binary bytes>queue, early output before inputEOF, independent stderr, EOF+exit42");}
static void merged_and_keys(void){int in[2],out[2];pipe_pair(in);pipe_pair(out);StruisVirtualPythonInvocation *i=NULL;StruisVPContext k;make(in[0],out[1],out[1],&i,&k);close(in[0]);close(out[1]);uint32_t function=0;size_t argc=0;assert(StruisVPDescribe(i,&k,&function,&argc)==0&&function==STRUIS_VP_PYTHON_MAIN&&argc==3);uint8_t arg[128];memset(arg,0xa5,sizeof(arg));size_t required=0;assert(StruisVPArgument(i,&k,2,arg,1,&required)==ERANGE&&required==strlen(argv_test[2])+1);for(size_t p=0;p<sizeof(arg);p++)assert(arg[p]==0xa5);assert(StruisVPArgument(i,&k,2,arg,sizeof(arg),&required)==0&&!memcmp(arg,argv_test[2],required));
 StruisVPContext wrong=k;wrong.generation++;StruisVPStatus status;size_t accepted=99;assert(StruisVPStatusRead(i,&wrong,&status)==EACCES&&status.started==0);assert(StruisVPStart(i,&wrong)==EACCES);assert(StruisVPPushOutput(i,&wrong,1,(const uint8_t *)"bad",3,&accepted)==EACCES&&accepted==0);assert(StruisVPFinished(i,&wrong,0)==EACCES);assert(StruisVPCancel(i,&wrong)==EACCES);assert(StruisVPDestroy(i,&wrong)==EACCES);
 StruisVPContext unknown={0};assert(StruisVPDescribe(i,&unknown,&function,&argc)==EACCES&&function==0&&argc==0);wrong=k;wrong.owner[0]='X';assert(StruisVPCancel(i,&wrong)==EACCES);wrong=k;wrong.worker_id[0]='X';assert(StruisVPStatusRead(i,&wrong,&status)==EACCES);
 assert(StruisVPStart(i,&k)==0);assert(StruisVPStatusRead(i,&k,&status)==0&&status.merged_output);uint8_t a[]={'A',0,'B'},b[]={'E','R','R'},c[]={'Z'};push_all(i,&k,1,a,sizeof(a));push_all(i,&k,2,b,sizeof(b));push_all(i,&k,1,c,sizeof(c));assert(StruisVPFinished(i,&k,7)==0);assert(StruisVPFinished(i,&k,9)==EALREADY);StruisVPResult result;assert(StruisVPAwait(i,&k,2000,&result)==0&&result.exit_code==7&&result.stdout_bytes==4&&result.stderr_bytes==3);assert(StruisVPCancel(i,&k)==EALREADY);assert(StruisVPAwait(i,&k,0,&result)==0&&result.exit_code==7&&result.reason==STRUIS_VP_EXIT_NORMAL);uint8_t output[16];ssize_t total=0,n;while((n=read(out[0],output+total,sizeof(output)-(size_t)total))>0)total+=n;assert(n==0&&total==7&&!memcmp(output,"A\0BERRZ",7));close(out[0]);close(in[1]);accepted=99;assert(StruisVPPushOutput(i,&k,1,a,1,&accepted)==EPIPE&&accepted==0);assert(StruisVPDestroy(i,&k)==0);
 pipe_pair(in);pipe_pair(out);StruisVirtualPythonInvocation *next=NULL;StruisVPContext next_key;make(in[0],out[1],out[1],&next,&next_key);assert(next_key.invocation_id!=k.invocation_id);assert(StruisVPStart(next,&k)==EACCES);assert(StruisVPCancel(next,&k)==EACCES);assert(StruisVPStart(next,&next_key)==0);assert(StruisVPCancel(next,&next_key)==0);assert(StruisVPAwait(next,&next_key,2000,&result)==0&&result.reason==STRUIS_VP_EXIT_CANCELLED);assert(StruisVPDestroy(next,&next_key)==0);close(in[0]);close(in[1]);close(out[0]);close(out[1]);puts("PASS merged descriptor FIFO, argv, unknown/wrong/old context, next invocation");}
static void cancel_backpressure(void){int in[2],out[2];pipe_pair(in);pipe_pair(out);int pipe_capacity=fcntl(out[1],F_GETPIPE_SZ);assert(pipe_capacity>0);StruisVirtualPythonInvocation *i=NULL;StruisVPContext k;make(in[0],out[1],out[1],&i,&k);close(in[0]);close(out[1]);assert(StruisVPStart(i,&k)==0);uint8_t frame[STRUIS_VP_MAX_FRAME];memset(frame,0x75,sizeof(frame));size_t accepted,total=0;int blocked=0;double end=now()+3;while(!blocked){accepted=99;int e=StruisVPPushOutput(i,&k,1,frame,sizeof(frame),&accepted);assert(e==0||e==EAGAIN);total+=accepted;if(e==EAGAIN){assert(accepted==0);int kernel_bytes=0;assert(ioctl(out[0],FIONREAD,&kernel_bytes)==0);if(kernel_bytes==pipe_capacity)blocked=1;else tick();}assert(now()<end);}
 StruisVPStatus status;assert(StruisVPStatusRead(i,&k,&status)==0&&status.stdout_credit==0);assert(total<=STRUIS_VP_QUEUE_CAPACITY+(size_t)pipe_capacity);StruisVPResult result;memset(&result,0xff,sizeof(result));assert(StruisVPAwait(i,&k,0,&result)==ETIMEDOUT&&result.exit_code==0&&result.stdout_bytes==0);assert(StruisVPDestroy(i,&k)==EBUSY);StruisVirtualPythonInvocation *second=NULL;StruisVPContext other;assert(StruisVPCreate("other","other",10,1,3,argv_test,in[1],out[0],out[0],&second,&other)==EBUSY&&!second);
 assert(StruisVPFinished(i,&k,0)==0);assert(StruisVPAwait(i,&k,20,&result)==ETIMEDOUT);double began=now();assert(StruisVPCancel(i,&k)==0);assert(StruisVPAwait(i,&k,2000,&result)==0);assert(now()-began<2&&result.reason==STRUIS_VP_EXIT_CANCELLED&&result.exit_code==130);accepted=99;assert(StruisVPPushOutput(i,&k,1,frame,1,&accepted)==ECANCELED&&accepted==0);assert(StruisVPDestroy(i,&k)==0);close(in[1]);uint8_t bytes[4096];while(read(out[0],bytes,sizeof(bytes))>0){}close(out[0]);puts("PASS finite credit+backpressure, timeout requires retirement/no new invocation, blocked write cancellation");}
static void cancel_input(void){int in[2],out[2];pipe_pair(in);pipe_pair(out);StruisVirtualPythonInvocation *i=NULL;StruisVPContext k;make(in[0],out[1],out[1],&i,&k);close(in[0]);close(out[1]);assert(StruisVPStart(i,&k)==0);tick();StruisVPResult result;assert(StruisVPAwait(i,&k,1,&result)==ETIMEDOUT);assert(StruisVPCancel(i,&k)==0);assert(StruisVPAwait(i,&k,2000,&result)==0&&result.exit_code==130);uint8_t bytes[16];size_t n=99;uint32_t eof=99;assert(StruisVPPullStdin(i,&k,bytes,sizeof(bytes),&n,&eof)==ECANCELED&&n==0&&!eof);assert(StruisVPDestroy(i,&k)==0);close(in[1]);assert(read(out[0],bytes,sizeof(bytes))==0);close(out[0]);puts("PASS blocked read cancellation and owned-fd EOF cleanup");}
static void broken_pipe(void){int in[2],out[2];pipe_pair(in);pipe_pair(out);struct sigaction before,after;assert(sigaction(SIGPIPE,NULL,&before)==0);sigset_t mask_before,mask_after;assert(pthread_sigmask(SIG_SETMASK,NULL,&mask_before)==0);StruisVirtualPythonInvocation *i=NULL;StruisVPContext k;make(in[0],out[1],out[1],&i,&k);close(in[0]);close(out[0]);close(out[1]);assert(StruisVPStart(i,&k)==0);size_t accepted=0;assert(StruisVPPushOutput(i,&k,1,(const uint8_t *)"closed",6,&accepted)==0&&accepted==6);StruisVPResult result;assert(StruisVPAwait(i,&k,2000,&result)==0&&result.reason==STRUIS_VP_EXIT_IO_ERROR&&result.io_error==EPIPE&&result.exit_code==125);assert(StruisVPFinished(i,&k,0)==EPIPE);assert(sigaction(SIGPIPE,NULL,&after)==0&&before.sa_handler==after.sa_handler);assert(pthread_sigmask(SIG_SETMASK,NULL,&mask_after)==0&&sigismember(&mask_before,SIGPIPE)==sigismember(&mask_after,SIGPIPE));assert(StruisVPDestroy(i,&k)==0);close(in[1]);puts("PASS actual downstream EPIPE, no process-global SIGPIPE mutation");}
static void nonblocking_flags_and_limits(void){int in[2],out[2];pipe_pair(in);pipe_pair(out);int original_in=fcntl(in[0],F_GETFL),original_out=fcntl(out[1],F_GETFL);assert(fcntl(in[0],F_SETFL,original_in|O_NONBLOCK)==0&&fcntl(out[1],F_SETFL,original_out|O_NONBLOCK)==0);StruisVirtualPythonInvocation *i=NULL;StruisVPContext k;make(in[0],out[1],out[1],&i,&k);assert(StruisVPStart(i,&k)==0);assert(fcntl(in[0],F_GETFL)==(original_in|O_NONBLOCK)&&fcntl(out[1],F_GETFL)==(original_out|O_NONBLOCK));uint8_t bytes[STRUIS_VP_MAX_FRAME];size_t count=99;uint32_t eof=99;assert(StruisVPPullStdin(i,&k,bytes,sizeof(bytes)+1,&count,&eof)==EINVAL&&count==0&&!eof);assert(StruisVPPushOutput(i,&k,3,bytes,1,&count)==EINVAL&&count==0);assert(StruisVPPushOutput(i,&k,1,bytes,sizeof(bytes)+1,&count)==EINVAL);assert(StruisVPCancel(i,&k)==0);StruisVPResult result;assert(StruisVPAwait(i,&k,STRUIS_VP_MAX_WAIT_MS+1,&result)==EINVAL);assert(StruisVPAwait(i,&k,2000,&result)==0);assert(StruisVPDestroy(i,&k)==0);assert(fcntl(in[0],F_GETFL)==(original_in|O_NONBLOCK)&&fcntl(out[1],F_GETFL)==(original_out|O_NONBLOCK));
 char *large=malloc(STRUIS_VP_MAX_ARG_LENGTH+2);assert(large);memset(large,'x',STRUIS_VP_MAX_ARG_LENGTH+1);large[STRUIS_VP_MAX_ARG_LENGTH+1]=0;const char *argv[]={large};assert(StruisVPCreate("w","o",1,1,1,argv,in[0],out[1],out[1],&i,&k)==E2BIG&&!i);free(large);close(in[0]);close(in[1]);close(out[0]);close(out[1]);puts("PASS shared status flags unchanged, preexisting nonblocking descriptors, frame/argv bounds");}
int main(void){assert(pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,NULL)==0);setvbuf(stdout,NULL,_IONBF,0);signal(SIGPIPE,SIG_DFL);alarm(20);transfer();merged_and_keys();cancel_backpressure();cancel_input();broken_pipe();nonblocking_flags_and_limits();assert(StruisVPAppleProbe()==STRUIS_VP_APPLE_PROBE_ALL);puts("PASS same portable Apple worker probe: all bits 63, joined helpers, cancellation/EOF/EPIPE/next context, regular stdout/stderr binary file visibility+flags");puts("PASS pure-C foundation only: native Python/provider routing remains unchanged");return 0;}
'''

def main():
    with tempfile.TemporaryDirectory(prefix="hyotan-native-duplex-") as directory:
        temp = Path(directory)
        source = temp / "caller.c"
        binary = temp / "caller"
        source.write_text(SOURCE)
        subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-pthread", "-I", str(ROOT / "Worker"), str(source), str(ROOT / "Worker/VirtualPythonCommandBridge.c"), str(ROOT / "Worker/VirtualPythonCommandBridgeAppleProbe.c"), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=25)

if __name__ == "__main__":
    main()
