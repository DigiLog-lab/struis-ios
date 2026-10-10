/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#import "VirtualPythonProviderAdapter.h"
#if DEBUG && TARGET_OS_SIMULATOR
#import "VirtualPythonCommandBridge.h"
#import "WorkerSupport.h"
#import <ios_system/ios_system.h>
#include <errno.h>
#include <pthread.h>
#include <time.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <stdatomic.h>
#include <sys/stat.h>
#ifdef write
#undef write
#endif
extern ssize_t write(int, const void *, size_t);

// Fixed numeric diagnostics only. Each stage emits at most four small records;
// no argv, paths, identities, payloads, or ios_system fprintf/TLS routing.
static atomic_uint diagnostic_counts[8];
static void diagnostic(unsigned stage, int error) {
    if (stage >= 8 || atomic_fetch_add(&diagnostic_counts[stage], 1) >= 4) return;
    struct stat metadata;
    if (fstat(STDERR_FILENO, &metadata) != 0 || !S_ISREG(metadata.st_mode)) return;
    char line[96]; int length = snprintf(line, sizeof(line), "STRUIS_VP_PROVIDER stage=%u errno=%d\n", stage, error);
    if (length <= 0 || length >= (int)sizeof(line)) return;
    size_t offset = 0;
    for (unsigned attempt = 0; attempt < 4 && offset < (size_t)length; attempt++) {
        ssize_t count = write(STDERR_FILENO, line + offset, (size_t)length - offset);
        if (count > 0) offset += (size_t)count;
        else if (count < 0 && errno == EINTR) continue;
        else break;
    }
}
// A trusted command owns the job. Model code never sets these identities or
// sees the C instance. Independent XPC sessions only hold this lock during
// bounded C operations; the native dash command waits outside it.
static NSLock *providerLock;
static NSString *workerID, *ownerID, *jobID;
static NSString *completedWorker, *completedOwner, *completedJob;
static uint64_t completedGeneration;
static int32_t completedExit;
static uint64_t jobGeneration, lastGeneration, nextSequence, lastCompletedInvocation;
static BOOL cancelled;
static double heartbeat;
static StruisVirtualPythonInvocation *invocation;
static StruisVPContext context;
static void initializeLock(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ providerLock = [NSLock new]; });
}
static double clockNow(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) { StruisTerminateWorker(125); for (;;) {} }
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}
static void retire(void) { StruisTerminateWorker(130); for (;;) {} }
static BOOL identity(NSString *worker, NSString *owner, NSString *job, uint64_t generation) {
    return jobID && [workerID isEqual:worker] && [ownerID isEqual:owner]
        && [jobID isEqual:job] && jobGeneration == generation;
}
int StruisVPPrepareJob(NSString *worker, NSString *owner, NSString *job, uint64_t generation) {
    initializeLock();
    if (!worker.length || !owner.length || !job.length ||
        [worker lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= 128 ||
        [owner lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= 256 || generation == 0) return EINVAL;
    [providerLock lock];
    int error = 0;
    if (jobID || invocation) error = EBUSY;
    else if (generation <= lastGeneration) error = EACCES;
    else {
        workerID = [worker copy]; ownerID = [owner copy]; jobID = [job copy];
        jobGeneration = lastGeneration = generation;
        cancelled = NO; lastCompletedInvocation = 0;
        completedWorker = completedOwner = completedJob = nil; heartbeat = clockNow();
    }
    [providerLock unlock];
    diagnostic(1, error);
    return error;
}
void StruisVPEndJob(NSString *job) {
    initializeLock(); [providerLock lock];
    if ([jobID isEqual:job]) {
        if (invocation) retire(); // Returning cannot release live C storage.
        workerID = ownerID = jobID = nil;
    }
    [providerLock unlock];
}
bool StruisVPCancelOwner(NSString *owner) {
    initializeLock();
    int previous; pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous);
    [providerLock lock];
    BOOL matches = jobID && [ownerID isEqual:owner];
    if (matches) {
        cancelled = YES;
        if (invocation) StruisVPCancel(invocation, &context);
    }
    [providerLock unlock];
    pthread_setcancelstate(previous, NULL);
    return matches;
}
bool StruisVPHasTestProvider(void) {
    initializeLock(); [providerLock lock];
    BOOL armed = jobID != nil;
    [providerLock unlock]; return armed;
}
bool StruisVPCancelJob(NSString *worker, NSString *owner, NSString *job, uint64_t generation) {
    initializeLock();
    int previous; pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous);
    [providerLock lock];
    BOOL matches = identity(worker, owner, job, generation);
    if (matches) {
        cancelled = YES;
        if (invocation) StruisVPCancel(invocation, &context);
    }
    [providerLock unlock]; pthread_setcancelstate(previous, NULL);
    return matches;
}
bool StruisVPIsJobCurrent(NSString *job, uint64_t generation) {
    initializeLock(); [providerLock lock];
    BOOL matches = [jobID isEqual:job] && jobGeneration == generation;
    [providerLock unlock]; return matches;
}
int StruisVPRunTestProvider(int argc, char **argv, uint32_t function) {
    initializeLock();
    int previous; pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous);
    [providerLock lock];
    int error = cancelled ? ECANCELED : !jobID ? EACCES : invocation ? EBUSY : 0;
    StruisVirtualPythonInvocation *local = NULL;
    StruisVPContext key = {0};
    if (!error) error = StruisVPCreate(workerID.UTF8String, ownerID.UTF8String,
        jobGeneration, function, argc, (const char *const *)argv,
        fileno(ios_stdin()), fileno(ios_stdout()), fileno(ios_stderr()), &local, &key);
    diagnostic(3, error);
    if (!error) error = StruisVPStart(local, &key);
    diagnostic(4, error);
    if (!error) {
        invocation = local; context = key; nextSequence = 1; heartbeat = clockNow();
    }
    [providerLock unlock];
    if (error) {
        if (local) {
            StruisVPCancel(local, &key);
            StruisVPResult failed;
            if (StruisVPAwait(local, &key, 2000, &failed) || StruisVPDestroy(local, &key)) retire();
        }
        pthread_setcancelstate(previous, NULL);
        return error == ECANCELED ? 130 : 125;
    }
    StruisVPResult result;
    double cancelDeadline = 0;
    for (;;) {
        error = StruisVPAwait(local, &key, 100, &result);
        if (!error) break;
        if (error != ETIMEDOUT) retire();
        [providerLock lock];
        if (cancelled || clockNow() - heartbeat > 5) {
            cancelled = YES;
            StruisVPCancel(local, &key);
            if (!cancelDeadline) cancelDeadline = clockNow() + 2;
        }
        [providerLock unlock];
        if (cancelDeadline && clockNow() > cancelDeadline) retire();
    }
    [providerLock lock];
    // Controls hold the same lock around every dereference. Unpublish before
    // destroy; no late discovery/control can acquire a freed pointer.
    invocation = NULL;
    memset(&context, 0, sizeof(context));
    int destroyError = StruisVPDestroy(local, &key);
    diagnostic(5, destroyError);
    if (destroyError) retire();
    // Published only after all shuttles joined and storage was destroyed.
    lastCompletedInvocation = key.invocation_id; completedExit = result.exit_code;
    completedWorker = workerID; completedOwner = ownerID; completedJob = jobID;
    completedGeneration = jobGeneration;
    [providerLock unlock];
    pthread_setcancelstate(previous, NULL);
    return result.exit_code;
}
NSDictionary<NSString *, id> *StruisVPControl(NSString *worker, NSString *owner,
    NSString *job, uint64_t generation, uint64_t requestedInvocation, uint64_t sequence,
    NSString *action, NSData *output, NSData *errors, uint32_t capacity, int32_t code) {
    initializeLock();
    int previous; pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous);
    [providerLock lock];
    NSMutableDictionary *reply = [@{@"errorCode": @0, @"sequence": @(sequence)} mutableCopy];
    int error = 0;
    BOOL completionIdentity = [action isEqual:@"completion"] &&
        [completedWorker isEqual:worker] && [completedOwner isEqual:owner] &&
        [completedJob isEqual:job] && completedGeneration == generation;
    if (!identity(worker, owner, job, generation) && !completionIdentity) { error = EACCES; diagnostic(2, error); }
    else if ([action isEqual:@"completion"]) {
        // Read-only terminal confirmation; never advances the data sequence.
        if (!requestedInvocation || sequence || output.length || errors.length || capacity) error = EINVAL;
        else if (lastCompletedInvocation == requestedInvocation) {
            reply[@"invocationID"] = @(requestedInvocation); reply[@"completed"] = @YES;
            reply[@"exitCode"] = @(completedExit);
        } else if (invocation && context.invocation_id == requestedInvocation) error = EAGAIN;
        else error = EACCES;
    }
    else if (cancelled) error = ECANCELED;
    else if (output.length > STRUIS_VP_MAX_FRAME || errors.length > STRUIS_VP_MAX_FRAME ||
        capacity > STRUIS_VP_MAX_FRAME) error = EINVAL;
    else if (!invocation) error = EAGAIN;
    else if ([action isEqual:@"discover"]) {
        if (requestedInvocation || sequence || output.length || errors.length) error = EINVAL;
        else {
            uint32_t function = 0; size_t argc = 0;
            error = StruisVPDescribe(invocation, &context, &function, &argc);
            NSMutableArray *args = [NSMutableArray array];
            uint8_t bytes[STRUIS_VP_MAX_ARG_LENGTH + 1];
            for (size_t n = 0; !error && n < argc; n++) {
                size_t required = 0;
                error = StruisVPArgument(invocation, &context, n, bytes, sizeof(bytes), &required);
                if (!error) [args addObject:[NSData dataWithBytes:bytes length:required - 1]];
            }
            if (!error) { reply[@"function"] = @(function); reply[@"argv"] = args; }
        }
    } else if (requestedInvocation != context.invocation_id) error = EACCES;
    else if (sequence != nextSequence || nextSequence == UINT64_MAX) error = EALREADY;
    else {
        nextSequence++; // No replay after unknown acknowledgement, even on error.
        if ([action isEqual:@"exchange"]) {
            size_t accepted = 0;
            error = StruisVPPushOutput(invocation, &context, STRUIS_VP_STDOUT,
                output.bytes, output.length, &accepted);
            reply[@"stdoutAccepted"] = @(accepted);
            if (error == EAGAIN) error = 0;
            accepted = 0;
            if (!error) error = StruisVPPushOutput(invocation, &context, STRUIS_VP_STDERR,
                errors.bytes, errors.length, &accepted);
            reply[@"stderrAccepted"] = @(accepted);
            if (error == EAGAIN) error = 0;
            uint8_t input[STRUIS_VP_MAX_FRAME]; size_t count = 0; uint32_t eof = 0;
            if (!error && capacity) {
                error = StruisVPPullStdin(invocation, &context, input, capacity, &count, &eof);
                if (error == EAGAIN) error = 0;
                reply[@"stdin"] = [NSData dataWithBytes:input length:count];
                reply[@"stdinEOF"] = @(eof);
            }
        } else if ([action isEqual:@"finish"]) error = StruisVPFinished(invocation, &context, code);
        else if ([action isEqual:@"cancel"]) { cancelled = YES; error = StruisVPCancel(invocation, &context); }
        else error = EINVAL;
    }
    if (![action isEqual:@"completion"] && invocation && identity(worker, owner, job, generation) && !cancelled &&
        ([action isEqual:@"discover"] || requestedInvocation == context.invocation_id)) {
        reply[@"invocationID"] = @(context.invocation_id);
        StruisVPStatus status;
        if (!StruisVPStatusRead(invocation, &context, &status)) {
            reply[@"stdoutCredit"] = @(status.stdout_credit);
            reply[@"stderrCredit"] = @(status.stderr_credit);
        }
    }
    if (!error) heartbeat = clockNow();
    reply[@"errorCode"] = @(error);
    [providerLock unlock];
    pthread_setcancelstate(previous, NULL);
    return reply;
}
#endif
