#!/usr/bin/env python3
"""Add files to an Xcode project without rewriting it.

Xcode's `project.pbxproj` is a plist, but re-serialising it churns the whole
file and makes review impossible. This script only *inserts* lines: one build
file entry, one file reference, one group child, one build phase entry. Every
other byte of the file is left alone.

Usage:
    xcodeproj_add_files.py <project.pbxproj> <target-name> <file>... [options]

Options:
    --group NAME            Group to file the references under
                            (default: the group of an existing file with the
                            same name, else a new group named after the file's
                            directory)
    --header-visibility X   Public, Private, or None (default: Private)
    --dry-run               Print what would change and exit
"""

import argparse
import os
import re
import sys
import uuid

SOURCES = 'PBXSourcesBuildPhase'
HEADERS = 'PBXHeadersBuildPhase'
RESOURCES = 'PBXResourcesBuildPhase'

# Xcode labels the entry by the short phase name, not the ISA.
PHASE_LABEL = {
    SOURCES: 'Sources',
    HEADERS: 'Headers',
    RESOURCES: 'Resources',
}

PHASE_FOR_EXT = {
    '.m': SOURCES, '.mm': SOURCES, '.c': SOURCES, '.cc': SOURCES, '.cpp': SOURCES,
    '.swift': SOURCES, '.metal': SOURCES,
    '.h': HEADERS,
    '.xib': RESOURCES, '.storyboard': RESOURCES, '.plist': RESOURCES,
    '.png': RESOURCES, '.xcassets': RESOURCES, '.lproj': RESOURCES,
}

TYPE_FOR_EXT = {
    '.m': 'sourcecode.c.objc', '.mm': 'sourcecode.cpp.objcpp',
    '.c': 'sourcecode.c.c', '.cc': 'sourcecode.cpp.cpp',
    '.cpp': 'sourcecode.cpp.cpp', '.swift': 'sourcecode.swift',
    '.metal': 'sourcecode.metal', '.h': 'sourcecode.c.h',
    '.xib': 'file.xib', '.storyboard': 'file.storyboard',
    '.plist': 'text.plist.xml', '.png': 'image.png',
    '.xcassets': 'folder.assetcatalog',
}

# Section markers in the pbxproj file.
SECTIONS = {
    'buildfile': '/* Begin PBXBuildFile section */',
    'fileref': '/* Begin PBXFileReference section */',
    'group': '/* Begin PBXGroup section */',
    'variant': '/* Begin PBXVariantGroup section */',
}


def read(path):
    with open(path) as fh:
        return fh.read()


def find_object_span(text, object_id):
    """Return (start, end) of the object body `ID = { ... };`.

    Object ids appear in several contexts — as a definition, as a reference in
    another object's body, and inside `TargetAttributes`. Only the definition
    has the shape `ID /* name */ = {` at the start of a line, so that is what is
    matched, and braces are walked from there.
    """
    pattern = r'^\t\t' + re.escape(object_id) + r'(?: /\* [^*]* \*/)? = \{'
    for m in re.finditer(pattern, text, re.M):
        start = m.start()
        i = text.index('{', m.start())
        depth = 0
        while i < len(text):
            ch = text[i]
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    return start, i + 1
            i += 1
    return None


def object_body(text, object_id):
    span = find_object_span(text, object_id)
    if span is None:
        return None
    return text[span[0]:span[1]]


def find_target(text, name):
    """Return the id of the PBXNativeTarget called `name`."""
    for m in re.finditer(r'^\t\t([0-9A-F]{24}) /\* ([^*]+) \*/ = \{', text, re.M):
        if m.group(2).strip() != name:
            continue
        body = object_body(text, m.group(1))
        if body and 'isa = PBXNativeTarget;' in body:
            return m.group(1)
    return None


def target_phases(text, target_id):
    """Map build phase ISA -> object id, for the phases of `target_id`."""
    body = object_body(text, target_id)
    phases = {}
    for m in re.finditer(r'([0-9A-F]{24}) /\* [^*]+ \*/,', body):
        phase_id = m.group(1)
        phase_body = object_body(text, phase_id)
        if phase_body is None:
            continue
        isa = re.search(r'isa = (PBX\w+BuildPhase);', phase_body)
        if isa:
            phases[isa.group(1)] = phase_id
    return phases


def used_ids(text):
    return set(re.findall(r'\b([0-9A-F]{24})\b', text))


def fresh_id(used):
    while True:
        candidate = uuid.uuid4().hex[:24].upper()
        if candidate not in used:
            used.add(candidate)
            return candidate


def find_file_reference(text, basename):
    for m in re.finditer(
            r'^\t\t([0-9A-F]{24}) /\* ' + re.escape(basename) + r' \*/ = \{isa = PBXFileReference;',
            text, re.M):
        return m.group(1)
    return None


def group_children_span(text, group_id):
    """Return the offset just after `children = (` inside the group body."""
    span = find_object_span(text, group_id)
    body = text[span[0]:span[1]]
    m = re.search(r'children = \(\n', body)
    if m is None:
        return None
    return span[0] + m.end()


def insert_after_section_header(text, key, line):
    header = SECTIONS[key]
    idx = text.index(header)
    insert_at = text.index('\n', idx) + 1
    return text[:insert_at] + line + text[insert_at:]


def find_group(text, name):
    """Return the id of a PBXGroup named `name`, or None."""
    pattern = r'^\t\t([0-9A-F]{24}) /\* ' + re.escape(name) + r' \*/ = \{'
    for m in re.finditer(pattern, text, re.M):
        body = object_body(text, m.group(1))
        if body and 'isa = PBXGroup;' in body:
            return m.group(1)
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('project')
    parser.add_argument('target')
    parser.add_argument('files', nargs='+')
    parser.add_argument('--group')
    parser.add_argument('--header-visibility', default='Private',
                        choices=['Public', 'Private', 'None'])
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()

    text = read(args.project)
    used = used_ids(text)

    target_id = find_target(text, args.target)
    if target_id is None:
        print(f'error: target {args.target!r} not found', file=sys.stderr)
        return 1

    phases = target_phases(text, target_id)
    needs_headers = any(os.path.splitext(f)[1] == '.h' for f in args.files)
    if needs_headers and HEADERS not in phases:
        print(f'error: target {args.target!r} has no headers build phase', file=sys.stderr)
        return 1

    # Decide where new file references go. Prefer the group that already holds a
    # file with the same name, so re-running is stable.
    group_id = None
    for file_path in args.files:
        base = os.path.basename(file_path)
        ref = find_file_reference(text, base)
        if ref is None:
            continue
        for m in re.finditer(r'^\t\t([0-9A-F]{24}) /\* [^*]+ \*/ = \{', text, re.M):
            gid = m.group(1)
            body = object_body(text, gid)
            if body and 'isa = PBXGroup;' in body and re.search(r'\b' + re.escape(ref) + r'\b', body):
                group_id = gid
                break
        if group_id:
            break

    if group_id is None:
        # Fall back to the group named after the target, which is how the SDK
        # project is laid out.
        group_name = args.group or args.target
        group_id = find_group(text, group_name)
        if group_id is None:
            print(f'warning: no group named {group_name!r}; file references will '
                  f'not be added to any group', file=sys.stderr)

    changed = []

    for file_path in args.files:
        ext = os.path.splitext(file_path)[1]
        phase_isa = PHASE_FOR_EXT.get(ext)
        if phase_isa is None:
            print(f'skip (unsupported type): {file_path}')
            continue
        if phase_isa not in phases:
            print(f'skip (target has no {phase_isa}): {file_path}')
            continue

        basename = os.path.basename(file_path)

        ref_id = find_file_reference(text, basename)
        if ref_id is None:
            ref_id = fresh_id(used)
            file_type = TYPE_FOR_EXT.get(ext, 'text')
            line = (f'\t\t{ref_id} /* {basename} */ = {{isa = PBXFileReference; '
                    f'lastKnownFileType = {file_type}; path = {basename}; '
                    f'sourceTree = "<group>"; }};\n')
            text = insert_after_section_header(text, 'fileref', line)
            changed.append(f'  + file reference {basename} ({ref_id})')

        # Group membership.
        if group_id is not None:
            insert_at = group_children_span(text, group_id)
            if insert_at is not None:
                body = object_body(text, group_id)
                if f'{ref_id} /* {basename} */' not in body:
                    text = text[:insert_at] + f'\t\t\t\t{ref_id} /* {basename} */,\n' + text[insert_at:]
                    changed.append(f'  + group child {basename}')

        # Build phase membership.
        phase_id = phases[phase_isa]
        phase_body = object_body(text, phase_id)
        build_marker = f'{ref_id} /* {basename} in '
        if build_marker in phase_body:
            continue

        build_id = fresh_id(used)
        settings = ''
        if phase_isa == HEADERS and args.header_visibility != 'None':
            settings = f' settings = {{ATTRIBUTES = ({args.header_visibility}, ); }};'
        line = (f'\t\t{build_id} /* {basename} in {PHASE_LABEL[phase_isa]} */ = {{isa = PBXBuildFile; '
                f'fileRef = {ref_id} /* {basename} */;{settings} }};\n')
        text = insert_after_section_header(text, 'buildfile', line)

        insert_at = group_children_span(text, phase_id)
        if insert_at is None:
            # phases use `files = (` rather than `children = (`
            span = find_object_span(text, phase_id)
            body = text[span[0]:span[1]]
            m = re.search(r'files = \(\n', body)
            insert_at = span[0] + m.end()
        text = (text[:insert_at]
                + f'\t\t\t\t{build_id} /* {basename} in {PHASE_LABEL[phase_isa]} */,\n'
                + text[insert_at:])
        changed.append(f'  + {PHASE_LABEL[phase_isa]} {basename}')

    if args.dry_run:
        print(f'would add to {args.target}:')
        print('\n'.join(changed) or '  (nothing)')
        return 0

    with open(args.project, 'w') as fh:
        fh.write(text)

    print('\n'.join(changed) or '(nothing to do)')
    print(f'{len(changed)} change(s) applied to {args.target}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
