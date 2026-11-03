// The model API is called from Swift; commands run in the Exec extension.
#include <stdio.h>
#include <sqlite3.h>
#include <zlib.h>

// Trusted workspace operations (statically linked libhyotan_operations.a); no command implementation.
#include "../NativeRuntime/NativeLibrary/include-operations/HyotanOperations.h"

// OS-only numeric host telemetry; no model or command runtime dependency.
#import "../NativeRuntime/Worker/NativeMemory.h"
