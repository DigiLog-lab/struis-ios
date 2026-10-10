/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#if TARGET_OS_IPHONE
/* ios_dup2 stores a redirection as a one-shot pending child tuple that the
 * next builtin or ios_system command consumes. Compound bodies, functions and
 * eval run several commands, so the selected tuple is activated for the whole
 * body and the parent tuple is restored on normal, error and exception exits.
 * Every scope is begun before its setjmp and is not modified afterwards. */
#define STRUIS_DASH_BORROWED 64
struct StruisDashRedirection {
    FILE *parent[3], *active[3];
    int borrowed[STRUIS_DASH_BORROWED], borrowedCount, borrowedAll;
};

/* <&N and >&N make ios_dup2 wrap the shell's own descriptor N in a new FILE.
 * The scope does not own N, so it records these targets for the next Begin
 * and never closes their wrappers. Every redirection list overwrites it. */
static int StruisDashNotedBorrowed[STRUIS_DASH_BORROWED], StruisDashNotedCount, StruisDashNotedAll;
static void StruisDashNoteBorrowed(union node *redirect) {
    StruisDashNotedCount = StruisDashNotedAll = 0;
    for (union node *n = redirect; n; n = n->nfile.next) {
        if ((n->type != NTOFD && n->type != NFROMFD) || n->ndup.dupfd < 0) continue;
        if (StruisDashNotedCount == STRUIS_DASH_BORROWED) StruisDashNotedAll = 1;
        else StruisDashNotedBorrowed[StruisDashNotedCount++] = n->ndup.dupfd;
    }
}

static void StruisDashRedirectionBegin(struct StruisDashRedirection *r) {
    FILE *old[3] = {NULL, NULL, NULL};
    memcpy(r->borrowed, StruisDashNotedBorrowed, sizeof(r->borrowed));
    r->borrowedCount = StruisDashNotedCount; r->borrowedAll = StruisDashNotedAll;
    StruisDashNotedCount = StruisDashNotedAll = 0;
    r->parent[0] = thread_stdin; r->parent[1] = thread_stdout; r->parent[2] = thread_stderr;
    ios_activateChildStreams(&old[0], &old[1], &old[2]);
    r->active[0] = old[0] ? thread_stdin : NULL;
    r->active[1] = old[1] ? thread_stdout : NULL;
    r->active[2] = old[2] ? thread_stderr : NULL;
}

static void StruisDashRedirectionEnd(const struct StruisDashRedirection *r) {
    INTOFF;
    if (r->active[1]) fflush(r->active[1]);
    if (r->active[2] && r->active[2] != r->active[1]) fflush(r->active[2]);
    thread_stdin = r->parent[0]; thread_stdout = r->parent[1]; thread_stderr = r->parent[2];
    for (int i = 0; i < 3; i++) {
        FILE *stream = r->active[i];
        int skip = !stream;
        for (int j = 0; j < 3 && !skip; j++) if (stream == r->parent[j]) skip = 1;
        for (int j = 0; j < i && !skip; j++) if (stream == r->active[j]) skip = 1;
        if (skip) continue;
        /* ios_dup2 can wrap a descriptor the caller still uses (>&2, <&0,
         * <&7 after exec 7<f, or a parent stream). Closing that wrapper would
         * close the shared descriptor, so only private descriptors are closed;
         * a borrowed wrapper is flushed above and its FILE is left open. */
        int fd = fileno(stream), shared = r->borrowedAll || (fd >= 0 && fd <= STDERR_FILENO);
        for (int j = 0; j < r->borrowedCount && !shared; j++)
            if (r->borrowed[j] == fd) shared = 1;
        for (int j = 0; j < 3 && !shared; j++)
            if (r->parent[j] && fileno(r->parent[j]) == fd) shared = 1;
        for (int j = 0; j < i && !shared; j++)
            if (r->active[j] && fileno(r->active[j]) == fd) shared = 1;
        if (!shared) fclose(stream);
    }
    INTON;
}

/* A redirection list that raises a non-EXERROR exception may leave a partial
 * pending tuple; consume and release it before the exception continues. */
static int StruisDashRedirectGuarded(union node *redirect) {
    struct jmploc *volatile previous = handler;
    struct jmploc guard;
    if (setjmp(guard.loc)) {
        struct StruisDashRedirection partial;
        handler = previous;
        StruisDashNoteBorrowed(redirect);
        StruisDashRedirectionBegin(&partial);
        StruisDashRedirectionEnd(&partial);
        longjmp(handler->loc, 1);
    }
    handler = &guard;
    int status = redirectsafe(redirect, REDIR_PUSH);
    handler = previous;
    return status;
}

static int StruisDashEvalRedirected(union node *n, int flags) {
    int failed = StruisDashRedirectGuarded(n->nredir.redirect);
    struct StruisDashRedirection r;
    StruisDashNoteBorrowed(n->nredir.redirect);
    StruisDashRedirectionBegin(&r);
    struct jmploc *volatile previous = handler;
    struct jmploc guard;
    volatile int status = failed;
    int raised = setjmp(guard.loc);
    if (!raised && !failed) {
        handler = &guard;
        status = evaltree(n->nredir.n, flags);
    }
    handler = previous;
    StruisDashRedirectionEnd(&r);
    if (raised) longjmp(handler->loc, 1);
    return status;
}

static int StruisDashEvalFunction(struct funcnode *func, int argc, char **argv, int flags) {
    struct StruisDashRedirection r;
    StruisDashRedirectionBegin(&r);
    struct jmploc *volatile previous = handler;
    struct jmploc guard;
    volatile int raised_by_body = 0;
    int raised = setjmp(guard.loc);
    if (!raised) {
        handler = &guard;
        raised_by_body = evalfun(func, argc, argv, flags);
    }
    handler = previous;
    StruisDashRedirectionEnd(&r);
    if (raised) longjmp(handler->loc, 1);
    return raised_by_body;
}
#endif
