/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#ifndef HYOTAN_BSD_STDIO_H
#define HYOTAN_BSD_STDIO_H
#include "HyotanBsdDescriptors.h"
#include <stdio.h>
/* Trusted selected native callers only: FILE pointers never come from guest
 * messages. Every operation must use these explicit wrappers, including cached
 * reads/writes, flushing and cleanup. Raw libc FILE calls are not a boundary.
 * Only library-owned regular-file cookies are registered; stdin/out/pipes and
 * ordinary FILEs are rejected. Destroying the table with cookies returns EBUSY.
 * Caller buffers/pointers and using no FILE pointer after close remain trusted
 * lifetime obligations. Threads must not be canceled while inside wrappers. */
/* Modes: r/w/a with optional single b/+ in either order, x only for w. */
int hyotan_bsd_fopen(HyotanBsdDescriptors *, const HyotanBsdScope *,
                     const uint8_t *, size_t, const char *, FILE **);
/* Adopts an existing live regular-file logical descriptor on success; does not
 * duplicate, truncate, create or close it on failure. Caller stops using that
 * descriptor after success. Access may narrow, never expand. 'a' requires an
 * already APPEND description; changing shared append status is ENOTSUP. No x.
 * Only one FILE cookie may adopt a particular table/descriptor at a time. */
int hyotan_bsd_fdopen(HyotanBsdDescriptors *, const HyotanBsdScope *, int,
                      const char *, FILE **);
/* Query libc FILE error/EOF state only after registry/scope/live validation.
 * clearerr clears FILE state but never clears the command refusal latch. */
int hyotan_bsd_ferror(FILE *, const HyotanBsdScope *, int *);
int hyotan_bsd_feof(FILE *, const HyotanBsdScope *, int *);
/* errno return, byte counts (not element counts); prevalidation denial consumes
 * zero and does not touch read buffers or enqueue writes. Partial operations
 * may return error with actual consumed byte count. Accepted buffered writes
 * are not persisted until successful fflush/fclose. */
int hyotan_bsd_fread(FILE *, const HyotanBsdScope *, void *, size_t, size_t *);
int hyotan_bsd_fwrite(FILE *, const HyotanBsdScope *, const void *, size_t,
                      size_t *);
int hyotan_bsd_getc(FILE *, const HyotanBsdScope *, int *);
int hyotan_bsd_putc(FILE *, const HyotanBsdScope *, unsigned char);
int hyotan_bsd_fseek(FILE *, const HyotanBsdScope *, int64_t, int);
int hyotan_bsd_ftell(FILE *, const HyotanBsdScope *, uint64_t *);
int hyotan_bsd_fflush(FILE *, const HyotanBsdScope *);
/* fclose with matching scope always deallocates the cookie, even after revoke,
 * but returns denial/flush/close errors. Foreign scope does not close a FILE.
 */
int hyotan_bsd_fclose(FILE *, const HyotanBsdScope *);
/* Logical descriptor only, never OS fileno. Unknown or revoked FILE denied. */
int hyotan_bsd_fileno(FILE *, const HyotanBsdScope *, int *);
/* setvbuf only before stream I/O; caller-owned buffer survives until close. */
int hyotan_bsd_setvbuf(FILE *, const HyotanBsdScope *, char *, int, size_t);
int hyotan_bsd_clearerr(FILE *, const HyotanBsdScope *);
#endif
