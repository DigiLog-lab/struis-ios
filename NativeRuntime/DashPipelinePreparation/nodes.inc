/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#include "StageSnapshot.h"
#include "stage_ast_validate.inc"
void *StruisDashSnapshotTree(struct StruisDashStageSnapshot *s, union node *n) {
    /* Validate fixed typed nodes and strings before the pinned copier's signed
     * size counters or recursive traversal can exceed their finite budget. */
    size_t bytes = offsetof(struct funcnode, n), nodes = 0;
    if (!StruisDashValidateNode(n, &bytes, &nodes, 0) ||
        bytes > STRUIS_DASH_STAGE_BYTES - s->bytes) return NULL;
    void *copy = copyfunc(n);
    s->bytes += bytes;
    return copy;
}
