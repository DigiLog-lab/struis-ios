#!/usr/bin/env python3
"""Register new sources, runtime assets, packages and build settings in strius.xcodeproj.

The app target is an explicit (non-synchronized) group, so every new Swift file
must be listed in the pbxproj. This script is idempotent:

  python3 scripts/sync_project.py

- Every `strius/**/*.swift` not yet referenced is added to the app Sources phase,
  creating groups that mirror directories.
- NativeRuntime sources, the ExtensionKit worker, frameworks and Python resources are registered.
- Old Linux libraries and rootfs resources are removed from the application target.
- SPM packages GRDB and Yams are declared.
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT_DIR = HERE.parent
PBXPROJ = PROJECT_DIR / "strius.xcodeproj" / "project.pbxproj"
APP_TARGET = "992C09AC2F927BB8009FF690"
APP_SOURCES_PHASE = "992C09A92F927BB8009FF690"
APP_RESOURCES_PHASE = "992C09AB2F927BB8009FF690"
APP_FRAMEWORKS_PHASE = "992C09AA2F927BB8009FF690"
APP_GROUP = "992C09AF2F927BB8009FF690"  # path = strius
MAIN_GROUP = "992C09A42F927BB8009FF690"
PROJECT_OBJECT = "992C09A52F927BB8009FF690"
APP_CONFIGS = ("992C09D12F927BB9009FF690", "992C09D22F927BB9009FF690")

PACKAGES = [
    ("GRDB.swift", "https://github.com/groue/GRDB.swift", "7.0.0", "GRDB"),
    ("Yams", "https://github.com/jpsim/Yams.git", "5.0.0", "Yams"),
]




def oid(kind: str, key: str) -> str:
    digest = hashlib.md5(f"{kind}:{key}".encode()).hexdigest().upper()
    return "E8" + digest[:22]


class Project:
    def __init__(self, text: str):
        self.text = text
        self.changed = False

    def has(self, identifier: str) -> bool:
        return identifier in self.text

    def insert_before(self, marker: str, line: str) -> None:
        index = self.text.index(marker)
        self.text = self.text[:index] + line + self.text[index:]
        self.changed = True

    def add_to_list(self, owner_id: str, list_name: str, entry: str) -> None:
        """Append `entry` to `list_name = ( ... );` inside the object `owner_id`."""
        pattern = re.compile(rf"(\t\t{re.escape(owner_id)} (/\* [^*]* \*/ )?= \{{.*?\n\t\t\t{list_name} = \(\n)(.*?)(\t\t\t\);)", re.S)
        match = pattern.search(self.text)
        if match is None:
            raise SystemExit(f"cannot find {list_name} of {owner_id}")
        if entry.strip() in match.group(3):
            return
        replacement = match.group(1) + match.group(3) + entry + match.group(4)
        self.text = self.text[: match.start()] + replacement + self.text[match.end():]
        self.changed = True

    def ensure_group(self, group_id: str, name: str, path: str | None, parent_id: str) -> None:
        if self.has(f"\t\t{group_id} /* {name} */ = {{"):
            return
        path_line = f"\t\t\tpath = {quote(path)};\n" if path is not None else f"\t\t\tname = {quote(name)};\n"
        block = (
            f"\t\t{group_id} /* {name} */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n"
            f"\t\t\t);\n"
            f"{path_line}"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};\n"
        )
        self.insert_before("/* End PBXGroup section */", block)
        self.add_to_list(parent_id, "children", f"\t\t\t\t{group_id} /* {name} */,\n")

    def ensure_file(self, file_id: str, build_id: str, name: str, file_type: str, group_id: str, phase_id: str | None, phase_label: str) -> None:
        if not self.has(f"\t\t{file_id} /* {name} */ = {{"):
            self.insert_before(
                "/* End PBXFileReference section */",
                f"\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type}; path = {quote(name)}; sourceTree = \"<group>\"; }};\n",
            )
            self.add_to_list(group_id, "children", f"\t\t\t\t{file_id} /* {name} */,\n")
        if phase_id and not self.has(f"\t\t{build_id} /* {name} in {phase_label} */ = {{"):
            self.insert_before(
                "/* End PBXBuildFile section */",
                f"\t\t{build_id} /* {name} in {phase_label} */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n",
            )
            self.add_to_list(phase_id, "files", f"\t\t\t\t{build_id} /* {name} in {phase_label} */,\n")

    def set_build_setting(self, config_id: str, key: str, value: str) -> None:
        pattern = re.compile(rf"(\t\t{config_id} /\* \w+ \*/ = \{{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = \{{\n)(.*?)(\t\t\t\}};)", re.S)
        match = pattern.search(self.text)
        if match is None:
            raise SystemExit(f"config {config_id} not found")
        body = match.group(2)
        line = f"\t\t\t\t{key} = {value};\n"
        existing = re.search(rf"\t\t\t\t{re.escape(key)} = .*?;\n", body, re.S)
        if existing:
            if existing.group(0) == line:
                return
            body = body[: existing.start()] + line + body[existing.end():]
        else:
            # Split the body into entries; a value may span lines inside ( ... ).
            entries = re.findall(r"\t\t\t\t[^\n]*?= (?:\([^)]*\)|[^\n]*?);\n", body, re.S)
            entries.append(line)
            entries.sort(key=lambda item: item.strip().strip('"').lower())
            body = "".join(entries)
        self.text = self.text[: match.start()] + match.group(1) + body + match.group(3) + self.text[match.end():]
        self.changed = True

    def ensure_package(self, name: str, url: str, minimum: str, product: str) -> None:
        ref_id = oid("package", name)
        dep_id = oid("product", product)
        build_id = oid("productbuild", product)
        if not self.has(f'XCRemoteSwiftPackageReference "{name}"'):
            self.insert_before(
                "/* End XCRemoteSwiftPackageReference section */",
                f"\t\t{ref_id} /* XCRemoteSwiftPackageReference \"{name}\" */ = {{\n"
                f"\t\t\tisa = XCRemoteSwiftPackageReference;\n"
                f"\t\t\trepositoryURL = \"{url}\";\n"
                f"\t\t\trequirement = {{\n\t\t\t\tkind = upToNextMajorVersion;\n\t\t\t\tminimumVersion = {minimum};\n\t\t\t}};\n"
                f"\t\t}};\n",
            )
            self.add_to_list(PROJECT_OBJECT, "packageReferences", f"\t\t\t\t{ref_id} /* XCRemoteSwiftPackageReference \"{name}\" */,\n")
        if not self.has(f"\t\t{dep_id} /* {product} */ = {{"):
            self.insert_before(
                "/* End XCSwiftPackageProductDependency section */",
                f"\t\t{dep_id} /* {product} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n"
                f"\t\t\tpackage = {ref_id} /* XCRemoteSwiftPackageReference \"{name}\" */;\n\t\t\tproductName = {product};\n\t\t}};\n",
            )
            self.add_to_list(APP_TARGET, "packageProductDependencies", f"\t\t\t\t{dep_id} /* {product} */,\n")
        if not self.has(f"\t\t{build_id} /* {product} in Frameworks */ = {{"):
            self.insert_before(
                "/* End PBXBuildFile section */",
                f"\t\t{build_id} /* {product} in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep_id} /* {product} */; }};\n",
            )
            self.add_to_list(APP_FRAMEWORKS_PHASE, "files", f"\t\t\t\t{build_id} /* {product} in Frameworks */,\n")


def quote(value: str) -> str:
    return value if re.fullmatch(r"[A-Za-z0-9_.]+", value) else f'"{value}"'


def main() -> int:
    project = Project(PBXPROJ.read_text())
    app_root = PROJECT_DIR / "strius"

    # 1. Swift sources under strius/, mirrored as groups.
    known_groups = {"strius": APP_GROUP}
    for path in sorted(app_root.rglob("*.swift")):
        relative = path.relative_to(app_root)
        if relative.parts[0] in ("Resources",):
            continue
        parent_id = APP_GROUP
        current = "strius"
        for part in relative.parts[:-1]:
            current = f"{current}/{part}"
            if current not in known_groups:
                group_id = oid("group", current)
                # Existing hand-written groups are matched by name under the same parent.
                existing = re.search(rf"\t\t([0-9A-F]{{24}}) /\* {re.escape(part)} \*/ = \{{\n\t\t\tisa = PBXGroup;", project.text)
                if existing and existing.group(1) in project.text.split(f"\t\t{parent_id} ")[1].split("};")[0]:
                    known_groups[current] = existing.group(1)
                else:
                    project.ensure_group(group_id, part, part, parent_id)
                    known_groups[current] = group_id
            parent_id = known_groups[current]
        name = relative.name
        if project.has(f"/* {name} */ = {{isa = PBXFileReference"):
            continue
        key = str(relative)
        project.ensure_file(oid("file", key), oid("build", key), name, "sourcecode.swift", parent_id, APP_SOURCES_PHASE, "Sources")

    # 1b. Prune references to Swift files that no longer exist on disk (renames).
    for match in re.finditer(r"\t\t([0-9A-F]{24,25}) /\* ([^*]+\.swift) \*/ = \{isa = PBXFileReference;[^\n]*\n", project.text):
        file_id, name = match.group(1), match.group(2)
        if not list(app_root.rglob(name)) and not list((PROJECT_DIR / "NativeRuntime").rglob(name)):
            project.text = re.sub(rf"\t\t{file_id} /\* {re.escape(name)} \*/ = \{{isa = PBXFileReference;[^\n]*\n", "", project.text)
            project.text = re.sub(rf"\t\t\t\t{file_id} /\* {re.escape(name)} \*/,\n", "", project.text)
            project.text = re.sub(rf"\t\t([0-9A-F]{{24,25}}) /\* {re.escape(name)} in Sources \*/ = \{{isa = PBXBuildFile; fileRef = {file_id}[^\n]*\n", "", project.text)
            project.text = re.sub(rf"\t\t\t\t[0-9A-F]{{24,25}} /\* {re.escape(name)} in Sources \*/,\n", "", project.text)
            project.changed = True
            print(f"pruned {name}")

    # Native runtime settings and extension target are synchronized below.

    # 4. Packages.
    for name, url, minimum, product in PACKAGES:
        project.ensure_package(name, url, minimum, product)

    if project.changed:
        PBXPROJ.write_text(project.text)
        print("project.pbxproj updated")
    else:
        print("project.pbxproj already up to date")
    import subprocess
    subprocess.run(["ruby", str(HERE / "sync_native_runtime.rb")], check=True)
    subprocess.run([sys.executable, str(HERE / "sync_test_resources.py")], check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
