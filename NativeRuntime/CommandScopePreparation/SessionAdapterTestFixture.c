/* Apache-2.0. Harness declarations for selected exact C adapter functions. */
#include <dlfcn.h>
#include <fcntl.h>
#include <stdbool.h>
#define RTLD_SELF ((void *)-3)
#define RTLD_MAIN_ONLY ((void *)-5)
#define NAME_MAX 255
static __thread FILE *thread_stdin;
static __thread void *thread_context;
static bool PythonIsRunning[128],PerlIsRunning[128],dashIsRunning[128],sshIsRunning[128],rsyncIsRunning[128],curlIsRunning,scpIsRunning;
