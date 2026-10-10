/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#define _POSIX_C_SOURCE 200809L
#include "HyotanBsdStdio.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#define OK(x) assert((x) == 0)
#define DENY(x) assert((x) == EACCES)
#define P(x) (const uint8_t *)(x), strlen(x)
static const HyotanBsdScope scope = {"adoption-owner", 19, 87};
int main(int argc, char **argv) {
  assert(argc == 2);
  char root[4096];
  assert(snprintf(root, sizeof(root), "%s/work", argv[1]) < (int)sizeof(root));
  assert(!mkdir(root, 0700));
  int rootfd = open(root, O_RDONLY | O_DIRECTORY);
  assert(rootfd >= 0);
  HyotanBsdDescriptors *t = NULL;
  OK(hyotan_bsd_descriptors_create(rootfd, &scope, 2, 64, 64, &t));
  HyotanBsdRefusalStatus status;
  OK(hyotan_bsd_refusal_status(t, &scope, &status));
  assert(!status.count);
  int fd = 0, duplicate = 0;
  size_t n = 0;
  uint64_t offset = 0;
  uint32_t flags = 0;
  HyotanOperationMetadata m;
  uint8_t binary[] = {0, 255, 17, 128}, b[8];
  FILE *f = NULL;
  OK(hyotan_bsd_open(t, &scope, P("adopt.bin"),
                     HYOTAN_OPEN_READ | HYOTAN_OPEN_WRITE | HYOTAN_OPEN_CREATE |
                         HYOTAN_OPEN_EXCLUSIVE,
                     &fd));
  OK(hyotan_bsd_write(t, &scope, fd, binary, 4, &n));
  OK(hyotan_bsd_seek(t, &scope, fd, 0, SEEK_SET, &offset));
  OK(hyotan_bsd_dup(t, &scope, fd, &duplicate));
  OK(hyotan_bsd_descriptor_flags(t, &scope, fd, &flags));
  assert(flags == (HYOTAN_OPEN_READ | HYOTAN_OPEN_WRITE));
  OK(hyotan_bsd_fdopen(t, &scope, fd, "r+b", &f));
  assert(hyotan_bsd_descriptors_destroy(t) == EBUSY);
  FILE *bad = (FILE *)(uintptr_t)1;
  assert(hyotan_bsd_fdopen(t, &scope, fd, "rb", &bad) == EBUSY && !bad);
  int q = 9;
  OK(hyotan_bsd_ferror(f, &scope, &q));
  assert(!q);
  OK(hyotan_bsd_feof(f, &scope, &q));
  assert(!q);
  OK(hyotan_bsd_fread(f, &scope, b, 4, &n));
  assert(n == 4 && !memcmp(b, binary, 4));
  OK(hyotan_bsd_fread(f, &scope, b, 1, &n));
  assert(!n);
  OK(hyotan_bsd_feof(f, &scope, &q));
  assert(q);
  OK(hyotan_bsd_ferror(f, &scope, &q));
  assert(!q);
  OK(hyotan_bsd_clearerr(f, &scope));
  OK(hyotan_bsd_feof(f, &scope, &q));
  assert(!q);
  OK(hyotan_bsd_fseek(f, &scope, 0, SEEK_SET));
  OK(hyotan_bsd_getc(f, &scope, &q));
  assert(q == 0);
  OK(hyotan_bsd_fclose(f, &scope));
  DENY(hyotan_bsd_stat(t, &scope, fd, &m));
  OK(hyotan_bsd_stat(t, &scope, duplicate, &m));
  assert(m.bytes == 4);
  OK(hyotan_bsd_close(t, &scope, duplicate));
  OK(hyotan_bsd_refusal_status(t, &scope, &status));
  assert(!status.count);
  /* Unsupported shared append changes and permission expansion never
   * adopt/close. */
  OK(hyotan_bsd_open(t, &scope, P("adopt.bin"), HYOTAN_OPEN_READ, &fd));
  DENY(hyotan_bsd_fdopen(t, &scope, fd, "r+b", &bad));
  assert(!bad);
  OK(hyotan_bsd_stat(t, &scope, fd, &m));
  OK(hyotan_bsd_refusal_status(t, &scope, &status));
  assert(status.operation == HYOTAN_BSD_REPORT_ADOPT &&
         status.error == EACCES && status.count == 1);
  OK(hyotan_bsd_fdopen(t, &scope, fd, "rb", &f));
  DENY(hyotan_bsd_fwrite(f, &scope, binary, 1, &n));
  OK(hyotan_bsd_clearerr(f, &scope));
  OK(hyotan_bsd_fclose(f, &scope));
  OK(hyotan_bsd_open(t, &scope, P("adopt.bin"), 3, &fd));
  assert(hyotan_bsd_fdopen(t, &scope, fd, "ab", &bad) == ENOTSUP && !bad);
  OK(hyotan_bsd_stat(t, &scope, fd, &m));
  assert(m.bytes == 4);
  OK(hyotan_bsd_close(t, &scope, fd));
  assert(strstr(hyotan_bsd_refusal_message(ENOTSUP), "Use a descriptor"));
  assert(strstr(hyotan_bsd_refusal_message(EACCES), "active workspace"));
  /* Existing APPEND mode is retained; fdopen w does not truncate an object. */
  OK(hyotan_bsd_open(t, &scope, P("adopt.bin"),
                     HYOTAN_OPEN_WRITE | HYOTAN_OPEN_APPEND, &fd));
  OK(hyotan_bsd_fdopen(t, &scope, fd, "ab", &f));
  OK(hyotan_bsd_fseek(f, &scope, 64, SEEK_SET));
  OK(hyotan_bsd_fwrite(f, &scope, binary, 4, &n));
  OK(hyotan_bsd_fclose(f, &scope));
  OK(hyotan_bsd_open(t, &scope, P("adopt.bin"), 3, &fd));
  OK(hyotan_bsd_fdopen(t, &scope, fd, "wb", &f));
  OK(hyotan_bsd_fileno(f, &scope, &fd));
  OK(hyotan_bsd_stat(t, &scope, fd, &m));
  assert(m.bytes == 8);
  OK(hyotan_bsd_fclose(f, &scope));
  /* Scope identities cannot alter another invocation's diagnostic latch. */
  HyotanBsdScope foreign = scope;
  foreign.instance++;
  DENY(hyotan_bsd_report_refusal(t, &foreign, HYOTAN_BSD_REPORT_WRITE, EACCES));
  DENY(hyotan_bsd_refusal_status(t, &foreign, &status));
  assert(!status.count);
  OK(hyotan_bsd_report_refusal(t, &scope, HYOTAN_BSD_REPORT_QUERY, 0));
  assert(hyotan_bsd_report_refusal(t, &scope, 999, EACCES) == EINVAL);
  OK(hyotan_bsd_refusal_status(t, &scope, &status));
  assert(status.operation == HYOTAN_BSD_REPORT_ADOPT && status.error == EACCES);
  /* Actual FILE ferror/clearerr state differs from the immutable refusal latch.
   */
  OK(hyotan_bsd_fopen(t, &scope, P("flush"), "wb", &f));
  char buf[256];
  OK(hyotan_bsd_setvbuf(f, &scope, buf, _IOFBF, sizeof(buf)));
  uint8_t many[80];
  memset(many, 17, sizeof(many));
  int e = hyotan_bsd_fwrite(f, &scope, many, sizeof(many), &n);
  assert(e == 0 || e == EACCES);
  e = hyotan_bsd_fflush(f, &scope);
  assert(e == 0 || e == EACCES);
  OK(hyotan_bsd_ferror(f, &scope, &q));
  assert(q);
  OK(hyotan_bsd_clearerr(f, &scope));
  OK(hyotan_bsd_ferror(f, &scope, &q));
  assert(!q);
  for (int i = 0; i < 80; i++)
    OK(hyotan_bsd_report_refusal(t, &scope, HYOTAN_BSD_REPORT_WRITE, EACCES));
  OK(hyotan_bsd_refusal_status(t, &scope, &status));
  assert(status.count == 64 && status.saturated && status.error == EACCES &&
         status.operation == HYOTAN_BSD_REPORT_ADOPT);
  OK(hyotan_bsd_revoke(t, &scope));
  DENY(hyotan_bsd_feof(f, &scope, &q));
  assert(!q);
  DENY(hyotan_bsd_ferror(f, &scope, &q));
  assert(!q);
  DENY(hyotan_bsd_fclose(f, &scope));
  OK(hyotan_bsd_refusal_status(t, &scope, &status));
  assert(status.count == 64 && status.saturated);
  OK(hyotan_bsd_descriptors_destroy(t));
  HyotanBsdScope fresh = scope;
  fresh.generation++;
  fresh.instance++;
  OK(hyotan_bsd_descriptors_create(rootfd, &fresh, 2, 64, 64, &t));
  OK(hyotan_bsd_refusal_status(t, &fresh, &status));
  assert(!status.count);
  DENY(hyotan_bsd_fdopen(t, &fresh, fd, "rb", &f));
  assert(!f);
  OK(hyotan_bsd_descriptors_destroy(t));
  close(rootfd);
  puts("PASS real C fdopen adoption: object/access/append/offset retained, one "
       "cookie owner, failure leaves descriptor live, close/pin cleanup, "
       "EOF/error queries and clearerr, bounded immutable sanitized refusal "
       "latch, foreign/revoke/fresh lifetime");
  return 0;
}
