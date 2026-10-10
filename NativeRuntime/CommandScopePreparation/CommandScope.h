/* Apache-2.0. Trusted preparation only; not a filesystem or cwd boundary. */
#ifndef STRUIS_COMMAND_SCOPE_H
#define STRUIS_COMMAND_SCOPE_H
#include <pthread.h>
#include <signal.h>
#include <sys/types.h>
int StruisCommandScopeBegin(void);
int StruisCommandScopeEnd(void);
int StruisCommandScopeEnabled(void);
pid_t *StruisCommandScopePidAddress(void);
pid_t StruisCommandScopeFork(void);
int StruisCommandScopeCapture(pid_t *child);
int StruisCommandScopeAdopt(pid_t child);
void StruisCommandScopeResult(int result);
void StruisCommandScopeFinish(void);
void StruisCommandScopeLaunchFailed(pid_t child, int error);
int StruisCommandScopeWait(pid_t child, int nohang, int *result);
int StruisCommandScopeStatus(void);
pid_t StruisCommandScopeCurrentPid(void);
int StruisCommandScopeEnvironmentIndex(pid_t id);
int StruisCommandScopeObserve(pid_t child, int *running);
int StruisCommandScopeCanEnd(void);
pthread_t StruisCommandScopeThread(pid_t child);
int StruisCommandScopeSignal(pid_t child, int signal);
#endif
