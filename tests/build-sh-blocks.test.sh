#!/usr/bin/bash
#
# Checks the "# ----" blocks in build_files/build.sh.
#
# Usage:
#   ./tests/build-sh-blocks.test.sh
#
# Those rulers make a promise: uncomment every line from one to the other and
# the feature is on, with nothing to find elsewhere in the file. That promise
# is easy to break by accident - add a command outside the rulers, leave a line
# uncommented inside them, forget the closing ruler - and nothing would say so
# until somebody enabled the feature and got a build that failed, or worse, one
# that succeeded while quietly missing a step. That is exactly the shape of
# failure the rest of this directory exists for.
#
# Three things are checked for every block:
#
#   it closes            an opening ruler with no closing one before the next
#                        opening ruler means the reader cannot tell where to
#                        stop uncommenting.
#   it is all commented  a line inside a block that is already live means the
#                        feature is half on, which is how you get a build doing
#                        something nobody chose.
#   it parses            uncommenting the block, exactly as the file tells you
#                        to, must leave build.sh valid shell. This is the check
#                        that would have caught a block split across two places
#                        or one that leans on a line left behind outside it.
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

# The block list, and the per-block checks, in one pass. python3 rather than
# awk because the "uncomment it and parse it" check needs to rewrite the whole
# file per block, and this keeps that in one place instead of three.
python3 - "${BUILD}" "${WORK}" <<'PY' > "${WORK}/report"
import pathlib, re, sys

path, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
lines = path.read_text().splitlines()

OPEN  = re.compile(r'^# --- .* -+$')
CLOSE = re.compile(r'^# -{74}$')

opens = [i for i, l in enumerate(lines) if OPEN.match(l)]
if not opens:
    print("SKIP no ruler blocks in this build.sh")
    raise SystemExit

for n, start in enumerate(opens):
    label = lines[start][6:].rstrip('- ').strip()
    nxt = opens[n + 1] if n + 1 < len(opens) else len(lines)
    close = next((i for i in range(start + 1, nxt) if CLOSE.match(lines[i])), None)

    if close is None:
        print(f"FAIL {label}: no closing ruler before the next block")
        continue
    print(f"PASS {label}: closes at line {close + 1}")

    body = lines[start + 1:close]
    live = [l for l in body if l.strip() and not l.lstrip().startswith('#')]
    if live:
        print(f"FAIL {label}: {len(live)} line(s) inside the block are not commented: {live[0][:50]}")
    else:
        print(f"PASS {label}: every line inside is commented")

    # Uncomment exactly as the file says to, then hand it to bash -n.
    out = lines[:start] + [re.sub(r'^#\s?', '', l, count=1) for l in body] + lines[close + 1:]
    f = work / f"block{n}.sh"
    f.write_text("\n".join(out) + "\n")
    print(f"CHECK {n} {label}")
PY

while read -r verdict rest; do
    case "${verdict}" in
        SKIP)  echo "  skip  ${rest}"; echo; echo "0 passed, 0 failed, 1 skipped"; exit 0 ;;
        PASS)  ok "${rest}" ;;
        FAIL)  bad "${rest}" ;;
        CHECK) n="${rest%% *}"; label="${rest#* }"
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
