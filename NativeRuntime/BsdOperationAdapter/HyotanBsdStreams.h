/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#ifndef HYOTAN_BSD_STREAMS_H
#define HYOTAN_BSD_STREAMS_H
#include "HyotanBsdStdio.h"
typedef struct HyotanBsdStreams HyotanBsdStreams;
typedef uint64_t HyotanBsdStream;
enum { HYOTAN_BSD_STREAM_REGULAR=1, HYOTAN_BSD_STREAM_STDIO=2,
       HYOTAN_BSD_STREAM_PIPE=3 };
/* Trusted captured-command factory only. Fresh table/scope per command; retain
 * caller table until destroy. No root, pointer, FILE, FD or identity from guests.
 * This API never exports native FD/FILE or converts unknown FILEs into grants. */
int hyotan_bsd_streams_create(HyotanBsdDescriptors *, const HyotanBsdScope *, HyotanBsdStreams **);
/* Trusted owner supplies ONLY its exact captured stdin/out/err tuple, with FILEs
 * already authorized as command data, never a user-selected host file. Regular
 * native stdio only; inherited FIFO/socket/device refused. Borrowed FILEs survive
 * all handle closes and must live until context destroy/actual I/O exits. */
int hyotan_bsd_streams_capture_stdio(HyotanBsdStreams *, const HyotanBsdScope *, FILE *, FILE *, FILE *, HyotanBsdStream[3]);
/* Adopts live logical regular descriptor only on success; mode cannot expand
 * access or change append. No native fdopen/fileno/path fallback. */
int hyotan_bsd_streams_adopt_regular(HyotanBsdStreams *, const HyotanBsdScope *, int, const char *, HyotanBsdStream *);
/* Creates exclusive actual pipe internally; Darwin NOSIGPIPE set before share.
 * Returned handles, never OS FDs. Blocking I/O is deferred-cancellable. */
int hyotan_bsd_streams_pipe(HyotanBsdStreams *, const HyotanBsdScope *, HyotanBsdStream *, HyotanBsdStream *);
/* dup retains same stream engine/open description, including shared buffer,
 * offset and append state. Handles monotonically issued, not reused. */
int hyotan_bsd_streams_dup(HyotanBsdStreams *, const HyotanBsdScope *, HyotanBsdStream, HyotanBsdStream *);
int hyotan_bsd_streams_class(HyotanBsdStreams *, const HyotanBsdScope *, HyotanBsdStream, int *);
int hyotan_bsd_streams_read(HyotanBsdStreams *, const HyotanBsdScope *, HyotanBsdStream, void *, size_t, size_t *);
int hyotan_bsd_streams_write(HyotanBsdStreams *, const HyotanBsdScope *, HyotanBsdStream, const void *, size_t, size_t *);
int hyotan_bsd_streams_flush(HyotanBsdStreams *, const HyotanBsdScope *, HyotanBsdStream);
int hyotan_bsd_streams_close(HyotanBsdStreams *, const HyotanBsdScope *, HyotanBsdStream);
/* cancel invalidates context + actual table, requests cancellation only for
 * registered native-pipe I/O; it is NOT an exit acknowledgement. Destroy EBUSY
 * until all handles closed and I/O cleanup observed. Timeout -> retain/retire. */
int hyotan_bsd_streams_cancel(HyotanBsdStreams *, const HyotanBsdScope *);
/* Trusted cleanup observation only; zero means no wrapper I/O still pins this
 * context, not an acknowledgement of other command/helper thread completion. */
int hyotan_bsd_streams_pending(HyotanBsdStreams *, const HyotanBsdScope *, unsigned *);
int hyotan_bsd_streams_destroy(HyotanBsdStreams *);
#endif
