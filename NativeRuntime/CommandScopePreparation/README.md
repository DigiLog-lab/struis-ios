# Trusted command-scope source preparation

This is an opt-in prerequisite for isolated real Dash AST stages. It does not
change the product configuration, native Python entry, AppServer model loop,
legacy command resolver, or current default `ios_system` build. No Apple build,
Cloud submission, publication, or native pipeline success is claimed here.

`Scripts/prepare-ios-command-scope.py` reads the exact ios_system revision
`ebc045299e56edaf3509144d43a7f7348af400a7`, checks both source file SHA-256 hashes,
and emits an independent source overlay plus the C support files. Changed input
is rejected before output writes. Generation is deterministic; pristine Vendor
sources stay unchanged. The upstream source headers/license remain in generated
files; new support is Apache-2.0. No GPL code or new external package is added.

The generated libc branches choose between unchanged legacy PID/environment
storage and explicitly enabled scoped storage. Every direct scoped PID array
consumer maps a monotonic public child ID to an owner-validated live slot in
separate arrays. Fake fork reserves its child and copies the parent's environment.
Capture restores the creator PID before pthread creation. Only that captured
child is adopted in the new thread. Every mutex is unlocked by its locking
thread. Results publish after cleanup and waits reject unknown, foreign-owner,
nonchild, and consumed IDs. Slots are reusable; public IDs never are. Exhaustion
fails with EAGAIN. Waits have a ten-second deadline; timeout retains live state.

The trusted Apple entry is generated in `ios_system.m`:

```c
int StruisIosCommandScopeBegin(FILE *input, FILE *output,
                              FILE *errorStream, void *context);
int StruisIosCommandScopeEnd(void);
int StruisIosCommandPipelineStreams(FILE **input, FILE **output,
                                   FILE **errorStream, void **context);
```

The isolated outer stage supplies its own live FILE streams before calling
StageEnter. Begin deep-copies the session command-name allocation, establishes
root environment state from an owned deep copy of the caller's actual
`environmentVariables(ios_currentPid())` map, and binds those exact streams.
The snapshot is captured before selecting the new scoped root, preserving
RuntimeCommand's HOME/WORKSPACE values when ambient `environ` differs. Snapshot
allocation failure leaves the caller's session, streams, and environment intact.
The existing known
command resolver remains authoritative. Only the explicit scope branch replaces
the pthread launch/cleanup. Each native command receives a private session and
captured child ID. Group FILE pointers are borrowed until the entire sequential
AST ends. Explicit command redirect/pipe transfers are owned by that command,
identified using actual trusted pointer identity and the upstream transfer flags;
cleanup closes each owned FILE once. No standard descriptor number is guessed.
End restores exactly the prior TLS stdin/stdout/stderr/context, including trusted
redirected streams that differ from the prior session defaults. Nested entry is
rejected without mutation. End refuses unreaped or live children; the caller must retain all stage resources
and retire the captured worker when bounded termination cannot be established.

PipelineStreams is a trusted acquisition ABI inside the same `ios_system` image
as the actual `ios_dup2` child-stream TLS. It selects pending `child_*` redirects
where present and the active `thread_*` streams otherwise, flushes selected
outputs, and returns an independently owned duplicate FILE tuple. Equal source
FILE pointers remain aliases in the returned tuple; descriptor access modes and
shared status flags are preserved. It never activates, clears, restores, or
closes the parent's pending redirects. The launcher closes every distinct
returned FILE once after creating stage duplicates, including error paths.
Stages retain their own duplicates on timeout, so subsequent parent restoration
or closure cannot invalidate those live stage resources. Acquisition failure
closes partial duplicates and returns null outputs with an errno result.

Run the finite Linux verification:

```sh
python3 NativeRuntime/Scripts/check-ios-command-scope.py \
  --source /path/to/pristine/pinned/ios_system
```

It runs real pthread/pipe tests for two owners, nested launches, distinct results,
monotonic stale-ID rejection, simulated creation-failure publication, blocked-read
cancellation, and a next scope. It also compiles and executes the entire selected
PID/environment/fork/wait/release section of the actual generated pinned libc
source. That proof executes 300 launches with IDs exceeding the upstream 128-slot
array, verifies independent owner environments/results, stale rejection, and
zero process chdir or ambient environment mutation. The harness supplies only
platform declarations and unrelated integration stubs. GCC's Darwin pthread_t
NULL comparison and getwd warnings are from the retained legacy branch.

A further source probe compiles the selected generated C session clone,
launch, and cleanup functions. It injects EAGAIN at the actual pthread_create
call and checks every tracked allocation is released, an owned redirect FILE
closes once, and borrowed group FILEs remain live. A binary stdio command through
those functions verifies independent parent session/status and command-name stack.
The same selected source Begin/End paths preserve distinct prior redirected TLS
stream pointers and visible bytes after real blocked-input cancellation; nested
entry is rejected, live-child End retains resources, and the next scope succeeds.
Caller-versus-ambient HOME/WORKSPACE checks verify captured root and child
inheritance, scope-local mutation, restored caller values, fresh next entry, and
partial snapshot allocation-failure cleanup. Another probe compiles the exact
selected pending-TLS capture helper with the untouched pinned `ios_dup2` and
`ios_activateChildStreams` functions. It checks pending input/output/separate
stderr, `2>&1` and all-pointer aliases, actual redirected bytes, unchanged parent
TLS and descriptor flags, retained captures after parent restoration/closure,
and partial duplicate failure cleanup. These are Linux C source-composition
checks; they do not verify Objective-C or Apple runtime behavior.
The fixture provides an unused initialization stub for the ObjC session initializer. It excludes only the
Objective-C TeX lookup and substitutes a C thread entry for the unbuildable
Objective-C exception wrapper; those excluded parts are unverified.

The full Objective-C SessionAdapter has not been compiled here. Apple cancellation,
interpreter pool races, real BSD command stdio, and full Apple Dash/ios_system/provider
composition remain unverified. Do not wire this overlay to a Cloud/product build as validated
until those source/SDK paths and composition evidence are reviewed.