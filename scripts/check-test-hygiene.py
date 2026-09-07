#!/usr/bin/env python3
"""Catch test-source defects that no local build on this repo can catch.

Why this exists
---------------
The `analyze` CI job compiles the test target with warnings-as-errors, and its
failure cancels both `test` jobs, so the run reports "cancelled" with no job
reporting "failure". A Mac with only Command Line Tools cannot compile any test
target at all (`no such module 'XCTest'`, thrown from the vendored
SnapshotTesting dependency), and `swift build` only compiles Sources. Those
three facts together mean a defect in a test file is invisible locally and
reports as an ambiguous "cancelled" in CI. Main sat broken for nine commits
that way, with the suite never running, until someone read the analyze log.

This is the mechanical half of that problem: a text-level check that runs in
milliseconds and needs no toolchain.

What it finds
-------------
`let X = ...` inside a function where X is never read again. That is fatal in
the analyze job ("initialization of immutable value 'X' was never used") and is
also the signature of a test whose assertions were deleted while its body was
left behind, which then passes unconditionally forever. Both occurrences found
so far were exactly that.

What it deliberately does not find
----------------------------------
Renames. A test referring to a symbol that no longer exists needs the compiler
or a diff of removed Sources declarations (see CLAUDE.md's note next to the
analyze job). This checker only reports what it can prove from one file's text.

Usage: check-test-hygiene.py <dir> [<dir> ...]
Exit 0 clean, 1 findings, 2 bad invocation.
"""
import pathlib
import re
import sys

# Only simple bindings. A tuple/pattern destructure has its own rules and a
# `_` element is idiomatic there, so those are skipped rather than guessed at.
LET = re.compile(r'^\s*let\s+([a-zA-Z_]\w*)\s*(?::\s*[^=]+?)?=')
FUNC = re.compile(r'^\s*(?:@\w+\s+)*(?:private\s+|internal\s+|public\s+|fileprivate\s+)?'
                  r'(?:static\s+)?func\s+(\w+)')


def findings_in(path: pathlib.Path):
    lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
    out = []
    i = 0
    while i < len(lines):
        match = FUNC.match(lines[i])
        if not match:
            i += 1
            continue
        # Walk to the end of this function by brace depth, starting from the
        # signature line so a same-line `{` is counted.
        depth = lines[i].count('{') - lines[i].count('}')
        end = i + 1
        while end < len(lines) and depth > 0:
            depth += lines[end].count('{') - lines[end].count('}')
            end += 1
        body = lines[i:end]
        for offset, line in enumerate(body):
            binding = LET.match(line)
            if not binding:
                continue
            name = binding.group(1)
            if name == '_':
                continue
            elsewhere = body[:offset] + body[offset + 1:]
            word = re.compile(r'\b' + re.escape(name) + r'\b')
            if not any(word.search(other) for other in elsewhere):
                out.append((path, i + offset + 1, name, match.group(1)))
        i = end
    return out


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    roots = [pathlib.Path(a) for a in argv[1:]]
    missing = [r for r in roots if not r.is_dir()]
    if missing:
        for r in missing:
            print(f"not a directory: {r}", file=sys.stderr)
        return 2

    all_findings = []
    scanned = 0
    for root in roots:
        for path in sorted(root.rglob('*.swift')):
            if '.build' in path.parts:
                continue
            scanned += 1
            all_findings.extend(findings_in(path))

    for path, line, name, func in all_findings:
        print(f"{path}:{line}: error: immutable value '{name}' is never used "
              f"in {func}() (fatal in the analyze CI job; often a test whose "
              f"assertions were deleted)")

    if all_findings:
        print(f"\n{len(all_findings)} finding(s) in {scanned} file(s).", file=sys.stderr)
        return 1
    # Say the file count: a silent pass over zero files reads identically to a
    # clean run, and a wrong path argument is the likely cause.
    print(f"OK — no unused test bindings in {scanned} file(s).")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
