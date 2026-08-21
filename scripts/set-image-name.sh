#!/usr/bin/bash
#
# Rename the image (and optionally the GitHub owner) everywhere in this
# template, so you only have to do it once after copying the files.
#
# Usage:
#   ./scripts/set-image-name.sh <image-name> [github-owner]
#   ./scripts/set-image-name.sh --dry-run <image-name> [github-owner]
#
# <github-owner> is your GitHub account or organisation handle - the part
# between github.com/ and the repository name, e.g. "octocat" in
# github.com/octocat/hello-world. Not your display name.
#
# Examples:
#   ./scripts/set-image-name.sh mydesktop
#   ./scripts/set-image-name.sh mydesktop myorg
#
# The script is safe to run again later: it looks up the name currently in
# use rather than assuming the template defaults.
#
# One caveat: renaming is a whole-word text substitution across the files below,
# including README.md prose. Avoid naming your image after an ordinary English
# word that appears there - "second", "image", "build" and the like - or the
# next rename will rewrite that prose along with the real references. "donkey"
# is reserved outright: build.sh and the README reference the Donkey Emacs
# package by that name, and an image called donkey would rewrite those paths.
set -euo pipefail

cd "$(dirname "$0")/.."

# Every file that mentions the image name or the owner. Add to this list if
# you introduce new files that need the same treatment.
FILES=(
    ".github/workflows/build.yml"
    ".github/workflows/build-disk.yml"
    "disk_config/iso.toml"
    "disk_config/disk.toml"
    "build_files/sysfiles/etc/motd.d/10-welcome"
    # These two carry the published image reference. Leave them out and a
    # rename silently scopes signature verification to the old repository,
    # so updates from the new one stop being checked at all. build_files/build.sh
    # is listed for the same reason once you paste in the policy.json block from
    # the README.
    "build_files/build.sh"
    "build_files/sysfiles/etc/containers/registries.d/sigstore-attachments.yaml"
    "scripts/build.sh"
    "scripts/build-disk.sh"
    "README.md"
)

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi

NEW_NAME="${1:-}"
NEW_OWNER="${2:-}"

if [ -z "${NEW_NAME}" ]; then
    echo "Usage: $0 [--dry-run] <image-name> [github-owner]" >&2
    exit 1
fi

# Accept the name in any case - it is normalised per file below. Registries
# only allow these characters, whatever the capitalisation.
if ! [[ "${NEW_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Error: '${NEW_NAME}' is not a valid image name." >&2
    echo "Use letters, digits, dots, underscores and dashes." >&2
    exit 1
fi

# Enforce the reservation from the caveat above: an image named "donkey"
# passes the character check, but the next rename away from it would rewrite
# the Donkey package paths in build.sh - consistently enough that the build
# still passes while every account silently ships without Donkey. The guard
# below only protects the upstream URLs, not those paths, so refuse here.
if [ "${NEW_NAME,,}" = "donkey" ]; then
    echo "Error: 'donkey' is reserved - build.sh and README.md refer to the" >&2
    echo "Donkey Emacs package by that name. Pick a different image name." >&2
    exit 1
fi

# One input, three renderings:
#   NAME_LOWER  everywhere that is a real image reference - registries reject
#               uppercase, so this is the only form that may appear in a tag,
#               a URL, or a config file.
#   NAME_CAP    prose in README.md, e.g. the title.
#   uppercase   the ISO filename - not written by this script; build-disk.yml
#               derives it with ${IMAGE_NAME^^} at build time, so it follows
#               automatically from NAME_LOWER.
NAME_LOWER="${NEW_NAME,,}"
NAME_CAP="${NAME_LOWER^}"
NAME_UPPER="${NAME_LOWER^^}"

if [ -n "${NEW_OWNER}" ] && ! [[ "${NEW_OWNER}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
    echo "Error: '${NEW_OWNER}' is not a valid GitHub owner name." >&2
    echo "Use the handle from your repository URL (github.com/<owner>/<repo>)," >&2
    echo "not your display name." >&2
    exit 1
fi

# Same reservation as for the image name: the owner substitution is
# case-insensitive, so an owner called "donkey" would rewrite the package's
# name in prose and paths on the rename after this one.
if [ "${NEW_OWNER,,}" = "donkey" ]; then
    echo "Error: an owner named 'donkey' would collide with the Donkey Emacs" >&2
    echo "package references in build.sh and README.md." >&2
    exit 1
fi

# The owner appears in image references such as ghcr.io/<owner>/<image>, where
# registries reject uppercase. GitHub URLs do not care about case, so the owner
# is lowercased everywhere, whatever was typed.
if [ -n "${NEW_OWNER}" ] && [ "${NEW_OWNER}" != "${NEW_OWNER,,}" ]; then
    echo "Note: using '${NEW_OWNER,,}' - image references must be lowercase."
fi
NEW_OWNER="${NEW_OWNER,,}"

# \b (word boundary) below is a GNU sed feature.
if ! sed --version >/dev/null 2>&1; then
    echo "Error: this script needs GNU sed (standard on Linux)." >&2
    exit 1
fi

# What is the name in use right now? build.yml is the single source of truth.
OLD_NAME=$(sed -n 's/^  IMAGE_NAME: "\(.*\)"$/\1/p' .github/workflows/build.yml | head -n1)
if [ -z "${OLD_NAME}" ]; then
    echo "Error: could not read IMAGE_NAME from .github/workflows/build.yml." >&2
    exit 1
fi

# The owner appears as ghcr.io/<owner>/<image> in the ISO kickstart.
OLD_OWNER=$(sed -n 's|.*ghcr\.io/\([^/]*\)/.*|\1|p' disk_config/iso.toml | head -n1)

# A name may contain dots, which mean "any character" to sed - escape them.
OLD_NAME_RE=$(printf '%s' "${OLD_NAME}" | sed 's/[].[^$*\\/]/\\&/g')
# The README carries the name in three cases at once, so the old value has to be
# matched in all three.
OLD_NAME_CAP_RE=$(printf '%s' "${OLD_NAME^}" | sed 's/[].[^$*\\/]/\\&/g')
OLD_NAME_UPPER_RE=$(printf '%s' "${OLD_NAME^^}" | sed 's/[].[^$*\\/]/\\&/g')
OLD_OWNER_RE=$(printf '%s' "${OLD_OWNER}" | sed 's/[].[^$*\\/]/\\&/g')

echo "image name : ${OLD_NAME} -> ${NAME_LOWER}  (README.md: ${NAME_CAP}, ISO: ${NAME_LOWER^^})"
if [ -n "${NEW_OWNER}" ]; then
    echo "owner      : ${OLD_OWNER:-?} -> ${NEW_OWNER}"
fi
echo

# A sed address matching the lines of a fenced code block in Markdown, used for
# README.md below. Kept in a variable because backticks cannot appear unescaped
# inside the double-quoted sed scripts.
FENCE='/^```/,/^```/'

# Lines that reference the Donkey upstream repository (yardquit/donkey URLs in
# build.sh and README.md) are not image references: rewriting the owner there
# breaks the build-time fetch with a 404 and dead links. This address matches
# them case-insensitively; every substitution below branches past such lines.
DONKEY_GUARD='\#yardquit/donkey#I'

for file in "${FILES[@]}"; do
    if [ ! -f "${file}" ]; then
        echo "  skipped (not found): ${file}"
        continue
    fi

    # Count the replacements this file would get, for the summary line.
    hits=$(grep -c -F -w -e "${OLD_NAME}" "${file}" || true)
    if [ -n "${NEW_OWNER}" ] && [ -n "${OLD_OWNER}" ]; then
        hits=$(( hits + $(grep -c -F -w -e "${OLD_OWNER}" "${file}" || true) ))
    fi

    if [ "${hits}" -eq 0 ]; then
        echo "  unchanged: ${file}"
        continue
    fi

    if [ "${DRY_RUN}" -eq 1 ]; then
        echo "  would change ${hits} line(s): ${file}"
        continue
    fi

    # The uppercase rendering appears in the ISO filename and in the comments
    # that quote it, in any file - so this pass runs everywhere.
    sed -i -e "${DONKEY_GUARD}b" \
           -e "s#\b${OLD_NAME_UPPER_RE}\b#${NAME_UPPER}#g" "${file}"

    if [ "${file}" = "README.md" ]; then
        # The README carries all three renderings at once: the ISO filename is
        # uppercase, an occurrence right after a "/" is part of an image
        # reference (ghcr.io/<owner>/<image>, localhost/<image>) and must stay
        # lowercase, and everything else is prose and gets the capitalised
        # form. Each pass is case-SENSITIVE and anchored, so none of them can
        # re-match what an earlier pass just produced - that is what keeps
        # repeated renames stable.
        #
        # A fenced code block is not prose: it quotes literal file content and
        # commands - os-release keys, image references, filenames - where the
        # name has to read exactly as it does in the file itself. So the
        # lowercase rule applies inside a fence, and only outside it does the
        # capitalised form take over.
        sed -i -e "${DONKEY_GUARD}b" \
               -e "${FENCE}{s#\b\(${OLD_NAME_RE}\|${OLD_NAME_CAP_RE}\)\b#${NAME_LOWER}#g}" "${file}"
        # "b" branches past the rest of the script for lines inside a fence, so
        # the prose rules cannot undo the pass above.
        sed -i -e "${DONKEY_GUARD}b" \
               -e "${FENCE}b" \
               -e "s#\(^\|[^/]\)\b\(${OLD_NAME_RE}\|${OLD_NAME_CAP_RE}\)\b#\1${NAME_CAP}#g" \
               -e "s#/\b${OLD_NAME_RE}\b#/${NAME_LOWER}#g" "${file}"
    else
        # Outside the README the name is always a real image reference and stays
        # lowercase - except where a comment quotes the ISO filename, which is
        # uppercase and was handled by the pass above.
        sed -i -e "${DONKEY_GUARD}b" \
               -e "s#\b${OLD_NAME_RE}\b#${NAME_LOWER}#g" "${file}"
    fi
    if [ -n "${NEW_OWNER}" ] && [ -n "${OLD_OWNER}" ]; then
        sed -i -e "${DONKEY_GUARD}b" \
               -e "s#\b${OLD_OWNER_RE}\b#${NEW_OWNER}#gI" "${file}"
    fi
    echo "  updated ${hits} line(s): ${file}"
done

echo
if [ "${DRY_RUN}" -eq 1 ]; then
    echo "Dry run - nothing was written. Drop --dry-run to apply."
else
    echo "Done. Review the changes with: git diff"
fi
