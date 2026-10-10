/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE 1
#endif
#include "VirtualPythonCommandBridge.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* Never assert(): release/NDEBUG must still fail a defective probe. Termination
 * prevents any timeout path returning while helpers retain stack references.
 * The worker's external watchdog remains responsible for a stalled syscall. */
static atomic_uint probeStage;
static void report(unsigned int code, unsigned int line, int error) {
    char bytes[96];
    int length = snprintf(bytes, sizeof(bytes),
        "STRUIS_VP_PROBE stage=%u line=%u errno=%d\n", code, line, error);
    if (length <= 0 || (size_t)length >= sizeof(bytes)) return;
    size_t offset = 0;
    // ios_system globally replaces fprintf using per-command thread streams;
    // XPC/pure-C threads have no such streams. Raw fd2 is the trusted diagnostic
    // file opened at worker startup. Never inspect or print native input data.
    for (unsigned int attempt = 0; attempt < 4 && offset < (size_t)length; attempt++) {
        ssize_t n = write(STDERR_FILENO, bytes + offset, (size_t)length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        offset += (size_t)n;
    }
}
static void stage(unsigned int code) {
    atomic_store(&probeStage, code);
#ifdef __APPLE__
    report(code, 0, 0);
#endif
}
static void requireAt(int condition, unsigned int line) {
    if (condition) return;
    int saved = errno;
    report(atomic_load(&probeStage), line, saved);
#ifdef __APPLE__
    /* ios_system interposes abort/exit as pthread_exit. The existing worker
     * terminator resolves libSystem _exit directly, then uses SIGKILL. Never
     * unwind this thread while helpers still refer to probe stack storage. */
    extern void StruisTerminateWorker(int status);
    StruisTerminateWorker(125);
    kill(getpid(), SIGKILL);
    for (;;) pause(); /* No return even if an unexpected termination failure. */
#else
    abort();
#endif
}
#define require(condition) requireAt((condition), __LINE__)
static double now(void) {
    struct timespec t;
    require(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}
static void tick(void) {
    struct timespec t = {.tv_nsec = 1000000};
    while (nanosleep(&t, &t) < 0) require(errno == EINTR);
}
static void until_done(atomic_int *done) {
    double end = now() + 2;
    while (!atomic_load(done)) { require(now() < end); tick(); }
}
static void pipes(int p[2]) {
    require(pipe(p) == 0);
#ifdef __APPLE__
    /* This probe owns the new exclusive pipe. Prepare before any sharing or
     * before-state capture; bridge duplication must not change this setting. */
    require(fcntl(p[1], F_SETNOSIGPIPE, 1) == 0);
    require(fcntl(p[1], F_GETNOSIGPIPE) == 1);
#endif
}
static uint8_t value(size_t offset) { return (uint8_t)((offset * 37) % 251); }
static void write_all(int fd, const uint8_t *bytes, size_t length) {
    while (length) {
        ssize_t n = write(fd, bytes, length);
        if (n < 0 && errno == EINTR) continue;
        require(n > 0);
        bytes += n;
        length -= (size_t)n;
    }
}
static void make(int input, int output, int error,
                 StruisVirtualPythonInvocation **i, StruisVPContext *key) {
    static const char *const argv[] = {"python3", "-c", "print('日本語')"};
    require(StruisVPCreate("synthetic-apple-probe", "synthetic-probe-owner", 1,
        STRUIS_VP_PYTHON_MAIN, 3, argv, input, output, error, i, key) == 0);
}
struct Producer {
    int fd;
    size_t count;
    atomic_int *early;
    atomic_int done;
};
static void *produce(void *raw) {
    struct Producer *p = raw;
    require(pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL) == 0);
    uint8_t bytes[4096];
    size_t offset = 1024;
    for (size_t n = 0; n < offset; n++) bytes[n] = value(n);
    write_all(p->fd, bytes, offset);
    double end = now() + 5;
    while (!atomic_load(p->early)) { require(now() < end); tick(); }
    while (offset < p->count) {
        size_t take = p->count - offset;
        if (take > sizeof(bytes)) take = sizeof(bytes);
        for (size_t n = 0; n < take; n++) bytes[n] = value(offset + n);
        write_all(p->fd, bytes, take);
        offset += take;
    }
    require(close(p->fd) == 0);
    atomic_store(&p->done, 1);
    return NULL;
}
struct Consumer {
    int fd;
    size_t expected;
    uint8_t mask;
    atomic_int *early, *producer_done;
    atomic_int done;
};
static void *consume(void *raw) {
    struct Consumer *c = raw;
    require(pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL) == 0);
    uint8_t bytes[997];
    size_t offset = 0;
    for (;;) {
        ssize_t n = read(c->fd, bytes, sizeof(bytes));
        if (n < 0 && errno == EINTR) continue;
        require(n >= 0);
        if (!n) break;
        for (ssize_t p = 0; p < n; p++) {
            require(offset < c->expected);
            require(bytes[p] == (uint8_t)(value(offset) ^ c->mask));
            offset++;
        }
        if (c->early && !atomic_load(c->early)) {
            require(!atomic_load(c->producer_done));
            atomic_store(c->early, 1);
        }
    }
    require(offset == c->expected);
    require(close(c->fd) == 0);
    atomic_store(&c->done, 1);
    return NULL;
}
static void push_all(StruisVirtualPythonInvocation *i, const StruisVPContext *key,
                     uint32_t stream, const uint8_t *bytes, size_t length) {
    double end = now() + 5;
    size_t offset = 0;
    while (offset < length) {
        size_t accepted = 0;
        int e = StruisVPPushOutput(i, key, stream, bytes + offset,
                                  length - offset, &accepted);
        require(e == 0 || e == EAGAIN);
        require(accepted <= length - offset);
        offset += accepted;
        if (!accepted) { require(now() < end); tick(); }
    }
}
static uint32_t transfer(void) {
    stage(10);
    int in[2], out[2], err[2];
    pipes(in); pipes(out); pipes(err);
    int flags[3] = {fcntl(in[0], F_GETFL), fcntl(out[1], F_GETFL), fcntl(err[1], F_GETFL)};
    require(flags[0] >= 0 && flags[1] >= 0 && flags[2] >= 0);
    StruisVirtualPythonInvocation *i = NULL;
    StruisVPContext key;
    make(in[0], out[1], err[1], &i, &key);
    stage(11);
    require(StruisVPStart(i, &key) == 0);
    stage(12);
    require(fcntl(in[0], F_GETFL) == flags[0] && fcntl(out[1], F_GETFL) == flags[1]
            && fcntl(err[1], F_GETFL) == flags[2]);
#ifdef __APPLE__
    require(fcntl(out[1], F_GETNOSIGPIPE) == 1 && fcntl(err[1], F_GETNOSIGPIPE) == 1);
#endif
    require(close(in[0]) == 0 && close(out[1]) == 0 && close(err[1]) == 0);
    size_t count = STRUIS_VP_QUEUE_CAPACITY * 5 + 237;
    atomic_int early = 0;
    struct Producer producer = {.fd = in[1], .count = count, .early = &early, .done = 0};
    struct Consumer stdout_reader = {.fd = out[0], .expected = count, .mask = 0x55,
        .early = &early, .producer_done = &producer.done, .done = 0};
    struct Consumer stderr_reader = {.fd = err[0], .expected = count, .mask = 0xaa, .done = 0};
    pthread_t prod, readout, readerr;
    require(pthread_create(&prod, NULL, produce, &producer) == 0);
    require(pthread_create(&readout, NULL, consume, &stdout_reader) == 0);
    require(pthread_create(&readerr, NULL, consume, &stderr_reader) == 0);
    stage(13);
    uint8_t bytes[8192], errors[8192];
    size_t seen = 0;
    double end = now() + 8;
    for (;;) {
        size_t n = 0;
        uint32_t eof = 0;
        int e = StruisVPPullStdin(i, &key, bytes, sizeof(bytes), &n, &eof);
        require(e == 0 || e == EAGAIN);
        if (e == EAGAIN) { require(!n && !eof && now() < end); tick(); continue; }
        if (!seen && n) stage(14);
        for (size_t p = 0; p < n; p++) {
            require(bytes[p] == value(seen + p));
            errors[p] = (uint8_t)(bytes[p] ^ 0xaa);
            bytes[p] ^= 0x55;
        }
        push_all(i, &key, STRUIS_VP_STDOUT, bytes, n);
        push_all(i, &key, STRUIS_VP_STDERR, errors, n);
        seen += n;
        if (eof) break;
    }
    require(seen == count && atomic_load(&early));
    stage(15);
    require(StruisVPFinished(i, &key, 42) == 0);
    stage(16);
    StruisVPResult result;
    require(StruisVPAwait(i, &key, 2000, &result) == 0);
    stage(17);
    require(result.exit_code == 42 && result.reason == STRUIS_VP_EXIT_NORMAL
        && result.stdin_bytes == count && result.stdout_bytes == count
        && result.stderr_bytes == count);
    until_done(&producer.done); until_done(&stdout_reader.done); until_done(&stderr_reader.done);
    require(pthread_join(prod, NULL) == 0 && pthread_join(readout, NULL) == 0
        && pthread_join(readerr, NULL) == 0);
    stage(18);
    require(StruisVPDestroy(i, &key) == 0);
    stage(19);
    return STRUIS_VP_APPLE_PROBE_TRANSFER | STRUIS_VP_APPLE_PROBE_EOF;
}
static StruisVPContext cancellation(int block_write) {
    stage(block_write ? 30 : 20);
    int in[2], out[2];
    pipes(in); pipes(out);
    if (block_write) {
        /* These fds are private to this probe and have not been duplicated or
         * given to any thread. Restore blocking status BEFORE creating bridge.
         * EAGAIN proves lack of write credit without Linux-only pipe sizing. */
        int flags = fcntl(out[1], F_GETFL);
        require(flags >= 0 && fcntl(out[1], F_SETFL, flags | O_NONBLOCK) == 0);
        uint8_t fill[512] = {0};
        size_t total = 0;
        for (;;) {
            ssize_t n = write(out[1], fill, sizeof(fill));
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
            require(n > 0);
            total += (size_t)n;
            require(total <= 8 * 1024 * 1024);
        }
        require(total > 0 && fcntl(out[1], F_SETFL, flags) == 0);
    }
    StruisVirtualPythonInvocation *i = NULL;
    StruisVPContext key;
    make(in[0], out[1], out[1], &i, &key);
    stage(block_write ? 31 : 21);
    require(close(in[0]) == 0 && close(out[1]) == 0);
    require(StruisVPStart(i, &key) == 0);
    stage(block_write ? 32 : 22);
    StruisVPResult result;
    if (block_write) {
        uint8_t frame[STRUIS_VP_MAX_FRAME] = {0};
        size_t accepted = 0;
        require(StruisVPPushOutput(i, &key, STRUIS_VP_STDOUT, frame, sizeof(frame), &accepted) == 0
            && accepted == sizeof(frame));
        require(StruisVPFinished(i, &key, 0) == 0);
        stage(33);
    }
    require(StruisVPAwait(i, &key, 50, &result) == ETIMEDOUT);
    if (block_write) {
        StruisVPStatus status;
        require(StruisVPStatusRead(i, &key, &status) == 0
            && status.provider_finished && !status.io_error
            && status.stdout_credit < STRUIS_VP_QUEUE_CAPACITY);
    }
    require(StruisVPDestroy(i, &key) == EBUSY);
    stage(block_write ? 34 : 23);
    require(StruisVPCancel(i, &key) == 0);
    stage(block_write ? 35 : 24);
    require(StruisVPAwait(i, &key, 2000, &result) == 0
        && result.reason == STRUIS_VP_EXIT_CANCELLED && result.exit_code == 130);
    stage(block_write ? 36 : 25);
    require(StruisVPDestroy(i, &key) == 0);
    stage(block_write ? 37 : 26);
    require(close(in[1]) == 0);
    uint8_t bytes[4096];
    for (;;) {
        ssize_t n = read(out[0], bytes, sizeof(bytes));
        if (n < 0 && errno == EINTR) continue;
        require(n >= 0);
        if (!n) break;
    }
    require(close(out[0]) == 0);
    return key;
}
static int synthetic_regular_file(int *first_before, int *first_after) {
    char path[1024];
#ifdef __APPLE__
    const char *directory = getenv("TMPDIR");
    require(directory && directory[0] == '/');
#else
    const char *directory = "/tmp";
#endif
    int length = snprintf(path, sizeof(path), "%s/hyotan-vp-redirect-XXXXXX", directory);
    require(length > 0 && (size_t)length < sizeof(path));
    int fd = mkstemp(path);
    require(fd >= 0 && unlink(path) == 0);
    struct stat metadata;
    require(fstat(fd, &metadata) == 0 && S_ISREG(metadata.st_mode));
    /* Apple XNU xnu-12377.121.6 sys_generic.c marks a successful first write
     * in shared fg_flag; kern_descrip.c F_GETFL exposes that history bit.
     * Establish the ordinary written-file baseline with this fixture owner's
     * own public write/truncate/seek before sharing. No private bit constant,
     * mask or relaxation: every subsequent F_GETFL bit is compared exactly. */
    *first_before = fcntl(fd, F_GETFL);
    require(*first_before >= 0);
    const uint8_t seed = 0;
    require(write(fd, &seed, 1) == 1);
    *first_after = fcntl(fd, F_GETFL);
    require(*first_after >= 0);
#ifdef __APPLE__
    /* The first write should expose kernel history, while public mutable
     * status flags retain their values. Never mask the bridge comparisons. */
    int status = O_ACCMODE | O_APPEND | O_NONBLOCK | O_ASYNC | O_SYNC | O_DSYNC;
    if (*first_before == *first_after || ((*first_before ^ *first_after) & status)) {
        report(62, (unsigned int)*first_before, *first_after);
        require(0);
    }
#endif
    require(ftruncate(fd, 0) == 0 && lseek(fd, 0, SEEK_SET) == 0);
    require(fcntl(fd, F_GETFL) == *first_after);
    require(fstat(fd, &metadata) == 0 && metadata.st_size == 0);
    return fd;
}
static void regular_redirection(void) {
    stage(60);
    int in[2];
    pipes(in);
    int out_first_before, out_first_after, err_first_before, err_first_after;
    int out = synthetic_regular_file(&out_first_before, &out_first_after);
    int err = synthetic_regular_file(&err_first_before, &err_first_after);
    int out_flags = fcntl(out, F_GETFL), err_flags = fcntl(err, F_GETFL);
    require(out_flags >= 0 && err_flags >= 0);
#ifdef __APPLE__
    int out_suppression = fcntl(out, F_GETNOSIGPIPE), err_suppression = fcntl(err, F_GETNOSIGPIPE);
    require(out_suppression == 0 && err_suppression == 0);
#endif
    StruisVirtualPythonInvocation *i = NULL;
    StruisVPContext key;
    make(in[0], out, err, &i, &key);
    require(StruisVPStart(i, &key) == 0);
    require(fcntl(out, F_GETFL) == out_flags && fcntl(err, F_GETFL) == err_flags);
    const uint8_t output[] = {'R', 0, 'F'}, error[] = {'E', 255};
    push_all(i, &key, STRUIS_VP_STDOUT, output, sizeof(output));
    push_all(i, &key, STRUIS_VP_STDERR, error, sizeof(error));
    require(StruisVPFinished(i, &key, 42) == 0);
    StruisVPResult result;
    require(StruisVPAwait(i, &key, 2000, &result) == 0 && result.exit_code == 42
        && result.stdout_bytes == sizeof(output) && result.stderr_bytes == sizeof(error));
    uint8_t observed[8];
    require(pread(out, observed, sizeof(observed), 0) == (ssize_t)sizeof(output) && !memcmp(observed, output, sizeof(output)));
    require(pread(err, observed, sizeof(observed), 0) == (ssize_t)sizeof(error) && !memcmp(observed, error, sizeof(error)));
    int out_final_flags = fcntl(out, F_GETFL), err_final_flags = fcntl(err, F_GETFL);
    if (out_final_flags != out_flags || err_final_flags != err_flags) {
        /* Mismatch-only numeric fixture diagnostics: stage62 is first-write
         * before/after; stage63 is bridge baseline/final. stdout then stderr. */
        report(62, (unsigned int)out_first_before, out_first_after);
        report(62, (unsigned int)err_first_before, err_first_after);
        report(63, (unsigned int)out_flags, out_final_flags);
        report(63, (unsigned int)err_flags, err_final_flags);
    }
    require(out_final_flags == out_flags && err_final_flags == err_flags);
#ifdef __APPLE__
    require(fcntl(out, F_GETNOSIGPIPE) == out_suppression && fcntl(err, F_GETNOSIGPIPE) == err_suppression);
#endif
    require(StruisVPDestroy(i, &key) == 0 && close(in[0]) == 0 && close(in[1]) == 0
        && close(out) == 0 && close(err) == 0);
    stage(61);
}
static void unprotected_output_is_denied(void) {
#ifdef __APPLE__
    int in[2], out[2], err[2];
    require(pipe(in) == 0 && pipe(out) == 0 && pipe(err) == 0);
    require(fcntl(out[1], F_GETNOSIGPIPE) == 0 && fcntl(err[1], F_GETNOSIGPIPE) == 0);
    int flags = fcntl(out[1], F_GETFL);
    struct sigaction before, after;
    require(sigaction(SIGPIPE, NULL, &before) == 0);
    const char *const argv[] = {"python3", "--version"};
    StruisVirtualPythonInvocation *i = NULL;
    StruisVPContext key;
    require(StruisVPCreate("synthetic-unprotected", "synthetic-owner", 1,
        STRUIS_VP_PYTHON_MAIN, 2, argv, in[0], out[1], out[1], &i, &key) == ENOTSUP && !i);
    require(fcntl(out[1], F_GETNOSIGPIPE) == 0 && fcntl(out[1], F_GETFL) == flags);
    require(sigaction(SIGPIPE, NULL, &after) == 0 && before.sa_handler == after.sa_handler);
    /* Also reject a separately unprotected stderr after stdout is prepared by
     * this pipe's trusted owner; partial duplication must be fully cleaned. */
    require(fcntl(out[1], F_SETNOSIGPIPE, 1) == 0);
    require(StruisVPCreate("synthetic-unprotected", "synthetic-owner", 1,
        STRUIS_VP_PYTHON_MAIN, 2, argv, in[0], out[1], err[1], &i, &key) == ENOTSUP && !i);
    require(fcntl(out[1], F_GETNOSIGPIPE) == 1 && fcntl(err[1], F_GETNOSIGPIPE) == 0);
    require(fcntl(out[1], F_GETFL) == flags);
    require(sigaction(SIGPIPE, NULL, &after) == 0 && before.sa_handler == after.sa_handler);
    require(close(in[0]) == 0 && close(in[1]) == 0 && close(out[0]) == 0 && close(out[1]) == 0
        && close(err[0]) == 0 && close(err[1]) == 0);
#endif
}
static uint32_t broken_pipe_and_next(const StruisVPContext *old) {
    stage(40);
    unprotected_output_is_denied();
    int in[2], out[2];
    pipes(in); pipes(out);
    struct sigaction before, after;
    sigset_t mask_before, mask_after;
    require(sigaction(SIGPIPE, NULL, &before) == 0);
    require(pthread_sigmask(SIG_SETMASK, NULL, &mask_before) == 0);
    StruisVirtualPythonInvocation *i = NULL;
    StruisVPContext key;
    make(in[0], out[1], out[1], &i, &key);
    stage(41);
#ifdef __APPLE__
    require(fcntl(out[1], F_GETNOSIGPIPE) == 1);
#endif
    require(key.invocation_id != old->invocation_id);
    require(StruisVPStart(i, old) == EACCES && StruisVPCancel(i, old) == EACCES);
    StruisVPContext wrong = key;
    wrong.generation++;
    require(StruisVPFinished(i, &wrong, 0) == EACCES);
    require(close(in[0]) == 0 && close(out[0]) == 0 && close(out[1]) == 0);
    require(StruisVPStart(i, &key) == 0);
    stage(42);
    size_t accepted = 0;
    require(StruisVPPushOutput(i, &key, STRUIS_VP_STDOUT,
        (const uint8_t *)"closed", 6, &accepted) == 0 && accepted == 6);
    stage(43);
    StruisVPResult result;
    require(StruisVPAwait(i, &key, 2000, &result) == 0
        && result.reason == STRUIS_VP_EXIT_IO_ERROR && result.io_error == EPIPE);
    stage(44);
    require(sigaction(SIGPIPE, NULL, &after) == 0 && before.sa_handler == after.sa_handler);
    require(pthread_sigmask(SIG_SETMASK, NULL, &mask_after) == 0
        && sigismember(&mask_before, SIGPIPE) == sigismember(&mask_after, SIGPIPE));
    require(StruisVPDestroy(i, &key) == 0 && close(in[1]) == 0);
    stage(45);
    return STRUIS_VP_APPLE_PROBE_EPIPE | STRUIS_VP_APPLE_PROBE_NEXT_CONTEXT;
}
uint32_t StruisVPAppleProbe(void) {
    stage(1);
    int previous = 0;
    require(pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous) == 0);
    uint32_t result = transfer();
    (void)cancellation(0);
    result |= STRUIS_VP_APPLE_PROBE_CANCEL_READ;
    StruisVPContext old = cancellation(1);
    result |= STRUIS_VP_APPLE_PROBE_CANCEL_WRITE;
    result |= broken_pipe_and_next(&old);
    regular_redirection();
    require(result == STRUIS_VP_APPLE_PROBE_ALL);
    stage(50);
    require(pthread_setcancelstate(previous, NULL) == 0);
    return result;
}
