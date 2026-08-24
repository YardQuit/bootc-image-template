#!/usr/bin/bash
#
# Tests for the placeholder-password guard in scripts/build-disk.sh.
#
# Usage:
#   ./tests/build-disk-guard.test.sh
#
# disk_config/disk.toml defines a user in wheel, and ships the password as the
# placeholder "changeme". build-disk.sh refuses to build a disk image while it
# still says that, because the result would be a sudo-capable login whose
# password is published in this repository.
#
# A guard like that has two halves, and only one of them is obvious. Refusing
# the placeholder is the half everyone tests. Letting a correctly configured
# file through is the half that breaks silently: the first version of this
# guard matched "changeme" anywhere in the file, and the comments above the
# password quote it twice while explaining what the placeholder is - so it
# refused every disk build forever, and the only way out was deleting the
# documentation. Both halves are tested here.
#
# Nothing here builds anything: every case runs build-disk.sh with --check, so
# it stops after the guard. That is not a detail - without it, the cases that
# expect the guard to stay quiet run the builder for real.
#
# set -e is deliberately absent: most of these run a command meant to fail.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO="${PWD}"
CONFIG="disk_config/disk.toml"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

ok()  { printf '  ok    %s\n' "$1"; PASSED=$((PASSED + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAILED=$((FAILED + 1)); }

# A throwaway copy of the repository, for the same reason the rename tests use
# one: no git, so this works in a fresh copy of the template too.
tree() {
    local dst="${WORK}/$1"
    rm -rf "${dst}"
    mkdir -p "${dst}"
    tar -cf - -C "${REPO}" \
        --exclude=./.git --exclude=./output --exclude='./_build*' . \
        | tar -xf - -C "${dst}"
    printf '%s' "${dst}"
}

# Did the guard fire?
#
# --check, so that build-disk.sh stops after the guard instead of going on to
# build. Without it the cases that expect the guard NOT to fire each run a real
# "sudo podman run --privileged" builder to completion - four qcow2 builds and
# an ISO - on any machine that happens to have localhost/<name>:latest, which
# is to say right after ./scripts/build.sh. That is exactly what this file
# looked like before, and it seemed harmless only because the image was absent
# and podman failed first.
#
# The output is captured before it is searched, not piped into grep: "grep -q"
# exits at the first match and closes the pipe, build-disk.sh then dies of
# SIGPIPE, and under "set -o pipefail" that non-zero status makes a successful
# match look like no match at all. Every case would report "no" - including the
# ones that expect it, which would then pass for the wrong reason.
guard_fired() {  # $1 tree, $2 disk type
    local out rc=0
    out="$( cd "$1" && ./scripts/build-disk.sh --check "$2" 2>&1 )" || rc=$?

    if grep -q "placeholder password" <<<"${out}"; then
        # Printing the message is not the guard working - stopping the build is.
        # A guard that says its piece and then goes on to build the image is
        # precisely the failure this file exists to catch, so that gets its own
        # answer rather than passing as "yes".
        if [ "${rc}" -ne 0 ]; then
            printf 'yes'
        else
            printf 'yes(but exit 0)'
        fi
    elif [ "${rc}" -ne 0 ]; then
        # Neither outcome: the script failed for some other reason. Reporting
        # that as "no" would let every case that expects the guard to stay
        # quiet pass against a script that never reached the guard at all -
        # a broken build-disk.sh would take this whole suite green with it.
        printf 'died(exit %s)' "${rc}"
    else
        printf 'no'
    fi
}

check() {  # $1 what, $2 got, $3 want
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 - guard fired: $2, wanted: $3"; fi
}

T="$(tree preflight)"
if [ ! -x "${T}/scripts/build-disk.sh" ] || [ ! -f "${T}/${CONFIG}" ]; then
    echo "Error: ${REPO} does not look like this template - the copy has no" >&2
    echo "scripts/build-disk.sh or ${CONFIG}. Run this from inside the" >&2
    echo "repository." >&2
    exit 1
fi


echo "The placeholder is refused"
T="$(tree untouched)"
check "an unedited disk.toml stops the build"    "$(guard_fired "${T}" qcow2)" "yes"
check "so does a raw build"                      "$(guard_fired "${T}" raw)"   "yes"


echo
echo "A configured file is let through"
# This is the half the first version of the guard got wrong.
T="$(tree hashed)"
sed -i 's|^password = "changeme"|password = "$6$salt$hashhashhash"|' "${T}/${CONFIG}"
check "a hashed password proceeds"               "$(guard_fired "${T}" qcow2)" "no"

T="$(tree plaintext)"
sed -i 's|^password = "changeme"|password = "something-else"|' "${T}/${CONFIG}"
check "a different plaintext password proceeds"  "$(guard_fired "${T}" qcow2)" "no"

T="$(tree sshkey)"
sed -i -e 's|^password = "changeme"|# password = "changeme"|' \
       -e 's|^# key = |key = |' "${T}/${CONFIG}"
check "an SSH key with no password proceeds"     "$(guard_fired "${T}" qcow2)" "no"

# The comments explaining the placeholder quote it, and must not count as the
# setting. This is the exact case that made the guard unsatisfiable.
T="$(tree comments)"
sed -i 's|^password = "changeme"|password = "set-properly"|' "${T}/${CONFIG}"
if grep -q '"changeme"' "${T}/${CONFIG}"; then
    ok    "the comments still quote the placeholder (so this case is real)"
else
    bad   "the comments no longer quote the placeholder - this test proves nothing"
fi
check "quoted in a comment does not count"       "$(guard_fired "${T}" qcow2)" "no"


echo
echo "The ISO never reads this file"
# iso.toml has no user block: Anaconda asks at install time.
T="$(tree iso)"
check "an unedited disk.toml does not block an ISO" "$(guard_fired "${T}" iso)" "no"


echo
printf '%s passed, %s failed\n' "${PASSED}" "${FAILED}"
[ "${FAILED}" -eq 0 ]
