/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#include "StageSnapshot.h"
#include <errno.h>
extern char *StruisDashSnapshotText(struct StruisDashStageSnapshot *, const char *);
int StruisDashSnapshotVariables(struct StruisDashStageSnapshot *s) {
    for (unsigned i = 0; i < VTABSIZE; i++) for (struct var *v = vartab[i]; v; v = v->next) {
        if (s->variables == STRUIS_DASH_STAGE_ITEMS) return E2BIG;
        struct StruisDashText *item = &s->variable[s->variables++];
        item->flags = v->flags & (VEXPORT | VREADONLY | VUNSET);
        item->text = StruisDashSnapshotText(s, v->text);
        if (!item->text) return E2BIG;
    }
    return 0;
}
void StruisDashImportVariables(const struct StruisDashStageSnapshot *s) {
    /* Remove environment-only entries absent in the parent; retain special
     * variables' native callbacks and static storage bookkeeping. */
    for (unsigned i = 0; i < VTABSIZE; i++) {
        struct var **link = &vartab[i];
        while (*link) {
            struct var *v = *link;
            if (v->flags & VSTRFIXED) {
                size_t length = strcspn(v->text, "=");
                char *name = ckmalloc(length + 1);
                memcpy(name, v->text, length); name[length] = 0;
                if (!(v->flags & (VTEXTFIXED | VSTACK))) free((char *)v->text);
                v->text = name; v->flags = VSTRFIXED | VUNSET;
                link = &v->next;
            } else {
                *link = v->next;
                if (!(v->flags & (VTEXTFIXED | VSTACK))) free((char *)v->text);
                free(v);
            }
        }
    }
    for (size_t i = 0; i < s->variables; i++)
        setvareq(s->variable[i].text, s->variable[i].flags);
}
