#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
NS_ASSUME_NONNULL_BEGIN
void StruisTerminateWorker(int status);
BOOL StruisPrivateFileAccessDenied(NSString *path);
#if DEBUG && TARGET_OS_SIMULATOR && STRUIS_EXEC_WORKER
// Newly owned pipe only: prepare before sharing; never alters inherited FDs.
int StruisOwnedProviderPipe(int descriptors[2]);
#endif
NS_ASSUME_NONNULL_END
