/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#include <stdbool.h>
#if DEBUG && TARGET_OS_SIMULATOR
NS_ASSUME_NONNULL_BEGIN
int StruisVPPrepareJob(NSString *worker, NSString *owner, NSString *job, uint64_t generation);
void StruisVPEndJob(NSString *job);
bool StruisVPCancelOwner(NSString *owner);
bool StruisVPCancelJob(NSString *worker, NSString *owner, NSString *job, uint64_t generation);
bool StruisVPIsJobCurrent(NSString *job, uint64_t generation);
bool StruisVPHasTestProvider(void);
int StruisVPRunTestProvider(int argc, char **argv, uint32_t function);
NSDictionary<NSString *, id> *StruisVPControl(NSString *worker, NSString *owner,
    NSString *job, uint64_t generation, uint64_t invocation, uint64_t sequence,
    NSString *action, NSData *output, NSData *error, uint32_t capacity, int32_t exitCode);
NS_ASSUME_NONNULL_END
#endif
