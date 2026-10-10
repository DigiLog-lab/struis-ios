/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#import "CompoundDashPreparation.h"
#include <TargetConditionals.h>
#if DEBUG && TARGET_OS_SIMULATOR && STRUIS_EXEC_WORKER && STRUIS_COMPOUND_DASH_PREPARATION
#import <Foundation/Foundation.h>
#import <ios_system/ios_system.h>
#import "VirtualPythonProviderAdapter.h"
#import "WorkerSupport.h"
#include "../DashPipelinePreparation/TrustedPipeline.h"
#include <dlfcn.h>
#include <errno.h>
static void *rootImage;
static void *stageImage[STRUIS_SIGNED_DASH_SLOTS];
static int (*rootInstall)(StruisDashPipelineLauncher, void *);
static int (*rootUninstall)(void *);
static int (*scopeBegin)(FILE *, FILE *, FILE *, void *);
static int (*scopeEnd)(void);
static int (*captureStreams)(FILE **, FILE **, FILE **, void **);
static int initialized, initializationError;
static __thread int active;
static int streams(FILE **in, FILE **out, FILE **err, void **context) {
    return captureStreams(in, out, err, context);
}
static NSString *frameworkDirectory(void) {
    NSURL *bundle = NSBundle.mainBundle.bundleURL;
    if ([bundle.pathExtension isEqualToString:@"appex"])
        bundle = bundle.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    return [bundle.path stringByAppendingPathComponent:@"Frameworks"];
}
static void *load(NSString *directory, NSString *name) {
    NSString *relative = [NSString stringWithFormat:@"%@.framework/%@", name, name];
    return dlopen([directory stringByAppendingPathComponent:relative].fileSystemRepresentation,
                  RTLD_NOW | RTLD_LOCAL);
}
static int initialize(void) {
    if (initialized) return initializationError;
    initialized = 1;
    initializationError = ENOTSUP;
    NSString *directory = frameworkDirectory();
    rootImage = load(directory, @"dash");
    if (!rootImage) return initializationError;
    rootInstall = dlsym(rootImage, "StruisDashInstallPipelineLauncher");
    rootUninstall = dlsym(rootImage, "StruisDashUninstallPipelineLauncher");
    struct StruisTrustedDashAPI table = {0};
    table.retain = dlsym(rootImage, "StruisDashSnapshotRetain");
    table.release = dlsym(rootImage, "StruisDashSnapshotDestroy");
    scopeBegin = dlsym(RTLD_DEFAULT, "StruisIosCommandScopeBegin");
    scopeEnd = dlsym(RTLD_DEFAULT, "StruisIosCommandScopeEnd");
    captureStreams = dlsym(RTLD_DEFAULT, "StruisIosCommandPipelineStreams");
    if (!rootInstall || !rootUninstall || !scopeBegin || !scopeEnd || !captureStreams) return initializationError;
    for (unsigned i = 0; i < STRUIS_SIGNED_DASH_SLOTS; i++) {
        /* Finite native selector; never a caller/guest supplied image name. */
        NSString *name = [NSString stringWithFormat:@"HyotanDashStage%u", i];
        stageImage[i] = load(directory, name);
        if (!stageImage[i]) return initializationError;
        table.enter[i] = dlsym(stageImage[i], "StruisSignedDashStageEnter");
        table.install[i] = dlsym(stageImage[i], "StruisSignedDashStageInstallLauncher");
    }
    table.scopeBegin = scopeBegin; table.scopeEnd = scopeEnd;
    table.ownedPipe = StruisOwnedProviderPipe; table.streams = streams;
    initializationError = StruisTrustedDashConfigure(&table);
    /* Images intentionally stay loaded for this physical worker generation. */
    return initializationError;
}
int StruisCompoundDashPrepare(FILE *in, FILE *out, FILE *err, void *context) {
    if (!StruisVPHasTestProvider()) return 0;
    if (active) return EBUSY;
    int error = initialize();
    if (error) return error;
    error = scopeBegin(in, out, err, context);
    if (error) return error;
    active = 1;
    error = rootInstall(StruisTrustedDashPipeline, NULL);
    if (error) return error;
    return 0;
}
int StruisCompoundDashFinish(void) {
    if (!active) return 0;
    int uninstall = rootUninstall(NULL);
    int end = scopeEnd();
    if (!end) active = 0;
    return end ? end : uninstall;
}
#else
int StruisCompoundDashPrepare(FILE *in, FILE *out, FILE *err, void *context) {
    (void)in; (void)out; (void)err; (void)context; return 0;
}
int StruisCompoundDashFinish(void) { return 0; }
#endif
