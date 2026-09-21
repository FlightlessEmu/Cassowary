#!/usr/bin/env python3
"""Read a core's Xcode project and report what it needs to build.

Each core ships its own `.xcodeproj` with the source list and build settings
the macOS build uses. Rather than hand-maintain an iOS copy of that, the iOS
build reads it from the project. That way a core's file list is stated once.

Usage:
    core-info.py <CoreName> [--json]

Prints a JSON object:

    {
      "name": "Gambatte",
      "product": "Gambatte",
      "bundleIdentifier": "org.openemu.Gambatte",
      "sources": ["GBGameCore.mm", "..."],
      "headerSearchPaths": ["..."],
      "otherCFlags": ["-DHAVE_STDINT_H"],
      "frameworks": ["..."]
    }

Paths are absolute and resolved against the project directory. Build settings
are expanded the way Xcode would expand them for this target: `$(SRCROOT)`,
`$(PROJECT_DIR)` and `$(SRCROOT)/..` are substituted.
"""

import argparse
import json
import os
import re
import sys

# Which build phase a source file belongs to.
SOURCE_PHASES = {'PBXSourcesBuildPhase'}
FRAMEWORK_PHASES = {'PBXFrameworksBuildPhase'}


def object_span(text, object_id):
    """Return the span of `ID /* name */ = { ... };`, matching braces."""
    # Most entries are indented with two tabs, but hand-added entries (e.g.
    # BSNES's debugger.c build files) sometimes use spaces instead.
    pattern = r'^[ \t]+' + re.escape(object_id) + r'(?: /\* [^*]* \*/)? = \{'
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
    span = object_span(text, object_id)
    return text[span[0]:span[1]] if span else None


def find_target(text, name):
    for m in re.finditer(r'^\t\t([0-9A-Za-z]{20,}) /\* ' + re.escape(name) + r' \*/ = \{', text, re.M):
        body = object_body(text, m.group(1))
        if body and 'isa = PBXNativeTarget;' in body:
            return m.group(1)
    return None


def build_settings(text, target_id):
    """Return the resolved Debug build settings for a target."""
    body = object_body(text, target_id)
    m = re.search(r'buildConfigurationList = ([0-9A-Za-z]{20,})', body)
    if m is None:
        return {}

    list_body = object_body(text, m.group(1))
    debug_id = None
    for config_id, name in re.findall(r'([0-9A-Za-z]{20,}) /\* ([^*]+) \*/', list_body):
        if name.strip() == 'Debug':
            debug_id = config_id
            break
    if debug_id is None:
        return {}

    config_body = object_body(text, debug_id)
    # Pull out the buildSettings dictionary.
    m = re.search(r'buildSettings = \{\n(.*?)\n\t\t\t\};', config_body, re.S)
    if m is None:
        return {}

    settings = {}
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line or line.startswith('//'):
            continue
        m = re.match(r'([A-Za-z_][A-Za-z0-9_]*) = (.*);$', line)
        if m:
            settings[m.group(1)] = m.group(2).strip('"')
    return settings


def file_reference_paths(text):
    """Map every PBXFileReference id to its path relative to the project.

    A file reference's path is only part of the story: groups above it can
    contribute path components. `src/libgambatte/cpu.cpp` is stored as a group
    named `src` containing a group named `libgambatte` containing a reference
    whose path is just `cpu.cpp`. Walking the group tree is what turns that back
    into the real path.
    """
    # group id -> (own path component, child ids, source tree)
    groups = {}
    for m in re.finditer(r'^\t\t([0-9A-Za-z]{20,}) /\* [^*]+ \*/ = \{\n\t\t\tisa = PBXGroup;', text, re.M):
        body = object_body(text, m.group(1))
        if body is None:
            continue
        path = re.search(r'\n\t\t\tpath = ([^;]+);', body)
        tree = re.search(r'\n\t\t\tsourceTree = ([^;]+);', body)
        children = re.search(r'children = \((.*?)\n\t\t\t\);', body, re.S)
        child_ids = re.findall(r'([0-9A-Za-z]{20,}) /\* [^*]+ \*/,', children.group(1)) if children else []
        groups[m.group(1)] = (
            path.group(1).strip('"') if path else '',
            child_ids,
            tree.group(1).strip('"') if tree else '<group>',
        )

    # file reference id -> (own path component, sourceTree)
    files = {}
    for m in re.finditer(r'^\t\t([0-9A-Za-z]{20,}) /\* [^*]+ \*/ = \{isa = PBXFileReference;', text, re.M):
        body = object_body(text, m.group(1))
        if body is None:
            continue
        path = re.search(r'path = ([^;]+);', body)
        name = re.search(r'name = ([^;]+);', body)
        tree = re.search(r'sourceTree = ([^;]+);', body)
        component = (path.group(1).strip('"') if path
                     else (name.group(1).strip('"') if name else None))
        files[m.group(1)] = (component, tree.group(1).strip('"') if tree else '<group>')

    # Which group holds each child, so the tree can be walked downwards.
    parent_of = {}
    for group_id, (_, child_ids, _) in groups.items():
        for child_id in child_ids:
            parent_of[child_id] = group_id

    def resolve(object_id):
        entry = files.get(object_id)
        if entry is None:
            return None
        own, source_tree = entry

        # A file reference whose source tree is the project root already
        # carries its full path; the groups above it must not be prepended.
        if source_tree in ('SOURCE_ROOT', '<absolute>'):
            return own
        if source_tree in ('SDKROOT', 'BUILT_PRODUCTS_DIR', 'DEVELOPER_DIR'):
            return None

        # Otherwise the path is relative to the groups above it. Deepest
        # component first, then each group; reversing puts them in disk order.
        #
        # A group can itself be rooted at the project rather than at its parent,
        # and its path may contain several components. When that happens the
        # walk stops: everything above it is already accounted for.
        parts = [own] if own else []
        current = object_id
        while current in parent_of:
            group_id = parent_of[current]
            component, _, group_tree = groups.get(group_id, ('', [], '<group>'))
            if component:
                parts.append(component)
                if group_tree in ('SOURCE_ROOT', '<absolute>'):
                    break
            current = group_id
        return '/'.join(reversed(parts)) if parts else None

    return {object_id: resolve(object_id) for object_id in files}


def dependent_target_ids(text, target_id):
    """Return the targets this one depends on, transitively.

    A core can split itself across targets: VirtualJaguar's plugin target
    depends on an `m68k` static-library target that holds the CPU emulator, and
    FCEU's on a helper target. Those objects are linked into the plugin, so
    their sources have to be compiled here too.
    """
    seen = set()
    pending = [target_id]
    found = []

    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)

        body = object_body(text, current)
        if body is None:
            continue

        # `dependencies = ( ... );` holds PBXTargetDependency ids.
        m = re.search(r'\n\t\t\tdependencies = \((.*?)\n\t\t\t\);', body, re.S)
        if m is None:
            continue

        for dependency_id in re.findall(r'([0-9A-Za-z]{20,}) /\* PBXTargetDependency \*/', m.group(1)):
            dep_body = object_body(text, dependency_id)
            if dep_body is None:
                continue
            target = re.search(r'target = ([0-9A-Za-z]{20,})', dep_body)
            if target is None:
                continue
            dep_id = target.group(1)
            if dep_id not in seen:
                found.append(dep_id)
                pending.append(dep_id)

    return found


def phase_files(text, target_id, phase_isa, file_paths):
    """Return (path, compiler flags) for the target's build phases of a kind.

    A build file can carry its own `COMPILER_FLAGS`. rcheevos needs them, for
    example, to be compiled single-threaded with ROM hashing turned on. They
    are per-file, so they cannot come from the target's settings.
    """
    body = object_body(text, target_id)
    entries = []

    for phase_id in re.findall(r'([0-9A-Za-z]{20,}) /\* [^*]+ \*/,', body):
        phase_body = object_body(text, phase_id)
        if phase_body is None or f'isa = {phase_isa};' not in phase_body:
            continue

        for build_file_id in re.findall(r'([0-9A-Za-z]{20,}) /\* [^*]+ \*/,', phase_body):
            build_body = object_body(text, build_file_id)
            if build_body is None:
                continue
            m = re.search(r'fileRef = ([0-9A-Za-z]{20,})', build_body)
            if m is None:
                continue
            path = file_paths.get(m.group(1))
            if not path:
                continue

            flags = ''
            m = re.search(r'COMPILER_FLAGS = "([^"]*)"', build_body)
            if m:
                flags = m.group(1)
            entries.append((path, flags))

    return entries


def framework_system_libraries(text, target_id):
    """Return -l names for system libraries in the target's Frameworks phase.

    A core can link usr/lib stubs such as libz (Bliss uses it for minizip).
    Those references live under SDKROOT, so file_reference_paths drops them;
    their basenames still say what to link. Frameworks are deliberately not
    mapped: Cocoa/OpenGL/Carbon do not exist on iOS.
    """
    body = object_body(text, target_id)
    libs = []
    for phase_id in re.findall(r'([0-9A-Za-z]{20,}) /\* [^*]+ \*/,', body):
        phase_body = object_body(text, phase_id)
        if phase_body is None or 'isa = PBXFrameworksBuildPhase;' not in phase_body:
            continue
        for _, comment in re.findall(r'([0-9A-Za-z]{20,}) /\* ([^*]+) \*/,', phase_body):
            m = re.match(r'lib([A-Za-z0-9_]+)(?:\.\d[\w.]*)?\.(?:dylib|tbd) in ', comment)
            if m and m.group(1) not in libs:
                libs.append(m.group(1))
    return libs


def split_list(value):
    """Split a build setting that holds a list into its items.

    xcodebuild prints these space-separated, quoting any item that contains a
    space. Paths with spaces are common here, so the quoting matters.

    xcodebuild also backslash-escapes quotes that are part of a value
    (-DPACKAGE=\"mednafen\"). Those are protected before splitting so the
    quotes survive as part of the item instead of acting as grouping.
    """
    if not value:
        return []
    value = value.strip()
    if value.startswith('(') and value.endswith(')'):
        value = value[1:-1]
    value = value.replace('\\"', '\x00')
    return [(a or b).replace('\x00', '"')
            for a, b in re.findall(r'"([^"]*)"|(\S+)', value) if (a or b)]


def expand(path, project_dir):
    """Expand the build settings that appear in paths."""
    path = path.replace('$(SRCROOT)', project_dir)
    path = path.replace('$(PROJECT_DIR)', project_dir)
    path = path.replace('${SRCROOT}', project_dir)
    path = path.replace('${PROJECT_DIR}', project_dir)
    return os.path.normpath(path)


# Directories that never contain headers worth searching.
SKIP_DIR_PARTS = {
    'build', '.git', '.github', 'node_modules', 'DerivedData',
    'test', 'tests', 'Test', 'Tests', 'testing',
    'example', 'examples', 'Example', 'Examples',
    'doc', 'docs', 'Doc', 'Docs',
    'cmake', 'CMake', 'CMakeFiles',
    'obj', 'bin', 'out',
    # Platform backends for systems other than Apple. Their headers are only
    # correct for those compilers — a vendored win32 stdint.h fails loudly when
    # it lands on the search path.
    'win32', 'Win32', 'windows', 'Windows', 'msvc', 'MSVC',
    'mingw', 'MinGW', 'wii', 'psp', 'ps3', 'xbox',
}


# Headers that belong to the C standard library. A directory containing one of
# these shadows the real header for anything that includes it by name.
# Block.h is the compiler's blocks-runtime header, shadowed the same way
# (Mednafen's tremor copy broke Foundation's <Block.h> include).
SYSTEM_HEADER_NAMES = {
    'assert.h', 'complex.h', 'ctype.h', 'errno.h', 'fenv.h', 'float.h',
    'inttypes.h', 'iso646.h', 'limits.h', 'locale.h', 'math.h', 'setjmp.h',
    'signal.h', 'stdarg.h', 'stdbool.h', 'stddef.h', 'stdint.h', 'stdio.h',
    'stdlib.h', 'string.h', 'tgmath.h', 'time.h', 'uchar.h', 'wchar.h',
    'wctype.h', 'block.h',
}


def discover_header_dirs(core_dir):
    """Find every directory under a core that holds a header.

    The projects' own header search paths are often stale — they point at
    directories that no longer exist, because the cores were reorganised after
    those settings were written. The macOS build survives this by including
    headers relative to each source file. For a build driven from outside
    Xcode, walking the tree is more reliable than trusting the settings.

    Returns (normal, quoted). A directory holding a C library header name
    (e.g. Mednafen's Time.h, which shadows the system time.h on a
    case-insensitive checkout) goes in quoted: -iquote serves "..." includes
    without hijacking <...> includes the way Xcode's header maps do.
    """
    found = set()
    quoted = set()
    for root, dirs, files in os.walk(core_dir):
        # Prune in place so os.walk does not descend into these.
        dirs[:] = [d for d in dirs if d not in SKIP_DIR_PARTS]
        if any(part in SKIP_DIR_PARTS for part in root.split(os.sep)):
            continue
        headers = [f for f in files if f.endswith(('.h', '.hpp', '.hh', '.hxx'))]
        if not headers:
            continue
        if any(f.lower() in SYSTEM_HEADER_NAMES for f in headers):
            # Quoted includes ("mednafen.h") still resolve; angle includes
            # (<time.h>) fall through to the real system headers. The
            # comparison is case-insensitive because the checkout may sit on
            # a case-insensitive filesystem.
            quoted.add(root)
            continue
        found.add(root)
    return sorted(found), sorted(quoted)


def resolved_settings(project_path, target_name, core_dir):
    """Ask xcodebuild for the target's build settings.

    Xcode expands `$(SRCROOT)`, `$(inherited)` and the project's own defaults,
    and it knows about settings defined in xcconfig files. Reimplementing that
    from the project file is a losing game, so the real thing is used.
    """
    import subprocess

    try:
        result = subprocess.run(
            ['xcodebuild', '-project', project_path, '-target', target_name,
             '-configuration', 'Debug', '-sdk', 'macosx', '-showBuildSettings'],
            capture_output=True, text=True, timeout=120)
    except (subprocess.SubprocessError, FileNotFoundError):
        return {}

    settings = {}
    for line in result.stdout.splitlines():
        m = re.match(r'\s+([A-Za-z_][A-Za-z0-9_]*) = (.*)$', line)
        if m:
            settings[m.group(1)] = m.group(2)
    return settings


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('core')
    parser.add_argument('--json', action='store_true', help='print JSON (the default)')
    parser.add_argument('--shell', action='store_true',
                        help='print shell variable assignments instead of JSON')
    args = parser.parse_args()

    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    core_dir = os.path.join(repo, 'cores', args.core)
    if not os.path.isdir(core_dir):
        print(f'error: no core directory at {core_dir}', file=sys.stderr)
        return 1

    projects = [f for f in os.listdir(core_dir) if f.endswith('.xcodeproj')]
    if not projects:
        print(f'error: {args.core} has no .xcodeproj', file=sys.stderr)
        return 1

    project_path = os.path.join(core_dir, projects[0])
    pbxproj = os.path.join(project_path, 'project.pbxproj')
    text = open(pbxproj, encoding='utf-8', errors='ignore').read()

    # The target is usually named after the core. Fall back to the only target
    # if that does not match (e.g. picodrive lives in target Picodrive).
    target_id = find_target(text, args.core)
    target_name = args.core
    if target_id is None:
        targets = re.findall(r'^\t\t([0-9A-Za-z]{20,}) /\* ([^*]+) \*/ = \{\n\t\t\tisa = PBXNativeTarget;',
                             text, re.M)
        if len(targets) == 1:
            target_id, target_name = targets[0]
        else:
            print(f'error: cannot pick a target for {args.core}: '
                  f'{", ".join(n for _, n in targets)}', file=sys.stderr)
            return 1

    settings = resolved_settings(project_path, target_name, core_dir)
    file_paths = file_reference_paths(text)

    # Source paths are relative to the project directory. Targets the core
    # depends on contribute their sources too (see dependent_target_ids).
    sources = []
    seen_sources = set()
    for owner in [target_id] + dependent_target_ids(text, target_id):
        for path, flags in phase_files(text, owner, 'PBXSourcesBuildPhase', file_paths):
            full = os.path.normpath(os.path.join(core_dir, path))
            if full in seen_sources:
                continue
            seen_sources.add(full)
            sources.append({'path': full, 'flags': flags})

    header_paths = [expand(p, core_dir) for p in split_list(settings.get('HEADER_SEARCH_PATHS', ''))]
    # Xcode also keeps search paths in the scope-specific settings. BSNES, for
    # example, keeps its $(SRCROOT)/bsnes/bsnes base (needed for
    # <emulator/emulator.hpp>) in SYSTEM_HEADER_SEARCH_PATHS, so those have to
    # be read too.
    for search_key in ('SYSTEM_HEADER_SEARCH_PATHS', 'USER_HEADER_SEARCH_PATHS'):
        header_paths += [expand(p, core_dir) for p in split_list(settings.get(search_key, ''))]
    other_flags = split_list(settings.get('OTHER_CFLAGS', ''))
    # Xcode passes GCC_PREPROCESSOR_DEFINITIONS as -D flags. Potator-Core
    # keeps its OPENEMU=OPENEMU define there (it selects the UINT32 typedef
    # and the POSIX include path in supervision.h). DEBUG=1 is filtered out:
    # Xcode's Debug configuration defines it, but this script is its own
    # build, and at least one core (SNES9x) refuses to compile with DEBUG set.
    other_flags += ['-D' + entry for entry in split_list(settings.get('GCC_PREPROCESSOR_DEFINITIONS', ''))
                    if entry not in ('DEBUG=1', 'DEBUG')]

    # xcodebuild reports `compiler-default` when the project sets no standard.
    # That is not a valid -std value, so it means "pass no flag".
    c_standard = settings.get('GCC_C_LANGUAGE_STANDARD', '')
    cxx_standard = settings.get('CLANG_CXX_LANGUAGE_STANDARD', '')
    if c_standard == 'compiler-default':
        c_standard = ''
    if cxx_standard == 'compiler-default':
        cxx_standard = ''
    frameworks = [p for p, _ in phase_files(text, target_id, 'PBXFrameworksBuildPhase', file_paths)]
    libraries = framework_system_libraries(text, target_id)

    # Project paths that exist, plus everything discovered on disk.
    live_header_paths = [p for p in header_paths if os.path.isdir(p)]
    discovered, quoted = discover_header_dirs(core_dir)

    seen = set()
    all_header_paths = []
    for path in live_header_paths + discovered:
        if path not in seen:
            seen.add(path)
            all_header_paths.append(path)

    info_plist = settings.get('INFOPLIST_FILE', 'Info.plist')
    info = {
        'name': args.core,
        'target': args.core,
        'project': project_path,
        'projectDir': core_dir,
        'product': settings.get('PRODUCT_NAME', args.core),
        'bundleIdentifier': settings.get('PRODUCT_BUNDLE_IDENTIFIER', f'org.openemu.{args.core}'),
        'wrapperExtension': settings.get('WRAPPER_EXTENSION', 'oecoreplugin'),
        'infoPlist': os.path.normpath(os.path.join(core_dir, expand(info_plist, core_dir))),
        'sources': sources,
        'headerSearchPaths': all_header_paths,
        'projectHeaderSearchPaths': live_header_paths,
        'discoveredHeaderPaths': discovered,
        'quoteHeaderSearchPaths': quoted,
        'otherCFlags': other_flags,
        'cStandard': c_standard,
        'cxxStandard': cxx_standard,
        'frameworks': frameworks,
        'libraries': libraries,
        'arc': settings.get('CLANG_ENABLE_OBJC_ARC', 'YES') == 'YES',
    }

    if args.shell:
        import shlex
        print(f"PRODUCT={shlex.quote(info['product'])}")
        print(f"BUNDLE_ID={shlex.quote(info['bundleIdentifier'])}")
        print(f"WRAPPER={shlex.quote(info['wrapperExtension'])}")
        print(f"PROJECT_DIR={shlex.quote(info['projectDir'])}")
        print(f"ARC={shlex.quote('YES' if info['arc'] else 'NO')}")
        print("SOURCES=(" + " ".join(shlex.quote(s['path']) for s in info['sources']) + ")")
        print("SOURCE_FLAGS=(" + " ".join(shlex.quote(s['flags']) for s in info['sources']) + ")")
        print("INCLUDES=(" + " ".join(shlex.quote(p) for p in info['headerSearchPaths']) + ")")
        print("QUOTE_INCLUDES=(" + " ".join(shlex.quote(p) for p in info['quoteHeaderSearchPaths']) + ")")
        print("EXTRA_CFLAGS=(" + " ".join(shlex.quote(f) for f in info['otherCFlags']) + ")")
        print("LIBS=(" + " ".join(shlex.quote(l) for l in info['libraries']) + ")")
        print(f"CSTD={shlex.quote(info['cStandard'])}")
        print(f"CXXSTD={shlex.quote(info['cxxStandard'])}")
        print(f"INFO_PLIST={shlex.quote(info['infoPlist'])}")
        return 0

    print(json.dumps(info, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
