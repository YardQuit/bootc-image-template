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
# script as well as in CI. Nothing here needs the network, podman, git or root,
# and the whole file takes a couple of seconds.
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
SKIPPED=0

ok()   { printf '  ok    %s\n' "$1"; PASSED=$((PASSED + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  skip  %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
check() {  # $1 what, $2 got, $3 want
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 - got '$2', wanted '$3'"; fi
}

# A throwaway copy of the working tree. $1 is a name under the temp directory.
#
# A plain file copy, not "git ls-files": this template is meant to be copied
# into a new repository, and in the moment right after that - before the first
# commit, or working from a downloaded tarball - git has nothing to list, so
# every test below would fail for a reason that has nothing to do with the
# rename script. The excludes mirror .gitignore.
tree() {
    local dst="${WORK}/$1"
    rm -rf "${dst}"
    mkdir -p "${dst}"
    tar -cf - -C "${REPO}" \
        --exclude=./.git --exclude=./output --exclude='./_build*' . \
        | tar -xf - -C "${dst}"
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


# Fail once, clearly, rather than report thirty confusing failures if the copy
# did not produce a repository.
T="$(tree preflight)"
if [ ! -x "${T}/scripts/set-image-name.sh" ] || [ ! -f "${T}/.github/workflows/build.yml" ]; then
    echo "Error: ${REPO} does not look like this template - the copy has no" >&2
    echo "scripts/set-image-name.sh or .github/workflows/build.yml. Run this" >&2
    echo "from inside the repository." >&2
    exit 1
fi


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
if grep -q '<!-- template-literals -->' "${T}/README.md"; then
    grep -q "starts life as the template's \`myimage\` and" "${T}/README.md"
    check "guarded README literals survive"   "$?" "0"
else
    skip "guarded README literals survive - this README has no guarded block"
fi

# Everywhere else in the README the name is the reader's, and does follow - the
# title most visibly. Same caveat as the block above: a project that wrote its
# own README has a title of its own choosing, with no image name in it for the
# rename to rewrite, so there is nothing to assert. Judged on the original,
# before the rename, by comparing its title against the name in use.
readme_titled_after_image() {
    local name
    name="$(sed -n 's/^  IMAGE_NAME: "\(.*\)"$/\1/p' \
            "${REPO}/.github/workflows/build.yml" | head -n1)"
    [ -n "${name}" ] && head -n1 "${REPO}/README.md" | grep -qi "^# ${name}\$"
}

if readme_titled_after_image; then
    grep -q '^# Vaulted' "${T}/README.md"
    check "README prose is renamed"       "$?" "0"
else
    skip "README prose is renamed - this README is not titled after the image"
fi

before="$(fingerprint "${T}")"
run "${T}" vaulted claudetest >/dev/null
check "re-running changes nothing"        "$(fingerprint "${T}")" "${before}"

check "a second rename succeeds"          "$(run "${T}" terrene claudetest)" "0"
grep -q 'ghcr\.io/claudetest/terrene' "${T}/disk_config/iso.toml"
check "the second rename lands"           "$?" "0"


echo
echo "A name with no letters"
# "2024" uppercases to itself, so the uppercase pass would match every ordinary
# lowercase reference and rewrite the lot to the UPPERCASE form of the next
# name - ghcr.io/owner/VAULTED, which registries reject.
T="$(tree digits)"
check "renaming to a digits-only name"    "$(run "${T}" 2024 acmelabs)"      "0"
check "and away from it again"            "$(run "${T}" vaulted acmelabs)"   "0"
grep -q 'IMAGE_NAME: "vaulted"' "${T}/.github/workflows/build.yml"
check "the result stays lowercase"        "$?" "0"
grep -q 'ghcr\.io/acmelabs/vaulted' "${T}/disk_config/iso.toml"
check "so does the kickstart"             "$?" "0"
check "--check is clean afterwards"       "$(run "${T}" --check)"            "0"


echo
echo "Renaming without an owner"
T="$(tree nameonly)"
# Read the owner rather than assume "myorg": these tests ship inside the
# template, so they also run in repositories created from it, where the owner
# was changed long ago.
owner="$(sed -n 's|.*ghcr\.io/\([^/]*\)/.*|\1|p' "${T}/disk_config/iso.toml" | head -n1)"
run "${T}" vaulted >/dev/null
grep -q "ghcr\.io/${owner}/vaulted" "${T}/disk_config/iso.toml"
check "the owner is left alone"           "$?" "0"
# The owner in use is never a leftover, whatever it is.
check "--check passes"                    "$(run "${T}" --check)"            "0"


echo
echo "Files copied down from the template after a rename"
CLEAN="$(tree clean)"
run "${CLEAN}" vaulted claudetest >/dev/null

STALE="$(tree stale)"
run "${STALE}" vaulted claudetest >/dev/null

# What a file copied down from the template looks like: one carrying the
# template's own placeholders. Produced by renaming a copy TO them, rather than
# read out of this repository - which may itself have been renamed long ago, in
# which case its files hold that name and there would be no placeholder left to
# find. Renaming to the template's values reconstructs an upstream file from any
# starting point.
UPSTREAM="$(tree upstream)"
check "a copy can be renamed to the template's values" \
    "$(run "${UPSTREAM}" myimage myorg)" "0"

# The files most likely to be synced down for a fix. iso.toml is in the list
# for a reason beyond being one of them: the owner used to be read from that
# one file and nowhere else, so a copy of it brought the placeholder back as
# the answer to "who owns this repository?" - see read_current_values.
for f in build_files/build.sh \
         build_files/sysfiles/etc/containers/registries.d/sigstore-attachments.yaml \
         build_files/sysfiles/etc/motd.d/10-welcome \
         disk_config/iso.toml; do
    cp "${UPSTREAM}/${f}" "${STALE}/${f}"
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

# The kickstart on its own, because it is the one file that used to decide who
# the owner was. With the owner read from that file alone, a copy of it made
# the script believe the owner had gone back to being the template's - so
# --check could not name it, the repair it printed was refused as "the owner
# ... already appears in files this script rewrites", and the rename with no
# owner argument quietly wrote ghcr.io/myorg/<name> instead. All three are
# checked here: what --check suggests, that the suggestion works, and that
# repairing without an owner argument keeps the right one.
ISO="$(tree stale-iso)"
run "${ISO}" vaulted claudetest >/dev/null
cp "${UPSTREAM}/disk_config/iso.toml" "${ISO}/disk_config/iso.toml"

out="$( cd "${ISO}" && ./scripts/set-image-name.sh --check 2>&1 )"
grep -q 'set-image-name\.sh vaulted claudetest$' <<<"${out}"
check "--check names the owner it found"  "$?" "0"

check "the suggested repair is accepted"  "$(run "${ISO}" vaulted claudetest)" "0"
check "--check passes afterwards"         "$(run "${ISO}" --check)"            "0"
check "it equals a clean rename"          "$(fingerprint "${ISO}")" "$(fingerprint "${CLEAN}")"

# And the same repair with no owner argument at all - what the README tells
# you to run, and the form that used to write the placeholder into the file.
ISO2="$(tree stale-iso-noowner)"
run "${ISO2}" vaulted claudetest >/dev/null
cp "${UPSTREAM}/disk_config/iso.toml" "${ISO2}/disk_config/iso.toml"
run "${ISO2}" vaulted >/dev/null
grep -q 'ghcr\.io/claudetest/vaulted' "${ISO2}/disk_config/iso.toml"
check "repairing without an owner keeps it" "$?" "0"
check "it equals a clean rename too"      "$(fingerprint "${ISO2}")" "$(fingerprint "${CLEAN}")"


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
# These two are refused because they occur in build_files/build.sh, in the
# Donkey Emacs package paths. A project built from this template is told to
# delete that section; with it goes the collision, and there is then nothing to
# refuse and nothing to assert. Judged on the file rather than assumed - the
# same reasoning as the README cases further up.
for word in donkey emacs; do
    if grep -q -i -w -F -e "${word}" "${T}/build_files/build.sh"; then
        check "'${word}' is refused"          "$(run "${T}" "${word}")"          "1"
    else
        skip "'${word}' is refused - this build.sh no longer mentions it"
    fi
done
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
if [ "${SKIPPED}" -gt 0 ]; then
    printf '%s passed, %s failed, %s skipped\n' "${PASSED}" "${FAILED}" "${SKIPPED}"
else
    printf '%s passed, %s failed\n' "${PASSED}" "${FAILED}"
fi
[ "${FAILED}" -eq 0 ] || exit 1

# Everything above ran against this repository as it stands. But these tests
# ship inside the template, so for everyone using it they run in a repository
# renamed away from "myimage"/"myorg" - and a test that quietly assumed those
# were still the values in use would be red on that user's first push, for a
# reason having nothing to do with their code. So run the whole suite once more
# in a renamed copy of this repository, which is the only way to notice.
if [ "${TEMPLATE_TEST_RENAMED:-0}" = "0" ]; then
    echo
    echo "Second pass, in a copy renamed to zonkzonk/acmelabs - how these tests"
    echo "run for anyone who created a repository from this template"
    RENAMED="$(tree second-pass)"
    if [ "$(run "${RENAMED}" zonkzonk acmelabs)" != "0" ]; then
        echo "  FAIL  could not rename a copy for the second pass"
        exit 1
    fi
    TEMPLATE_TEST_RENAMED=1 "${RENAMED}/tests/set-image-name.test.sh" || exit 1
fi
