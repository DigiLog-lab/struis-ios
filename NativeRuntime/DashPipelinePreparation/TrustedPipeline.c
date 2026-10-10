/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#define _POSIX_C_SOURCE 200809L
#include "TrustedPipeline.h"
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static struct StruisTrustedDashAPI api;
static pthread_mutex_t poolLock = PTHREAD_MUTEX_INITIALIZER;
static unsigned slotsUsed;
static int configured;
struct Invocation;
struct Stage {
    struct Invocation *owner;
    struct StruisDashStageSnapshot *snapshot;
    FILE *in, *out, *err;
    void *context;
    pthread_t thread;
    unsigned slot;
    int error, code, started, done, retained;
};
struct Invocation {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    size_t count;
    struct Stage stage[STRUIS_SIGNED_DASH_SLOTS];
};
int StruisTrustedDashConfigure(const struct StruisTrustedDashAPI *source) {
    if (!source || !source->retain || !source->release || !source->scopeBegin ||
        !source->scopeEnd || !source->ownedPipe || !source->streams) return EINVAL;
    for (unsigned i = 0; i < STRUIS_SIGNED_DASH_SLOTS; i++)
        if (!source->enter[i] || !source->install[i]) return EINVAL;
    pthread_mutex_lock(&poolLock);
    int error = configured ? EBUSY : 0;
    if (!error) { api = *source; configured = 1; }
    pthread_mutex_unlock(&poolLock);
    return error;
}
int StruisCompoundDashWorkerSpent(void) {
    pthread_mutex_lock(&poolLock);
    int spent = slotsUsed != 0;
    pthread_mutex_unlock(&poolLock);
    return spent;
}
static void closeTuple(FILE *in, FILE *out, FILE *err) {
    FILE *streams[3] = {in, out, err};
    for (unsigned i = 0; i < 3; i++) if (streams[i]) {
        int prior = 0;
        for (unsigned j = 0; j < i; j++) if (streams[j] == streams[i]) prior = 1;
        if (!prior) fclose(streams[i]);
    }
}
static void closeStreams(struct Stage *s) {
    closeTuple(s->in, s->out, s->err);
    s->in = s->out = s->err = NULL;
}
static void *stageRun(void *opaque) {
    struct Stage *s = opaque;
    /* This thread owns its retained snapshot and unique FILE tuple before it
       starts. Never pthread-cancel the evaluator or its native cleanup. */
    int error = api.scopeBegin(s->in, s->out, s->err, s->context);
    if (!error) {
        error = api.install[s->slot](StruisTrustedDashPipeline, NULL);
        if (!error) error = api.enter[s->slot](s->snapshot, &s->code);
        int end = api.scopeEnd();
        if (end) {
            /* Scope still references child streams/state. Preserve everything
               until acknowledged physical worker exit; no slot is reused. */
            s->retained = 1;
            if (!error) error = end;
        }
    }
    if (!s->retained) {
        closeStreams(s);
        api.release(s->snapshot); s->snapshot = NULL;
    }
    pthread_mutex_lock(&s->owner->lock);
    s->error = error; s->done = 1;
    pthread_cond_broadcast(&s->owner->changed);
    pthread_mutex_unlock(&s->owner->lock);
    return NULL;
}
static FILE *duplicateFD(int original, const char *mode) {
    int fd = dup(original);
    if (fd < 0) return NULL;
    FILE *copy = fdopen(fd, mode);
    if (!copy) close(fd);
    return copy;
}
static FILE *duplicate(FILE *stream, const char *mode) { return stream ? duplicateFD(fileno(stream), mode) : NULL; }
int StruisTrustedDashPipeline(const struct StruisDashStageSnapshot *const *snapshots,
                             size_t count, int *result, void *opaque) {
    (void)opaque;
    if (!snapshots || !result || !count || count > STRUIS_SIGNED_DASH_SLOTS) return EINVAL;
    pthread_mutex_lock(&poolLock);
    int ready = configured;
    pthread_mutex_unlock(&poolLock);
    if (!ready) return ENOTSUP;
    FILE *in = NULL, *out = NULL, *err = NULL; void *context = NULL;
    int capture = api.streams(&in, &out, &err, &context);
    if (capture || !in || !out || !err) {
        closeTuple(in, out, err);
        return capture ? capture : EINVAL;
    }
    struct Invocation *job = calloc(1, sizeof(*job));
    if (!job) { closeTuple(in, out, err); return ENOMEM; }
    int error = pthread_mutex_init(&job->lock, NULL);
    if (error) { closeTuple(in, out, err); free(job); return error; }
    error = pthread_cond_init(&job->changed, NULL);
    if (error) { closeTuple(in, out, err); pthread_mutex_destroy(&job->lock); free(job); return error; }
    job->count = count;
    pthread_mutex_lock(&poolLock);
    if (!configured || count > STRUIS_SIGNED_DASH_SLOTS - slotsUsed) error = E2BIG;
    unsigned first = slotsUsed;
    if (!error) slotsUsed += (unsigned)count; /* permanently consumed generation */
    pthread_mutex_unlock(&poolLock);
    int pipes[STRUIS_SIGNED_DASH_SLOTS - 1][2];
    size_t made = 0;
    if (!error) for (; made + 1 < count; made++)
        if (api.ownedPipe(pipes[made])) { error = errno ? errno : EIO; break; }
    if (!error) for (size_t i = 0; i < count; i++) {
        struct Stage *s = &job->stage[i];
        s->owner = job; s->slot = first + (unsigned)i; s->code = 125; s->context = context;
        error = api.retain((struct StruisDashStageSnapshot *)snapshots[i]);
        if (error) break;
        s->snapshot = (struct StruisDashStageSnapshot *)snapshots[i];
        s->in = i ? duplicateFD(pipes[i - 1][0], "r") : duplicate(in, "r");
        s->out = i + 1 < count ? duplicateFD(pipes[i][1], "w") : duplicate(out, "w");
        s->err = err == out && i + 1 == count ? s->out : duplicate(err, "w");
        if (!s->in || !s->out || !s->err) { error = errno ? errno : ENOMEM; break; }
    }
    /* The shell owns its original active/pending tuple. Each stage now owns
       independent duplicates; capture copies are no longer needed, including
       on allocation failure. A timed-out stage retains only its own tuple. */
    closeTuple(in, out, err);
    /* Every pipe and stage resource exists before any evaluator can block. */
    if (!error) for (size_t i = 0; i < count; i++) {
        struct Stage *s = &job->stage[i];
        error = pthread_create(&s->thread, NULL, stageRun, s);
        if (error) break;
        s->started = 1;
    }
    for (size_t i = 0; i < made; i++) { close(pipes[i][0]); close(pipes[i][1]); }
    for (size_t i = 0; i < count; i++) if (!job->stage[i].started) {
        closeStreams(&job->stage[i]);
        api.release(job->stage[i].snapshot); job->stage[i].snapshot = NULL;
    }
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline); deadline.tv_sec += 10;
    int unknown = 0;
    pthread_mutex_lock(&job->lock);
    for (size_t i = 0; i < count; i++) {
        struct Stage *s = &job->stage[i];
        while (s->started && !s->done) {
            int wait = pthread_cond_timedwait(&job->changed, &job->lock, &deadline);
            if (wait) { if (!error) error = wait; unknown = 1; break; }
        }
        if (s->retained) unknown = 1;
        if (s->error && !error) error = s->error;
        if (i + 1 == count && s->done) *result = s->code;
    }
    pthread_mutex_unlock(&job->lock);
    for (size_t i = 0; i < count; i++) if (job->stage[i].started) {
        if (unknown) pthread_detach(job->stage[i].thread);
        else pthread_join(job->stage[i].thread, NULL);
    }
    if (!unknown) { pthread_cond_destroy(&job->changed); pthread_mutex_destroy(&job->lock); free(job); }
    /* An unknown job and its refs are deliberately retained until process exit. */
    return error;
}
