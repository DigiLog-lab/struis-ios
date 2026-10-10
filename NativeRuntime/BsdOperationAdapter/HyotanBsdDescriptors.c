/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#include "HyotanBsdDescriptors.h"
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define SLOTS 64
typedef struct {
  uint64_t handle, offset;
  uint32_t flags, refs;
} Description;

typedef struct {
  int number;
  Description *description;
} Entry;

struct HyotanBsdDescriptors {
  pthread_mutex_t lock;
  HyotanWorkspace *workspace;

  HyotanBsdScope scope;
  uint64_t read_extent, write_extent;
  int revoked;
  size_t retained;
  int stream_context_claimed;
  HyotanBsdRefusalStatus refusal;
  Entry entries[SLOTS];
};

static pthread_mutex_t numbers_lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t next_number = 3;

static int number(int *out) {
  pthread_mutex_lock(&numbers_lock);
  int e = 0;

  if (next_number > INT_MAX)
    e = EMFILE;
  else
    *out = (int)next_number++;

  pthread_mutex_unlock(&numbers_lock);
  return e;
}
static int enter(HyotanBsdDescriptors *t, const HyotanBsdScope *s) {
  if (!t || !s)
    return EINVAL;

  pthread_mutex_lock(&t->lock);

  if (t->revoked || s->generation != t->scope.generation ||
      s->instance != t->scope.instance ||
      (!memchr(s->owner, 0, sizeof(s->owner)) ||
       strcmp(s->owner, t->scope.owner) != 0)) {
    pthread_mutex_unlock(&t->lock);
    return EACCES;
  }
  return 0;
}
static Entry *find(HyotanBsdDescriptors *t, int n) {
  for (size_t i = 0; i < SLOTS; i++)
    if (t->entries[i].number == n && n > 0)
      return &t->entries[i];
  return NULL;
}
static Entry *vacant(HyotanBsdDescriptors *t) {
  for (size_t i = 0; i < SLOTS; i++)
    if (!t->entries[i].number)
      return &t->entries[i];
  return NULL;
}
static int validate(HyotanBsdDescriptors *t, Entry *e) {
  HyotanOperationMetadata m;
  return e ? hyotan_operations_stat(t->workspace, e->description->handle, &m)
           : EACCES;
}
static void release(HyotanBsdDescriptors *t, Entry *e) {
  Description *d = e->description;
  e->number = 0;
  e->description = NULL;
  if (!--d->refs) {
    hyotan_operations_close(t->workspace, d->handle);
    free(d);
  }
}
int hyotan_bsd_descriptors_create(int root, const HyotanBsdScope *s,
                                  uint32_t access, uint64_t r, uint64_t w,
                                  HyotanBsdDescriptors **out) {
  if (!out)
    return EINVAL;
  *out = NULL;

  if (!s || !s->instance || !s->owner[0] ||
      !memchr(s->owner, 0, sizeof(s->owner)))
    return EINVAL;

  HyotanBsdDescriptors *t = calloc(1, sizeof(*t));
  if (!t)
    return ENOMEM;

  /* Normalize trailing identity bytes so trusted caller padding is irrelevant.
   */
  t->scope.generation = s->generation;
  t->scope.instance = s->instance;
  memcpy(t->scope.owner, s->owner, strlen(s->owner));

  int e = pthread_mutex_init(&t->lock, NULL);
  if (e) {
    free(t);
    return e;
  }
  e = hyotan_operations_create_with_descriptor_limits(
      root, t->scope.owner, s->generation, access, r, w, &t->workspace);

  if (e) {
    pthread_mutex_destroy(&t->lock);
    free(t);
    return e;
  }
  t->read_extent = r;
  t->write_extent = w;
  *out = t;
  return 0;
}
int hyotan_bsd_open(HyotanBsdDescriptors *t, const HyotanBsdScope *s,
                    const uint8_t *p, size_t len, uint32_t f, int *out) {
  if (!out)
    return EINVAL;
  *out = 0;
  int e = enter(t, s);
  if (e)
    return e;

  Entry *entry = vacant(t);
  Description *d = NULL;
  int n = 0;

  if (!entry)
    e = EMFILE;
  else if (!(d = calloc(1, sizeof(*d))))
    e = ENOMEM;

  else if (!(e = number(&n))) {
    e = hyotan_operations_open(t->workspace, p, len, f, &d->handle);

    if (!e) {
      d->flags = f;
      d->refs = 1;
      entry->number = n;
      entry->description = d;
      *out = n;
      d = NULL;
    }
  }
  free(d);
  pthread_mutex_unlock(&t->lock);
  return e;
}
int hyotan_bsd_dup(HyotanBsdDescriptors *t, const HyotanBsdScope *s, int n,
                   int *out) {
  if (!out)
    return EINVAL;
  *out = 0;
  int e = enter(t, s);
  if (e)
    return e;

  Entry *src = find(t, n), *dst = vacant(t);
  int v = 0;
  e = validate(t, src);

  if (!e && !dst)
    e = EMFILE;
  if (!e)
    e = number(&v);

  if (!e) {
    dst->number = v;
    dst->description = src->description;
    dst->description->refs++;
    *out = v;
  }
  pthread_mutex_unlock(&t->lock);
  return e;
}
int hyotan_bsd_read(HyotanBsdDescriptors *t, const HyotanBsdScope *s, int n,
                    uint8_t *b, size_t len, size_t *out) {
  if (!out)
    return EINVAL;
  *out = 0;
  int e = enter(t, s);
  if (e)
    return e;
  Entry *a = find(t, n);

  e = validate(t, a);
  if (!e) {
    Description *d = a->description;

    e = hyotan_operations_read_at(t->workspace, d->handle, d->offset, len, b,
                                  len, out);
    if (!e)
      d->offset += *out;
  }
  pthread_mutex_unlock(&t->lock);
  return e;
}
int hyotan_bsd_write(HyotanBsdDescriptors *t, const HyotanBsdScope *s, int n,
                     const uint8_t *b, size_t len, size_t *out) {
  if (!out)
    return EINVAL;
  *out = 0;
  int e = enter(t, s);
  if (e)
    return e;
  Entry *a = find(t, n);

  e = validate(t, a);
  if (!e) {
    Description *d = a->description;

    /* APPEND ignores the shared seek position. Core retains O_APPEND and
     * checks actual EOF + length under its authority lock; zero satisfies
     * its preliminary write-at budget without weakening the EOF bound. */
    uint64_t write_offset = (d->flags & HYOTAN_OPEN_APPEND) ? 0 : d->offset;
    e = hyotan_operations_write_at(t->workspace, d->handle, write_offset, b,
                                   len, out);

    if (!e) {
      if (d->flags & HYOTAN_OPEN_APPEND) {
        HyotanOperationMetadata m;
        e = hyotan_operations_stat(t->workspace, d->handle, &m);
        if (!e)
          d->offset = m.bytes;
      } else
        d->offset += *out;
    }
  }
  pthread_mutex_unlock(&t->lock);
  return e;
}
int hyotan_bsd_seek(HyotanBsdDescriptors *t, const HyotanBsdScope *s, int n,
                    int64_t delta, int whence, uint64_t *out) {
  if (!out)
    return EINVAL;
  *out = 0;
  int e = enter(t, s);
  if (e)
    return e;
  Entry *a = find(t, n);
  e = validate(t, a);

  if (!e) {
    Description *d = a->description;
    uint64_t base = 0, next = 0;

    if (whence == SEEK_CUR)
      base = d->offset;
    else if (whence == SEEK_END) {
      HyotanOperationMetadata m;
      e = hyotan_operations_stat(t->workspace, d->handle, &m);
      base = m.bytes;
    } else if (whence != SEEK_SET)
      e = EINVAL;

    if (!e) {
      uint64_t magnitude =
          delta < 0 ? (uint64_t)(-(delta + 1)) + 1 : (uint64_t)delta;

      if (delta < 0) {
        if (magnitude > base)
          e = EINVAL;
        else
          next = base - magnitude;
      } else if (base > (uint64_t)INT64_MAX - magnitude)
        e = EOVERFLOW;
      else
        next = base + magnitude;

      uint64_t limit = (d->flags & HYOTAN_OPEN_READ) ? t->read_extent : 0;
      if ((d->flags & HYOTAN_OPEN_WRITE) && t->write_extent > limit)
        limit = t->write_extent;

      if (!e && next > limit)
        e = EACCES;
      if (!e) {
        d->offset = next;
        *out = next;
      }
    }
  }
  pthread_mutex_unlock(&t->lock);
  return e;
}
int hyotan_bsd_stat(HyotanBsdDescriptors *t, const HyotanBsdScope *s, int n,
                    HyotanOperationMetadata *out) {
  if (!out)
    return EINVAL;
  memset(out, 0, sizeof(*out));
  int e = enter(t, s);
  if (e)
    return e;
  Entry *a = find(t, n);

  e = a ? hyotan_operations_stat(t->workspace, a->description->handle, out)
        : EACCES;
  pthread_mutex_unlock(&t->lock);
  return e;
}
int hyotan_bsd_truncate(HyotanBsdDescriptors *t, const HyotanBsdScope *s, int n,
                        uint64_t len) {
  int e = enter(t, s);
  if (e)
    return e;
  Entry *a = find(t, n);
  e = a ? hyotan_operations_truncate(t->workspace, a->description->handle, len)
        : EACCES;
  pthread_mutex_unlock(&t->lock);
  return e;
}
int hyotan_bsd_close(HyotanBsdDescriptors *t, const HyotanBsdScope *s, int n) {
  int e = enter(t, s);
  if (e)
    return e;
  Entry *a = find(t, n);
  e = validate(t, a);
  if (!e)
    release(t, a);
  pthread_mutex_unlock(&t->lock);
  return e;
}
int hyotan_bsd_revoke(HyotanBsdDescriptors *t, const HyotanBsdScope *s) {
  int e = enter(t, s);
  if (e)
    return e;
  t->revoked = 1;
  e = hyotan_operations_revoke(t->workspace);

  for (size_t i = 0; i < SLOTS; i++)
    if (t->entries[i].number)
      release(t, &t->entries[i]);
  pthread_mutex_unlock(&t->lock);
  return e;
}
int hyotan_bsd_descriptor_flags(HyotanBsdDescriptors *t,
                                const HyotanBsdScope *s, int n, uint32_t *out) {
  if (!out)
    return EINVAL;
  *out = 0;
  int e = enter(t, s);
  if (e)
    return e;
  Entry *a = find(t, n);
  e = validate(t, a);
  if (!e)
    *out = a->description->flags &
           (HYOTAN_OPEN_READ | HYOTAN_OPEN_WRITE | HYOTAN_OPEN_APPEND);
  pthread_mutex_unlock(&t->lock);
  return e;
}
static int diagnostic_enter(HyotanBsdDescriptors *t, const HyotanBsdScope *s) {
  if (!t || !s)
    return EINVAL;
  pthread_mutex_lock(&t->lock);
  if (!memchr(s->owner, 0, sizeof(s->owner)) ||
      strcmp(s->owner, t->scope.owner) ||
      s->generation != t->scope.generation ||
      s->instance != t->scope.instance) {
    pthread_mutex_unlock(&t->lock);
    return EACCES;
  }
  return 0;
}
int hyotan_bsd_report_refusal(HyotanBsdDescriptors *t, const HyotanBsdScope *s,
                              uint32_t operation, int error) {
  if (operation < HYOTAN_BSD_REPORT_OPEN || operation > HYOTAN_BSD_REPORT_ADOPT)
    return EINVAL;
  int e = diagnostic_enter(t, s);
  if (e)
    return e;
  if (error == EACCES || error == EPERM || error == ENOTSUP || error == EFBIG) {
    if (!t->refusal.count) {
      t->refusal.operation = operation;
      t->refusal.error = error;
    }
    if (t->refusal.count < 64)
      t->refusal.count++;
    else
      t->refusal.saturated = 1;
  }
  pthread_mutex_unlock(&t->lock);
  return 0;
}
int hyotan_bsd_refusal_status(HyotanBsdDescriptors *t, const HyotanBsdScope *s,
                              HyotanBsdRefusalStatus *out) {
  if (!out)
    return EINVAL;
  memset(out, 0, sizeof(*out));
  int e = diagnostic_enter(t, s);
  if (e)
    return e;
  *out = t->refusal;
  pthread_mutex_unlock(&t->lock);
  return 0;
}
const char *hyotan_bsd_refusal_message(int error) {
  if (error == ENOTSUP)
    return "Operation unsupported for this owned descriptor. Use a descriptor "
           "opened with the supported workspace access and append mode; no "
           "unrestricted fallback is allowed.";
  if (error == EFBIG)
    return "Operation exceeds the permitted size limit. Use smaller chunks "
           "within the active workspace extent; no unrestricted fallback is "
           "allowed.";
  if (error == EPERM)
    error = EACCES;
  return hyotan_operations_error_message(error);
}
/* Trusted cookie lifetime pins; release is allowed after revoke. */
int hyotan_bsd_descriptors_retain(HyotanBsdDescriptors *t,
                                  const HyotanBsdScope *s) {
  int e = enter(t, s);
  if (e)
    return e;
  if (t->retained == SIZE_MAX)
    e = EOVERFLOW;
  else
    t->retained++;
  pthread_mutex_unlock(&t->lock);
  return e;
}
int hyotan_bsd_descriptors_release(HyotanBsdDescriptors *t) {
  if (!t)
    return EINVAL;
  pthread_mutex_lock(&t->lock);
  int e = 0;
  if (!t->retained)
    e = EINVAL;
  else
    t->retained--;
  pthread_mutex_unlock(&t->lock);
  return e;
}
int hyotan_bsd_descriptors_claim_stream_context(HyotanBsdDescriptors *t,
                                                const HyotanBsdScope *s) {
  int e = enter(t, s);
  if (e)
    return e;
  if (t->stream_context_claimed)
    e = EBUSY;
  else
    t->stream_context_claimed = 1;
  pthread_mutex_unlock(&t->lock);
  return e;
}
int hyotan_bsd_descriptors_destroy(HyotanBsdDescriptors *t) {
  if (!t)
    return EINVAL;
  pthread_mutex_lock(&t->lock);
  if (t->retained) {
    pthread_mutex_unlock(&t->lock);
    return EBUSY;
  }
  hyotan_operations_revoke(t->workspace);

  for (size_t i = 0; i < SLOTS; i++)
    if (t->entries[i].number)
      release(t, &t->entries[i]);
  int e = hyotan_operations_destroy(t->workspace);

  pthread_mutex_unlock(&t->lock);
  pthread_mutex_destroy(&t->lock);
  free(t);
  return e;
}
