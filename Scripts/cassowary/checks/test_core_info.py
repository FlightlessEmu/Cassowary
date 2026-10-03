#!/usr/bin/env python3
"""Check project paths, dependent source flags, system libraries, and arm64 settings."""

from pathlib import Path
import plistlib
import runpy
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

core = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'core-info.py'))


def main():
    objects = {
        'root': {'isa': 'PBXGroup', 'path': 'wrapper', 'children': ['src', 'direct', 'absolute']},
        'src': {'isa': 'PBXGroup', 'path': 'src', 'sourceTree': 'SOURCE_ROOT', 'children': ['nested']},
        'nested': {'isa': 'PBXGroup', 'path': 'engine', 'children': ['cpu']},
        'cpu': {'isa': 'PBXFileReference', 'path': 'cpu.c', 'sourceTree': '<group>'},
        'direct': {'isa': 'PBXFileReference', 'path': 'core.m', 'sourceTree': 'SOURCE_ROOT'},
        'absolute': {'isa': 'PBXGroup', 'path': '/external', 'sourceTree': '<absolute>', 'children': ['external']},
        'external': {'isa': 'PBXFileReference', 'path': 'external.c', 'sourceTree': '<group>'},
        'z': {'isa': 'PBXFileReference', 'path': 'usr/lib/libz.tbd', 'sourceTree': 'SDKROOT'},
        'lzma': {'isa': 'PBXFileReference', 'name': 'liblzma.5.dylib', 'path': 'usr/lib/liblzma.dylib', 'sourceTree': 'SDKROOT'},
        'cocoa': {'isa': 'PBXFileReference', 'path': 'System/Library/Frameworks/Cocoa.framework', 'sourceTree': 'SDKROOT'},
        'build_core': {'isa': 'PBXBuildFile', 'fileRef': 'direct'},
        'build_cpu': {'isa': 'PBXBuildFile', 'fileRef': 'cpu', 'settings': {'COMPILER_FLAGS': '-DSINGLE_THREADED=1 -DNO_HASH'}},
        'build_z': {'isa': 'PBXBuildFile', 'fileRef': 'z'},
        'build_lzma': {'isa': 'PBXBuildFile', 'fileRef': 'lzma'},
        'build_cocoa': {'isa': 'PBXBuildFile', 'fileRef': 'cocoa'},
        'sources': {'isa': 'PBXSourcesBuildPhase', 'files': ['build_core']},
        'helper_sources': {'isa': 'PBXSourcesBuildPhase', 'files': ['build_cpu']},
        'frameworks': {'isa': 'PBXFrameworksBuildPhase', 'files': ['build_z', 'build_lzma', 'build_z', 'build_cocoa']},
        'main': {'isa': 'PBXNativeTarget', 'name': 'Core', 'buildPhases': ['sources', 'frameworks'], 'dependencies': ['helper_dep']},
        'helper': {'isa': 'PBXNativeTarget', 'name': 'Helper', 'buildPhases': ['helper_sources'], 'dependencies': ['main_dep']},
        'helper_dep': {'isa': 'PBXTargetDependency', 'target': 'helper'},
        'main_dep': {'isa': 'PBXTargetDependency', 'target': 'main'},
    }
    with tempfile.TemporaryDirectory() as folder:
        project = Path(folder) / 'Core.xcodeproj'
        project.mkdir()
        path = project / 'project.pbxproj'
        path.write_bytes(plistlib.dumps({'objects': objects}))
        loaded = core['read_project'](str(path))
        assert loaded == objects
        assert core['find_target'](loaded, 'Core') == 'main'
        paths = core['file_reference_paths'](loaded)
        assert paths['cpu'] == 'src/engine/cpu.c'
        assert paths['direct'] == 'core.m'
        assert paths['external'] == '/external/external.c'
        assert paths['z'] is None
        owners = ['main'] + core['dependent_target_ids'](loaded, 'main')
        assert owners == ['main', 'helper']
        sources = [entry for owner in owners for entry in
                   core['phase_files'](loaded, owner, 'PBXSourcesBuildPhase', paths)]
        assert sources == [('core.m', ''), ('src/engine/cpu.c', '-DSINGLE_THREADED=1 -DNO_HASH')]
        assert core['framework_system_libraries'](loaded, 'main') == ['z', 'lzma']
    project = Path(__file__).resolve().parents[3] / 'cores/Mupen64Plus/Mupen64Plus.xcodeproj'
    stdout = ('    OTHER_CFLAGS = -DBASE -DPACKAGE=\\"demo\\"\n'
              '    GCC_PREPROCESSOR_DEFINITIONS = BASE=1\n'
              '    HEADER_SEARCH_PATHS = "/source with spaces/include"\n')
    with patch('subprocess.run', return_value=SimpleNamespace(stdout=stdout)) as run:
        settings = core['resolved_settings'](str(project), 'Mupen64Plus')
    assert '-showBuildSettings' in run.call_args.args[0]
    plugin_flags = ['-DIN_OPENEMU', '-DM64P_PARALLEL', '-DNDEBUG', '-DNOCRYPT',
                    '-DNOUNCRYPT', '-fno-strict-aliasing']
    assert core['split_list'](settings['OTHER_CFLAGS']) == (
        ['-DBASE', '-DPACKAGE="demo"'] + plugin_flags * 2 + ['-DUSE_SSE2NEON'] * 2)
    assert settings['GCC_PREPROCESSOR_DEFINITIONS'] == (
        'BASE=1 NEW_DYNAREC=NEW_DYNAREC_ARM64 NEW_DYNAREC=NEW_DYNAREC_ARM64')
    assert core['split_list'](settings['HEADER_SEARCH_PATHS']) == ['/source with spaces/include']
    print('Core project checks passed: nested paths, dependency flags, system libraries, arm64 settings.')


if __name__ == '__main__':
    main()
