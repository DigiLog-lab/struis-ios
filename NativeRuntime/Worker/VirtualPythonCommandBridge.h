/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#ifndef STRUIS_VIRTUAL_PYTHON_COMMAND_BRIDGE_H
#define STRUIS_VIRTUAL_PYTHON_COMMAND_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define STRUIS_VP_QUEUE_CAPACITY 65536u
#define STRUIS_VP_MAX_FRAME 16384u
#define STRUIS_VP_MAX_ARGC 256u
#define STRUIS_VP_MAX_ARG_BYTES 65536u
#define STRUIS_VP_MAX_ARG_LENGTH 16384u
#define STRUIS_VP_MAX_WAIT_MS 10000u
#define STRUIS_VP_APPLE_PROBE_TRANSFER 1u
#define STRUIS_VP_APPLE_PROBE_EOF 2u
#define STRUIS_VP_APPLE_PROBE_CANCEL_READ 4u
#define STRUIS_VP_APPLE_PROBE_CANCEL_WRITE 8u
#define STRUIS_VP_APPLE_PROBE_EPIPE 16u
#define STRUIS_VP_APPLE_PROBE_NEXT_CONTEXT 32u
#define STRUIS_VP_APPLE_PROBE_ALL 63u
/* Trusted, sequential Debug Simulator worker test only; never a model tool.
 * Runs synthetic owned pipes, joins all helper/shuttle threads before returning.
 * Any failed check or cleanup timeout terminates the worker instead of returning
 * with live threads referring to local storage. Saves/disables/restores caller
 * pthread cancellation; does not change process SIGPIPE disposition. */
uint32_t StruisVPAppleProbe(void);
typedef struct StruisVirtualPythonInvocation StruisVirtualPythonInvocation;
typedef struct { char worker_id[128]; char owner[256]; uint64_t generation, invocation_id; } StruisVPContext;
enum { STRUIS_VP_PYTHON_MAIN=1, STRUIS_VP_GIT_MAIN=2 };
enum { STRUIS_VP_STDOUT=1, STRUIS_VP_STDERR=2 };
enum { STRUIS_VP_EXIT_NORMAL=0, STRUIS_VP_EXIT_CANCELLED=1, STRUIS_VP_EXIT_IO_ERROR=2 };
typedef struct {
 uint32_t started, provider_finished, cancelled, threads_complete;
 uint32_t stdin_eof, merged_output;
 int32_t io_error;
 size_t stdin_available, stdout_credit, stderr_credit;
} StruisVPStatus;
typedef struct { int32_t exit_code; uint32_t reason; int32_t io_error; uint64_t stdin_bytes,stdout_bytes,stderr_bytes; } StruisVPResult;
/* TRUSTED NATIVE HOST ONLY. No JS/model message chooses C pointers, descriptors,
 * worker identity, owner, generation, provider function or creates a context.
 * Keys are copied from create and verified on every later call. Caller owns
 * pointer/buffer validity, nonaliasing and instance lifetime. Destroy only after
 * concurrent API calls end. API callers must keep pthread cancellation disabled
 * across these calls (in particular await/destroy); cancel the invocation using
 * Cancel, never by cancelling its API caller. All APIs return errno (0 success).
 *
 * create duplicates real pipeline fds without changing ANY shared file status
 * flags. Darwin output must be a known regular file, or a FIFO/socket already
 * protected with F_SETNOSIGPIPE by its trusted owner before sharing. The getter
 * only checks this precondition: dup shares fileglob, so the bridge never sets
 * it on inherited descriptors. Unprepared/unsupported outputs fail ENOTSUP.
 * create copies exact argc/argv including argv[0], and reserves the one active
 * invocation in this process. start begins pure-C shuttle threads; it may fail
 * after some threads start, so caller must cancel/await before destroy.
 * stdout/stderr are merged only when their input fd NUMBERS are identical.
 * Otherwise they retain independent queues/writers; no inode-based guessing.
 * Distinct fds aliasing one open-file description are not detected: trusted
 * integration must pass the same fd number to preserve merged FIFO ordering.
 * Queues hold binary data, not decoded text. No shell, fork or Python evaluator.
 * Queue storage is fixed (three 64KiB data + three 64KiB tag arrays), plus <=64KiB
 * copied argv, <=256 pointers, thread-local 16KiB frames and platform pthread
 * stacks. These bounds do not promise an OS physical-memory budget.
 */
int StruisVPCreate(const char *worker_id,const char *owner,uint64_t generation,
 uint32_t function,int argc,const char *const *argv,int stdin_fd,int stdout_fd,
 int stderr_fd,StruisVirtualPythonInvocation **out,StruisVPContext *out_context);
int StruisVPStart(StruisVirtualPythonInvocation *,const StruisVPContext *);
int StruisVPDescribe(StruisVirtualPythonInvocation *,const StruisVPContext *,uint32_t *out_function,size_t *out_argc);
/* Arg returns exact bytes plus trailing NUL; required includes that terminator.
 * ERANGE reports required capacity without touching buffer. */
int StruisVPArgument(StruisVirtualPythonInvocation *,const StruisVPContext *,size_t index,uint8_t *output,size_t capacity,size_t *out_required);
int StruisVPStatusRead(StruisVirtualPythonInvocation *,const StruisVPContext *,StruisVPStatus *out);
/* Nonblocking bounded pull/push. EAGAIN means no data/credit yet. Pull EOF is
 * true only after buffered stdin drains; empty EOF returns 0 count, success.
 * Push may accept a prefix; resend only the remainder. out counts begin at0.
 * Frames <=16KiB, queues64KiB each; merged streams share one FIFO and credit.
 */
int StruisVPPullStdin(StruisVirtualPythonInvocation *,const StruisVPContext *,uint8_t *output,size_t capacity,size_t *out_count,uint32_t *out_eof);
int StruisVPPushOutput(StruisVirtualPythonInvocation *,const StruisVPContext *,uint32_t stream,const uint8_t *input,size_t length,size_t *out_accepted);
/* Finished signals provider exit, stops/cancels unused stdin pumping and drains
 * queued output before await succeeds. Cancel discards pending queues, requests
 * deferred pthread cancellation and returns BEFORE completion is confirmed.
 * Linux SIGPIPE is blocked in each writer, never process-wide. Darwin also
 * requires the trusted creation-time NOSIGPIPE contract described above.
 * Cancel after terminal normal/error completion returns EALREADY and retains
 * its result. Repeated Cancel after cancellation is idempotent. Cancellation
 * can discard queued bytes; it cannot retract bytes the kernel already wrote.
 * Byte counters describe observed completed syscalls, not transactional output
 * acknowledgement during cancellation. Status/await remain usable for cleanup.
 */
int StruisVPFinished(StruisVirtualPythonInvocation *,const StruisVPContext *,int32_t exit_code);
int StruisVPCancel(StruisVirtualPythonInvocation *,const StruisVPContext *);
/* Await on native command/background thread ONLY, never UI/main thread. Returns
 * ETIMEDOUT if unfinished, including after cancellation. Timeout is NOT joined
 * or successful termination: do not destroy or start another invocation; retire
 * the native worker with the existing host watchdog. No fake bounded join.
 * Max timeout10seconds;0 is immediate. Result starts zeroed on failure.
 */
int StruisVPAwait(StruisVirtualPythonInvocation *,const StruisVPContext *,uint32_t timeout_ms,StruisVPResult *out);
/* EBUSY while threads/provider unfinished. Joins only threads whose pure-C
 * cleanup has closed owned duplicate fds and reported completion; does not close
 * the caller's original fds. Releases the sole active slot after cleanup.
 * Native regular-file/device stalls or unsupported Apple cancellation require
 * worker retirement; Linux pipe tests do not prove WK/XPC/Apple behavior.
 */
int StruisVPDestroy(StruisVirtualPythonInvocation *,const StruisVPContext *);
#ifdef __cplusplus
}
#endif
#endif
