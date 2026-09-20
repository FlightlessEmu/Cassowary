#!/usr/bin/env python3
"""Set or replace a build setting on specific targets in an Xcode project.

`xcodeproj_add_setting.py` only adds settings that are missing. This one also
replaces an existing value, which is what you need when a project deliberately
sets something to NO and you want it YES.

Only the target's own configurations are touched, so project-level defaults and
other targets are left alone.

Usage:
    xcodeproj_set_setting.py <project.pbxproj> <target>... --setting NAME=VALUE
"""

import argparse
import re
import sys

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from xcodeproj_add_setting import object_body, target_configurations


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
    replaced = 0
    added = 0

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

            for name, value in settings:
                pattern = re.compile(r'^(\t\t\t\t' + re.escape(name) + r' = )[^;]*;', re.M)
                if pattern.search(body):
                    body, n = pattern.subn(lambda m: m.group(1) + value + ';', body)
                    replaced += n
                else:
                    m = re.search(r'buildSettings = \{\n', body)
                    if m is None:
                        continue
                    body = body[:m.end()] + f'\t\t\t\t{name} = {value};\n' + body[m.end():]
                    added += 1

            text = text[:span[0]] + body + text[span[1]:]

    open(args.project, 'w').write(text)
    print(f'{replaced} setting(s) replaced, {added} added')
    return 0


if __name__ == '__main__':
    sys.exit(main())
