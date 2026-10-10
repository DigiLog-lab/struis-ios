/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#include "StageSnapshot.h"
#include <errno.h>
extern void *StruisDashSnapshotTree(struct StruisDashStageSnapshot *, union node *);
int StruisDashSnapshotFunctions(struct StruisDashStageSnapshot *s) {
    for (unsigned i = 0; i < CMDTABLESIZE; i++) for (struct tblentry *e = cmdtable[i]; e; e = e->next) {
        if (e->cmdtype != CMDFUNCTION) continue;
        if (s->functions == STRUIS_DASH_STAGE_ITEMS) return E2BIG;
        void *tree = StruisDashSnapshotTree(s, &e->param.func->n);
        if (!tree) return E2BIG;
        s->function[s->functions++] = tree;
    }
    return 0;
}
void StruisDashImportFunctions(const struct StruisDashStageSnapshot *s) {
    for (size_t i = 0; i < s->functions; i++)
        defun(&((struct funcnode *)s->function[i])->n);
}
