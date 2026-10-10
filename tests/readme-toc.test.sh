#!/usr/bin/bash
#
# Checks that README.md's table of contents still matches its headings.
#
# Usage:
#   ./tests/readme-toc.test.sh
#
# A table of contents is the kind of thing that rots without anyone noticing:
# rename a section and the link keeps rendering, it just goes nowhere. That is
# the same shape as the other things tested here - it fails quietly - so it gets
# checked rather than trusted.
#
# The TOC lives between <!-- toc --> and <!-- /toc --> markers. A project built
# from this template that wrote its own README has no markers and nothing to
# check, so this skips rather than fails; the same reasoning as the README
# assertions in set-image-name.test.sh.
#
# On a mismatch it prints the corrected block, so fixing it is a paste.
#
# set -e is deliberately absent: this reports rather than aborts.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
README="README.md"

if [ ! -f "${README}" ]; then
    echo "  skip  README.md is not present - nothing to check"
    echo
    echo "0 passed, 0 failed, 1 skipped"
    exit 0
fi

if ! grep -q '^<!-- toc -->$' "${README}"; then
    echo "  skip  this README has no <!-- toc --> block - nothing to check"
    echo
    echo "0 passed, 0 failed, 1 skipped"
    exit 0
fi

# The generator and the comparison are the same code path, so the block this
# prints on failure is exactly the block that would then pass.
GENERATED="$(python3 - "${README}" <<'PY'
import re, sys, pathlib

def slug(text):
    # GitHub's heading anchors: strip inline markup, lowercase, drop everything
    # that is not alphanumeric, space, hyphen or underscore, then spaces to
    # hyphens. "Signing (required)" -> "signing-required".
    t = re.sub(r'`([^`]*)`', r'\1', text)
    t = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', t)
    t = t.strip().lower()
    t = ''.join(c for c in t if c.isalnum() or c in ' -_')
    return t.replace(' ', '-')

fence, out = False, []
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.startswith("```"):
        fence = not fence
        continue
    if fence:
        # A "## " inside a fenced block is sample content, not a heading.
        continue
    m = re.match(r'^(#{2,3})\s+(.*)$', line)
    if m:
        depth, title = len(m.group(1)) - 2, m.group(2).strip()
        out.append(f"{'  ' * depth}- [{title}](#{slug(title)})")
print("\n".join(out))
PY
)"

CURRENT="$(sed -n '/^<!-- toc -->$/,/^<!-- \/toc -->$/p' "${README}" \
           | sed -e '1d' -e '$d' -e '/^$/d')"

if [ "${CURRENT}" = "${GENERATED}" ]; then
    echo "  ok    the table of contents matches the headings"
    echo
    echo "1 passed, 0 failed"
    exit 0
fi

echo "  FAIL  the table of contents does not match the headings" >&2
echo >&2
diff <(printf '%s\n' "${CURRENT}") <(printf '%s\n' "${GENERATED}") \
    | sed 's/^/    /' >&2
echo >&2
echo "Replace the lines between the <!-- toc --> markers with:" >&2
echo >&2
printf '%s\n' "${GENERATED}" | sed 's/^/  /' >&2
echo >&2
echo "0 passed, 1 failed"
exit 1
