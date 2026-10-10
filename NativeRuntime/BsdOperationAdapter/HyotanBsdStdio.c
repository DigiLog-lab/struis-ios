/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#define _GNU_SOURCE
#include "HyotanBsdStdio.h"
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#define MAX_FRAME (1024u * 1024u)
#define MAX_STREAMS 64
#define COOKIE_CHUNK 8192u
typedef struct Stream Stream;
struct Stream {
  FILE *file;
  HyotanBsdDescriptors *table;
  HyotanBsdScope scope;
  int descriptor, readable, writable, error, started;
  Stream *next;
};
static pthread_once_t lock_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t registry_lock;
static Stream *streams;
static size_t stream_count;
static void init_lock(void) {
  pthread_mutexattr_t attr;
  pthread_mutexattr_init(&attr);
  pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
  pthread_mutex_init(&registry_lock, &attr);
  pthread_mutexattr_destroy(&attr);
}
static void lock(void) {
  pthread_once(&lock_once, init_lock);
  pthread_mutex_lock(&registry_lock);
}
static void unlock(void) { pthread_mutex_unlock(&registry_lock); }
static int same_scope(const HyotanBsdScope *a, const HyotanBsdScope *b) {
  return a && memchr(a->owner, 0, sizeof(a->owner)) &&
         a->generation == b->generation && a->instance == b->instance &&
         strcmp(a->owner, b->owner) == 0;
}
static Stream *lookup(FILE *f, const HyotanBsdScope *scope) {
  for (Stream *s = streams; s; s = s->next)
    if (s->file == f && same_scope(scope, &s->scope))
      return s;
  return NULL;
}
static int live(Stream *s) {
  HyotanOperationMetadata m;
  return s ? hyotan_bsd_stat(s->table, &s->scope, s->descriptor, &m) : EACCES;
}
static int remember(Stream *s, int e, uint32_t operation) {
  if (e) {
    s->error = e;
    hyotan_bsd_report_refusal(s->table, &s->scope, operation, e);
    errno = e;
  }
  return e;
}
static ssize_t read_bytes(Stream *s, char *b, size_t len) {
  lock();
  size_t n = 0;
  int e = 0;
  if (!s->readable)
    e = EACCES;
  /* libc may request larger internal buffers; perform bounded frames. */
  while (!e && n < len) {
    size_t count = 0, want = len - n;
    if (want > COOKIE_CHUNK)
      want = COOKIE_CHUNK;
    e = hyotan_bsd_read(s->table, &s->scope, s->descriptor, (uint8_t *)b + n,
                        want, &count);
    n += count;
    if (count < want)
      break;
  }
  remember(s, e, HYOTAN_BSD_REPORT_READ);
  unlock();
  return e && n == 0 ? -1 : (ssize_t)n;
}
static ssize_t write_bytes(Stream *s, const char *b, size_t len) {
  lock();
  size_t n = 0;
  int e = 0;
  if (!s->writable)
    e = EACCES;
  while (!e && n < len) {
    size_t count = 0, want = len - n;
    if (want > COOKIE_CHUNK)
      want = COOKIE_CHUNK;
    e = hyotan_bsd_write(s->table, &s->scope, s->descriptor,
                         (const uint8_t *)b + n, want, &count);
    n += count;
    if (count < want)
      break;
  }
  remember(s, e, HYOTAN_BSD_REPORT_WRITE);
  unlock();
  return e && n == 0 ? -1 : (ssize_t)n;
}
static int seek_bytes(Stream *s, int64_t delta, int whence, uint64_t *out) {
  lock();
  int e =
      hyotan_bsd_seek(s->table, &s->scope, s->descriptor, delta, whence, out);
  remember(s, e, HYOTAN_BSD_REPORT_SEEK);
  unlock();
  return e;
}
static int close_cookie(void *raw) {
  Stream *s = raw;
  lock();
  int e = hyotan_bsd_close(s->table, &s->scope, s->descriptor);
  Stream **cursor = &streams;
  while (*cursor && *cursor != s)
    cursor = &(*cursor)->next;
  if (*cursor) {
    *cursor = s->next;
    stream_count--;
  }
  hyotan_bsd_report_refusal(s->table, &s->scope, HYOTAN_BSD_REPORT_CLOSE, e);
  int release = hyotan_bsd_descriptors_release(s->table);
  if (!e)
    e = release;
  free(s);
  unlock();
  if (e) {
    errno = e;
    return -1;
  }
  return 0;
}
#ifdef __APPLE__
static int cookie_read(void *s, char *b, int len) {
  return (int)read_bytes(s, b, (size_t)len);
}
static int cookie_write(void *s, const char *b, int len) {
  return (int)write_bytes(s, b, (size_t)len);
}
static fpos_t cookie_seek(void *s, fpos_t delta, int whence) {
  uint64_t out = 0;
  int e = seek_bytes(s, (int64_t)delta, whence, &out);
  return e ? (fpos_t)-1 : (fpos_t)out;
}
#else
static ssize_t cookie_read(void *s, char *b, size_t len) {
  return read_bytes(s, b, len);
}
static ssize_t cookie_write(void *s, const char *b, size_t len) {
  ssize_t n = write_bytes(s, b, len);
  return n < 0 ? 0 : n;
}
static int cookie_seek(void *s, off64_t *delta, int whence) {
  uint64_t out = 0;
  int e = seek_bytes(s, (int64_t)*delta, whence, &out);
  if (!e)
    *delta = (off64_t)out;
  return e ? -1 : 0;
}
#endif
static int mode_flags(const char *mode, uint32_t *flags, int *r, int *w) {
  if (!mode || !mode[0])
    return EINVAL;
  char first = mode[0];
  if (first != 'r' && first != 'w' && first != 'a')
    return EINVAL;
  int plus = 0, binary = 0, exclusive = 0;
  /* Bounded mode parsing: no libc extensions, unknown suffixes or duplicate
   * flags. */
  for (size_t i = 1; mode[i]; i++) {
    if (i > 3)
      return EINVAL;
    if (mode[i] == '+') {
      if (plus++)
        return EINVAL;
    } else if (mode[i] == 'b') {
      if (binary++)
        return EINVAL;
    } else if (mode[i] == 'x' && first == 'w') {
      if (exclusive++)
        return EINVAL;
    } else
      return EINVAL;
  }
  *r = first == 'r' || plus;
  *w = first != 'r' || plus;
  *flags = (*r ? HYOTAN_OPEN_READ : 0) | (*w ? HYOTAN_OPEN_WRITE : 0);
  if (first != 'r')
    *flags |= HYOTAN_OPEN_CREATE;
  if (first == 'w')
    *flags |= HYOTAN_OPEN_TRUNCATE;
  if (first == 'a')
    *flags |= HYOTAN_OPEN_APPEND;
  if (exclusive)
    *flags |= HYOTAN_OPEN_EXCLUSIVE;
  return 0;
}
static FILE *make_cookie(Stream *s, char first) {
  int r = s->readable, w = s->writable;
#ifdef __APPLE__
  s->file = funopen(s, r ? cookie_read : NULL, w ? cookie_write : NULL,
                    cookie_seek, close_cookie);
#else
  char libc_mode[3] = {first, r && w ? '+' : 0, 0};
  cookie_io_functions_t functions = {r ? cookie_read : NULL,
                                     w ? cookie_write : NULL, cookie_seek,
                                     close_cookie};
  s->file = fopencookie(s, libc_mode, functions);
#endif
  return s->file;
}
int hyotan_bsd_fopen(HyotanBsdDescriptors *t, const HyotanBsdScope *scope,
                     const uint8_t *p, size_t len, const char *mode,
                     FILE **out) {
  if (!out)
    return EINVAL;
  *out = NULL;
  uint32_t flags = 0;
  int r = 0, w = 0;
  int e = mode_flags(mode, &flags, &r, &w);
  if (e)
    return e;
  lock();
  if (stream_count == MAX_STREAMS) {
    unlock();
    return EMFILE;
  }
  e = hyotan_bsd_descriptors_retain(t, scope);
  if (e) {
    hyotan_bsd_report_refusal(t, scope, HYOTAN_BSD_REPORT_OPEN, e);
    unlock();
    return e;
  }
  Stream *s = calloc(1, sizeof(*s));
  if (!s) {
    hyotan_bsd_descriptors_release(t);
    unlock();
    return ENOMEM;
  }
  s->table = t;
  s->scope = *scope;
  s->readable = r;
  s->writable = w;
  e = hyotan_bsd_open(t, scope, p, len, flags, &s->descriptor);
  if (e) {
    hyotan_bsd_report_refusal(t, scope, HYOTAN_BSD_REPORT_OPEN, e);
    hyotan_bsd_descriptors_release(t);
    free(s);
    unlock();
    return e;
  }
  make_cookie(s, mode[0]);
  if (!s->file) {
    e = errno ? errno : EIO;
    hyotan_bsd_close(t, scope, s->descriptor);
    hyotan_bsd_descriptors_release(t);
    free(s);
    unlock();
    return e;
  }
  s->next = streams;
  streams = s;
  stream_count++;
  *out = s->file;
  unlock();
  return 0;
}
int hyotan_bsd_fdopen(HyotanBsdDescriptors *t, const HyotanBsdScope *scope,
                      int descriptor, const char *mode, FILE **out) {
  if (!out)
    return EINVAL;
  *out = NULL;
  uint32_t requested = 0, actual = 0;
  int r = 0, w = 0;
  int e = mode_flags(mode, &requested, &r, &w);
  if (e)
    return e;
  if (requested & HYOTAN_OPEN_EXCLUSIVE)
    return EINVAL;
  lock();
  e = hyotan_bsd_descriptors_retain(t, scope);
  if (e) {
    hyotan_bsd_report_refusal(t, scope, HYOTAN_BSD_REPORT_ADOPT, e);
    unlock();
    return e;
  }
  if (stream_count == MAX_STREAMS) {
    hyotan_bsd_descriptors_release(t);
    unlock();
    return EMFILE;
  }
  for (Stream *existing = streams; existing; existing = existing->next)
    if (existing->table == t && existing->descriptor == descriptor) {
      hyotan_bsd_descriptors_release(t);
      unlock();
      return EBUSY;
    }
  e = hyotan_bsd_descriptor_flags(t, scope, descriptor, &actual);
  if (!e && ((r && !(actual & HYOTAN_OPEN_READ)) ||
             (w && !(actual & HYOTAN_OPEN_WRITE))))
    e = EACCES;
  if (!e && mode[0] == 'a' && !(actual & HYOTAN_OPEN_APPEND))
    e = ENOTSUP;
  if (e) {
    hyotan_bsd_report_refusal(t, scope, HYOTAN_BSD_REPORT_ADOPT, e);
    hyotan_bsd_descriptors_release(t);
    unlock();
    return e;
  }
  Stream *s = calloc(1, sizeof(*s));
  if (!s) {
    hyotan_bsd_descriptors_release(t);
    unlock();
    return ENOMEM;
  }
  s->table = t;
  s->scope = *scope;
  s->descriptor = descriptor;
  s->readable = r;
  s->writable = w;
  make_cookie(s, mode[0]);
  if (!s->file) {
    e = errno ? errno : EIO;
    hyotan_bsd_descriptors_release(t);
    free(s);
    unlock();
    return e;
  }
  s->next = streams;
  streams = s;
  stream_count++;
  *out = s->file;
  unlock();
  return 0;
}
static int start(FILE *f, const HyotanBsdScope *scope, Stream **out,
                 uint32_t operation) {
  lock();
  *out = lookup(f, scope);
  int e = live(*out);
  if (e) {
    if (*out)
      hyotan_bsd_report_refusal((*out)->table, &(*out)->scope, operation, e);
    unlock();
    return e;
  }
  (*out)->error = 0;
  return 0;
}
static int finish(Stream *s, int libc_failed) {
  int e = s->error;
  if (!e && libc_failed)
    e = errno ? errno : EIO;
  unlock();
  return e;
}
static int report_file(FILE *f, const HyotanBsdScope *scope, uint32_t operation,
                       int error) {
  lock();
  Stream *s = lookup(f, scope);
  if (s)
    hyotan_bsd_report_refusal(s->table, &s->scope, operation, error);
  unlock();
  return error;
}
int hyotan_bsd_fread(FILE *f, const HyotanBsdScope *scope, void *b, size_t len,
                     size_t *out) {
  if (!out)
    return EINVAL;
  *out = 0;
  if (len > MAX_FRAME)
    return report_file(f, scope, HYOTAN_BSD_REPORT_READ, EFBIG);
  if (len && !b)
    return EINVAL;
  Stream *s;
  int e = start(f, scope, &s, HYOTAN_BSD_REPORT_READ);
  if (e)
    return e;
  if (!s->readable) {
    hyotan_bsd_report_refusal(s->table, &s->scope, HYOTAN_BSD_REPORT_READ,
                              EACCES);
    unlock();
    return EACCES;
  }
  s->started = 1;
  errno = 0;
  *out = fread(b, 1, len, f);
  return finish(s, ferror(f));
}
int hyotan_bsd_fwrite(FILE *f, const HyotanBsdScope *scope, const void *b,
                      size_t len, size_t *out) {
  if (!out)
    return EINVAL;
  *out = 0;
  if (len > MAX_FRAME)
    return report_file(f, scope, HYOTAN_BSD_REPORT_WRITE, EFBIG);
  if (len && !b)
    return EINVAL;
  Stream *s;
  int e = start(f, scope, &s, HYOTAN_BSD_REPORT_WRITE);
  if (e)
    return e;
  if (!s->writable) {
    hyotan_bsd_report_refusal(s->table, &s->scope, HYOTAN_BSD_REPORT_WRITE,
                              EACCES);
    unlock();
    return EACCES;
  }
  s->started = 1;
  errno = 0;
  *out = fwrite(b, 1, len, f);
  return finish(s, *out != len || ferror(f));
}
int hyotan_bsd_getc(FILE *f, const HyotanBsdScope *scope, int *out) {
  if (!out)
    return EINVAL;
  *out = EOF;
  unsigned char b;
  size_t n = 0;
  int e = hyotan_bsd_fread(f, scope, &b, 1, &n);
  if (!e && n)
    *out = b;
  return e;
}
int hyotan_bsd_putc(FILE *f, const HyotanBsdScope *scope, unsigned char b) {
  size_t n;
  return hyotan_bsd_fwrite(f, scope, &b, 1, &n);
}
int hyotan_bsd_fseek(FILE *f, const HyotanBsdScope *scope, int64_t offset,
                     int whence) {
  Stream *s;
  int e = start(f, scope, &s, HYOTAN_BSD_REPORT_SEEK);
  if (e)
    return e;
  if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) {
    unlock();
    return EINVAL;
  }
  if (sizeof(off_t) < sizeof(int64_t) &&
      (offset > INT32_MAX || offset < INT32_MIN)) {
    unlock();
    return EOVERFLOW;
  }
  s->started = 1;
  errno = 0;
  int rc = fseeko(f, (off_t)offset, whence);
  return finish(s, rc != 0);
}
int hyotan_bsd_ftell(FILE *f, const HyotanBsdScope *scope, uint64_t *out) {
  if (!out)
    return EINVAL;
  *out = 0;
  Stream *s;
  int e = start(f, scope, &s, HYOTAN_BSD_REPORT_QUERY);
  if (e)
    return e;
  s->started = 1;
  errno = 0;
  off_t offset = ftello(f);
  if (offset >= 0)
    *out = (uint64_t)offset;
  return finish(s, offset < 0);
}
int hyotan_bsd_fflush(FILE *f, const HyotanBsdScope *scope) {
  Stream *s;
  int e = start(f, scope, &s, HYOTAN_BSD_REPORT_FLUSH);
  if (e)
    return e;
  s->started = 1;
  errno = 0;
  int rc = fflush(f);
  return finish(s, rc != 0);
}
int hyotan_bsd_fclose(FILE *f, const HyotanBsdScope *scope) {
  lock();
  Stream *s = lookup(f, scope);
  if (!s) {
    unlock();
    return EACCES;
  }
  int e = live(s);
  hyotan_bsd_report_refusal(s->table, &s->scope, HYOTAN_BSD_REPORT_CLOSE, e);
  errno = 0;
  int rc = fclose(f);
  int close_error = errno;
  /* close_cookie has removed/free'd s; never inspect it after fclose. */
  unlock();
  return e ? e : (rc ? close_error ? close_error : EIO : 0);
}
int hyotan_bsd_fileno(FILE *f, const HyotanBsdScope *scope, int *out) {
  if (!out)
    return EINVAL;
  *out = 0;
  Stream *s;
  int e = start(f, scope, &s, HYOTAN_BSD_REPORT_QUERY);
  if (e)
    return e;
  *out = s->descriptor;
  unlock();
  return 0;
}
int hyotan_bsd_setvbuf(FILE *f, const HyotanBsdScope *scope, char *b, int mode,
                       size_t len) {
  if (mode != _IONBF && mode != _IOFBF && mode != _IOLBF)
    return EINVAL;
  if (len > MAX_FRAME)
    return EFBIG;
  Stream *s;
  int e = start(f, scope, &s, HYOTAN_BSD_REPORT_QUERY);
  if (e)
    return e;
  if (s->started) {
    unlock();
    return EINVAL;
  }
  errno = 0;
  int rc = setvbuf(f, b, mode, len);
  return finish(s, rc != 0);
}
int hyotan_bsd_clearerr(FILE *f, const HyotanBsdScope *scope) {
  Stream *s;
  int e = start(f, scope, &s, HYOTAN_BSD_REPORT_QUERY);
  if (e)
    return e;
  clearerr(f);
  unlock();
  return 0;
}

int hyotan_bsd_ferror(FILE *f, const HyotanBsdScope *scope, int *out) {
  if (!out)
    return EINVAL;
  *out = 0;
  Stream *s;
  int e = start(f, scope, &s, HYOTAN_BSD_REPORT_QUERY);
  if (e)
    return e;
  *out = !!ferror(f);
  unlock();
  return 0;
}
int hyotan_bsd_feof(FILE *f, const HyotanBsdScope *scope, int *out) {
  if (!out)
    return EINVAL;
  *out = 0;
  Stream *s;
  int e = start(f, scope, &s, HYOTAN_BSD_REPORT_QUERY);
  if (e)
    return e;
  *out = !!feof(f);
  unlock();
  return 0;
}
