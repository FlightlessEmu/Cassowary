#!/usr/bin/env python3
"""Build and run the PlayStation frame dumper.

Boots a disc in the SwanStation core on this Mac - no app, no simulator - and
writes the frame the renderer produced to a PPM. Running the same disc with and
without `--software` gives two pictures of the same moment, which is how the
Metal renderer gets compared against the software one:

    Scripts/cassowary/dump-psx-frame.py --game game.bin --out metal.ppm
    Scripts/cassowary/dump-psx-frame.py --game game.bin --out soft.ppm --software
    Scripts/cassowary/compare-psx-frames.py metal.ppm soft.ppm

The build is incremental: object files land in build/psx-frame-dump and only
changed sources are rebuilt, so iterating on a renderer is a few seconds rather
than the minutes an app build and a simulator install take.

Usage:
    dump-psx-frame.py --game FILE --out FILE [--software] [--frames N]
                      [--bios DIR] [--save DIR] [--keep-going]
                      [--press ID,START,END] [--state-at N]

Options:
    --frames N    frames to run before dumping (default 300: a few seconds of
                  emulation, enough for the BIOS to hand over to the disc)
    --bios DIR    BIOS directory (default: the BIOS pack in ~/Downloads if it
                  is there, otherwise no BIOS, which boots OpenBIOS)
    --save DIR    where memory cards go (default: build/psx-frame-dump/save)
    --press ID,START,END
                  hold a RetroPad button (0 is B, the PlayStation's cross;
                  3 is Start) from frame START up to END. Repeatable.
    --state-at N  save a state at frame N, run on to --frames, then load it
                  back and dump the frame after N. Compare it with a plain
                  run of --frames N+1 to check save states.
"""

import argparse
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CORE_DIR = os.path.join(REPO, 'cores', 'SwanStation')
BUILD_DIR = os.path.join(REPO, 'build', 'psx-frame-dump')
OBJECT_DIR = os.path.join(BUILD_DIR, 'obj')
HARNESS = os.path.join(CORE_DIR, 'tools', 'frame-dump.mm')
BINARY = os.path.join(BUILD_DIR, 'psx-frame-dump')

# The glue is the OpenEmu side of the core and needs UIKit; the harness is the
# frontend here, so it is left out.
EXCLUDED_SOURCES = {'SwanStationGameCore.mm'}

COMPILE_FLAGS = ['-std=c++17', '-O1', '-g', '-DSWANSTATION_NO_HW_RENDER_APIS=1']

# Metal and Foundation drag CoreServices in, and its Carbon-era TickCount()
# function collides with the core's TickCount type. The shim pulls those
# headers in first with the name moved aside, so the Objective-C++ sources are
# compiled through it.
SHIM = os.path.join(CORE_DIR, 'tools', 'carbon_tickcount_shim.h')


def core_info():
    """The source list, include paths and defines the core's project states."""
    output = subprocess.run(
        [sys.executable, os.path.join(REPO, 'Scripts', 'cassowary', 'core-info.py'), 'SwanStation'],
        capture_output=True, text=True, check=True).stdout
    return json.loads(output)


def include_flags(info):
    flags = []
    for path in info.get('headerSearchPaths', []):
        flags += ['-I', path]
    # src/common holds a string.h that shadows the system one when it is a
    # plain -I root, so it goes in as a quoted include path instead.
    flags += ['-iquote', os.path.join(CORE_DIR, 'src', 'common')]
    for path in info.get('quoteHeaderSearchPaths', []):
        flags += ['-iquote', path]
    return flags


def compile_command(source, output, includes, defines):
    extension = os.path.splitext(source)[1]
    if extension == '.c':
        compiler = ['xcrun', 'clang', '-std=c11']
    elif extension == '.mm':
        compiler = ['xcrun', 'clang++'] + COMPILE_FLAGS + ['-fobjc-arc', '-include', SHIM]
    else:
        compiler = ['xcrun', 'clang++'] + COMPILE_FLAGS

    return compiler + ['-c', source, '-o', output] + includes + defines + ['-w']


def build(info, verbose):
    os.makedirs(OBJECT_DIR, exist_ok=True)
    includes = include_flags(info)
    defines = list(info.get('otherCFlags', []))

    objects = []
    built = 0
    for entry in info['sources']:
        source = entry['path']
        if os.path.basename(source) in EXCLUDED_SOURCES:
            continue

        object_path = os.path.join(OBJECT_DIR, source.replace('/', '_') + '.o')
        objects.append(object_path)

        if os.path.exists(object_path) and os.path.getmtime(object_path) >= os.path.getmtime(source):
            continue

        command = compile_command(source, object_path, includes, defines)
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stdout)
            print(result.stderr)
            print(f'failed to compile {source}')
            return None
        built += 1

    if verbose or built:
        print(f'compiled {built} of {len(objects)} sources')

    harness_object = os.path.join(OBJECT_DIR, 'frame-dump.mm.o')
    if (not os.path.exists(harness_object)
            or os.path.getmtime(harness_object) < os.path.getmtime(HARNESS)):
        command = compile_command(HARNESS, harness_object, includes, defines)
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stdout)
            print(result.stderr)
            print('failed to compile the harness')
            return None

    link = (['xcrun', 'clang++', '-o', BINARY, harness_object] + objects +
            ['-framework', 'Metal', '-framework', 'Foundation'])
    result = subprocess.run(link, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        print('failed to link')
        return None

    return BINARY


def default_bios():
    candidate = os.path.expanduser('~/Downloads/OpenEmu BIOS Pack')
    return candidate if os.path.isdir(candidate) else ''


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument('--game', required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--frames', type=int, default=300)
    parser.add_argument('--series', type=int, default=0,
                        help='dump this many consecutive frames instead of one, named FILE-0000.ppm onwards')
    parser.add_argument('--bios', default=None)
    parser.add_argument('--save', default=os.path.join(BUILD_DIR, 'save'))
    parser.add_argument('--software', action='store_true')
    parser.add_argument('--vram', default=None, help='also write the renderer VRAM out as a PPM here')
    parser.add_argument('--press', action='append', default=[],
                        help='hold a joypad button for frames ID,START,END (repeatable)')
    parser.add_argument('--state-at', type=int, default=None,
                        help='save a state at this frame, run on, then load it back and dump the frame after it')
    parser.add_argument('--verbose', action='store_true')
    parser.add_argument('--no-build', action='store_true')
    args = parser.parse_args()

    game = os.path.abspath(os.path.expanduser(args.game))
    if not os.path.isfile(game):
        print(f'no such game: {game}', file=sys.stderr)
        return 1

    os.makedirs(args.save, exist_ok=True)

    if not args.no_build:
        binary = build(core_info(), args.verbose)
        if binary is None:
            return 1

    command = [BINARY,
               '--bios', os.path.expanduser(args.bios) if args.bios is not None else default_bios(),
               '--save', args.save,
               '--game', game,
               '--out', os.path.abspath(args.out),
               '--frames', str(args.frames)]
    if args.series:
        command += ['--series', str(args.series)]
    if args.vram:
        command += ['--vram', os.path.abspath(args.vram)]
    for press in args.press:
        command += ['--press', press]
    if args.software:
        command.append('--software')
    if args.state_at is not None:
        command += ['--state-at', str(args.state_at)]

    return subprocess.run(command).returncode


if __name__ == '__main__':
    sys.exit(main())
