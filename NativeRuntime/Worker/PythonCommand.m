#import <Foundation/Foundation.h>
#import <ios_system/ios_system.h>
#include <Python/Python.h>
#include <unistd.h>
#include <stdatomic.h>
#include <stdbool.h>
#import "VirtualPythonProviderAdapter.h"

static atomic_bool pythonRunning;
static atomic_ulong pythonGeneration;
static unsigned long pythonThread;

bool hyotan_python_interrupt(void) {
    if (!atomic_load(&pythonRunning)) return false;
    unsigned long generation = atomic_load(&pythonGeneration);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        PyGILState_STATE gil = PyGILState_Ensure();
        if (atomic_load(&pythonRunning) && generation == atomic_load(&pythonGeneration)) {
            int count = PyThreadState_SetAsyncExc(pythonThread, PyExc_KeyboardInterrupt);
            if (count > 1) PyThreadState_SetAsyncExc(pythonThread, NULL);
        }
        PyGILState_Release(gil);
    });
    return true;
}

static BOOL pythonReady;
static NSString *pythonFailure;
extern PyObject *PyInit__hyotan_graphics(void);

static void initializePython(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        PyImport_AppendInittab("_hyotan_graphics", PyInit__hyotan_graphics);
        PyPreConfig preconfig;
        PyPreConfig_InitIsolatedConfig(&preconfig);
        preconfig.utf8_mode = 1;
        PyStatus status = Py_PreInitialize(&preconfig);
        if (PyStatus_Exception(status)) {
            pythonFailure = [NSString stringWithUTF8String:status.err_msg ?: "Python preinitialization failed"];
            return;
        }
        PyConfig config;
        PyConfig_InitIsolatedConfig(&config);
        config.install_signal_handlers = 0;
        config.write_bytecode = 0;
        config.buffered_stdio = 0;
        // iOS extensions load Python resources and frameworks from the containing app.
        NSString *appPath = [NSBundle.mainBundle.bundlePath stringByDeletingLastPathComponent].stringByDeletingLastPathComponent;
        NSBundle *pythonBundle = [NSBundle bundleWithPath:appPath];
        NSString *home = [pythonBundle.resourcePath stringByAppendingPathComponent:@"python"];
        status = PyConfig_SetBytesString(&config, &config.home, home.UTF8String);
        if (!PyStatus_Exception(status)) status = PyConfig_SetBytesString(&config, &config.executable, pythonBundle.executablePath.UTF8String);
        if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
        if (PyStatus_Exception(status)) {
            pythonFailure = [NSString stringWithUTF8String:status.err_msg ?: "Python initialization failed"];
        } else {
            // iOS may initialize sys.executable to an empty string. The framework loader
            // resolves .fwork paths relative to this value, so bind it to the containing app.
            NSString *executableName = [pythonBundle objectForInfoDictionaryKey:@"CFBundleExecutable"];
            NSString *executable = [pythonBundle.bundlePath stringByAppendingPathComponent:executableName];
            PyObject *pythonExecutable = PyUnicode_FromString(executable.UTF8String);
            PySys_SetObject("executable", pythonExecutable);
            Py_DECREF(pythonExecutable);
            NSString *modules = [pythonBundle.resourcePath stringByAppendingPathComponent:@"PythonModules"];
            PyObject *path = PyUnicode_FromString(modules.UTF8String);
            PyList_Insert(PySys_GetObject("path"), 0, path);
            Py_DECREF(path);
            NSString *packages = [pythonBundle.resourcePath stringByAppendingPathComponent:@"PythonPackages"];
            path = PyUnicode_FromString(packages.UTF8String);
            PyList_Insert(PySys_GetObject("path"), 0, path);
            Py_DECREF(path);
            path = PyUnicode_FromString("");
            PyList_Insert(PySys_GetObject("path"), 0, path);
            Py_DECREF(path);
            pythonReady = YES;
            PyEval_SaveThread();
        }
        PyConfig_Clear(&config);
    });
}

static int runPythonCommand(int argc, char **argv, const char *function) {
    initializePython();
    if (!pythonReady) { fprintf(ios_stderr(), "%s\n", pythonFailure.UTF8String); return 1; }
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *os = PyImport_ImportModule("os");
    PyObject *environment = os ? PyObject_GetAttrString(os, "environ") : NULL;
    if (environment) {
        NSArray<NSString *> *entries = environmentAsArray();
        PyObject *cleared = PyObject_CallMethod(environment, "clear", NULL);
        Py_XDECREF(cleared);
        for (NSString *entry in entries) {
            NSRange split = [entry rangeOfString:@"="];
            if (split.location == NSNotFound) continue;
            NSString *key = [entry substringToIndex:split.location];
            NSString *value = [entry substringFromIndex:split.location + 1];
            PyObject *pyValue = PyUnicode_FromString(value.UTF8String);
            PyMapping_SetItemString(environment, key.UTF8String, pyValue);
            Py_DECREF(pyValue);
        }
    }
    Py_XDECREF(environment);
    Py_XDECREF(os);
    FILE *files[] = {ios_stdin(), ios_stdout(), ios_stderr()};
    const char *names[] = {"stdin", "stdout", "stderr"};
    PyObject *saved[3], *streams[3];
    for (int index = 0; index < 3; index++) {
        saved[index] = Py_XNewRef(PySys_GetObject(names[index]));
        streams[index] = PyFile_FromFd(dup(fileno(files[index])), names[index], index ? "w" : "r", index ? 1 : -1, "utf-8", "replace", NULL, 1);
        if (streams[index]) PySys_SetObject(names[index], streams[index]);
    }
    PyObject *args = PyList_New(argc - 1);
    for (int index = 1; index < argc; index++) PyList_SET_ITEM(args, index - 1, PyUnicode_DecodeFSDefault(argv[index]));
    PyObject *module = PyImport_ImportModule("hyotan_runner");
    PyObject *callable = module ? PyObject_GetAttrString(module, function) : NULL;
    pythonThread = PyThread_get_thread_ident();
    atomic_fetch_add(&pythonGeneration, 1);
    atomic_store(&pythonRunning, true);
    PyObject *result = callable ? PyObject_CallOneArg(callable, args) : NULL;
    atomic_store(&pythonRunning, false);
    int code = result ? (int)PyLong_AsLong(result) : 1;
    if (PyErr_Occurred()) { PyErr_Print(); code = 1; }
    Py_XDECREF(result);
    Py_XDECREF(callable);
    Py_XDECREF(module);
    Py_DECREF(args);
    for (int index = 0; index < 3; index++) {
        if (streams[index] && index) { PyObject *r = PyObject_CallMethod(streams[index], "flush", NULL); Py_XDECREF(r); }
        PySys_SetObject(names[index], saved[index]);
        Py_XDECREF(saved[index]);
        Py_XDECREF(streams[index]);
    }
    PyGILState_Release(gil);
    return code;
}

__attribute__((visibility("default"))) int hyotan_python_main(int argc, char **argv) {
    #if DEBUG && TARGET_OS_SIMULATOR
    if (StruisVPHasTestProvider()) return StruisVPRunTestProvider(argc, argv, 1);
    #endif
    return runPythonCommand(argc, argv, "python_main");
}
__attribute__((visibility("default"))) int hyotan_git_main(int argc, char **argv) {
    #if DEBUG && TARGET_OS_SIMULATOR
    if (StruisVPHasTestProvider()) return StruisVPRunTestProvider(argc, argv, 2);
    #endif
    return runPythonCommand(argc, argv, "git_main");
}
