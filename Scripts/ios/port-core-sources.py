#!/usr/bin/env python3
"""Make a core's OpenEmu glue compile for iOS.

The cores were written for macOS. Almost all of what stops them building for
iOS is in the glue file — the small Objective-C class that adapts the emulator
to `OEGameCore`. The emulator itself is portable C and is left alone.

Three changes, all mechanical:

1. Drop the Cocoa import. The SDK's `OEGameCore.h` already brings in what the
   glue needs, and on iOS `OEPlatform.h` supplies the platform differences.

2. Drop the OpenGL import. It is there for the `GL_*` constants used to
   describe the pixel format. `OEGameCore.h` defines the same numbers as
   `OEPixelFormat_*` and `OEPixelType_*`, so the constants are renamed rather
   than the header kept.

3. Note anything that still needs a human. A core that makes real OpenGL calls,
   or that imports IOKit, cannot be fixed mechanically and is reported.

Usage:
    port-core-sources.py [CoreName...] [--dry-run] [--check]
"""

import argparse
import os
import re
import sys

# The glue file is the one that subclasses OEGameCore.
GLUE_PATTERN = re.compile(r'GameCore\.(m|mm|h)$')

# Headers that do not exist on iOS, and what to do about them.
DROP_IMPORTS = [
    (re.compile(r'^#import <Cocoa/Cocoa\.h>\n', re.M), ''),
    (re.compile(r'^#import <AppKit/AppKit\.h>\n', re.M), ''),
    (re.compile(r'^#import <OpenGL/gl\.h>\n', re.M), ''),
    (re.compile(r'^#import <OpenGL/gl3\.h>\n', re.M), ''),
    (re.compile(r'^#import <OpenGL/glu\.h>\n', re.M), ''),
    (re.compile(r'^#include <OpenGL/gl\.h>\n', re.M), ''),
    (re.compile(r'^#include <OpenGL/gl3\.h>\n', re.M), ''),
]

# Pixel format constants. These are the same numbers on both platforms; the SDK
# just spells them without the GL prefix.
PIXEL_FORMATS = ['LUMINANCE', 'RGB', 'BGR', 'RGBA', 'BGRA']
PIXEL_TYPES = [
    'UNSIGNED_BYTE',
    'UNSIGNED_SHORT_5_6_5',
    'UNSIGNED_SHORT_5_6_5_REV',
    'UNSIGNED_SHORT_4_4_4_4',
    'UNSIGNED_SHORT_4_4_4_4_REV',
    'UNSIGNED_SHORT_5_5_5_1',
    'UNSIGNED_SHORT_1_5_5_5_REV',
    'UNSIGNED_INT_8_8_8_8',
    'UNSIGNED_INT_8_8_8_8_REV',
    'UNSIGNED_INT_10_10_10_2',
    'UNSIGNED_INT_2_10_10_10_REV',
]

# Things that need a person to look at them.
NEEDS_REVIEW = {
    r'#import <IOKit/': 'imports IOKit, which iOS does not have',
    r'#import <Carbon/': 'imports Carbon, which iOS does not have',
    r'#import <CoreAudio/': 'imports CoreAudio directly',
    r'\bNSEvent\b': 'uses NSEvent',
    r'\bNSImage\b': 'uses NSImage',
    r'\bNSView\b|\bNSWindow\b': 'uses AppKit views',
    r'\bgl[A-Z]\w*\s*\(': 'makes OpenGL calls',
    r'\bCGL\w*\s*\(': 'uses CGL, which iOS does not have',
}


def glue_files(core_dir):
    """Return the glue files for a core, most specific first.

    Matched on filename alone. The implementation file often only imports its
    own header and never mentions OEGameCore by name, so requiring that string
    would skip exactly the files that need changing.
    """
    found = []
    for root, dirs, files in os.walk(core_dir):
        dirs[:] = [d for d in dirs if d not in ('build', '.git')]
        for name in files:
            if not GLUE_PATTERN.search(name):
                continue
            found.append(os.path.join(root, name))
    return sorted(found, key=lambda p: (p.count(os.sep), len(p)))


def port_file(path, dry_run=False):
    """Apply the mechanical changes to one file. Returns (changed, notes)."""
    text = open(path, encoding='utf-8', errors='ignore').read()
    original = text
    notes = []

    for pattern, replacement in DROP_IMPORTS:
        if pattern.search(text):
            text = pattern.sub(replacement, text)
            notes.append(f"dropped {pattern.pattern.strip('^').split('<')[1].split('>')[0]}")

    for name in PIXEL_FORMATS:
        text = re.sub(r'\bGL_' + name + r'\b', f'OEPixelFormat_{name}', text)
    for name in PIXEL_TYPES:
        text = re.sub(r'\bGL_' + name + r'\b', f'OEPixelType_{name}', text)

    if text != original:
        for name in PIXEL_FORMATS + PIXEL_TYPES:
            if f'OEPixelFormat_{name}' in text or f'OEPixelType_{name}' in text:
                if f'GL_{name}' in original:
                    notes.append(f'renamed GL_{name}')

    # The pixel format methods still say `GLenum`. That type comes from the
    # OpenGL headers, so it has to become a plain integer.
    if re.search(r'\(GLenum\)', text):
        text = re.sub(r'\(GLenum\)', '(uint32_t)', text)
        notes.append('replaced GLenum with uint32_t')

    if text != original and not dry_run:
        open(path, 'w').write(text)

    return text != original, notes


def review_file(path):
    """Report anything in a file that still needs a person."""
    text = open(path, encoding='utf-8', errors='ignore').read()
    found = []
    for pattern, description in NEEDS_REVIEW.items():
        if re.search(pattern, text):
            found.append(description)
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('cores', nargs='*')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--check', action='store_true',
                        help='only report what still needs review')
    args = parser.parse_args()

    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    # A core is a directory with an Xcode project and a glue file. That
    # excludes the SDK, OpenEmuKit and the app, which also have projects.
    NOT_CORES = {
        'OpenEmu-SDK', 'OpenEmu-iOS', 'OpenEmuKit', 'OpenEmu-Shaders',
        'OpenEmu', 'Vendor', 'Scripts', 'docs', 'Casks', 'Appcasts',
        'OpenEmu.iconset', 'OpenEmu-metal.xcworkspace', 'OpenEmu.xcworkspace',
    }

    cores = args.cores
    if not cores:
        cores = []
        for name in sorted(os.listdir(repo)):
            if name in NOT_CORES or name.startswith('.'):
                continue
            core_dir = os.path.join(repo, name)
            if not os.path.isdir(core_dir):
                continue
            if not any(f.endswith('.xcodeproj') for f in os.listdir(core_dir)):
                continue
            if glue_files(core_dir):
                cores.append(name)

    total_changed = 0
    problems = []

    for core in cores:
        core_dir = os.path.join(repo, core)
        if not os.path.isdir(core_dir):
            print(f'warning: no such core: {core}', file=sys.stderr)
            continue

        files = glue_files(core_dir)
        if not files:
            continue

        for path in files:
            relative = os.path.relpath(path, repo)
            changed, notes = port_file(path, dry_run=args.dry_run)
            if changed:
                total_changed += 1
                verb = 'would change' if args.dry_run else 'changed'
                print(f'{verb} {relative}')
                for note in notes:
                    print(f'    {note}')

            remaining = review_file(path)
            if remaining:
                problems.append((relative, remaining))

    print()
    print(f'{total_changed} file(s) {"would be " if args.dry_run else ""}changed')

    if problems:
        print()
        print('still needs review:')
        for relative, reasons in problems:
            print(f'  {relative}')
            for reason in reasons:
                print(f'      {reason}')

    return 0


if __name__ == '__main__':
    sys.exit(main())
