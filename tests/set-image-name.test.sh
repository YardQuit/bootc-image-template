#!/usr/bin/bash
#
# Tests for scripts/set-image-name.sh.
#
# Usage:
#   ./tests/set-image-name.test.sh
#
# The rename script rewrites the image name and owner across the whole
# repository with whole-word text substitution, guarded in four different ways
# (Donkey package paths, the template-literal block in README.md, values that
# overlap each other, and the placeholder repair pass). When one of those
# guards is wrong the script does not crash - it writes a plausible-looking
# file, the build stays green, and the first symptom is a machine that cannot
# upgrade. So the guards get tested.
#
# Every test runs against a throwaway copy of the working tree, including
# uncommitted changes, so this is worth running before pushing a change to the
# script as well as in CI. Nothing here needs the network, podman or root, and
# the whole file takes a couple of seconds.
#
# set -e is deliberately absent: most of these tests run a command that is
# meant to fail and check how it failed.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO="${PWD}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

ok()   { printf '  ok    %s\n' "$1"; PASSED=$((PASSED + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAILED=$((FAILED + 1)); }
check() {  # $1 what, $2 got, $3 want
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 - got '$2', wanted '$3'"; fi
}

# A throwaway copy of the working tree, as git sees it: tracked files only, but
# with whatever is in them right now. $1 is a name under the temp directory.
tree() {
    local dst="${WORK}/$1"
    rm -rf "${dst}"
    mkdir -p "${dst}"
    ( cd "${REPO}" && git ls-files -z | tar --null -T - -cf - ) | tar -xf - -C "${dst}"
    printf '%s' "${dst}"
}

# Run the script inside a copy, discarding its output. Echoes the exit status.
run() {  # $1 tree, rest: arguments
    local dir="$1"; shift
    ( cd "${dir}" && ./scripts/set-image-name.sh "$@" >/dev/null 2>&1 )
    printf '%s' "$?"
}

# A fingerprint of every file in a tree, for comparing two trees or one tree
# against its earlier self.
fingerprint() {  # $1 tree
    ( cd "$1" && find . -type f -exec md5sum {} + | sort | md5sum )
}


echo "An untouched template"
T="$(tree pristine)"
check "--check passes"                    "$(run "${T}" --check)"           "0"
check "--check rejects extra arguments"   "$(run "${T}" --check extra)"     "1"
check "no arguments is a usage error"     "$(run "${T}")"                   "1"


echo
echo "Renaming"
T="$(tree renamed)"
check "rename succeeds"                   "$(run "${T}" vaulted claudetest)" "0"
check "--check passes afterwards"         "$(run "${T}" --check)"            "0"

grep -q 'ghcr\.io/claudetest/vaulted' "${T}/disk_config/iso.toml"
check "the ISO kickstart follows"         "$?" "0"
grep -q 'ghcr\.io/claudetest/vaulted' \
    "${T}/build_files/sysfiles/etc/containers/registries.d/sigstore-attachments.yaml"
check "the registries.d scope follows"    "$?" "0"
grep -q 'IMAGE_REPO:-ghcr\.io/claudetest/vaulted' "${T}/build_files/build.sh"
check "the policy fallback follows"       "$?" "0"
grep -q 'IMAGE_NAME: "vaulted"' "${T}/.github/workflows/build.yml"
check "both workflows follow"             "$?" "0"

# README.md documents the template's own placeholders between HTML-comment
# markers. Rewriting those turns the section that explains the placeholders
# into a description of the reader's own image, and would make --check flag
# its own documentation on every run.
grep -q "starts life as the template's \`myimage\` and" "${T}/README.md"
check "guarded README literals survive"   "$?" "0"

# Everywhere else in the README the name is the reader's, and does follow.
grep -q '^# Vaulted' "${T}/README.md"
check "README prose is renamed"           "$?" "0"

before="$(fingerprint "${T}")"
run "${T}" vaulted claudetest >/dev/null
check "re-running changes nothing"        "$(fingerprint "${T}")" "${before}"

check "a second rename succeeds"          "$(run "${T}" terrene claudetest)" "0"
grep -q 'ghcr\.io/claudetest/terrene' "${T}/disk_config/iso.toml"
check "the second rename lands"           "$?" "0"


echo
echo "Renaming without an owner"
T="$(tree nameonly)"
run "${T}" vaulted >/dev/null
grep -q 'ghcr\.io/myorg/vaulted' "${T}/disk_config/iso.toml"
check "the owner is left alone"           "$?" "0"
# "myorg" is still the owner in use here, so it is not a leftover.
check "--check passes"                    "$(run "${T}" --check)"            "0"


echo
echo "Files copied down from the template after a rename"
CLEAN="$(tree clean)"
run "${CLEAN}" vaulted claudetest >/dev/null

STALE="$(tree stale)"
run "${STALE}" vaulted claudetest >/dev/null
# The upstream versions of the files most likely to be synced for a fix.
for f in build_files/build.sh \
         build_files/sysfiles/etc/containers/registries.d/sigstore-attachments.yaml \
         build_files/sysfiles/etc/motd.d/10-welcome; do
    cp "${REPO}/${f}" "${STALE}/${f}"
done

check "--check catches them"              "$(run "${STALE}" --check)"        "1"

# Three different files are stale here, so the listing crosses two file
# boundaries. Every match has to start its own line: each file is grepped
# separately, and a command substitution strips trailing newlines, so appending
# one file's output straight onto the previous one runs the last match of one
# into the first match of the next. Checking that the second and third files
# each begin a line is what catches that.
out="$( cd "${STALE}" && ./scripts/set-image-name.sh --check 2>&1 )"
grep -q '^  build_files/build\.sh:' <<<"${out}" \
    && grep -q '^  build_files/sysfiles/etc/containers/registries\.d/' <<<"${out}"
check "every match starts its own line" "$?" "0"

check "re-running the rename repairs"     "$(run "${STALE}" vaulted claudetest)" "0"
check "--check passes afterwards"         "$(run "${STALE}" --check)"        "0"
check "the repair equals a clean rename"  "$(fingerprint "${STALE}")" "$(fingerprint "${CLEAN}")"


echo
echo "Values that cannot be told apart"
T="$(tree overlap)"
# "myorg-labs" contains "myorg" at word boundaries, so a pass for the
# placeholder would eat half of it. Both the repair and --check have to stand
# down rather than corrupt the file - and say so rather than stay quiet.
run "${T}" vaulted myorg-labs >/dev/null
out="$( cd "${T}" && ./scripts/set-image-name.sh vaulted myorg-labs 2>&1 )"
grep -q "leaving 'myorg' alone" <<<"${out}"
check "the repair stands down, and says so" "$?" "0"
out="$( cd "${T}" && ./scripts/set-image-name.sh --check 2>&1 )"
grep -q "cannot check for 'myorg'" <<<"${out}"
check "--check stands down, and says so"  "$?" "0"
check "--check does not fail on it"       "$(run "${T}" --check)"            "0"


echo
echo "Refusals"
T="$(tree refuse)"
before="$(fingerprint "${T}")"
check "'donkey' is refused"               "$(run "${T}" donkey)"             "1"
check "'emacs' is refused"                "$(run "${T}" emacs)"              "1"
check "a name equal to the owner"         "$(run "${T}" zonk zonk)"          "1"
check "a name ending in a dash"           "$(run "${T}" 'bad-')"             "1"
check "an owner ending in a dash"         "$(run "${T}" good 'bad-')"        "1"
check "nothing was written"               "$(fingerprint "${T}")" "${before}"


echo
echo "--dry-run"
T="$(tree dryrun)"
before="$(fingerprint "${T}")"
check "succeeds"                          "$(run "${T}" --dry-run vaulted claudetest)" "0"
check "writes nothing"                    "$(fingerprint "${T}")" "${before}"


echo
printf '%s passed, %s failed\n' "${PASSED}" "${FAILED}"
[ "${FAILED}" -eq 0 ]
