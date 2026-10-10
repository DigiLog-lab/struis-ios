/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
/* Linux acceptance caller only, never part of a signed product target. */
#include <errno.h>
#include <unistd.h>
#include "shell.h"
#include "nodes.h"
#include "parser.h"
#include "input.h"
#include "options.h"
#include "eval.h"
#include "error.h"
#include "memalloc.h"
#include "init.h"
#include "main.h"
#include "output.h"
#include "StageSnapshot.h"
#ifdef __GLIBC__
extern int *dash_errno;
#endif
int StruisDashHostSnapshot(char *setup, char *script, struct StruisDashStageSnapshot **output) {
    struct jmploc guard;
    handler = &guard;
    if (setjmp(guard.loc)) return EINVAL;
    #ifdef __GLIBC__
    dash_errno = __errno_location();
#endif
    rootpid = getpid();
    StruisDashStageInitializing = 1; init(); StruisDashStageInitializing = 0;
    char *argv[] = {"dash", "-c", "", "fixture-zero", NULL};
    procargs(4, argv);
    evalstring(setup, 0);
    setinputstring(script);
    union node *tree = parsecmd(0);
    if (!tree || tree == NEOF) return EINVAL;
    return StruisDashSnapshotCreate(tree, output);
}

/* Host fork adapter for actual parsed compound-stage proof. This is not the
 * iOS launcher and is never compiled into a product image. */
#include <signal.h>
#include <sys/wait.h>
#include <stdlib.h>
typedef int (*StageEntry)(const struct StruisDashStageSnapshot *, int *);
struct HostPipeline { StageEntry entries[8]; size_t used, capacity; };
static volatile sig_atomic_t hostCancelled;
static void hostCancel(int signalNumber) { (void)signalNumber; hostCancelled = 1; }
static int hostPipeline(const struct StruisDashStageSnapshot *const *snapshots, size_t count, int *result, void *opaque) {
    struct HostPipeline *p = opaque;
    if (count > p->capacity - p->used) return E2BIG;
    int pipes[7][2]; size_t made = 0, started = 0;
    pid_t children[8] = {0};
    int error = 0;
    for (; made + 1 < count; made++) if (pipe(pipes[made])) { error = errno; goto cleanup; }
    for (; started < count; started++) {
        size_t slot = p->used++;
        pid_t child = fork();
        if (child < 0) { error = errno; goto cleanup; }
        if (!child) {
            if (setpgid(0, 0) != 0) _exit(125);
            if (started && dup2(pipes[started - 1][0], STDIN_FILENO) < 0) _exit(125);
            if (started + 1 < count && dup2(pipes[started][1], STDOUT_FILENO) < 0) _exit(125);
            for (size_t i = 0; i < made; i++) { close(pipes[i][0]); close(pipes[i][1]); }
            int code = 125;
            int failure = p->entries[slot](snapshots[started], &code);
            _exit(failure ? 125 : code);
        }
        children[started] = child;
        if (setpgid(child, child) != 0 && errno != EACCES && errno != ESRCH) { started++; error = errno; goto cleanup; }
    }
cleanup:
    for (size_t i = 0; i < made; i++) { close(pipes[i][0]); close(pipes[i][1]); }
    int stopped = 0;
    for (size_t i = 0; i < started; i++) {
        int status = 0;
        pid_t waited;
        for (;;) {
            if ((error || hostCancelled) && !stopped) {
                for (size_t j = 0; j < started; j++) { kill(-children[j], SIGKILL); kill(children[j], SIGKILL); }
                stopped = 1;
            }
            waited = waitpid(children[i], &status, 0);
            if (waited >= 0 || errno != EINTR) break;
        }
        if (waited != children[i]) { error = ECHILD; continue; }
        if (i + 1 == count) *result = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    }
    if (hostCancelled) error = ECANCELED;
    return error;
}
int StruisDashHostPipelineRunFlags(char *script, const StageEntry *entries, size_t capacity, int *code, int flags) {
    if (!script || !entries || !capacity || capacity > 8 || !code) return EINVAL;
    struct HostPipeline context = {.capacity = capacity};
    for (size_t i = 0; i < capacity; i++) context.entries[i] = entries[i];
    int error = StruisDashInstallPipelineLauncher(hostPipeline, &context);
    if (error) return error;
    struct sigaction previous, action = {0};
    volatile int installed = 0;
    struct jmploc guard; handler = &guard;
    if (setjmp(guard.loc)) {
        int normal = exception == EXEXIT || exception == EXEND;
        exitreset(); *code = exitstatus;
        if (installed && sigaction(SIGUSR1, &previous, NULL) != 0) return errno;
        if (StruisDashUninstallPipelineLauncher(&context)) return EBUSY;
        return normal ? 0 : EIO;
    }
    #ifdef __GLIBC__
    dash_errno = __errno_location();
#endif
    rootpid = getpid(); StruisDashStageInitializing = 1; init(); StruisDashStageInitializing = 0;
    char *argv[] = {"dash", "-c", "", "fixture-zero", NULL}; procargs(4, argv);
    action.sa_handler = hostCancel; sigemptyset(&action.sa_mask);
    hostCancelled = 0;
    if (sigaction(SIGUSR1, &action, &previous) != 0) return errno;
    installed = 1;
    *code = evalstring(script, flags);
    if (sigaction(SIGUSR1, &previous, NULL) != 0) return errno;
    return StruisDashUninstallPipelineLauncher(&context);
}

int StruisDashHostPipelineRun(char *script, const StageEntry *entries, size_t capacity, int *code) {
    return StruisDashHostPipelineRunFlags(script, entries, capacity, code, 0);
}
int StruisDashHostEvaluateFlags(char *script, int *code, int flags) {
    if (!script || !code) return EINVAL;
    struct jmploc guard; handler = &guard;
    if (setjmp(guard.loc)) { exitreset(); *code = exitstatus; return 0; }
#ifdef __GLIBC__
    dash_errno = __errno_location();
#endif
    rootpid = getpid(); StruisDashStageInitializing = 1; init(); StruisDashStageInitializing = 0;
    char *argv[] = {"dash", "-c", "", "fixture-zero", NULL}; procargs(4, argv);
    *code = evalstring(script, flags); flushall(); return 0;
}

int StruisDashHostEvaluate(char *script, int *code) { return StruisDashHostEvaluateFlags(script, code, 0); }
