#!/usr/bin/env python3
"""Find an ARM64 library using XCFramework platform metadata, not folder names."""
import argparse
from pathlib import Path
import plistlib


def select_library(root, mode):
    platform, variant = {
        'device': ('ios', None), 'simulator': ('ios', 'simulator'),
        'catalyst': ('ios', 'maccatalyst'), 'tvos': ('tvos', None),
        'tvos-sim': ('tvos', 'simulator'), 'macos': ('macos', None),
    }[mode]
    with (root / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    for entry in info['AvailableLibraries']:
        if (entry['SupportedPlatform'] == platform
                and entry.get('SupportedPlatformVariant') == variant
                and 'arm64' in entry['SupportedArchitectures']):
            library = root / entry['LibraryIdentifier'] / entry['LibraryPath']
            if library.suffix == '.framework':
                library = library / library.stem
            if library.is_file():
                return library
    raise ValueError(f'no ARM64 {mode} library in {root}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('xcframework', type=Path)
    parser.add_argument('mode', choices=['device', 'simulator', 'catalyst', 'tvos', 'tvos-sim', 'macos'])
    args = parser.parse_args()
    try:
        print(select_library(args.xcframework, args.mode))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'{error}\n')
