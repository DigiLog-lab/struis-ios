#!/usr/bin/env python3
"""Set the dedicated CI checkout's Exec Debug Simulator preparation macro."""
import os
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
KEY = '"GCC_PREPROCESSOR_DEFINITIONS[sdk=iphonesimulator*]"'
VALUE = '("$(inherited)", "DEBUG=1", "STRUIS_EXEC_WORKER=1", "STRUIS_COMPOUND_DASH_PREPARATION=1")'


def configure(text, enabled):
    targets = re.findall(r'\t\t[0-9A-F]{24} /\* StruisExec \*/ = \{\n(.*?)\n\t\t\};', text, re.S)
    if len(targets) != 1:
        raise RuntimeError('Expected exactly one Exec target')
    match = re.search(r'buildConfigurationList = ([0-9A-F]{24}) ', targets[0])
    if not match:
        raise RuntimeError('Missing Exec configuration list')
    lists = re.findall(r'\t\t' + match[1] + r' /\* [^\n]* \*/ = \{\n(.*?)\n\t\t\};', text, re.S)
    if len(lists) != 1:
        raise RuntimeError('Ambiguous Exec configuration list')
    configurations = re.findall(r'([0-9A-F]{24}) /\* (Debug|Release) \*/,', lists[0])
    if len(configurations) != 2 or {name for _, name in configurations} != {'Debug', 'Release'}:
        raise RuntimeError('Expected Exec Debug and Release configurations')
    for identifier, name in configurations:
        pattern = r'(\t\t' + identifier + r' /\* ' + name + r' \*/ = \{\n.*?)(\t\t\t\};)'
        block = re.search(pattern, text, re.S)
        if not block:
            raise RuntimeError('Missing Exec build configuration')
        content = re.sub(r'\t\t\t\t' + re.escape(KEY) + r' = .*?;\n', '', block[1], flags=re.S)
        if enabled and name == 'Debug':
            anchor = re.search(r'\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = \(\n.*?\t\t\t\t\);\n', content, re.S)
            if not anchor or '"STRUIS_EXEC_WORKER=1"' not in anchor[0]:
                raise RuntimeError('Missing actual Exec preprocessor role')
            line = f'\t\t\t\t{KEY} = {VALUE};\n'
            content = content[:anchor.end()] + line + content[anchor.end():]
        text = text[:block.start()] + content + block[2] + text[block.end():]
    return text


def main():
    flag = os.environ.get('STRUIS_COMPOUND_DASH_PREPARATION', '0')
    if flag not in ('0', '1'):
        raise RuntimeError('Invalid compound Dash preparation selector')
    if flag == '1':
        from package_compound_dash_preparation import validate
        validate(HERE.parent / 'NativeRuntime/Vendor')
    path = HERE.parent / 'strius.xcodeproj/project.pbxproj'
    text = configure(path.read_text(), flag == '1')
    path.write_text(text)
    print('Configured Exec Debug Simulator preparation only' if flag == '1' else 'Removed preparation macro')


if __name__ == '__main__':
    main()
