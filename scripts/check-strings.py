#!/usr/bin/env python3
"""Checks the app's translations against each other.

    scripts/check-strings.py

Every language in Sources/AgentableApp/Localization/*.lproj (English excepted: its keys are the
English text, so it needs no entries) must have the same keys, no empty values, and the format
specifiers of the English text: the key itself, or for dotted keys ("access.read") whatever the
other languages agree on. Exits 1 on any problem.
"""
import collections
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / 'Sources/AgentableApp/Localization'
ENTRY = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
COMMENT = re.compile(r'/\*.*?\*/', re.S)
SPEC = re.compile(r'%(?:(\d+)\$)?(@|lld|ld|llu|lu|d|lf|f|%)')
DOTTED = re.compile(r'^[a-z]+(\.[a-zA-Z]+)+$')


def specs(text):
    found, index = [], 0
    for match in SPEC.finditer(text):
        if match.group(2) == '%':
            continue
        index += 1
        kind = {'ld': 'lld', 'd': 'lld', 'lu': 'llu', 'f': 'lf'}.get(match.group(2), match.group(2))
        found.append((int(match.group(1)) if match.group(1) else index, kind))
    return tuple(sorted(found))


def load(path):
    lint = subprocess.run(['plutil', '-lint', str(path)], capture_output=True, text=True)
    problems = [] if lint.returncode == 0 else [lint.stdout.strip() or lint.stderr.strip()]
    text = COMMENT.sub('', path.read_text(encoding='utf-8'))
    entries = {}
    for key, value in ENTRY.findall(text):
        if key in entries:
            problems.append(f'duplicate {key!r}')
        entries[key] = value
    if ENTRY.sub('', text).strip():
        problems.append('text that is not an entry or a comment')
    return entries, problems


def main():
    languages = {}
    problems = collections.defaultdict(list)
    for path in sorted(ROOT.glob('*.lproj/Localizable.strings')):
        code = path.parent.stem
        if code == 'en':
            continue
        languages[code], problems[code] = load(path)
    keys = set().union(*(entries.keys() for entries in languages.values()))
    for key in sorted(keys):
        if DOTTED.match(key):
            votes = collections.Counter(specs(e[key]) for e in languages.values() if key in e)
            expected = votes.most_common(1)[0][0]
        else:
            expected = specs(key)
        for code, entries in languages.items():
            if key not in entries:
                problems[code].append(f'missing {key!r}')
            elif not entries[key].strip():
                problems[code].append(f'empty {key!r}')
            elif specs(entries[key]) != expected:
                problems[code].append(f'specifiers differ {key!r}: {entries[key]!r}')
    total = 0
    for code in languages:
        for line in problems[code]:
            print(f'{code}: {line}')
        total += len(problems[code])
    print(f'{len(languages)} languages, {len(keys)} keys, {total} problems')
    return 1 if total else 0


sys.exit(main())
