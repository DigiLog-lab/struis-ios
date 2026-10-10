/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#ifndef HYOTAN_BSD_DESCRIPTORS_H
#define HYOTAN_BSD_DESCRIPTORS_H
#include "HyotanOperations.h"
#include <stddef.h>
#include <stdint.h>
typedef struct HyotanBsdDescriptors HyotanBsdDescriptors;
/* Trusted router supplies this identity, never command argv/environment/guest
 * messages. instance must uniquely identify the captured command lifetime. */
typedef struct {
  char owner[257];
  uint64_t generation, instance;
} HyotanBsdScope;
/* Owns a NEW operations instance. No external operations handle or raw OS file
 * FD is exposed. Caller retains root_fd. Limits are immutable trusted policy.
 */
int hyotan_bsd_descriptors_create(int root_fd, const HyotanBsdScope *,
                                  uint32_t access, uint64_t read_extent,
                                  uint64_t write_extent,
                                  HyotanBsdDescriptors **);
/* All functions return errno (0 success). Outputs zero on failure. Descriptor
 * numbers are process-global monotonic positive signed ints, never reused.
 * Only regular files. dup shares offset/access/append and original file object.
 * No pipe/stdio/FTS/glob/native fallback. Pointer and buffer lifetimes are
 * trusted caller responsibilities; destroy requires all calls have ended. */
int hyotan_bsd_open(HyotanBsdDescriptors *, const HyotanBsdScope *,
                    const uint8_t *, size_t, uint32_t, int *);
int hyotan_bsd_dup(HyotanBsdDescriptors *, const HyotanBsdScope *, int, int *);
int hyotan_bsd_read(HyotanBsdDescriptors *, const HyotanBsdScope *, int,
                    uint8_t *, size_t, size_t *);
int hyotan_bsd_write(HyotanBsdDescriptors *, const HyotanBsdScope *, int,
                     const uint8_t *, size_t, size_t *);
/* whence uses SEEK_SET/CUR/END; returned offset is uint64_t <= INT64_MAX. */
int hyotan_bsd_seek(HyotanBsdDescriptors *, const HyotanBsdScope *, int,
                    int64_t, int, uint64_t *);
int hyotan_bsd_stat(HyotanBsdDescriptors *, const HyotanBsdScope *, int,
                    HyotanOperationMetadata *);
int hyotan_bsd_truncate(HyotanBsdDescriptors *, const HyotanBsdScope *, int,
                        uint64_t);
int hyotan_bsd_close(HyotanBsdDescriptors *, const HyotanBsdScope *, int);
int hyotan_bsd_revoke(HyotanBsdDescriptors *, const HyotanBsdScope *);
/* Trusted selected-command diagnostic latch. Fixed enum/errno only: no paths,
 * descriptor numbers, pointers or data. Query/report remain available after
 * revoke with exact captured scope; neither issues or revives authority. */
enum {
  HYOTAN_BSD_REPORT_OPEN = 1,
  HYOTAN_BSD_REPORT_READ = 2,
  HYOTAN_BSD_REPORT_WRITE = 3,
  HYOTAN_BSD_REPORT_SEEK = 4,
  HYOTAN_BSD_REPORT_FLUSH = 5,
  HYOTAN_BSD_REPORT_CLOSE = 6,
  HYOTAN_BSD_REPORT_QUERY = 7,
  HYOTAN_BSD_REPORT_ADOPT = 8
};
typedef struct {
  uint32_t operation;
  int32_t error;
  uint32_t count, saturated;
} HyotanBsdRefusalStatus;
/* Only EACCES/EPERM/ENOTSUP/EFBIG are recorded; other operation outcomes do not
 * clear the latch. First refusal is immutable; count saturates at64. */
int hyotan_bsd_report_refusal(HyotanBsdDescriptors *, const HyotanBsdScope *,
                              uint32_t, int);
int hyotan_bsd_refusal_status(HyotanBsdDescriptors *, const HyotanBsdScope *,
                              HyotanBsdRefusalStatus *);
const char *hyotan_bsd_refusal_message(int);
/* Mode bits only, from a live logical descriptor; opaque handle never exported.
 */
int hyotan_bsd_descriptor_flags(HyotanBsdDescriptors *, const HyotanBsdScope *,
                                int, uint32_t *);
/* Trusted registered-cookie lifetime only; retain verifies live scope. Release
 * never revives authority and may run after revoke. Destroy returns EBUSY while
 * pins remain, without revoking or freeing the table. */
int hyotan_bsd_descriptors_retain(HyotanBsdDescriptors *,
                                  const HyotanBsdScope *);
int hyotan_bsd_descriptors_release(HyotanBsdDescriptors *);
/* Trusted stream-context factory claim, at most once per command table lifetime.
 * Does not reset earlier refusals or mint authority; fresh commands need a fresh
 * table/instance. A separate retained pin protects the claimed context lifetime. */
int hyotan_bsd_descriptors_claim_stream_context(HyotanBsdDescriptors *,
                                                const HyotanBsdScope *);
int hyotan_bsd_descriptors_destroy(HyotanBsdDescriptors *);
#endif
