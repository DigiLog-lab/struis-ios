#!/usr/bin/env python3
"""Build the same BSD dash port for ARM64 iOS and ARM64 Simulator.

The GPL build-time mksignames generator is not used. Signal-name data is
generated independently from Python's Darwin signal constants below.
"""
import os
import hashlib
import importlib.util
import json
import pathlib
import plistlib
import shutil
import signal
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
VENDOR = ROOT / "Vendor"
SOURCE = VENDOR / "dash-source"
REVISION = "3da49bb7ac15458ea4f554b589dde5197816f6ba"

def run(args, **kwargs):
    subprocess.run(args, check=True, **kwargs)

selection = os.environ.get("STRUIS_COMPOUND_DASH_PREPARATION", "0")
if selection not in ("0", "1"):
    raise RuntimeError("STRUIS_COMPOUND_DASH_PREPARATION must be 0 or 1")
PREPARATION = selection == "1"

def prepare_makefile(text, preparation):
    """Patch the configured pinned graph; compile stage through normal make CC.

    Automake emits dash_DEPENDENCIES separately from dash_LDADD. Changing only
    the link inputs does not schedule compilation, even when stage.c exists.
    """
    text = text.replace("HELPERS = mkinit mksyntax mknodes mksignames", "HELPERS = mkinit mksyntax mknodes")
    text = text.replace("signames.c: mksignames\n\t$(AM_V_GEN)./$^", "signames.c:\n\t@test -f signames.c")
    if preparation:
        for name in ("dash_LDADD", "dash_DEPENDENCIES"):
            original = name + " = builtins.o init.o nodes.o signames.o syntax.o"
            if text.count(original + "\n") != 1:
                raise RuntimeError("pinned configured dash graph changed: " + name)
            text = text.replace(original + "\n", original + " stage.o\n")
        # LDADD's original inputs are all generated sources; stage.c is an
        # overlay source and must survive make clean so a rebuild can compile it.
        generated = "$(patsubst %.o,%.c,$(dash_LDADD))"
        if text.count(generated) != 1:
            raise RuntimeError("pinned configured dash clean graph changed")
        text = text.replace(generated, "$(patsubst %.o,%.c,$(filter-out stage.o,$(dash_LDADD)))")
        # Direct stage.o builds and parallel recursive all builds both require
        # generated headers. The existing .c.o recipe uses configured COMPILE,
        # including CC/CPPFLAGS/CFLAGS and the SDK target; no custom object build.
        text += "\nstage.o: stage.c StageSnapshot.h $(BUILT_SOURCES) $(top_builddir)/config.h\n"
    return text

def prepare_port_sources(source, work, preparation):
    # Without libedit, upstream reads the application's fd 0 rather than
    # ios_system's session input. Keep shell input attached to this session.
    input_source = work / "src/input.c"
    input_source.write_text((source / "src/input.c").read_text().replace(
        "read(parsefile->fd, buf, IBUFSIZ - 1)",
        "read(parsefile->fd == 0 ? fileno(thread_stdin) : parsefile->fd, buf, IBUFSIZ - 1)")
        .replace("basepf.nextc = basepf.buf = basebuf;",
                 "popallfiles();\n\tbasepf.lleft = basepf.nleft = basepf.unget = 0;\n\tbasepf.nextc = basepf.buf = basebuf;"))
    variables = work / "src/var.c"
    variables.write_text((source / "src/var.c").read_text()
        .replace('INCLUDE "var.h"', 'INCLUDE "var.h"\nINCLUDE "ios_error.h"')
        .replace("for (envp = environ ; *envp ; envp++)", "for (envp = environmentVariables(ios_currentPid()) ; *envp ; envp++)")
        # Each exec command gets a fresh variable table. The library survives
        # thread exit, including exported/readonly variables from the last call.
        .replace("vp = varinit;", """static struct var defaults[sizeof(varinit) / sizeof(varinit[0])];
        static int initialized;
        if (!initialized) {
            memcpy(defaults, varinit, sizeof(varinit));
            initialized = 1;
        } else {
            for (unsigned i = 0; i < VTABSIZE; i++) {
                struct var *current = vartab[i];
                while (current) {
                    struct var *next = current->next;
                    if (!(current->flags & (VTEXTFIXED | VSTACK))) ckfree(current->text);
                    if (!(current->flags & VSTRFIXED)) ckfree(current);
                    current = next;
                }
                vartab[i] = NULL;
            }
            memcpy(varinit, defaults, sizeof(varinit));
        }
        vp = varinit;""")
        .replace("setvareq(*envp, VEXPORT|VTEXTFIXED);", "setvareq(savestr(*envp), VEXPORT);"))
    commands = work / "src/exec.c"
    commands.write_text((source / "src/exec.c").read_text().replace(
        "\t/* We have to search path. */",
        "\t/* Signed in-process commands have no executable file in PATH. */\n"
        "\tif (ios_executable(name)) {\n"
        "\t\tentry->cmdtype = CMDNORMAL;\n\t\tentry->u.index = -1;\n\t\treturn;\n\t}\n"
        "\t/* We have to search path. */"))
    # Pass dash's exported environment through ios_system's execve API.
    evaluation = work / "src/eval.c"
    evaluation_text = (source / "src/eval.c").read_text()
    bail = "bail:\n\t\texitstatus = status;\n"
    if evaluation_text.count(bail) != 1:
        raise RuntimeError("dash eval.c no longer has the expected bail label")
    evaluation.write_text(evaluation_text.replace(
        "ios_execv(argv[0], argv);", "ios_execve(argv[0], argv, environment());")
        # A pipeline stage that never starts (command not found, redirection
        # error) must still release the pipe ios_dup2 handed it. Otherwise the
        # next stage never sees EOF: `pdftotext x | sed` waited forever.
        .replace(bail, bail + """#if TARGET_OS_IPHONE
\t\t{
\t\t\tFILE *old_stdin = NULL, *old_stdout = NULL, *old_stderr = NULL;
\t\t\tios_activateChildStreams(&old_stdin, &old_stdout, &old_stderr);
\t\t\tif (old_stdin != NULL)
\t\t\t\tthread_stdin = old_stdin;
\t\t\tif (old_stderr != NULL) {
\t\t\t\tif (thread_stderr != thread_stdout)
\t\t\t\t\tfclose(thread_stderr);
\t\t\t\tthread_stderr = old_stderr;
\t\t\t}
\t\t\tif (old_stdout != NULL) {
\t\t\t\tfclose(thread_stdout);
\t\t\t\tthread_stdout = old_stdout;
\t\t\t}
\t\t}
#endif
"""))
    # A simulator-only trusted callback prepares newly owned pipeline writers
    # before ios_dup2 publishes them. Release/device and ordinary jobs preserve
    # original pipe semantics; no libc interposition or inherited-FD mutation.
    pipe_helper = """
#include <dlfcn.h>
#include <TargetConditionals.h>
static int hyotan_owned_pipe(int descriptors[2]) {
#if TARGET_OS_SIMULATOR
    int (*create)(int *) = (int (*)(int *))dlsym(RTLD_MAIN_ONLY, "StruisOwnedProviderPipe");
    if (create) return create(descriptors);
#endif
    return pipe(descriptors);
}
"""
    for filename, expected in (("eval.c", 3), ("redir.c", 1)):
        path = work / "src" / filename
        text = path.read_text() if filename == "eval.c" else (source / "src" / filename).read_text()
        if text.count("pipe(pip)") != expected:
            raise RuntimeError("dash pipe creation sites changed: " + filename)
        # Place helper after includes and before the first source declaration.
        marker = "STATIC "
        if marker not in text:
            raise RuntimeError("dash source declaration marker changed: " + filename)
        text = text.replace("pipe(pip)", "hyotan_owned_pipe(pip)")
        index = text.index(marker)
        path.write_text(text[:index] + pipe_helper + text[index:])
    if preparation:
        # Compose on the existing ios_system environment/stdio/exec patches.
        # Restore untouched preparation-only inputs before the scoped overlay.
        for filename in ("alias.c", "nodes.c.pat", "trap.c"):
            shutil.copy2(source / "src" / filename, work / "src" / filename)
        spec = importlib.util.spec_from_file_location("dash_stage_preparation", ROOT / "Scripts/prepare-dash-stage.py")
        overlay = importlib.util.module_from_spec(spec); spec.loader.exec_module(overlay)
        overlay.prepare(source, work, copy_source=False)

def build(sdk, target, slice_name):
    preparation = PREPARATION and sdk == "iphonesimulator"
    work = ROOT / ".build" / (("dash-compound-" if preparation else "dash-") + sdk)
    if not work.exists():
        shutil.copytree(SOURCE, work, symlinks=True, ignore=shutil.ignore_patterns(".git", "*.zip"))
    # The upstream checkout omits its host-only Automake helper links.
    # Forward to the actual host tools; none of these scripts is bundled.
    for name, body in {"compile": 'exec "$@"', "missing": 'exec "$@"', "install-sh": 'exec /usr/bin/install "$@"'}.items():
        helper = work / name
        if helper.is_symlink():
            helper.unlink()
        helper.write_text("#!/bin/sh\n" + body + "\n")
        helper.chmod(0o755)
    prepare_port_sources(SOURCE, work, preparation)
    sdkroot = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
    hostroot = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    flags = f"-target {target} -isysroot {sdkroot} -DJOBS=0 -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -DFLUSHERR=1 -I{work} -Wno-error=implicit-function-declaration"
    env = dict(os.environ, CC="clang", CXX="clang++", CFLAGS=flags, CPPFLAGS=flags,
               CC_FOR_BUILD=f"clang -isysroot {hostroot} -DJOBS=0",
               LDFLAGS=f"-target {target} -isysroot {sdkroot} -dynamiclib -F{VENDOR}/ios_system-native.xcframework/{slice_name} -framework ios_system")
    run(["./configure", "--build=aarch64-apple-darwin", "--host=arm-apple-darwin", "cross_compiling=yes", "--without-libedit", "--disable-dependency-tracking"], cwd=work, env=env)
    makefile = work / "src/Makefile"
    makefile.write_text(prepare_makefile(makefile.read_text(), preparation))
    names = ["EXIT"] + ["UNKNOWN"] * (signal.NSIG - 1)
    for item in signal.Signals:
        if item.value < len(names):
            names[item.value] = item.name.removeprefix("SIG")
    (work / "src/signames.c").write_text("/* Generated from Darwin signal constants by Hyotan. */\n#include <signal.h>\nconst char *const signal_names[NSIG+1] = {\n" + ",\n".join('"'+name+'"' for name in names) + ", 0};\n")
    run(["make", "-j4", "-o", "Makefile.in", "-o", "aclocal.m4", "-o", "configure", "-o", "config.h.in"], cwd=work, env=env)
    framework = work / "dash.framework"
    framework.mkdir(exist_ok=True)
    shutil.copy2(work / "src/dash", framework / "dash")
    info = {"CFBundleExecutable": "dash", "CFBundleIdentifier": "org.digiloglab.hyotan.dash", "CFBundleName": "dash", "CFBundlePackageType": "FMWK", "CFBundleShortVersionString": "0.1", "CFBundleVersion": "1", "MinimumOSVersion": "18.4", "CFBundleSupportedPlatforms": ["iPhoneSimulator" if sdk == "iphonesimulator" else "iPhoneOS"]}
    (framework / "Info.plist").write_bytes(plistlib.dumps(info))
    run(["install_name_tool", "-id", "@rpath/dash.framework/dash", str(framework / "dash")])
    if preparation:
        symbols = subprocess.check_output(["xcrun", "nm", "-gU", framework / "dash"], text=True)
        exported = {line.split()[-1] for line in symbols.splitlines() if line.split()}
        required = {"_StruisDashInstallPipelineLauncher", "_StruisDashUninstallPipelineLauncher",
                    "_StruisDashSnapshotRetain", "_StruisDashSnapshotDestroy"}
        if not required <= exported:
            raise RuntimeError("root dash is missing the preparation ABI3 exports")
        build_helpers(work, sdkroot, target, slice_name, env, framework)
    return framework

def build_helpers(work, sdkroot, target, slice_name, env, root_framework):
    wrapper = work / "src/signed-stage.c"
    wrapper.write_text("""/* Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0 */
#include "StageSnapshot.h"
int StruisSignedDashStageEnter(const struct StruisDashStageSnapshot *s, int *code) {
    return StruisDashStageEnter(s, code);
}
int StruisSignedDashStageInstallLauncher(StruisDashPipelineLauncher launch, void *context) {
    return StruisDashInstallPipelineLauncher(launch, context);
}
""")
    wrapper_object = work / "signed-stage.o"
    run(["clang", "-target", target, "-isysroot", sdkroot, "-I", work / "src", "-c", wrapper, "-o", wrapper_object])
    exports = work / "signed-stage-exports.txt"
    exports.write_text("_StruisSignedDashStageEnter\n_StruisSignedDashStageInstallLauncher\n")
    objects = sorted((work / "src").glob("*.o")) + sorted((work / "src/bltin").glob("*.o"))
    objects = [p for p in objects if p.name != "signed-stage.o"]
    helpers = []
    for index in range(8):
        name = "HyotanDashStage" + str(index)
        framework = work / (name + ".framework")
        framework.mkdir(exist_ok=True)
        binary = framework / name
        run(["clang", "-target", target, "-isysroot", sdkroot, "-dynamiclib", "-install_name", "@rpath/" + name + ".framework/" + name,
             "-Wl,-exported_symbols_list," + str(exports), "-F", VENDOR / "ios_system-native.xcframework" / slice_name,
             *objects, wrapper_object, "-framework", "ios_system", "-o", binary])
        symbols = subprocess.check_output(["xcrun", "nm", "-gU", binary], text=True)
        exported = {line.split()[-1] for line in symbols.splitlines() if line.split()}
        if exported != {"_StruisSignedDashStageEnter", "_StruisSignedDashStageInstallLauncher"}:
            raise RuntimeError("signed stage exports differ from fixed ABI: " + name)
        info = {"CFBundleExecutable": name, "CFBundleIdentifier": "org.digiloglab.hyotan." + name,
                "CFBundleName": name, "CFBundlePackageType": "FMWK", "CFBundleShortVersionString": "0.1",
                "CFBundleVersion": "1", "MinimumOSVersion": "18.4", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]}
        (framework / "Info.plist").write_bytes(plistlib.dumps(info))
        output = VENDOR / (name + "-native.xcframework")
        if output.exists(): shutil.rmtree(output)
        run(["xcodebuild", "-create-xcframework", "-framework", framework, "-output", output])
        helpers.append({"index": index, "xcframework": output.name,
                        "path": output.name + "/ios-arm64-simulator/" + name + ".framework",
                        "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()})
    (VENDOR / "compound-dash-preparation.json").write_text(json.dumps({
        "abi": 3, "mode": "debug-simulator-one-shot", "helpers": helpers,
        "exports": ["StruisSignedDashStageEnter", "StruisSignedDashStageInstallLauncher"],
        "rootSimulatorSHA256": hashlib.sha256((root_framework / "dash").read_bytes()).hexdigest(),
        "dashSourceRevision": REVISION,
    }, indent=2) + "\n")

if __name__ == "__main__":
    if not SOURCE.exists():
        run(["git", "clone", "https://github.com/holzschu/dash_iOS.git", str(SOURCE)])
        run(["git", "-C", str(SOURCE), "checkout", REVISION])
    if subprocess.check_output(["git", "-C", str(SOURCE), "rev-parse", "HEAD"], text=True).strip() != REVISION:
        raise RuntimeError("dash checkout does not match its recorded revision")
    if not PREPARATION:
        (VENDOR / "compound-dash-preparation.json").unlink(missing_ok=True)
    device = build("iphoneos", "arm64-apple-ios18.4", "ios-arm64")
    simulator = build("iphonesimulator", "arm64-apple-ios18.4-simulator", "ios-arm64-simulator")
    output = VENDOR / "dash-native.xcframework"
    if output.exists():
        shutil.rmtree(output)
    run(["xcodebuild", "-create-xcframework", "-framework", str(device), "-framework", str(simulator), "-output", str(output)])
