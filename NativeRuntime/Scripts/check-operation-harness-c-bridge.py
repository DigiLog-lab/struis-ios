#!/usr/bin/env python3
"""Run an actual C caller against the operations-only Rust static library.

No AppServer, browser/Python provider, private user files, or credentials are used.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
C_SOURCE = r'''
#define _POSIX_C_SOURCE 200809L
#include "HyotanOperations.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sched.h>
_Static_assert(sizeof(HyotanOperationMetadata)==32,"metadata size");
_Static_assert(offsetof(HyotanOperationMetadata,flags)==24,"metadata flags offset");
#define P(s) (const uint8_t *)(s),strlen(s)
#define OK(call) assert((call)==0)
#define DENY(call) assert((call)==EACCES)
static void file(const char *path,const char *bytes) { int fd=open(path,O_WRONLY|O_CREAT|O_EXCL,0600);assert(fd>=0);assert(write(fd,bytes,strlen(bytes))==(ssize_t)strlen(bytes));close(fd); }
struct Race {HyotanWorkspace *workspace;uint64_t handle;atomic_uint completed;atomic_int denied;};
static void *reader(void *raw) {struct Race *race=raw;uint8_t byte;size_t count;for(;;){int code=hyotan_operations_read_at(race->workspace,race->handle,0,1,&byte,1,&count);if(code==EACCES){assert(count==0);atomic_store(&race->denied,1);return NULL;}assert(code==0&&count==1);atomic_fetch_add(&race->completed,1);}}
static void configured_policy_case(const char *base) {
 char root[4096],canary[4096],path[4096];
 assert(snprintf(root,sizeof(root),"%s/configured",base)<(int)sizeof(root));assert(mkdir(root,0700)==0);
 assert(snprintf(canary,sizeof(canary),"%s/policy-canary",base)<(int)sizeof(canary));file(canary,"private canary");
 int directory=open(root,O_RDONLY|O_DIRECTORY);assert(directory>=0);
 uint64_t limit=UINT64_C(4)*1024*1024*1024,read_limit=9,write_limit=9;uint32_t configured=9;
 HyotanWorkspace *w=NULL,*legacy=NULL,*other=NULL,*invalid=(HyotanWorkspace *)(uintptr_t)1;
 assert(hyotan_operations_create_with_descriptor_limits(directory,"trusted",1,2,0,limit,&invalid)==EINVAL&&!invalid);
 invalid=(HyotanWorkspace *)(uintptr_t)1;assert(hyotan_operations_create_with_descriptor_limits(directory,"trusted",1,2,limit,UINT64_MAX,&invalid)==EINVAL&&!invalid);
 invalid=(HyotanWorkspace *)(uintptr_t)1;assert(hyotan_operations_create_with_descriptor_limits(directory,"trusted",1,2,UINT64_MAX,limit,&invalid)==EINVAL&&!invalid);
 OK(hyotan_operations_create_with_descriptor_limits(directory,"trusted",1,2,limit,limit,&w));
 OK(hyotan_operations_create(directory,"trusted",1,2,&legacy));OK(hyotan_operations_create_with_descriptor_limits(directory,"foreign",2,1,limit,limit,&other));
 OK(hyotan_operations_descriptor_limits(w,&read_limit,&write_limit,&configured));assert(read_limit==limit&&write_limit==limit&&configured==1);
 assert(hyotan_operations_descriptor_limits(w,NULL,&write_limit,&configured)==EINVAL);
 read_limit=write_limit=9;configured=9;assert(hyotan_operations_descriptor_limits(NULL,&read_limit,&write_limit,&configured)==EINVAL);assert(read_limit==0&&write_limit==0&&configured==0);
 OK(hyotan_operations_descriptor_limits(legacy,&read_limit,&write_limit,&configured));assert(read_limit==16*1024*1024&&write_limit==16*1024*1024&&configured==0);
 uint64_t handle=0,denied_handle=99;size_t count=99;uint8_t bytes[16];HyotanOperationMetadata metadata;
 OK(hyotan_operations_open(w,P("日本語.bin"),HYOTAN_OPEN_READ|HYOTAN_OPEN_WRITE|HYOTAN_OPEN_CREATE|HYOTAN_OPEN_EXCLUSIVE,&handle));
 OK(hyotan_operations_truncate(w,handle,limit));OK(hyotan_operations_stat(w,handle,&metadata));assert(metadata.bytes==limit);
 const uint8_t payload[]={0,255,42,65};const uint64_t offsets[]={UINT64_C(2)*1024*1024*1024+3,limit-4};
 for(size_t i=0;i<2;i++){OK(hyotan_operations_write_at(w,handle,offsets[i],payload,sizeof(payload),&count));assert(count==4);memset(bytes,0xa5,sizeof(bytes));OK(hyotan_operations_read_at(w,handle,offsets[i],sizeof(bytes),bytes,sizeof(bytes),&count));assert(count>=4&&!memcmp(bytes,payload,4));if(i==1){assert(count==4);for(size_t j=4;j<sizeof(bytes);j++)assert(bytes[j]==0xa5);}}
 OK(hyotan_operations_read_at(w,handle,limit,16,bytes,sizeof(bytes),&count));assert(count==0);
 DENY(hyotan_operations_read_at(w,handle,limit+1,1,bytes,sizeof(bytes),&count));assert(count==0);
 DENY(hyotan_operations_write_at(w,handle,limit,payload,1,&count));assert(count==0);
 DENY(hyotan_operations_write_at(w,handle,UINT64_MAX,payload,1,&count));assert(count==0);
 DENY(hyotan_operations_truncate(w,handle,limit+1));DENY(hyotan_operations_truncate(w,handle,UINT64_MAX));
 assert(hyotan_operations_read_at(w,handle,0,1024*1024+1,bytes,sizeof(bytes),&count)==EFBIG&&count==0);
 assert(hyotan_operations_write_at(w,handle,0,NULL,1024*1024+1,&count)==EFBIG&&count==0);
 DENY(hyotan_operations_open(legacy,P("日本語.bin"),HYOTAN_OPEN_READ,&denied_handle));assert(denied_handle==0);
 DENY(hyotan_operations_copy(w,P("日本語.bin"),P("copy.bin"),0));
 DENY(hyotan_operations_read_at(other,handle,0,1,bytes,sizeof(bytes),&count));assert(count==0);
 uint64_t readonly=0;OK(hyotan_operations_open(other,P("日本語.bin"),HYOTAN_OPEN_READ,&readonly));DENY(hyotan_operations_write_at(other,readonly,0,payload,1,&count));assert(count==0);
 assert(snprintf(path,sizeof(path),"%s/日本語.bin",root)<(int)sizeof(path));struct stat stat;assert(lstat(path,&stat)==0&&stat.st_size==(off_t)limit&&(uint64_t)stat.st_blocks*512<1024*1024);
 assert(snprintf(path,sizeof(path),"%s/link",root)<(int)sizeof(path));assert(symlink(canary,path)==0);DENY(hyotan_operations_open(w,P("link"),HYOTAN_OPEN_READ,&denied_handle));assert(denied_handle==0);
 assert(snprintf(path,sizeof(path),"%s/hard",root)<(int)sizeof(path));assert(link(canary,path)==0);DENY(hyotan_operations_open(w,P("hard"),HYOTAN_OPEN_READ,&denied_handle));assert(denied_handle==0);
 DENY(hyotan_operations_open(w,P("../policy-canary"),HYOTAN_OPEN_READ,&denied_handle));DENY(hyotan_operations_open(w,P(canary),HYOTAN_OPEN_READ,&denied_handle));
 OK(hyotan_operations_revoke(w));read_limit=write_limit=9;configured=9;DENY(hyotan_operations_descriptor_limits(w,&read_limit,&write_limit,&configured));assert(read_limit==0&&write_limit==0&&configured==0);
 DENY(hyotan_operations_read_at(w,handle,0,1,bytes,sizeof(bytes),&count));assert(count==0);
 HyotanWorkspace *fresh=NULL;OK(hyotan_operations_create_with_descriptor_limits(directory,"trusted",3,2,limit,limit,&fresh));uint64_t new_handle=0;OK(hyotan_operations_open(fresh,P("日本語.bin"),HYOTAN_OPEN_READ,&new_handle));assert(new_handle!=handle);DENY(hyotan_operations_read_at(fresh,handle,0,1,bytes,sizeof(bytes),&count));OK(hyotan_operations_read_at(fresh,new_handle,limit-4,4,bytes,sizeof(bytes),&count));assert(count==4&&!memcmp(bytes,payload,4));
 HyotanWorkspace *asymmetric=NULL;OK(hyotan_operations_create_with_descriptor_limits(directory,"trusted",4,2,16,64,&asymmetric));uint64_t asymmetric_handle=0;OK(hyotan_operations_open(asymmetric,P("asym"),3|4|8,&asymmetric_handle));OK(hyotan_operations_truncate(asymmetric,asymmetric_handle,64));OK(hyotan_operations_write_at(asymmetric,asymmetric_handle,15,payload,4,&count));OK(hyotan_operations_read_at(asymmetric,asymmetric_handle,15,16,bytes,sizeof(bytes),&count));assert(count==1&&bytes[0]==0);OK(hyotan_operations_read_at(asymmetric,asymmetric_handle,16,16,bytes,sizeof(bytes),&count));assert(count==0);DENY(hyotan_operations_read_at(asymmetric,asymmetric_handle,17,1,bytes,sizeof(bytes),&count));assert(count==0);OK(hyotan_operations_write_at(asymmetric,asymmetric_handle,63,payload,1,&count));DENY(hyotan_operations_write_at(asymmetric,asymmetric_handle,64,payload,1,&count));
 int canary_fd=open(canary,O_RDONLY);assert(canary_fd>=0);assert(read(canary_fd,bytes,sizeof(bytes))==14&&!memcmp(bytes,"private canary",14));close(canary_fd);
 OK(hyotan_operations_destroy(w));OK(hyotan_operations_destroy(legacy));OK(hyotan_operations_destroy(other));OK(hyotan_operations_destroy(fresh));OK(hyotan_operations_destroy(asymmetric));close(directory);
 puts("PASS configured C descriptor policy: real sparse4GiB, >2GiB binary chunks, bounded EOF, asymmetry, unchanged legacy/frame/copy, foreign/revoke/fresh and unchanged canary");
}

int main(int argc,char **argv) {
 assert(argc==2);configured_policy_case(argv[1]);char work[4096],private[4096],canary[4096],path[4096],original[4096];
 assert(snprintf(work,sizeof(work),"%s/work",argv[1])<(int)sizeof(work));assert(snprintf(private,sizeof(private),"%s/private",argv[1])<(int)sizeof(private));
 assert(mkdir(work,0700)==0);assert(mkdir(private,0700)==0);assert(snprintf(canary,sizeof(canary),"%s/canary",private)<(int)sizeof(canary));file(canary,"private canary");
 int fd=open(work,O_RDONLY|O_DIRECTORY);assert(fd>=0);HyotanWorkspace *w=NULL,*other=NULL,*ro=NULL;
 HyotanWorkspace *invalid_instance=(HyotanWorkspace *)(uintptr_t)1;
 assert(hyotan_operations_create(fd,"parent",7,99,&invalid_instance)==EINVAL);assert(!invalid_instance);
 assert(hyotan_operations_create(-1,"parent",7,HYOTAN_WORKSPACE_READ_WRITE,&invalid_instance)==EBADF);assert(!invalid_instance);
 assert(hyotan_operations_create(fd,"",7,HYOTAN_WORKSPACE_READ_WRITE,&invalid_instance)==EINVAL);assert(!invalid_instance);
 OK(hyotan_operations_create(fd,"parent",7,HYOTAN_WORKSPACE_READ_WRITE,&w));OK(hyotan_operations_create(fd,"child",8,HYOTAN_WORKSPACE_READ_WRITE,&other));OK(hyotan_operations_create(fd,"parent",7,HYOTAN_WORKSPACE_READ_ONLY,&ro));close(fd);
 uint64_t handle=999,foreign=999;size_t written=999,read_count=999;uint8_t buffer[64];HyotanOperationMetadata stat;
 uint32_t rw=HYOTAN_OPEN_READ|HYOTAN_OPEN_WRITE;
 OK(hyotan_operations_open(w,P("日本語.txt"),rw|HYOTAN_OPEN_CREATE|HYOTAN_OPEN_EXCLUSIVE,&handle));assert(handle!=0);
 OK(hyotan_operations_write_at(w,handle,0,(const uint8_t *)"abcdef",6,&written));assert(written==6);
 OK(hyotan_operations_read_at(w,handle,2,3,buffer,sizeof(buffer),&read_count));assert(read_count==3&&!memcmp(buffer,"cde",3));
 OK(hyotan_operations_write_at(w,handle,2,(const uint8_t *)"XY",2,&written));OK(hyotan_operations_read_at(w,handle,0,6,buffer,sizeof(buffer),&read_count));assert(!memcmp(buffer,"abXYef",6));
 memset(buffer,0xa5,sizeof(buffer));read_count=999;assert(hyotan_operations_read_at(w,handle,0,6,buffer,2,&read_count)==ERANGE);assert(read_count==0);for(size_t i=0;i<sizeof(buffer);i++)assert(buffer[i]==0xa5);
 uint64_t failed=999;assert(hyotan_operations_open(w,P("日本語.txt"),rw|HYOTAN_OPEN_CREATE|HYOTAN_OPEN_EXCLUSIVE,&failed)==EEXIST);assert(failed==0);
 OK(hyotan_operations_open(other,P("日本語.txt"),HYOTAN_OPEN_READ,&foreign));assert(foreign!=handle);DENY(hyotan_operations_read_at(w,foreign,0,1,buffer,sizeof(buffer),&read_count));assert(read_count==0);DENY(hyotan_operations_read_at(other,handle,0,1,buffer,sizeof(buffer),&read_count));
 uint64_t append=0;OK(hyotan_operations_open(w,P("日本語.txt"),HYOTAN_OPEN_WRITE|HYOTAN_OPEN_APPEND,&append));OK(hyotan_operations_write_at(w,append,0,(const uint8_t *)"!",1,&written));DENY(hyotan_operations_read_at(w,append,0,1,buffer,sizeof(buffer),&read_count));OK(hyotan_operations_stat(w,append,&stat));assert(stat.bytes==7);OK(hyotan_operations_close(w,append));DENY(hyotan_operations_close(w,append));
 OK(hyotan_operations_truncate(w,handle,4));OK(hyotan_operations_stat(w,handle,&stat));assert(stat.bytes==4);OK(hyotan_operations_close(w,handle));DENY(hyotan_operations_read_at(w,handle,0,1,buffer,sizeof(buffer),&read_count));
 OK(hyotan_operations_open(w,P("日本語.txt"),rw|HYOTAN_OPEN_TRUNCATE,&handle));OK(hyotan_operations_stat(w,handle,&stat));assert(stat.bytes==0);OK(hyotan_operations_write_at(w,handle,0,(const uint8_t *)"allowed",7,&written));
 assert(snprintf(path,sizeof(path),"%s/日本語.txt",work)<(int)sizeof(path));assert(snprintf(original,sizeof(original),"%s/original",work)<(int)sizeof(original));assert(rename(path,original)==0);assert(symlink(canary,path)==0);
 OK(hyotan_operations_read_at(w,handle,0,7,buffer,sizeof(buffer),&read_count));assert(!memcmp(buffer,"allowed",7));OK(hyotan_operations_write_at(w,handle,0,(const uint8_t *)"changed",7,&written));DENY(hyotan_operations_open(w,P("日本語.txt"),rw|HYOTAN_OPEN_TRUNCATE,&failed));assert(failed==0);
 assert(snprintf(path,sizeof(path),"%s/ancestor",work)<(int)sizeof(path));assert(symlink(private,path)==0);assert(snprintf(path,sizeof(path),"%s/hard",work)<(int)sizeof(path));assert(link(canary,path)==0);
 DENY(hyotan_operations_open(w,P("ancestor/canary"),rw|HYOTAN_OPEN_TRUNCATE,&failed));DENY(hyotan_operations_open(w,P("hard"),rw|HYOTAN_OPEN_TRUNCATE,&failed));DENY(hyotan_operations_open(w,P("../private/canary"),rw,&failed));DENY(hyotan_operations_open(w,P(canary),rw,&failed));DENY(hyotan_operations_metadata(w,P("hard"),&stat));assert(stat.bytes==0);
 uint8_t embedded[]={ 'o','k',0,'x' },invalid[]={0xff};assert(hyotan_operations_open(w,embedded,sizeof(embedded),HYOTAN_OPEN_READ,&failed)==EINVAL);assert(hyotan_operations_open(w,invalid,sizeof(invalid),HYOTAN_OPEN_READ,&failed)==EINVAL);assert(hyotan_operations_open(w,P("original"),64,&failed)==EINVAL);assert(hyotan_operations_open(w,P("original"),HYOTAN_OPEN_READ|HYOTAN_OPEN_TRUNCATE,&failed)==EINVAL);assert(hyotan_operations_open(w,P("original"),HYOTAN_OPEN_READ|HYOTAN_OPEN_EXCLUSIVE,&failed)==EINVAL);
 DENY(hyotan_operations_open(ro,P("original"),HYOTAN_OPEN_WRITE,&failed));DENY(hyotan_operations_open(ro,P("new"),HYOTAN_OPEN_READ|HYOTAN_OPEN_CREATE,&failed));uint64_t readonly=0;OK(hyotan_operations_open(ro,P("original"),HYOTAN_OPEN_READ,&readonly));DENY(hyotan_operations_write_at(ro,readonly,0,(const uint8_t *)"bad",3,&written));assert(written==0);DENY(hyotan_operations_truncate(ro,readonly,0));
 OK(hyotan_operations_metadata(w,NULL,0,&stat));assert(stat.flags&HYOTAN_METADATA_DIRECTORY);OK(hyotan_operations_mkdir(w,P("資料")));OK(hyotan_operations_copy(w,P("original"),P("資料/copy"),0));OK(hyotan_operations_copy(w,P("資料"),P("copied"),1));OK(hyotan_operations_metadata(w,P("copied/copy"),&stat));assert(stat.bytes==7);OK(hyotan_operations_remove(w,P("copied"),1));DENY(hyotan_operations_mkdir(ro,P("denied")));DENY(hyotan_operations_copy(ro,P("original"),P("denied"),0));DENY(hyotan_operations_remove(ro,P("original"),0));
 uint64_t source_handle=0,replaced_handle=0;
 OK(hyotan_operations_open(w,P("rename-temp"),rw|HYOTAN_OPEN_CREATE|HYOTAN_OPEN_EXCLUSIVE,&source_handle));OK(hyotan_operations_write_at(w,source_handle,0,(const uint8_t *)"new",3,&written));
 OK(hyotan_operations_open(w,P("rename-pending"),rw|HYOTAN_OPEN_CREATE|HYOTAN_OPEN_EXCLUSIVE,&replaced_handle));OK(hyotan_operations_write_at(w,replaced_handle,0,(const uint8_t *)"old",3,&written));
 DENY(hyotan_operations_rename(ro,P("rename-temp"),P("rename-pending")));
 const char *bad_rename[]={"../private/canary",canary,"日本語.txt","hard","ancestor/canary","."};
 for(size_t i=0;i<sizeof(bad_rename)/sizeof(bad_rename[0]);i++){DENY(hyotan_operations_rename(w,P("rename-temp"),P(bad_rename[i])));DENY(hyotan_operations_rename(w,P(bad_rename[i]),P("rename-pending")));}
 assert(hyotan_operations_rename(w,embedded,sizeof(embedded),P("rename-pending"))==EINVAL);assert(hyotan_operations_rename(w,P("rename-temp"),invalid,sizeof(invalid))==EINVAL);
 OK(hyotan_operations_rename(w,P("rename-temp"),P("rename-pending")));assert(hyotan_operations_metadata(w,P("rename-temp"),&stat)==ENOENT);
 OK(hyotan_operations_read_at(w,source_handle,0,3,buffer,sizeof(buffer),&read_count));assert(read_count==3&&!memcmp(buffer,"new",3));
 OK(hyotan_operations_read_at(w,replaced_handle,0,3,buffer,sizeof(buffer),&read_count));assert(read_count==3&&!memcmp(buffer,"old",3));
 OK(hyotan_operations_write_at(w,replaced_handle,0,(const uint8_t *)"OLD",3,&written));OK(hyotan_operations_truncate(w,replaced_handle,2));OK(hyotan_operations_stat(w,replaced_handle,&stat));assert(stat.bytes==2);
 OK(hyotan_operations_remove(w,P("rename-pending"),0));OK(hyotan_operations_stat(w,source_handle,&stat));assert(stat.bytes==3);OK(hyotan_operations_close(w,source_handle));OK(hyotan_operations_close(w,replaced_handle));
 OK(hyotan_operations_mkdir(w,P("rename-dir")));OK(hyotan_operations_copy(w,P("original"),P("rename-dir/child"),0));OK(hyotan_operations_mkdir(w,P("rename-empty")));OK(hyotan_operations_rename(w,P("rename-dir"),P("rename-empty")));
 OK(hyotan_operations_mkdir(w,P("rename-full")));OK(hyotan_operations_copy(w,P("original"),P("rename-full/child"),0));
 assert(hyotan_operations_rename(w,P("rename-empty"),P("rename-full"))==ENOTEMPTY);assert(hyotan_operations_rename(w,P("original"),P("rename-empty"))==EISDIR);assert(hyotan_operations_rename(w,P("rename-empty"),P("original"))==ENOTDIR);assert(hyotan_operations_rename(w,P("rename-empty"),P("rename-empty/sub"))==EINVAL);
 OK(hyotan_operations_metadata(w,P("rename-empty/child"),&stat));assert(stat.bytes==7);OK(hyotan_operations_rename(w,P("rename-empty"),P("rename-empty")));
 size_t required=999,entries=999;written=999;memset(buffer,0x5a,sizeof(buffer));assert(hyotan_operations_list(w,NULL,0,buffer,1,&written,&entries,&required)==ERANGE);assert(required>1&&written==0&&entries==0);for(size_t i=0;i<sizeof(buffer);i++)assert(buffer[i]==0x5a);uint8_t *names=malloc(required);assert(names);OK(hyotan_operations_list(w,NULL,0,names,required,&written,&entries,&required));assert(entries>=5&&written==required);free(names);
 DENY(hyotan_operations_truncate(w,handle,16*1024*1024+1));DENY(hyotan_operations_write_at(w,handle,UINT64_MAX,(const uint8_t *)"x",1,&written));assert(hyotan_operations_read_at(w,handle,0,1024*1024+1,NULL,0,&read_count)==EFBIG);assert(read_count==0);
 written=999;assert(hyotan_operations_write_at(w,handle,0,NULL,1,&written)==EINVAL);assert(written==0);
 written=999;assert(hyotan_operations_write_at(w,handle,0,NULL,1024*1024+1,&written)==EFBIG);assert(written==0);
 failed=999;assert(hyotan_operations_open(w,NULL,1,HYOTAN_OPEN_READ,&failed)==EINVAL);assert(failed==0);
 failed=999;assert(hyotan_operations_open(w,(const uint8_t *)"x",4097,HYOTAN_OPEN_READ,&failed)==EFBIG);assert(failed==0);
 assert(hyotan_operations_remove(w,P("original"),2)==EINVAL);
 struct Race race={.workspace=w,.handle=handle};atomic_init(&race.completed,0);atomic_init(&race.denied,0);pthread_t thread;assert(pthread_create(&thread,NULL,reader,&race)==0);while(atomic_load(&race.completed)<100)sched_yield();
 OK(hyotan_operations_revoke(w));assert(pthread_join(thread,NULL)==0);assert(atomic_load(&race.denied));DENY(hyotan_operations_read_at(w,handle,0,1,buffer,sizeof(buffer),&read_count));assert(read_count==0);DENY(hyotan_operations_open(w,P("original"),HYOTAN_OPEN_READ,&failed));assert(failed==0);DENY(hyotan_operations_metadata(w,NULL,0,&stat));DENY(hyotan_operations_mkdir(w,P("later")));DENY(hyotan_operations_revoke(w));DENY(hyotan_operations_rename(w,P("original"),P("after-revoke")));
 OK(hyotan_operations_read_at(other,foreign,0,7,buffer,sizeof(buffer),&read_count));assert(!memcmp(buffer,"changed",7));OK(hyotan_operations_close(other,foreign));
 fd=open(work,O_RDONLY|O_DIRECTORY);assert(fd>=0);HyotanWorkspace *fresh=NULL;OK(hyotan_operations_create(fd,"parent",9,HYOTAN_WORKSPACE_READ_WRITE,&fresh));close(fd);uint64_t current=0;OK(hyotan_operations_open(fresh,P("original"),rw,&current));assert(current!=handle);DENY(hyotan_operations_read_at(fresh,handle,0,1,buffer,sizeof(buffer),&read_count));OK(hyotan_operations_write_at(fresh,current,0,(const uint8_t *)"next",4,&written));OK(hyotan_operations_close(fresh,current));
 fd=open(canary,O_RDONLY);assert(fd>=0);assert(read(fd,buffer,sizeof(buffer))==14&&!memcmp(buffer,"private canary",14));close(fd);
 const char *message=hyotan_operations_error_message(EACCES);assert(strstr(message,"active workspace")&&strstr(message,"do not retry"));assert(!strstr(message,argv[1])&&!strstr(message,"canary"));
 OK(hyotan_operations_destroy(w));OK(hyotan_operations_destroy(other));OK(hyotan_operations_destroy(ro));OK(hyotan_operations_destroy(fresh));assert(hyotan_operations_destroy(NULL)==EINVAL);
 puts("PASS actual C caller: operations, modes, buffers, escapes, foreign handles, revoke, fresh generation, unchanged private canary");return 0;
}
'''

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-dir", type=Path, default=Path("/tmp/hyotan-c-operation-bridge-target"))
    args = parser.parse_args()
    target_dir = args.target_dir.resolve()
    subprocess.run(["cargo", "build", "--offline", "--locked", "--manifest-path", str(ROOT / "NativeCodex/Cargo.toml"), "--no-default-features", "--features", "operations", "--target-dir", str(target_dir)], check=True)
    with tempfile.TemporaryDirectory(prefix="hyotan-c-operations-") as temp:
        temp = Path(temp)
        source = temp / "caller.c"
        executable = temp / "caller"
        source.write_text(C_SOURCE)
        subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "NativeCodex/include-operations"), str(source), str(target_dir / "debug/libhyotan_codex.a"), "-ldl", "-lpthread", "-lm", "-o", str(executable)], check=True)
        subprocess.run([str(executable), str(temp)], check=True)
    print("C pointer lifetimes were trusted; this does not activate Swift/WK/Python or product host mode.")

if __name__ == "__main__":
    main()
