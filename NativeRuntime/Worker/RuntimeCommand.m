#import "RuntimeCommand.h"
#import "WorkerSupport.h"
#import "NativeCommandCapture.h"
#import "CompoundDashPreparation.h"
#import <ios_system/ios_system.h>
#include <stdbool.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <dlfcn.h>
#include <signal.h>
extern bool hyotan_python_interrupt(void);
extern bool hyotan_rg_interrupt(void);
extern int numDashCommands;
static char sessionID[] = "struis-command";

NSDictionary *StruisRunCommand(NSString *command, NSString *directory, NSString *home) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ initializeEnvironment(); sideLoading = false; numPythonInterpreters = 1; numDashCommands = 1; });
    int descriptors[2];
    #if DEBUG && TARGET_OS_SIMULATOR && STRUIS_EXEC_WORKER
    int streamError = StruisOwnedProviderPipe(descriptors);
    #else
    int streamError = pipe(descriptors);
    #endif
    if (streamError != 0) return @{@"exit":@125,@"output":@"Cannot create command streams",@"truncated":@NO,@"compoundDashWorkerSpent":@(StruisCompoundDashWorkerSpent() != 0)};
    FILE *input = tmpfile(), *output = fdopen(descriptors[1], "w");
    if (!input || !output) {
        if (input) fclose(input);
        if (output) fclose(output); else close(descriptors[1]);
        close(descriptors[0]);
        return @{@"exit":@125,@"output":@"Cannot create command streams",@"truncated":@NO,@"compoundDashWorkerSpent":@(StruisCompoundDashWorkerSpent() != 0)};
    }
    // Drain continuously, retaining only a bounded suffix. Large output must not fill a temp file.
    const NSUInteger limit = 96000;
    NSMutableData *data = [NSMutableData dataWithCapacity:limit];
    __block BOOL truncated = NO;
    __block int captureError = 0;
    const int reader = descriptors[0];
    fcntl(reader, F_SETFL, O_NONBLOCK);
    atomic_bool *finished = calloc(1, sizeof(atomic_bool));
    atomic_init(finished, false);
    dispatch_group_t capture = dispatch_group_create();
    dispatch_group_async(capture, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned char suffix[96000];
        size_t length = 0;
        bool clipped = false;
        captureError = StruisCaptureCommandOutput(reader, finished, suffix, sizeof(suffix), &length, &clipped);
        [data appendBytes:suffix length:length];
        truncated = clipped;
        close(reader);
    });
    ios_switchSession(sessionID);
    ios_setContext(sessionID);
    static NSArray<NSString *> *baselineEnvironment;
    if (!baselineEnvironment) baselineEnvironment = [environmentAsArray() copy];
    for (NSString *entry in environmentAsArray()) {
        NSString *key = [entry componentsSeparatedByString:@"="].firstObject;
        ios_unsetenv(key.UTF8String);
    }
    for (NSString *entry in baselineEnvironment) {
        NSRange split = [entry rangeOfString:@"="];
        if (split.location != NSNotFound) ios_setenv([entry substringToIndex:split.location].UTF8String, [entry substringFromIndex:split.location+1].UTF8String, 1);
    }
    ios_setDirectoryURL([NSURL fileURLWithPath:directory isDirectory:YES]);
    ios_setStreams(input, output, output);
    ios_setenv("HOME", home.UTF8String, 1);
    ios_setenv("WORKSPACE", directory.UTF8String, 1);
    ios_setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
    ios_setenv("LANG", "en_US.UTF-8", 1);
    ios_setenv("TERM", "dumb", 1);
    NSString *escaped = [command stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    int preparationError = StruisCompoundDashPrepare(input, output, output, sessionID);
    int code = 125;
    if (!preparationError) {
        pid_t pid = ios_fork();
        code = ios_system([[NSString stringWithFormat:@"dash -c '%@'", escaped] UTF8String]);
        ios_waitpid(pid);
        // The scoped launcher returns admission, while wait publishes the
        // actual child's result into this owner's command status.
        code = ios_getCommandStatus();
        ios_releaseThreadId(pid);
    }
    int finishError = StruisCompoundDashFinish();
    if (preparationError || finishError) code = 125;
    // Commands change process cwd. Never leave Codex in a workspace that Swift can remove.
    if (!finishError) {
        ios_setDirectoryURL([NSURL fileURLWithPath:home isDirectory:YES]);
        chdir(home.UTF8String);
        fflush(output);
        fclose(input); fclose(output);
    }
    // A live scoped child retains the original FILE tuple until worker exit.
    atomic_store_explicit(finished, true, memory_order_release);
    dispatch_group_wait(capture, DISPATCH_TIME_FOREVER);
    free(finished);
    if (captureError != 0) return @{@"exit":@125,@"output":@"Cannot read command output",@"truncated":@YES,@"compoundDashWorkerSpent":@(StruisCompoundDashWorkerSpent() != 0 || finishError != 0)};
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) { // A bounded suffix can start in the middle of a UTF-8 scalar.
        for (NSUInteger skip=1; skip<=3 && skip<data.length && !text; skip++) text=[[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(skip,data.length-skip)] encoding:NSUTF8StringEncoding];
    }
    if (preparationError) text = @"Compound pipeline preparation unavailable";
    else if (finishError) text = @"Compound pipeline worker did not finish";
    return @{@"exit":@(code),@"output":text ?: @"Output is not UTF-8",@"truncated":@(truncated),
             @"compoundDashWorkerSpent":@(StruisCompoundDashWorkerSpent() != 0 || finishError != 0)};
}
void StruisInterruptCommand(void) {
    ios_switchSession(sessionID);
    if (!hyotan_python_interrupt() && !hyotan_rg_interrupt()) ios_kill();
}
