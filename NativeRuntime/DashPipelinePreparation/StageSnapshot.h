/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#ifndef STRUIS_DASH_STAGE_SNAPSHOT_H
#define STRUIS_DASH_STAGE_SNAPSHOT_H
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>
#define STRUIS_DASH_STAGE_ABI 3u
#define STRUIS_DASH_STAGE_ITEMS 256u
#define STRUIS_DASH_STAGE_BYTES (1024u * 1024u)
struct StruisDashText { char *text; int flags; };
struct StruisDashAlias { char *name; char *value; };
/* Native trusted-only data. This ABI is never a command, RPC or guest pointer API.
 * The creating image owns all allocations until every stage has returned. */
struct StruisDashStageSnapshot {
    uint32_t abi;
    atomic_uint references;
    size_t bytes, variables, functions, aliases, arguments;
    struct StruisDashText variable[STRUIS_DASH_STAGE_ITEMS];
    void *function[STRUIS_DASH_STAGE_ITEMS];
    struct StruisDashAlias alias[STRUIS_DASH_STAGE_ITEMS];
    char *argument[STRUIS_DASH_STAGE_ITEMS + 1];
    char *arg0;
    char options[17];
    int optind, optoff, status, evaluationFlags;
    void *tree;
};
/* Launcher is fixed by the trusted embedding before evaluation. Before return
 * it must join terminated children or retain every still-live snapshot/stream/
 * image reference and require acknowledged physical worker retirement. */
typedef int (*StruisDashPipelineLauncher)(const struct StruisDashStageSnapshot *const *, size_t, int *, void *);
int StruisDashInstallPipelineLauncher(StruisDashPipelineLauncher launcher, void *context);
int StruisDashUninstallPipelineLauncher(void *context);
int StruisDashHasPipelineLauncher(void);
int StruisDashPipeline(void *tree, int flags);
extern int StruisDashStageInitializing;
int StruisDashSnapshotCreate(void *tree, struct StruisDashStageSnapshot **output);
int StruisDashSnapshotRetain(struct StruisDashStageSnapshot *snapshot);
void StruisDashSnapshotDestroy(struct StruisDashStageSnapshot *snapshot);
int StruisDashStageEnter(const struct StruisDashStageSnapshot *snapshot, int *exit_code);
#endif
