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
      "frameworks": ["..."],
      "resources": ["..."]
    }

Paths are absolute and resolved against the project directory. Build settings
are expanded the way Xcode would expand them for this target: `$(SRCROOT)`,
`$(PROJECT_DIR)` and `$(SRCROOT)/..` are substituted.
"""

import argparse
import json
import os
import re
import subprocess
import sys

def read_project(path):
    """Let macOS decode Xcode's OpenStep property list."""
    return json.loads(subprocess.check_output(
        ['plutil', '-convert', 'json', '-o', '-', path]))['objects']


def find_target(objects, name):
    return next((key for key, value in objects.items()
                 if value.get('isa') == 'PBXNativeTarget' and value.get('name') == name), None)


def file_reference_paths(objects):
    """Map every PBXFileReference id to its path relative to the project.

    A file reference's path is only part of the story: groups above it can
    contribute path components. `src/libgambatte/cpu.cpp` is stored as a group
    named `src` containing a group named `libgambatte` containing a reference
    whose path is just `cpu.cpp`. Walking the group tree is what turns that back
    into the real path.
    """
    groups = {key: value for key, value in objects.items() if value.get('isa') == 'PBXGroup'}
    files = {key: value for key, value in objects.items() if value.get('isa') == 'PBXFileReference'}
    parent_of = {child: key for key, group in groups.items() for child in group.get('children', [])}

    def resolve(object_id):
        entry = files[object_id]
        own = entry.get('path', entry.get('name'))
        source_tree = entry.get('sourceTree', '<group>')

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
            group = groups[group_id]
            component = group.get('path', '')
            if component:
                parts.append(component)
                if group.get('sourceTree') in ('SOURCE_ROOT', '<absolute>'):
                    break
            current = group_id
        return '/'.join(reversed(parts)) if parts else None

    return {object_id: resolve(object_id) for object_id in files}


def dependent_target_ids(objects, target_id):
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

        for dependency_id in objects.get(current, {}).get('dependencies', []):
            dep_id = objects[dependency_id].get('target')
            if dep_id and dep_id not in seen:
                found.append(dep_id)
                pending.append(dep_id)

    return found


def phase_files(objects, target_id, phase_isa, file_paths):
    """Return (path, compiler flags) for the target's build phases of a kind.

    A build file can carry its own `COMPILER_FLAGS`. rcheevos needs them, for
    example, to be compiled single-threaded with ROM hashing turned on. They
    are per-file, so they cannot come from the target's settings.
    """
    entries = []
    for phase_id in objects[target_id].get('buildPhases', []):
        phase = objects[phase_id]
        if phase.get('isa') != phase_isa:
            continue
        for build_file_id in phase.get('files', []):
            build_file = objects[build_file_id]
            path = file_paths.get(build_file.get('fileRef'))
            if path:
                entries.append((path, build_file.get('settings', {}).get('COMPILER_FLAGS', '')))
    return entries


def framework_system_libraries(objects, target_id):
    """Return -l names for system libraries in the target's Frameworks phase.

    A core can link usr/lib stubs such as libz (Bliss uses it for minizip).
    Those references live under SDKROOT, so file_reference_paths drops them;
    their basenames still say what to link. Frameworks are deliberately not
    mapped: Cocoa/OpenGL/Carbon do not exist on iOS.
    """
    libs = []
    for phase_id in objects[target_id].get('buildPhases', []):
        phase = objects[phase_id]
        if phase.get('isa') != 'PBXFrameworksBuildPhase':
            continue
        for build_file_id in phase.get('files', []):
            reference = objects.get(objects[build_file_id].get('fileRef'), {})
            name = reference.get('name') or os.path.basename(reference.get('path', ''))
            m = re.fullmatch(r'lib([A-Za-z0-9_]+)(?:\.\d[\w.]*)?\.(?:dylib|tbd)', name)
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


def resolved_settings(project_path, target_name):
    """Ask xcodebuild for the target's build settings.

    Xcode expands `$(SRCROOT)`, `$(inherited)` and the project's own defaults,
    and it knows about settings defined in xcconfig files. Reimplementing that
    from the project file is a losing game, so the real thing is used.
    """
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

    # `-showBuildSettings` does not resolve [arch=...] conditionals, but some
    # projects rely on them: Mupen64Plus sets NEW_DYNAREC=NEW_DYNAREC_ARM64
    # that way, and the JIT sources will not compile without it. The build is
    # arm64, so merge the arm64 variants in directly from the project file.
    try:
        text = open(os.path.join(project_path, 'project.pbxproj'), encoding='utf-8', errors='ignore').read()
    except OSError:
        text = ''
    for m in re.finditer(r'"([A-Za-z_][A-Za-z0-9_]*)\[arch=arm64\]" = \(\n(.*?)\n\t+\);', text, re.S):
        key = m.group(1)
        entries = [e for e in re.findall(r'"([^"]*)"', m.group(2)) if e != '$(inherited)']
        if entries:
            settings[key] = (settings.get(key, '') + ' ' + ' '.join(entries)).strip()

    return settings


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('core')
    parser.add_argument('--json', action='store_true', help='print JSON (the default)')
    parser.add_argument('--shell', action='store_true',
                        help='print shell variable assignments instead of JSON')
    parser.add_argument('--exclude-target', action='append', default=[],
                        help='skip the sources of a dependent target by name '
                             '(repeatable). Used when a core ships several '
                             'video plugins and only one can build on iOS, '
                             'e.g. Mupen64Plus without GLideN64.')
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
    objects = read_project(pbxproj)

    # The target is usually named after the core. Fall back to the only target
    # if that does not match (e.g. picodrive lives in target Picodrive).
    target_id = find_target(objects, args.core)
    target_name = args.core
    if target_id is None:
        targets = [(key, value['name']) for key, value in objects.items()
                   if value.get('isa') == 'PBXNativeTarget']
        if len(targets) == 1:
            target_id, target_name = targets[0]
        else:
            print(f'error: cannot pick a target for {args.core}: '
                  f'{", ".join(n for _, n in targets)}', file=sys.stderr)
            return 1

    settings = resolved_settings(project_path, target_name)
    file_paths = file_reference_paths(objects)

    # Source paths are relative to the project directory. Targets the core
    # depends on contribute their sources too (see dependent_target_ids).
    # Named excluded targets stay out (see --exclude-target).
    excluded_ids = set()
    for name in args.exclude_target:
        excluded_id = find_target(objects, name)
        if excluded_id is None:
            print(f'warning: --exclude-target {name}: no such target', file=sys.stderr)
        else:
            excluded_ids.add(excluded_id)

    sources = []
    seen_sources = set()
    for owner in [target_id] + dependent_target_ids(objects, target_id):
        if owner in excluded_ids:
            continue
        for path, flags in phase_files(objects, owner, 'PBXSourcesBuildPhase', file_paths):
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
    frameworks = [p for p, _ in phase_files(objects, target_id, 'PBXFrameworksBuildPhase', file_paths)]
    libraries = framework_system_libraries(objects, target_id)

    # Data files from the target's Resources phase. Localizations arrive as
    # *.lproj paths, which the build script copies as a folder of their own, so
    # they are left out here.
    resources = []
    seen_resources = set()
    for owner in [target_id] + dependent_target_ids(objects, target_id):
        if owner in excluded_ids:
            continue
        for path, _ in phase_files(objects, owner, 'PBXResourcesBuildPhase', file_paths):
            if '.lproj/' in path:
                continue
            full = os.path.normpath(os.path.join(core_dir, path))
            if full in seen_resources or not os.path.isfile(full):
                continue
            seen_resources.add(full)
            resources.append(full)

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
        'resources': resources,
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
        print("RESOURCES=(" + " ".join(shlex.quote(r) for r in info['resources']) + ")")
        print(f"CSTD={shlex.quote(info['cStandard'])}")
        print(f"CXXSTD={shlex.quote(info['cxxStandard'])}")
        print(f"INFO_PLIST={shlex.quote(info['infoPlist'])}")
        return 0

    print(json.dumps(info, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
