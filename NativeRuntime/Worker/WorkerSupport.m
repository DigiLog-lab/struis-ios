#import "WorkerSupport.h"
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <signal.h>

void StruisTerminateWorker(int status) {
    // ios_system exports _exit/exit/abort as pthread_exit. Resolve the actual
    // system implementation so the worker and native OnceLock really retire.
    void *system = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW | RTLD_LOCAL);
    void (*terminate)(int) = system ? dlsym(system, "_exit") : NULL;
    if (terminate) terminate(status);
    kill(getpid(), SIGKILL);
}

BOOL StruisPrivateFileAccessDenied(NSString *path) {
    void *system = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW | RTLD_LOCAL);
    int (*systemOpen)(const char *, int, ...) = system ? dlsym(system, "open") : NULL;
    if (!systemOpen) return NO;
    for (int mode = 0; mode < 2; mode++) {
        errno = 0;
        int fd = systemOpen(path.fileSystemRepresentation, mode == 0 ? O_RDONLY : O_WRONLY);
        int failure = errno;
        if (fd >= 0) { close(fd); return NO; }
        // A missing file or any unrelated I/O error does not prove isolation.
        if (failure != EPERM && failure != EACCES) return NO;
    }
    return YES;
}

#if DEBUG && TARGET_OS_SIMULATOR && STRUIS_EXEC_WORKER
#import "VirtualPythonProviderAdapter.h"
__attribute__((visibility("default"), used))
int StruisOwnedProviderPipe(int descriptors[2]) {
    if (pipe(descriptors) != 0) return -1;
    // The newly created writer is still exclusive, before any fdopen/dup/thread.
    // Ordinary native commands retain the original pipe creation semantics.
    if (StruisVPHasTestProvider() && fcntl(descriptors[1], F_SETNOSIGPIPE, 1) != 0) {
        int failure = errno;
        close(descriptors[0]); close(descriptors[1]);
        descriptors[0] = descriptors[1] = -1; errno = failure; return -1;
    }
    return 0;
}
#endif
