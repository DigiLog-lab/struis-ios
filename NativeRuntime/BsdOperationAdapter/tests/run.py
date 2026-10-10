#!/usr/bin/env python3
"""Compile exact repository Core/operations.rs with only libc and run actual C I/O."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

NATIVE = Path(__file__).resolve().parents[2]
ADAPTER = NATIVE / "BsdOperationAdapter"
with tempfile.TemporaryDirectory(prefix="bsd-descriptors-") as tmp:
    scratch = Path(tmp)
    (scratch / "src").mkdir()
    core = NATIVE / "OperationHarness"
    operations = NATIVE / "NativeCodex/src/operations.rs"
    (scratch / "Cargo.toml").write_text(f'''[package]
name = "bsd-descriptor-operations-probe"
version = "0.0.0"
edition = "2024"
license = "Apache-2.0"
[lib]
crate-type = ["staticlib"]
[dependencies]
libc = "=0.2.189"
hyotan-operation-harness = {{ path = "{core}" }}
''')
    (scratch / "src/lib.rs").write_text(f'#[path = "{operations}"]\nmod operations;\n')
    subprocess.run(["cargo", "generate-lockfile", "--offline", "--manifest-path", str(scratch / "Cargo.toml")], check=True)
    subprocess.run(["cargo", "build", "--offline", "--locked", "--manifest-path", str(scratch / "Cargo.toml")], check=True)
    library = scratch / "target/debug/libbsd_descriptor_operations_probe.a"
    for path in [operations, core / "src/lib.rs", core / "src/handles.rs", library]:
        print(f"SHA256 {hashlib.sha256(path.read_bytes()).hexdigest()} {path}", flush=True)
    for caller in ["descriptors", "stdio", "adoption", "streams"]:
        binary = scratch / caller
        sources = [str(ADAPTER / "HyotanBsdDescriptors.c")]
        if caller in ["stdio", "adoption", "streams"]:
            sources.append(str(ADAPTER / "HyotanBsdStdio.c"))
        if caller == "streams":
            sources.append(str(ADAPTER / "HyotanBsdStreams.c"))
        subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread",
                        "-I", str(NATIVE / "NativeCodex/include-operations"), "-I", str(ADAPTER),
                        *sources, str(ADAPTER / f"tests/{caller}.c"),
                        str(library), "-ldl", "-lm", "-o", str(binary)], check=True)
        workspace = scratch / f"{caller}-workspace"
        workspace.mkdir()
        subprocess.run([str(binary), str(workspace)], check=True, timeout=20 if caller == "streams" else None)
    from pinned_algorithms import run as run_pinned_algorithms
    run_pinned_algorithms(NATIVE, ADAPTER, scratch, library)
