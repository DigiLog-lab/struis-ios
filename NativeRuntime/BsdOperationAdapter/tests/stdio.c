/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#define _POSIX_C_SOURCE 200809L
#include "HyotanBsdStdio.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#define OK(x) assert((x) == 0)
#define DENY(x) assert((x) == EACCES)
#define P(x) (const uint8_t *)(x), strlen(x)
static const HyotanBsdScope scope = {"stdio-owner", 9, 71};
static const uint8_t binary[] = {0, 255, 42, 128, 0, 17, 10, 13};
struct Writer {
  FILE *f;
};
static void *writer(void *raw) {
  struct Writer *a = raw;
  for (int i = 0; i < 100; i++) {
    size_t n;
    OK(hyotan_bsd_fwrite(a->f, &scope, binary, sizeof(binary), &n));
    assert(n == sizeof(binary));
  }
  return NULL;
}
int main(int argc, char **argv) {
  assert(argc == 2);
  char root[4096], canary[4096], path[4096];
  snprintf(root, sizeof(root), "%s/work", argv[1]);
  snprintf(canary, sizeof(canary), "%s/private", argv[1]);
  assert(!mkdir(root, 0700));
  int host = open(canary, O_WRONLY | O_CREAT | O_EXCL, 0600);
  assert(host >= 0 && write(host, "SECRET", 6) == 6);
  close(host);
  int rootfd = open(root, O_RDONLY | O_DIRECTORY);
  assert(rootfd >= 0);
  HyotanBsdDescriptors *t = NULL, *ro = NULL;
  OK(hyotan_bsd_descriptors_create(rootfd, &scope, 2, 4096, 4096, &t));
  FILE *f = NULL;
  size_t n = 0;
  uint64_t pos = 0;
  uint8_t b[16384];
  int fd = 0, c = 0;
  const char *invalid[] = {"", "q", "rbb", "r++", "rx", "we", "wbbbb", "wx+x"};
  for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
    assert(hyotan_bsd_fopen(t, &scope, P("no-create"), invalid[i], &f) ==
               EINVAL &&
           !f);
  }
  assert(hyotan_bsd_open(t, &scope, P("no-create"), 1, &fd) == ENOENT);
  OK(hyotan_bsd_fopen(t, &scope, P("日本語.bin"), "w+b", &f));
  assert(hyotan_bsd_descriptors_destroy(t) == EBUSY);
  OK(hyotan_bsd_fileno(f, &scope, &fd));
  assert(fd >= 3); /* libc's own cookie fileno is never an OS FD. */
  assert(fileno(f) == -1);
  char buffer[256];
  OK(hyotan_bsd_setvbuf(f, &scope, buffer, _IOFBF, sizeof(buffer)));
  OK(hyotan_bsd_fwrite(f, &scope, binary, sizeof(binary), &n));
  assert(n == 8);
  OK(hyotan_bsd_putc(f, &scope, 0xfe));
  OK(hyotan_bsd_fflush(f, &scope));
  OK(hyotan_bsd_ftell(f, &scope, &pos));
  assert(pos == 9);
  OK(hyotan_bsd_fseek(f, &scope, 0, SEEK_SET));
  OK(hyotan_bsd_fread(f, &scope, b, 8, &n));
  assert(n == 8 && !memcmp(b, binary, 8));
  OK(hyotan_bsd_getc(f, &scope, &c));
  assert(c == 0xfe);
  OK(hyotan_bsd_getc(f, &scope, &c));
  assert(c == EOF);
  OK(hyotan_bsd_fseek(f, &scope, -9, SEEK_END));
  OK(hyotan_bsd_getc(f, &scope, &c));
  assert(c == 0);
  HyotanBsdScope foreign = scope;
  foreign.instance++;
  DENY(hyotan_bsd_fread(f, &foreign, b, 1, &n));
  assert(n == 0);
  foreign = scope;
  foreign.generation++;
  DENY(hyotan_bsd_fileno(f, &foreign, &fd));
  assert(fd == 0);
  foreign = scope;
  strcpy(foreign.owner, "other");
  DENY(hyotan_bsd_fclose(f, &foreign));
  OK(hyotan_bsd_getc(f, &scope, &c));
  assert(c == 255);
  FILE *unknown = tmpfile();
  assert(unknown);
  DENY(hyotan_bsd_fread(unknown, &scope, b, 1, &n));
  DENY(hyotan_bsd_fwrite(unknown, &scope, binary, 1, &n));
  DENY(hyotan_bsd_fflush(unknown, &scope));
  DENY(hyotan_bsd_fileno(unknown, &scope, &fd));
  DENY(hyotan_bsd_fclose(unknown, &scope));
  assert(!fclose(unknown));
  OK(hyotan_bsd_fclose(f, &scope));
  DENY(hyotan_bsd_fflush(f, &scope));
  OK(hyotan_bsd_descriptors_destroy(t));
  /* Buffered reader/writer must validate before touching cached bytes. */
  OK(hyotan_bsd_descriptors_create(rootfd, &scope, 2, 4096, 4096, &t));
  FILE *reader_file = NULL, *writer_file = NULL;
  char readbuf[256], writebuf[256];
  OK(hyotan_bsd_fopen(t, &scope, P("日本語.bin"), "rb", &reader_file));
  OK(hyotan_bsd_setvbuf(reader_file, &scope, readbuf, _IOFBF, sizeof(readbuf)));
  OK(hyotan_bsd_getc(reader_file, &scope, &c));
  assert(c == 0);
  assert((unsigned char)readbuf[1] == 255); /* Actual libc read-ahead cache. */
  OK(hyotan_bsd_fopen(t, &scope, P("buffered"), "wb", &writer_file));
  OK(hyotan_bsd_setvbuf(
      writer_file, &scope, writebuf, _IOFBF,
      sizeof(writebuf))); /* First fwrite may bypass an empty libc buffer;
                             second small writer_file stays cached. */
  OK(hyotan_bsd_putc(writer_file, &scope, 17));
  OK(hyotan_bsd_putc(writer_file, &scope, 255));
  int pendingfd = 0;
  HyotanOperationMetadata pending;
  OK(hyotan_bsd_fileno(writer_file, &scope, &pendingfd));
  OK(hyotan_bsd_stat(t, &scope, pendingfd, &pending));
  assert(pending.bytes < 2); /* At least one accepted byte is still buffered. */
  OK(hyotan_bsd_revoke(t, &scope));
  assert(hyotan_bsd_descriptors_destroy(t) == EBUSY);
  memset(b, 0xa5, 8);
  DENY(hyotan_bsd_fread(reader_file, &scope, b, 8, &n));
  assert(n == 0 && b[0] == 0xa5);
  DENY(hyotan_bsd_getc(reader_file, &scope, &c));
  assert(c == EOF);
  DENY(hyotan_bsd_putc(writer_file, &scope, 33));
  DENY(hyotan_bsd_fwrite(writer_file, &scope, binary, 8, &n));
  assert(n == 0);
  DENY(hyotan_bsd_fflush(writer_file, &scope));
  DENY(hyotan_bsd_fseek(reader_file, &scope, 0, SEEK_SET));
  DENY(hyotan_bsd_fileno(reader_file, &scope, &fd));
  DENY(hyotan_bsd_fclose(reader_file, &scope));
  DENY(hyotan_bsd_fclose(writer_file, &scope));
  assert(snprintf(path, sizeof(path), "%s/buffered", root) < (int)sizeof(path));
  struct stat after_revoke;
  assert(!stat(path, &after_revoke) &&
         (uint64_t)after_revoke.st_size == pending.bytes);
  OK(hyotan_bsd_descriptors_destroy(t));
  /* Read-only permission rejection precedes writable libc buffering. */
  OK(hyotan_bsd_descriptors_create(rootfd, &scope, 1, 4096, 4096, &ro));
  DENY(hyotan_bsd_fopen(ro, &scope, P("deny-create"), "wb", &f));
  OK(hyotan_bsd_fopen(ro, &scope, P("日本語.bin"), "rb", &f));
  DENY(hyotan_bsd_fwrite(f, &scope, binary, 8, &n));
  assert(n == 0);
  OK(hyotan_bsd_fclose(f, &scope));
  OK(hyotan_bsd_descriptors_destroy(ro));
  /* Append ignores seek; EOF overflow is a real fflush/fclose failure. */
  OK(hyotan_bsd_descriptors_create(rootfd, &scope, 2, 16, 16, &t));
  OK(hyotan_bsd_fopen(t, &scope, P("append"), "w+b", &f));
  OK(hyotan_bsd_fwrite(f, &scope, binary, 8, &n));
  OK(hyotan_bsd_fclose(f, &scope));
  OK(hyotan_bsd_fopen(t, &scope, P("append"), "ab+", &f));
  OK(hyotan_bsd_fseek(f, &scope, 16, SEEK_SET));
  OK(hyotan_bsd_fwrite(f, &scope, binary, 2, &n));
  assert(n == 2);
  OK(hyotan_bsd_fflush(f, &scope));
  OK(hyotan_bsd_ftell(f, &scope, &pos));
  assert(pos == 10);
  OK(hyotan_bsd_fseek(f, &scope, 8, SEEK_SET));
  OK(hyotan_bsd_fread(f, &scope, b, 2, &n));
  assert(n == 2 && !memcmp(b, binary, 2));
  OK(hyotan_bsd_fclose(f, &scope));
  OK(hyotan_bsd_fopen(t, &scope, P("append"), "ab", &f));
  char small[256];
  OK(hyotan_bsd_setvbuf(f, &scope, small, _IOFBF, sizeof(small)));
  OK(hyotan_bsd_putc(f, &scope,
                     17)); /* Can buffer oversized pending output, but must
                              report actual flush refusal. */
  int e = hyotan_bsd_fwrite(f, &scope, binary, 8, &n);
  assert(e == 0 || e == EACCES);
  DENY(hyotan_bsd_fflush(f, &scope));
  e = hyotan_bsd_fclose(f, &scope);
  assert(e == 0 || e == EACCES);
  /* A separate pending overflow must fail directly at fclose and release pin.
   */
  OK(hyotan_bsd_fopen(t, &scope, P("close-error"), "w+b", &f));
  OK(hyotan_bsd_fwrite(f, &scope, binary, 8, &n));
  OK(hyotan_bsd_fclose(f, &scope));
  OK(hyotan_bsd_fopen(t, &scope, P("close-error"), "ab", &f));
  char closebuf[256];
  OK(hyotan_bsd_setvbuf(f, &scope, closebuf, _IOFBF, sizeof(closebuf)));
  OK(hyotan_bsd_putc(f, &scope, 17));
  OK(hyotan_bsd_fwrite(f, &scope, binary, 8, &n));
  assert(n == 8);
  DENY(hyotan_bsd_fclose(f, &scope));
  OK(hyotan_bsd_descriptors_destroy(t));
  /* Actual partial output: one libc block persists, next block exceeds extent.
   */
  OK(hyotan_bsd_descriptors_create(rootfd, &scope, 2, 12000, 12000, &t));
  OK(hyotan_bsd_fopen(t, &scope, P("partial"), "wb", &f));
  uint8_t large[16384];
  memset(large, 0x7f, sizeof(large));
  char partialbuf[8192];
  OK(hyotan_bsd_setvbuf(f, &scope, partialbuf, _IOFBF, sizeof(partialbuf)));
  e = hyotan_bsd_fwrite(f, &scope, large, sizeof(large), &n);
  assert(e == EACCES && n == 8192);
  OK(hyotan_bsd_fileno(f, &scope, &pendingfd));
  OK(hyotan_bsd_stat(t, &scope, pendingfd, &pending));
  assert(pending.bytes == 8192);
  e = hyotan_bsd_fclose(f, &scope);
  assert(e == 0 || e == EACCES);
  OK(hyotan_bsd_descriptors_destroy(t));
  /* Private/link denial uses actual operations; no normal-path reopen. */
  OK(hyotan_bsd_descriptors_create(rootfd, &scope, 2, 4096, 4096, &t));
  assert(snprintf(path, sizeof(path), "%s/link", root) < (int)sizeof(path));
  assert(!symlink(canary, path));
  DENY(hyotan_bsd_fopen(t, &scope, P("link"), "rb", &f));
  assert(snprintf(path, sizeof(path), "%s/hard", root) < (int)sizeof(path));
  assert(!link(canary, path));
  DENY(hyotan_bsd_fopen(t, &scope, P("hard"), "wb", &f));
  DENY(hyotan_bsd_fopen(t, &scope, P(canary), "rb", &f));
  DENY(hyotan_bsd_fopen(t, &scope, P("../private"), "wb", &f));
  /* Shared registered FILE concurrency preserves complete binary records. */
  OK(hyotan_bsd_fopen(t, &scope, P("threads"), "w+b", &f));
  struct Writer a = {f};
  pthread_t p, q;
  assert(!pthread_create(&p, NULL, writer, &a) &&
         !pthread_create(&q, NULL, writer, &a));
  assert(!pthread_join(p, NULL) && !pthread_join(q, NULL));
  OK(hyotan_bsd_fflush(f, &scope));
  OK(hyotan_bsd_ftell(f, &scope, &pos));
  assert(pos == 1600);
  OK(hyotan_bsd_fseek(f, &scope, 0, SEEK_SET));
  OK(hyotan_bsd_fread(f, &scope, b, 1600, &n));
  assert(n == 1600);
  for (size_t i = 0; i < n; i += 8)
    assert(!memcmp(b + i, binary, 8));
  OK(hyotan_bsd_fclose(f, &scope));
  OK(hyotan_bsd_descriptors_destroy(t));
  HyotanBsdScope fresh = scope;
  fresh.generation++;
  fresh.instance++;
  OK(hyotan_bsd_descriptors_create(rootfd, &fresh, 2, 4096, 4096, &t));
  OK(hyotan_bsd_fopen(t, &fresh, P("next"), "wxb+", &f));
  DENY(hyotan_bsd_fwrite(f, &scope, binary, 8, &n));
  OK(hyotan_bsd_fwrite(f, &fresh, binary, 8, &n));
  OK(hyotan_bsd_fclose(f, &fresh));
  OK(hyotan_bsd_descriptors_destroy(t));
  host = open(canary, O_RDONLY);
  assert(host >= 0 && read(host, b, 16) == 6 && !memcmp(b, "SECRET", 6));
  close(host);
  close(rootfd);
  puts(
      "PASS actual libc cookie FILE: binary buffered I/O, logical fileno, "
      "owner/generation/instance registry, table pin/EBUSY, cached-byte revoke "
      "and denied close cleanup, readonly, seek/append/flush errors, private "
      "link refusal, concurrent writes and fresh instance; canary unchanged");
  return 0;
}
