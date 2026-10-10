/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#include <errno.h>
#include <limits.h>
#include <string.h>
#include <stdatomic.h>
#include <unistd.h>
#include "shell.h"
#include "nodes.h"
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
int StruisDashStageInitializing;
static atomic_uint imageState; /* 0 fresh, 1 configured, 2 control, 3 consumed, 5/6 pipeline running */
static StruisDashPipelineLauncher pipelineLauncher;
static void *pipelineContext;
int StruisDashInstallPipelineLauncher(StruisDashPipelineLauncher launcher, void *context) {
    unsigned expected = 0;
    if (!launcher || !atomic_compare_exchange_strong(&imageState, &expected, 2)) return EBUSY;
    pipelineLauncher = launcher; pipelineContext = context;
    atomic_store(&imageState, 1); return 0;
}
int StruisDashUninstallPipelineLauncher(void *context) {
    unsigned expected = 1;
    if (!atomic_compare_exchange_strong(&imageState, &expected, 2)) return EBUSY;
    if (pipelineContext != context) { atomic_store(&imageState, 1); return EACCES; }
    pipelineLauncher = NULL; pipelineContext = NULL;
    atomic_store(&imageState, 0); return 0;
}
int StruisDashHasPipelineLauncher(void) {
    unsigned state = atomic_load(&imageState);
    return (state == 1 || state == 3 || state == 5 || state == 6) && pipelineLauncher != NULL;
}
int StruisDashPipeline(void *tree, int flags) {
    union node *n = tree;
    if ((flags & ~(EV_EXIT | EV_TESTED)) || !pipelineLauncher || !n || n->type != NPIPE || n->npipe.backgnd) sh_error("unsupported native pipeline operation");
    unsigned previousState = atomic_load(&imageState);
    unsigned expected = previousState;
    if ((previousState != 1 && previousState != 3) ||
        !atomic_compare_exchange_strong(&imageState, &expected, previousState + 4))
        sh_error("native pipeline is already running");
    struct StruisDashStageSnapshot *snapshots[8] = {0};
    size_t count = 0;
    int error = 0, result = 125;
    for (struct nodelist *stage = n->npipe.cmdlist; stage; stage = stage->next) {
        if (count == 8) { error = E2BIG; break; }
        error = StruisDashSnapshotCreate(stage->n, &snapshots[count]);
        if (error) break;
        /* EV_EXIT controls this isolated evaluator's return via EXEND;
         * its guard catches that normal termination. EV_TESTED must survive
         * or compound stages incorrectly apply errexit. EV_NOFORK belongs
         * only to the legacy shared-image launch workaround, not this ABI. */
        snapshots[count]->evaluationFlags = flags;
        count++;
    }
    if (!error && count) error = pipelineLauncher((const struct StruisDashStageSnapshot *const *)snapshots, count, &result, pipelineContext);
    for (size_t i = 0; i < count; i++) StruisDashSnapshotDestroy(snapshots[i]);
    atomic_store(&imageState, previousState);
    if (error == ECANCELED) return 130;
    if (error || !count) sh_error("native pipeline operation failed");
    return result;
}
int StruisDashSnapshotVariables(struct StruisDashStageSnapshot *);
int StruisDashSnapshotFunctions(struct StruisDashStageSnapshot *);
int StruisDashSnapshotAliases(struct StruisDashStageSnapshot *);
void StruisDashImportVariables(const struct StruisDashStageSnapshot *);
void StruisDashImportFunctions(const struct StruisDashStageSnapshot *);
void StruisDashImportAliases(const struct StruisDashStageSnapshot *);
void *StruisDashSnapshotTree(struct StruisDashStageSnapshot *, union node *);
char *StruisDashSnapshotText(struct StruisDashStageSnapshot *s, const char *text) {
    size_t length = strnlen(text, STRUIS_DASH_STAGE_BYTES + 1u);
    if (length >= STRUIS_DASH_STAGE_BYTES || length + 1u > STRUIS_DASH_STAGE_BYTES - s->bytes) return NULL;
    char *copy = malloc(length + 1u);
    if (!copy) return NULL;
    memcpy(copy, text, length + 1u); s->bytes += length + 1u; return copy;
}
int StruisDashSnapshotRetain(struct StruisDashStageSnapshot *s) {
    if (!s || s->abi != STRUIS_DASH_STAGE_ABI) return EINVAL;
    unsigned count = atomic_load(&s->references);
    do { if (!count || count == UINT_MAX) return EOVERFLOW; }
    while (!atomic_compare_exchange_weak(&s->references, &count, count + 1));
    return 0;
}
void StruisDashSnapshotDestroy(struct StruisDashStageSnapshot *s) {
    if (!s || atomic_fetch_sub(&s->references, 1) != 1) return;
    for (size_t i = 0; i < s->variables; i++) free(s->variable[i].text);
    for (size_t i = 0; i < s->functions; i++) freefunc(s->function[i]);
    for (size_t i = 0; i < s->aliases; i++) { free(s->alias[i].name); free(s->alias[i].value); }
    for (size_t i = 0; i < s->arguments; i++) free(s->argument[i]);
    free(s->arg0); freefunc(s->tree); free(s);
}
int StruisDashSnapshotCreate(void *tree, struct StruisDashStageSnapshot **output) {
    if (!tree || !output) return EINVAL;
    *output = NULL;
    if (shellparam.nparam < 0 || shellparam.nparam > STRUIS_DASH_STAGE_ITEMS) return E2BIG;
    struct StruisDashStageSnapshot *s = calloc(1, sizeof(*s));
    if (!s) return ENOMEM;
    atomic_init(&s->references, 1);
    struct jmploc guard;
    struct jmploc *previous = handler;
    int savedInterrupts; SAVEINT(savedInterrupts);
    volatile int error = 0;
    if (setjmp(guard.loc)) { error = ENOMEM; goto end; }
    handler = &guard;
    s->abi = STRUIS_DASH_STAGE_ABI;
    s->status = exitstatus; s->optind = shellparam.optind; s->optoff = shellparam.optoff;
    memcpy(s->options, optlist, sizeof(s->options));
    s->arg0 = StruisDashSnapshotText(s, arg0 ? arg0 : "dash");
    if (!s->arg0) { error = E2BIG; goto end; }
    for (int i = 0; i < shellparam.nparam; i++) {
        s->argument[s->arguments++] = StruisDashSnapshotText(s, shellparam.p[i]);
        if (!s->argument[i]) { error = E2BIG; goto end; }
    }
    error = StruisDashSnapshotVariables(s);
    if (!error) error = StruisDashSnapshotFunctions(s);
    if (!error) error = StruisDashSnapshotAliases(s);
    if (!error) { s->tree = StruisDashSnapshotTree(s, tree); if (!s->tree) error = E2BIG; }
end:
    handler = previous;
    if (error) StruisDashSnapshotDestroy(s); else *output = s;
    RESTOREINT(savedInterrupts);
    return error;
}
int StruisDashStageEnter(const struct StruisDashStageSnapshot *s, int *code) {
    if (!s || !code || s->abi != STRUIS_DASH_STAGE_ABI || !s->tree ||
        s->variables > STRUIS_DASH_STAGE_ITEMS || s->functions > STRUIS_DASH_STAGE_ITEMS ||
        s->aliases > STRUIS_DASH_STAGE_ITEMS || s->arguments > STRUIS_DASH_STAGE_ITEMS ||
        s->bytes > STRUIS_DASH_STAGE_BYTES || (s->evaluationFlags & ~(EV_EXIT | EV_TESTED))) return EINVAL;
    /* A fresh image is consumed once. Reusing mutable dash globals across
     * unrelated stages is forbidden even after an exceptional stage return. */
    unsigned expected = atomic_load(&imageState);
    if (expected > 1 || !atomic_compare_exchange_strong(&imageState, &expected, 3)) return EBUSY;
    struct jmploc guard;
    struct funcnode *volatile local = NULL;
    struct stackmark mark;
    volatile int marked = 0;
    volatile int error = 0;
    *code = 125;
    handler = &guard;
    if (setjmp(guard.loc)) {
        if (exception == EXEXIT || exception == EXEND) { exitreset(); *code = exitstatus; }
        else if (exception == EXINT) *code = 130;
        else *code = 2;
        goto end;
    }
    #ifdef __GLIBC__
    dash_errno = __errno_location();
#endif
    rootpid = getpid(); shlvl = 0;
    StruisDashStageInitializing = 1;
    init();
    StruisDashStageInitializing = 0;
    setstackmark(&mark); marked = 1;
    StruisDashImportVariables(s);
    setparam((char **)s->argument);
    shellparam.optind = s->optind; shellparam.optoff = s->optoff;
    arg0 = savestr(s->arg0);
    memcpy(optlist, s->options, sizeof(s->options));
    StruisDashImportFunctions(s); StruisDashImportAliases(s);
    local = copyfunc(&((struct funcnode *)s->tree)->n);
    exitstatus = s->status;
    *code = evaltree(&local->n, s->evaluationFlags);
end:
    StruisDashStageInitializing = 0;
    flushall();
    if (marked) { exitreset(); popstackmark(&mark); }
    freefunc(local);
    /* All stage-global storage remains with its consumed image until the
     * caller has joined every native child and releases the image. */
    handler = NULL;
    return error;
}
