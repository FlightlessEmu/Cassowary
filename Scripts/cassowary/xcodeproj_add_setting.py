#!/usr/bin/env python3
"""Add a build setting to specific targets in an Xcode project.

Like `xcodeproj_add_files.py`, this only inserts lines. It does not reserialise
the project, so the diff stays readable.

Usage:
    xcodeproj_add_setting.py <project.pbxproj> <target>... --setting NAME=VALUE
"""

import argparse
import re
import sys

SETTING_RE = re.compile(r'^\t\t\t\t([A-Za-z_][A-Za-z0-9_]*) = ', re.M)


def object_body(text, object_id):
    """Return the span of `ID ... = { ... };`, matching braces."""
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


def target_configurations(text, target_name):
    """Return the ids of the build configurations belonging to a target."""
    target_id = None
    for m in re.finditer(r'^\t\t([0-9A-F]{24}) /\* ' + re.escape(target_name) + r' \*/ = \{', text, re.M):
        span = object_body(text, m.group(1))
        if span and 'isa = PBXNativeTarget;' in text[span[0]:span[1]]:
            target_id = m.group(1)
            break

    if target_id is None:
        return []

    span = object_body(text, target_id)
    m = re.search(r'buildConfigurationList = ([0-9A-F]{24})', text[span[0]:span[1]])
    if m is None:
        return []

    list_span = object_body(text, m.group(1))
    return re.findall(r'([0-9A-F]{24}) /\* [^*]+ \*/,', text[list_span[0]:list_span[1]])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('project')
    parser.add_argument('targets', nargs='+')
    parser.add_argument('--setting', action='append', required=True,
                        help='NAME=VALUE, repeatable')
    args = parser.parse_args()

    settings = []
    for entry in args.setting:
        name, _, value = entry.partition('=')
        settings.append((name, value))

    text = open(args.project).read()
    changed = 0

    for target_name in args.targets:
        config_ids = target_configurations(text, target_name)
        if not config_ids:
            print(f'warning: no build configurations found for {target_name}', file=sys.stderr)
            continue

        for config_id in config_ids:
            span = object_body(text, config_id)
            if span is None:
                continue
            body = text[span[0]:span[1]]

            additions = []
            for name, value in settings:
                if re.search(r'\b' + re.escape(name) + r' = ', body):
                    continue
                additions.append(f'\t\t\t\t{name} = {value};')

            if not additions:
                continue

            # Insert after buildSettings = { so the setting lands in the right
            # dictionary rather than at the top of the configuration object.
            m = re.search(r'buildSettings = \{\n', body)
            if m is None:
                continue
            insert_at = span[0] + m.end()
            text = text[:insert_at] + '\n'.join(additions) + '\n' + text[insert_at:]
            changed += len(additions)

    open(args.project, 'w').write(text)
    print(f'{changed} setting(s) added')
    return 0


if __name__ == '__main__':
    sys.exit(main())
