/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#include "StageSnapshot.h"
#include <errno.h>
extern char *StruisDashSnapshotText(struct StruisDashStageSnapshot *, const char *);
int StruisDashSnapshotAliases(struct StruisDashStageSnapshot *s) {
    for (unsigned i = 0; i < ATABSIZE; i++) for (struct alias *a = atab[i]; a; a = a->next) {
        if (a->flag & ALIASDEAD) continue;
        if (s->aliases == STRUIS_DASH_STAGE_ITEMS) return E2BIG;
        struct StruisDashAlias *item = &s->alias[s->aliases++];
        item->name = StruisDashSnapshotText(s, a->name);
        item->value = StruisDashSnapshotText(s, a->val);
        if (!item->name || !item->value) return E2BIG;
    }
    return 0;
}
void StruisDashImportAliases(const struct StruisDashStageSnapshot *s) {
    for (size_t i = 0; i < s->aliases; i++) setalias(s->alias[i].name, s->alias[i].value);
}
