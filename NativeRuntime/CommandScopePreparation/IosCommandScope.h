/* Apache-2.0. Private trusted stage embedding ABI; never guest message fields. */
#ifndef STRUIS_IOS_COMMAND_SCOPE_H
#define STRUIS_IOS_COMMAND_SCOPE_H
#include <stdio.h>
/* Caller owns all three FILEs until successful End. On EBUSY/timeout keep them
   alive and retire the captured worker before releasing stage resources. */
int StruisIosCommandScopeBegin(FILE *input, FILE *output, FILE *errorStream, void *context);
int StruisIosCommandScopeEnd(void);
/* Captures actual pending ios_dup2 redirects into independently owned FILEs.
   Does not mutate parent TLS or its FILE ownership. Caller closes every distinct
   returned pointer exactly once, including failure/timeout after acquisition. */
int StruisIosCommandPipelineStreams(FILE **input, FILE **output, FILE **errorStream, void **context);
#endif
