#!/usr/bin/bash
#
# Checks the "# ----" blocks in build_files/build.sh.
#
# Usage:
#   ./tests/build-sh-blocks.test.sh
#
# Those rulers make a promise: everything one feature needs is between them, so
# flipping every line from one ruler to the other turns the feature on or off
# and there is nothing to find elsewhere in the file. That is easy to break by
# accident - add a command outside the rulers, flip half the lines inside them,
# forget the closing ruler - and nothing would say so until somebody enabled the
# feature and got a build that failed, or worse, one that succeeded while
# quietly missing a step.
#
# Four things are checked for every block:
#
#   it is formed         a "# ---" label with no ruler under it, or a ruler with
#                        no label, is a block the reader cannot act on.
#   it closes            an opening ruler with no closing one before the next
#                        block means there is no telling where to stop.
#   it is all one way    every line inside is commented, or every line is live.
#                        A block that is half and half is a feature half turned
#                        on, which is how a build ends up doing something nobody
#                        chose. This is the check that matters in a project
#                        built from the template, where blocks are meant to be
#                        switched on.
#   it parses            a commented block, uncommented exactly as the file says
#                        to, must leave build.sh valid shell. This catches a
#                        block split across two places, or one leaning on a line
#                        left outside it.
#
# Nothing here runs build.sh or needs the network, podman or root - it is
# "bash -n" and some text handling, so it costs a second.
#
# set -e is deliberately absent: this reports every failure rather than
# stopping at the first.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
BUILD="build_files/build.sh"

PASSED=0
FAILED=0
ok()  { printf '  ok    %s\n' "$1"; PASSED=$((PASSED + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAILED=$((FAILED + 1)); }

if [ ! -f "${BUILD}" ]; then
    echo "  skip  ${BUILD} is not present - nothing to check"
    echo
    echo "0 passed, 0 failed, 1 skipped"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# The block list and the per-block checks in one pass. python3 rather than awk
# because the "flip it and parse it" check rewrites the whole file per block,
# and this keeps that in one place instead of three.
python3 - "${BUILD}" "${WORK}" <<'PY' > "${WORK}/report"
import pathlib, re, sys

path, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
lines = path.read_text().splitlines()

LABEL = re.compile(r'^# --- \S')
RULER = re.compile(r'^# -{20,}$')

labels = [i for i, l in enumerate(lines) if LABEL.match(l)]
rulers = [i for i, l in enumerate(lines) if RULER.match(l)]

# Skipping is for a build.sh that has no blocks at all - a project that stripped
# the examples out. Labels without rulers, or rulers without labels, is a broken
# file rather than an absent feature, and says so.
if not labels and not rulers:
    print("SKIP no ruler blocks in this build.sh")
    raise SystemExit
if not labels or not rulers:
    print(f"FAIL {len(labels)} '# ---' labels but {len(rulers)} rulers - one of the two is missing")
    raise SystemExit

for n, start in enumerate(labels):
    label = lines[start][6:].strip()

    if start + 1 >= len(lines) or not RULER.match(lines[start + 1]):
        print(f"FAIL {label}: no ruler under the label")
        continue

    nxt = labels[n + 1] if n + 1 < len(labels) else len(lines)
    close = next((i for i in range(start + 2, nxt) if RULER.match(lines[i])), None)
    if close is None:
        print(f"FAIL {label}: no closing ruler before the next block")
        continue
    print(f"PASS {label}: closes at line {close + 1}")

    # Prose inside a block stays prose whichever way the block is switched:
    # "# ## note" when it is off, "## note" when it is on. Only the command
    # lines say whether the feature is on, so only those are compared.
    def kind(line):
        s = line.lstrip()
        if s.startswith('##'):
            return 'prose'
        if s.startswith('#'):
            return 'prose' if re.sub(r'^#\s?', '', s).startswith('#') else 'off'
        return 'on'

    body = [l for l in lines[start + 2:close] if l.strip()]
    commands = [kind(l) for l in body if kind(l) != 'prose']
    if not commands:
        print(f"FAIL {label}: the block holds no commands")
        continue
    if len(set(commands)) != 1:
        print(f"FAIL {label}: {commands.count('on')} of {len(commands)} commands are "
              f"live and the rest commented - the feature is half on")
        continue
    commented = commands[0] == 'off'
    print(f"PASS {label}: all {len(commands)} commands are {'commented' if commented else 'live'}")

    if not commented:
        # Already switched on; the file as a whole parsing covers it.
        continue
    out = (lines[:start] +
           [re.sub(r'^#\s?', '', l, count=1) for l in lines[start + 2:close]] +
           lines[close + 1:])
    f = work / f"block{n}.sh"
    f.write_text("\n".join(out) + "\n")
    print(f"CHECK {n} {label}")
PY

while read -r verdict rest; do
    case "${verdict}" in
        SKIP)     echo "  skip  ${rest}"; echo; echo "0 passed, 0 failed, 1 skipped"; exit 0 ;;
        PASS)     ok "${rest}" ;;
        FAIL)     bad "${rest}" ;;
        CHECK)    n="${rest%% *}"; label="${rest#* }"
                  if bash -n "${WORK}/block${n}.sh" 2>"${WORK}/err"; then
                      ok "${label}: uncommenting it leaves valid shell"
                  else
                      bad "${label}: uncommenting it breaks build.sh - $(head -n1 "${WORK}/err")"
                  fi ;;
    esac
done < "${WORK}/report"

echo
printf '%s passed, %s failed\n' "${PASSED}" "${FAILED}"
[ "${FAILED}" -eq 0 ]
