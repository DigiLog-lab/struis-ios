#define _POSIX_C_SOURCE 200809L
#include "HyotanBsdDescriptors.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#define OK(x) assert((x) == 0)
#define DENY(x) assert((x) == EACCES)
#define P(x) (const uint8_t *)(x), strlen(x)
static const HyotanBsdScope scope = {"trusted-owner", 7, 42};
static const uint32_t rw = HYOTAN_OPEN_READ | HYOTAN_OPEN_WRITE;
struct Thread {
  HyotanBsdDescriptors *t;
  int fd;
  atomic_int *ready;
};
static void *writer(void *raw) {
  struct Thread *a = raw;
  size_t n;
  uint8_t record[] = {0, 255, 17, 128};
  for (int i = 0; i < 100; i++) {
    OK(hyotan_bsd_write(a->t, &scope, a->fd, record, 4, &n));
    assert(n == 4);
  }
  return NULL;
}
static void *reader(void *raw) {
  struct Thread *a = raw;
  size_t n;
  uint8_t b;
  for (;;) {
    uint64_t off;
    int e = hyotan_bsd_seek(a->t, &scope, a->fd, 0, SEEK_SET, &off);
    if (e == EACCES)
      break;
    OK(e);
    e = hyotan_bsd_read(a->t, &scope, a->fd, &b, 1, &n);
    if (e == EACCES)
      break;
    OK(e);
    atomic_store(a->ready, 1);
  }
  return NULL;
}
int main(int argc, char **argv) {
  assert(argc == 2);
  char root[4096], canary[4096], path[4096];
  snprintf(root, sizeof(root), "%s/work", argv[1]);
  snprintf(canary, sizeof(canary), "%s/private-canary", argv[1]);
  assert(mkdir(root, 0700) == 0);
  int private = open(canary, O_CREAT | O_EXCL | O_WRONLY, 0600);
  assert(private >= 0 && write(private, "SECRET", 6) == 6);
  close(private);
  int rootfd = open(root, O_RDONLY | O_DIRECTORY);
  assert(rootfd >= 0);
  HyotanBsdDescriptors *t = NULL, *other = NULL, *ro = NULL;
  HyotanBsdScope foreign = scope;
  foreign.instance++;
  OK(hyotan_bsd_descriptors_create(rootfd, &scope, 2, 16, 64, &t));
  OK(hyotan_bsd_descriptors_create(rootfd, &foreign, 2, 16, 64, &other));
  OK(hyotan_bsd_descriptors_create(rootfd, &scope, 1, 64, 64, &ro));
  int fd = 0, dupfd = 0, newfd = 0;
  size_t n = 99;
  uint64_t off = 99;
  uint8_t b[1024];
  HyotanOperationMetadata m;
  OK(hyotan_bsd_open(t, &scope, P("日本語.bin"), rw | 4 | 8, &fd));
  OK(hyotan_bsd_dup(t, &scope, fd, &dupfd));
  assert(fd >= 3 && dupfd > fd);
  const uint8_t bytes[] = {0, 255, 128, 42, 0, 1};
  OK(hyotan_bsd_write(t, &scope, fd, bytes, 6, &n));
  assert(n == 6);
  OK(hyotan_bsd_seek(t, &scope, dupfd, 0, SEEK_CUR, &off));
  assert(off == 6);
  OK(hyotan_bsd_seek(t, &scope, dupfd, 0, SEEK_SET, &off));
  OK(hyotan_bsd_read(t, &scope, fd, b, 2, &n));
  assert(n == 2 && !memcmp(b, bytes, 2));
  OK(hyotan_bsd_read(t, &scope, dupfd, b, 4, &n));
  assert(n == 4 && !memcmp(b, bytes + 2, 4));
  OK(hyotan_bsd_close(t, &scope, fd));
  DENY(hyotan_bsd_read(t, &scope, fd, b, 1, &n));
  assert(n == 0);
  OK(hyotan_bsd_read(t, &scope, dupfd, b, 1, &n));
  assert(n == 0);
  OK(hyotan_bsd_open(t, &scope, P("日本語.bin"), rw, &newfd));
  assert(newfd > dupfd);
  OK(hyotan_bsd_read(t, &scope, newfd, b, 1, &n));
  assert(n == 1 && b[0] == 0);
  DENY(hyotan_bsd_read(other, &foreign, dupfd, b, 1, &n));
  DENY(hyotan_bsd_read(t, &foreign, dupfd, b, 1, &n));
  foreign = scope;
  foreign.generation++;
  DENY(hyotan_bsd_stat(t, &foreign, dupfd, &m));
  foreign = scope;
  strcpy(foreign.owner, "foreign");
  DENY(hyotan_bsd_close(t, &foreign, dupfd));
  DENY(hyotan_bsd_read(t, &scope, INT32_MAX, b, 1, &n));
  DENY(hyotan_bsd_dup(t, &scope, 0, &fd));
  assert(fd == 0);
  OK(hyotan_bsd_truncate(t, &scope, newfd, 64));
  OK(hyotan_bsd_seek(t, &scope, newfd, 15, SEEK_SET, &off));
  OK(hyotan_bsd_write(t, &scope, newfd, bytes, 4, &n));
  OK(hyotan_bsd_seek(t, &scope, newfd, 15, SEEK_SET, &off));
  OK(hyotan_bsd_read(t, &scope, newfd, b, 10, &n));
  assert(n == 1);
  OK(hyotan_bsd_read(t, &scope, newfd, b, 10, &n));
  assert(n == 0);
  DENY(hyotan_bsd_seek(t, &scope, newfd, 65, SEEK_SET, &off));
  assert(off == 0);
  assert(hyotan_bsd_seek(t, &scope, newfd, INT64_MIN, SEEK_CUR, &off) ==
         EINVAL);
  assert(hyotan_bsd_seek(t, &scope, newfd, INT64_MAX, SEEK_CUR, &off) ==
         EOVERFLOW);
  DENY(hyotan_bsd_truncate(t, &scope, newfd, 65));
  OK(hyotan_bsd_seek(t, &scope, newfd, 64, SEEK_SET, &off));
  DENY(hyotan_bsd_write(t, &scope, newfd, bytes, 1, &n));
  assert(n == 0);
  int readonly = 0;
  OK(hyotan_bsd_open(ro, &scope, P("日本語.bin"), 1, &readonly));
  DENY(hyotan_bsd_write(ro, &scope, readonly, bytes, 1, &n));
  DENY(hyotan_bsd_truncate(ro, &scope, readonly, 0));
  DENY(hyotan_bsd_open(ro, &scope, P("new"), 2 | 4, &fd));
  HyotanBsdDescriptors *inverse = NULL;
  int inversefd = 0;
  OK(hyotan_bsd_descriptors_create(rootfd, &scope, 2, 64, 16, &inverse));
  OK(hyotan_bsd_open(inverse, &scope, P("inverse"), rw | 4 | 8, &inversefd));
  OK(hyotan_bsd_write(inverse, &scope, inversefd, bytes, 6, &n));
  OK(hyotan_bsd_seek(inverse, &scope, inversefd, 32, SEEK_SET, &off));
  OK(hyotan_bsd_read(inverse, &scope, inversefd, b, 1, &n));
  assert(n == 0);
  DENY(hyotan_bsd_write(inverse, &scope, inversefd, bytes, 1, &n));
  assert(n == 0);
  OK(hyotan_bsd_descriptors_destroy(inverse));
  /* Append updates shared offset to actual EOF, and dup keeps write-only
   * access. */
  int appendfd = 0, appenddup = 0;
  OK(hyotan_bsd_truncate(t, &scope, newfd, 6));
  OK(hyotan_bsd_open(t, &scope, P("日本語.bin"),
                     HYOTAN_OPEN_WRITE | HYOTAN_OPEN_APPEND, &appendfd));
  OK(hyotan_bsd_dup(t, &scope, appendfd, &appenddup));
  OK(hyotan_bsd_seek(t, &scope, appenddup, 0, SEEK_SET, &off));
  OK(hyotan_bsd_write(t, &scope, appendfd, bytes, 2, &n));
  OK(hyotan_bsd_seek(t, &scope, appenddup, 0, SEEK_CUR, &off));
  assert(off == 8);
  /* APPEND must ignore a successful seek at the write extent. */
  OK(hyotan_bsd_seek(t, &scope, appenddup, 64, SEEK_SET, &off));
  OK(hyotan_bsd_write(t, &scope, appendfd, bytes, 2, &n));
  assert(n == 2);
  OK(hyotan_bsd_seek(t, &scope, appenddup, 0, SEEK_CUR, &off));
  assert(off == 10);
  OK(hyotan_bsd_seek(t, &scope, newfd, 8, SEEK_SET, &off));
  OK(hyotan_bsd_read(t, &scope, newfd, b, 2, &n));
  assert(n == 2 && !memcmp(b, bytes, 2));
  /* Actual EOF, rather than the ignored seek position, still bounds append. */
  OK(hyotan_bsd_truncate(t, &scope, newfd, 63));
  OK(hyotan_bsd_seek(t, &scope, appenddup, 0, SEEK_SET, &off));
  DENY(hyotan_bsd_write(t, &scope, appendfd, bytes, 2, &n));
  assert(n == 0);
  OK(hyotan_bsd_stat(t, &scope, appenddup, &m));
  assert(m.bytes == 63);
  OK(hyotan_bsd_seek(t, &scope, appenddup, 0, SEEK_CUR, &off));
  assert(off == 0);
  OK(hyotan_bsd_write(t, &scope, appenddup, bytes, 1, &n));
  assert(n == 1);
  OK(hyotan_bsd_seek(t, &scope, appendfd, 0, SEEK_CUR, &off));
  assert(off == 64);
  DENY(hyotan_bsd_write(t, &scope, appendfd, bytes, 1, &n));
  assert(n == 0);
  DENY(hyotan_bsd_read(t, &scope, appenddup, b, 1, &n));
  OK(hyotan_bsd_close(t, &scope, appendfd));
  OK(hyotan_bsd_close(t, &scope, appenddup));
  OK(hyotan_bsd_truncate(t, &scope, newfd, 64));
  /* Trusted host replacement never retargets already-open objects. */
  assert(snprintf(path, sizeof(path), "%s/日本語.bin", root) > 0);
  assert(unlink(path) == 0);
  assert(symlink(canary, path) == 0);
  OK(hyotan_bsd_stat(t, &scope, newfd, &m));
  assert(m.bytes == 64);
  DENY(hyotan_bsd_open(t, &scope, P("日本語.bin"), rw | 16, &fd));
  assert(snprintf(path, sizeof(path), "%s/hard", root) > 0);
  assert(link(canary, path) == 0);
  DENY(hyotan_bsd_open(t, &scope, P("hard"), rw | 16, &fd));
  DENY(hyotan_bsd_open(t, &scope, P(canary), 1, &fd));
  DENY(hyotan_bsd_open(t, &scope, P("../private-canary"), 1, &fd));
  assert(snprintf(path, sizeof(path), "%s/ancestor", root) > 0);
  assert(symlink(argv[1], path) == 0);
  DENY(hyotan_bsd_open(t, &scope, P("ancestor/private-canary"), 1, &fd));
  assert(snprintf(path, sizeof(path), "%s/fifo", root) > 0);
  assert(mkfifo(path, 0600) == 0);
  DENY(hyotan_bsd_open(t, &scope, P("fifo"), 1, &fd));
  uint8_t nul[] = {'x', 0, 'y'};
  assert(hyotan_bsd_open(t, &scope, nul, 3, 1, &fd) == EINVAL);
  OK(hyotan_bsd_revoke(t, &scope));
  DENY(hyotan_bsd_read(t, &scope, newfd, b, 1, &n));
  DENY(hyotan_bsd_seek(t, &scope, newfd, 0, SEEK_SET, &off));
  DENY(hyotan_bsd_dup(t, &scope, newfd, &fd));
  DENY(hyotan_bsd_close(t, &scope, newfd));
  OK(hyotan_bsd_descriptors_destroy(t));
  OK(hyotan_bsd_descriptors_destroy(ro));
  OK(hyotan_bsd_descriptors_destroy(other));
  /* Tiny binary chunks above 2GiB on a real sparse file, no reservation claim.
   */
  uint64_t extent = UINT64_C(4) * 1024 * 1024 * 1024;
  OK(hyotan_bsd_descriptors_create(rootfd, &scope, 2, extent, extent, &t));
  OK(hyotan_bsd_open(t, &scope, P("sparse"), rw | 4 | 8, &fd));
  OK(hyotan_bsd_truncate(t, &scope, fd, extent));
  OK(hyotan_bsd_seek(t, &scope, fd, (int64_t)extent - 6, SEEK_SET, &off));
  OK(hyotan_bsd_write(t, &scope, fd, bytes, 6, &n));
  OK(hyotan_bsd_seek(t, &scope, fd, -6, SEEK_END, &off));
  OK(hyotan_bsd_read(t, &scope, fd, b, 16, &n));
  assert(n == 6 && !memcmp(b, bytes, 6));
  OK(hyotan_bsd_read(t, &scope, fd, b, 1, &n));
  assert(n == 0);
  DENY(hyotan_bsd_write(t, &scope, fd, bytes, 1, &n));
  OK(hyotan_bsd_descriptors_destroy(t));
  /* Independent next lifetime, shared-offset threads, then real revoke race. */
  HyotanBsdScope fresh = scope;
  fresh.generation++;
  fresh.instance++;
  OK(hyotan_bsd_descriptors_create(rootfd, &fresh, 2, 4096, 4096, &t));
  DENY(hyotan_bsd_read(t, &fresh, newfd, b, 1, &n));
  OK(hyotan_bsd_open(t, &fresh, P("fresh"), rw | 4 | 8, &fd));
  assert(fd > newfd);
  OK(hyotan_bsd_write(t, &fresh, fd, bytes, 6, &n));
  OK(hyotan_bsd_descriptors_destroy(t));
  OK(hyotan_bsd_descriptors_create(rootfd, &scope, 2, 4096, 4096, &t));
  OK(hyotan_bsd_open(t, &scope, P("threads"), rw | 4 | 8, &fd));
  OK(hyotan_bsd_dup(t, &scope, fd, &dupfd));
  struct Thread a = {t, fd, NULL}, c = {t, dupfd, NULL};
  pthread_t p, q;
  assert(!pthread_create(&p, NULL, writer, &a) &&
         !pthread_create(&q, NULL, writer, &c));
  assert(!pthread_join(p, NULL) && !pthread_join(q, NULL));
  OK(hyotan_bsd_stat(t, &scope, fd, &m));
  assert(m.bytes == 800);
  OK(hyotan_bsd_seek(t, &scope, fd, 0, SEEK_SET, &off));
  OK(hyotan_bsd_read(t, &scope, dupfd, b, 800, &n));
  assert(n == 800);
  for (size_t i = 0; i < n; i += 4) {
    assert(b[i] == 0 && b[i + 1] == 255 && b[i + 2] == 17 && b[i + 3] == 128);
  }
  atomic_int ready = 0;
  a.ready = &ready;
  assert(!pthread_create(&p, NULL, reader, &a));
  while (!atomic_load(&ready))
    sched_yield();
  OK(hyotan_bsd_revoke(t, &scope));
  assert(!pthread_join(p, NULL));
  DENY(hyotan_bsd_stat(t, &scope, fd, &m));
  OK(hyotan_bsd_descriptors_destroy(t));
  private = open(canary, O_RDONLY);
  assert(private >= 0 && read(private, b, 8) == 6 && !memcmp(b, "SECRET", 6));
  close(private);
  close(rootfd);
  puts("PASS real C regular-file descriptors: binary dup offsets, independent "
       "opens, stale/guessed/foreign identities, asymmetric extents, readonly, "
       "replacement/link/private/special denial, fresh instance, concurrent "
       "shared offsets and revoke; canary unchanged");
  return 0;
}
