/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#ifndef STRUIS_TRUSTED_DASH_PIPELINE_H
#define STRUIS_TRUSTED_DASH_PIPELINE_H
#include <stdio.h>
#include "StageSnapshot.h"
#define STRUIS_SIGNED_DASH_SLOTS 8u
typedef int (*StruisDashEntry)(const struct StruisDashStageSnapshot *, int *);
struct StruisTrustedDashAPI {
    StruisDashEntry enter[STRUIS_SIGNED_DASH_SLOTS];
    int (*install[STRUIS_SIGNED_DASH_SLOTS])(StruisDashPipelineLauncher, void *);
    int (*retain)(struct StruisDashStageSnapshot *);
    void (*release)(struct StruisDashStageSnapshot *);
    int (*scopeBegin)(FILE *, FILE *, FILE *, void *);
    int (*scopeEnd)(void);
    int (*ownedPipe)(int *);
    /* Capture owned duplicates of effective pending-or-active streams without
       mutating the shell's TLS or redirect ownership. Preserve FILE aliases. */
    int (*streams)(FILE **, FILE **, FILE **, void **);
};
/* Fixed trusted ABI only; no paths, symbols or pointers accepted from guests. */
int StruisTrustedDashConfigure(const struct StruisTrustedDashAPI *);
int StruisTrustedDashPipeline(const struct StruisDashStageSnapshot *const *, size_t, int *, void *);
int StruisCompoundDashWorkerSpent(void);
#endif
