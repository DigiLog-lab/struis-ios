# Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0
"""Execute exact pinned BSD function bodies with explicit captured final-I/O calls.

This is not a registered command, whole CLI, shell, pipe or product execution.
Upstream code is generated only into the temporary test directory, retaining its
license notice; the repository does not vendor or alter the algorithm bodies.
"""
import hashlib
import os
from pathlib import Path
import subprocess

REVISION = "ebc045299e56edaf3509144d43a7f7348af400a7"
PINS = {
    "text_cmds/cat/cat.c": "6debbd5fbd36d57af30f9520268005e678e6c5770e699ed35be33f8671696655",
    "text_cmds/head/head.c": "bb89c36bb64b44403c59831c4b806868ca8e2ed3f5c2f53c077451d08bb19222",
}


def extract(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
        cursor += 1
    return source[start:cursor]


PREAMBLE = r'''
#define _POSIX_C_SOURCE 200809L
#include "HyotanBsdStdio.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static HyotanBsdDescriptors *captured_table;
static const HyotanBsdScope captured_scope={"pinned-algorithm-caller",21,93};
static FILE *captured_output;
static int rval;
static const char *filename="synthetic";
static void report(uint32_t op,int e) { assert(!hyotan_bsd_report_refusal(captured_table,&captured_scope,op,e));if(e)errno=e; }
static size_t capture_fread(void *p,size_t size,size_t count,FILE *f) {
 if(size!=1){report(HYOTAN_BSD_REPORT_READ,ENOTSUP);return 0;}
 size_t n=0;int e=hyotan_bsd_fread(f,&captured_scope,p,count,&n);report(HYOTAN_BSD_REPORT_READ,e);return n;
}
static size_t capture_fwrite(const void *p,size_t size,size_t count,FILE *f) {
 if(size!=1){report(HYOTAN_BSD_REPORT_WRITE,ENOTSUP);return 0;}
 size_t n=0;int e=hyotan_bsd_fwrite(f,&captured_scope,p,count,&n);report(HYOTAN_BSD_REPORT_WRITE,e);return n;
}
static int capture_fputc(int ch,FILE *f) {int e=hyotan_bsd_putc(f,&captured_scope,(unsigned char)ch);report(HYOTAN_BSD_REPORT_WRITE,e);return e?EOF:(unsigned char)ch;}
static ssize_t capture_read(int fd,void *p,size_t count) {size_t n=0;int e=hyotan_bsd_read(captured_table,&captured_scope,fd,p,count,&n);report(HYOTAN_BSD_REPORT_READ,e);return e?-1:(ssize_t)n;}
static int capture_fileno(FILE *f) {int fd=0;int e=hyotan_bsd_fileno(f,&captured_scope,&fd);report(HYOTAN_BSD_REPORT_QUERY,e);return e?-1:fd;}
static void capture_err(int status,const char *format,...) {(void)status;(void)format;abort();}
static void capture_warn(const char *format,...) {(void)format;}
#define fread capture_fread
#define fwrite capture_fwrite
#define fputc capture_fputc
#define read capture_read
#define fileno capture_fileno
#define err capture_err
#define warn capture_warn
#undef stdout
#define stdout captured_output
#define thread_stdout captured_output
'''

DRIVER = r'''
#undef fread
#undef fwrite
#undef fputc
#undef read
#undef fileno
#undef err
#undef warn
#undef stdout
#undef thread_stdout
#define OK(x) assert((x)==0)
#define P(x) (const uint8_t *)(x),strlen(x)
int main(int argc,char **argv){assert(argc==2);char root[4096];assert(snprintf(root,sizeof(root),"%s/work",argv[1])<(int)sizeof(root));assert(!mkdir(root,0700));int rootfd=open(root,O_RDONLY|O_DIRECTORY);assert(rootfd>=0);OK(hyotan_bsd_descriptors_create(rootfd,&captured_scope,2,8192,8192,&captured_table));int fd=0;size_t n=0;uint64_t offset=0;uint8_t binary[4096],out[4096];for(size_t i=0;i<sizeof(binary);i++)binary[i]=(uint8_t)(i*37);OK(hyotan_bsd_open(captured_table,&captured_scope,P("input"),3|4|8,&fd));OK(hyotan_bsd_write(captured_table,&captured_scope,fd,binary,sizeof(binary),&n));OK(hyotan_bsd_seek(captured_table,&captured_scope,fd,0,SEEK_SET,&offset));FILE *input=NULL;OK(hyotan_bsd_fdopen(captured_table,&captured_scope,fd,"rb",&input));OK(hyotan_bsd_fopen(captured_table,&captured_scope,P("head-output"),"w+b",&captured_output));head_bytes(input,31);OK(hyotan_bsd_fflush(captured_output,&captured_scope));OK(hyotan_bsd_fseek(captured_output,&captured_scope,0,SEEK_SET));OK(hyotan_bsd_fread(captured_output,&captured_scope,out,sizeof(out),&n));assert(n==31&&!memcmp(out,binary,31));OK(hyotan_bsd_fclose(input,&captured_scope));OK(hyotan_bsd_fclose(captured_output,&captured_scope));HyotanBsdRefusalStatus status;OK(hyotan_bsd_refusal_status(captured_table,&captured_scope,&status));assert(!status.count);
OK(hyotan_bsd_open(captured_table,&captured_scope,P("input"),1,&fd));OK(hyotan_bsd_fopen(captured_table,&captured_scope,P("cat-output"),"w+b",&captured_output));rval=0;raw_cat(fd);assert(!rval);OK(hyotan_bsd_fflush(captured_output,&captured_scope));OK(hyotan_bsd_fseek(captured_output,&captured_scope,0,SEEK_SET));OK(hyotan_bsd_fread(captured_output,&captured_scope,out,sizeof(out),&n));assert(n==sizeof(binary)&&!memcmp(out,binary,n));OK(hyotan_bsd_close(captured_table,&captured_scope,fd));OK(hyotan_bsd_fclose(captured_output,&captured_scope));OK(hyotan_bsd_refusal_status(captured_table,&captured_scope,&status));assert(!status.count);
/* Real raw_cat ignores each fputc error: its return state stays0, but the
 * captured trusted refusal latch cannot turn denied output into success. */
OK(hyotan_bsd_open(captured_table,&captured_scope,P("input"),1,&fd));OK(hyotan_bsd_fopen(captured_table,&captured_scope,P("input"),"rb",&captured_output));rval=0;raw_cat(fd);assert(!rval);OK(hyotan_bsd_refusal_status(captured_table,&captured_scope,&status));assert(status.operation==HYOTAN_BSD_REPORT_WRITE&&status.error==EACCES&&status.count==64&&status.saturated);OK(hyotan_bsd_close(captured_table,&captured_scope,fd));OK(hyotan_bsd_fclose(captured_output,&captured_scope));OK(hyotan_bsd_descriptors_destroy(captured_table));
/* Real head_bytes returns normally at denied read. Cached libc bytes must
 * remain unavailable and the new invocation's latch identifies the denial. */
OK(hyotan_bsd_descriptors_create(rootfd,&captured_scope,2,8192,8192,&captured_table));OK(hyotan_bsd_fopen(captured_table,&captured_scope,P("input"),"rb",&input));OK(hyotan_bsd_fopen(captured_table,&captured_scope,P("revoked-output"),"wb",&captured_output));int ch=EOF;OK(hyotan_bsd_getc(input,&captured_scope,&ch));assert(ch==binary[0]);OK(hyotan_bsd_revoke(captured_table,&captured_scope));head_bytes(input,31);OK(hyotan_bsd_refusal_status(captured_table,&captured_scope,&status));assert(status.error==EACCES&&status.operation==HYOTAN_BSD_REPORT_READ);assert(hyotan_bsd_fclose(input,&captured_scope)==EACCES);assert(hyotan_bsd_fclose(captured_output,&captured_scope)==EACCES);OK(hyotan_bsd_descriptors_destroy(captured_table));close(rootfd);puts("PASS exact pinned BSD raw_cat/head_bytes bodies: explicit captured final calls, real binary regular-file processing; unchanged raw_cat ignores refused fputc but immutable latch reports WRITE/EACCES; revoked cached head read refused with READ/EACCES. Whole CLI/pipe/command dispatch remains pending.");return 0;}
'''


def run(native, adapter, scratch, library):
    source_root = Path(os.environ.get("HYOTAN_PINNED_IOS_SYSTEM_SOURCE", "/tmp/hyotan-ios-system-audit"))
    revision = subprocess.check_output(["git", "-C", str(source_root), "rev-parse", "HEAD"], text=True).strip()
    if revision != REVISION:
        raise RuntimeError("Pinned ios_system revision differs; source fixture is required, never skipped")
    bodies = []
    for relative, expected in PINS.items():
        source = (source_root / relative).read_bytes()
        if hashlib.sha256(source).hexdigest() != expected:
            raise RuntimeError(f"Pinned source content differs: {relative}")
        decoded = source.decode()
        signature = "static void\nraw_cat(int rfd)\n" if "cat/cat" in relative else "static void\nhead_bytes(FILE *fp, off_t cnt)\n"
        body = extract(decoded, signature)
        notice = decoded[:decoded.index("*/") + 2]
        bodies.append(notice + "\n" + body)
        print(f"PINNED SHA256 {expected} {relative}; exact body SHA256 {hashlib.sha256(body.encode()).hexdigest()}", flush=True)
    target = scratch / "pinned-algorithms.c"
    target.write_text(PREAMBLE + "\n" + "\n".join(bodies) + DRIVER)
    binary = scratch / "pinned-algorithms"
    subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-but-set-variable", "-pthread",
                    "-I", str(native / "NativeCodex/include-operations"), "-I", str(adapter),
                    str(adapter / "HyotanBsdDescriptors.c"), str(adapter / "HyotanBsdStdio.c"), str(target),
                    str(library), "-ldl", "-lm", "-o", str(binary)], check=True)
    workspace = scratch / "pinned-algorithms-workspace"
    workspace.mkdir()
    subprocess.run([str(binary), str(workspace)], check=True)
