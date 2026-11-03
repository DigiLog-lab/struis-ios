/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#ifndef HYOTAN_OPERATIONS_H
#define HYOTAN_OPERATIONS_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Trusted host only: JS/AI messages must never supply pointers, root FDs,
 * owner identities, generations, or workspace creation. The host owns instance
 * and buffer lifetimes, valid pointer ranges/alignment and nonaliasing output
 * arguments. Destroy requires all concurrent calls to have ended.
 * Calls serialize within each instance; revoke ends authority and closes all
 * mapped handles before returning. A revoked instance cannot be reused.
 * No API exposes an OS fd or reopens a denied operation through a pathname.
 * Every return is an errno value: 0 success; nonzero failure. Never infer
 * success from output bytes or a nonzero opaque handle alone.
 */
typedef struct HyotanWorkspace HyotanWorkspace;
enum { HYOTAN_WORKSPACE_READ_ONLY=1, HYOTAN_WORKSPACE_READ_WRITE=2 };
enum {
 HYOTAN_OPEN_READ=1, HYOTAN_OPEN_WRITE=2, HYOTAN_OPEN_CREATE=4,
 HYOTAN_OPEN_EXCLUSIVE=8, HYOTAN_OPEN_TRUNCATE=16, HYOTAN_OPEN_APPEND=32
};
/* At least READ or WRITE; EXCLUSIVE requires CREATE. APPEND/TRUNCATE require
 * WRITE. CREATE needs a mutable workspace even with a read-only file handle.
 * APPEND atomically writes at EOF; supplied offsets remain budget-checked.
 */
enum { HYOTAN_METADATA_DIRECTORY=1, HYOTAN_METADATA_CREATED=2, HYOTAN_METADATA_MODIFIED=4 };
typedef struct {
 uint64_t bytes, created_at_ms, modified_at_ms;
 uint32_t flags, reserved;
} HyotanOperationMetadata;
/* create duplicates a directory fd whose workspace provenance the host has
 * verified. owner is valid NUL-terminated UTF-8, 1..256 bytes. Caller retains fd.
 * On failure *out_workspace=NULL. Handles are globally unique, never reused,
 * and valid only with their issuing instance; numbers are not grants.
 */
int hyotan_operations_create(int directory_fd,const char *owner,uint64_t generation,uint32_t access,HyotanWorkspace **out_workspace);
/* Explicit trusted-policy variant: positive extents <= signed off_t maximum.
 * Capture once at creation, never from guest JSON. Invalid limits return EINVAL
 * and NULL output. Ordinary create/open retain their existing 16MiB behavior.
 * Configured instances select streamed handles using captured separate read/write
 * extents; frames, handle counts, bulk/copy budgets remain unchanged. */
int hyotan_operations_create_with_descriptor_limits(int directory_fd,const char *owner,uint64_t generation,uint32_t access,uint64_t read_extent,uint64_t write_extent,HyotanWorkspace **out_workspace);
/* Read-only effective descriptor policy. On failure outputs start at zero;
 * returns EACCES after revoke. Output pointers must be valid and nonaliasing. */
int hyotan_operations_descriptor_limits(HyotanWorkspace *,uint64_t *out_read_extent,uint64_t *out_write_extent,uint32_t *out_configured);
int hyotan_operations_revoke(HyotanWorkspace *workspace);
int hyotan_operations_destroy(HyotanWorkspace *workspace);
/* Paths are UTF-8 bytes, at most 4096, not NUL terminated; embedded NUL,
 * absolute/parent paths and symlink traversal are rejected. Empty path means
 * root only for metadata/list. Otherwise nonempty path is required.
 */
int hyotan_operations_open(HyotanWorkspace *,const uint8_t *path,size_t path_length,uint32_t flags,uint64_t *out_handle);
/* Max chunk 1 MiB; legacy logical file/write/truncate limit 16 MiB. Configured
 * instances enforce immutable per-instance read/write extents. Exact read-limit
 * EOF succeeds with zero bytes; requests are clipped to remaining read extent. Maximum 64
 * handles per workspace. Insufficient read/list output capacity returns ERANGE
 * without partial success or touching that output buffer. Read returns up to
 * requested bytes (EOF may return0). Write returns actual bytes; callers must
 * handle short writes. All out-counts start at0; metadata starts zeroed.
 */
int hyotan_operations_read_at(HyotanWorkspace *,uint64_t handle,uint64_t offset,size_t requested,uint8_t *output,size_t output_capacity,size_t *out_read);
int hyotan_operations_write_at(HyotanWorkspace *,uint64_t handle,uint64_t offset,const uint8_t *input,size_t input_length,size_t *out_written);
int hyotan_operations_truncate(HyotanWorkspace *,uint64_t handle,uint64_t length);
int hyotan_operations_stat(HyotanWorkspace *,uint64_t handle,HyotanOperationMetadata *out_metadata);
int hyotan_operations_close(HyotanWorkspace *,uint64_t handle);
int hyotan_operations_metadata(HyotanWorkspace *,const uint8_t *path,size_t path_length,HyotanOperationMetadata *out_metadata);
/* List returns UTF-8 names with a NUL separator after each name, no paths.
 * Max 4096 names/1 MiB. On ERANGE required byte count is returned in out_required;
 * out_written/out_entries stay0. Empty listing requires0 bytes, no separator.
 */
int hyotan_operations_list(HyotanWorkspace *,const uint8_t *path,size_t path_length,uint8_t *output,size_t output_capacity,size_t *out_written,size_t *out_entries,size_t *out_required);
int hyotan_operations_mkdir(HyotanWorkspace *,const uint8_t *path,size_t path_length);
int hyotan_operations_remove(HyotanWorkspace *,const uint8_t *path,size_t path_length,uint32_t recursive);
/* Atomic same-instance replacement. Both paths are bounded relative UTF-8;
 * existing regular-file handles retain their original object after replacement.
 * Independent instances/privileged host mutation require workspace serialization. */
int hyotan_operations_rename(HyotanWorkspace *, const uint8_t *source, size_t source_len,
                             const uint8_t *destination, size_t destination_len);
int hyotan_operations_copy(HyotanWorkspace *,const uint8_t *source,size_t source_length,const uint8_t *destination,size_t destination_length,uint32_t recursive);
/* Fixed, process-owned string; never free. EACCES message is actionable but
 * contains no path, credentials or secret data. No fallback is permitted.
 */
const char *hyotan_operations_error_message(int error);
#ifdef __cplusplus
}
#endif
#endif
