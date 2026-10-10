// Codex runs in the app process from NativeCodexHost.framework; commands run in the Exec extension.
#include <stdio.h>
#include <sqlite3.h>
#include <zlib.h>

// Trusted workspace operations and the in-process Codex server; no command implementation.
#include "../NativeRuntime/NativeCodex/include-operations/HyotanOperations.h"
#include "../NativeRuntime/Worker/CodexBridge.h"

// OS-only numeric host telemetry; no model or command runtime dependency.
#import "../NativeRuntime/Worker/NativeMemory.h"
