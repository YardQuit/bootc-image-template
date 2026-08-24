#!/usr/bin/bash
#
# Rename the image (and optionally the GitHub owner) everywhere in this
# template, so you only have to do it once after copying the files.
#
# Usage:
#   ./scripts/set-image-name.sh <image-name> [github-owner]
#   ./scripts/set-image-name.sh --dry-run <image-name> [github-owner]
#   ./scripts/set-image-name.sh --check
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
# It also repairs a repository that copied files down from the template after
# renaming - the case looking up the current name cannot cover on its own,
# because the name it finds is already the new one and it would substitute
# that for itself while the freshly copied "myimage"/"myorg" sat there
# untouched. Every run rewrites those placeholders as well, so re-running the
# same rename fixes an upstream copy:
#
#   ./scripts/set-image-name.sh mydesktop myorg     # after copying files down
#
# --check reports leftover placeholders without changing anything, and exits
# non-zero when it finds one. .github/workflows/build.yml runs it before it
# builds: a stale placeholder means the signature policy, the ISO kickstart or
# the image name is pointing at a repository nobody publishes to, which is far
# cheaper to hear about there than from a machine that can no longer upgrade.
# The untouched template passes - "myimage" and "myorg" are its real values,
# not leftovers.
#
# One caveat: renaming is a whole-word text substitution across the files below,
# including README.md prose. Avoid naming your image after an ordinary English
# word that appears there - "second", "image", "build" and the like - or the
# next rename will rewrite that prose along with the real references. The
# script refuses up front what a rename would silently corrupt, and says
# which lines collide:
#   - a new image name that already occurs in the non-README files it
#     rewrites, or a new owner that occurs in any of them, README included
#     ("donkey", "emacs", "build", ...);
#   - a new name and owner that overlap each other as whole words, or a new
#     name that overlaps the current owner ("myorg-x" under owner "myorg");
#   - running at all while the current name and owner already overlap, or
#     while either is "donkey" - those need a hand-edit first, and the
#     error says exactly what to do;
#   - an owner change when no ghcr.io/<owner>/<image> reference is left to
#     read the current owner from - there would be nothing to substitute.
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
    # These two carry the published image reference, and both feed signature
    # verification. The registries.d file is what tells containers/image to
    # go and fetch the signature at all, and it ships verbatim - leave it out
    # of a rename and the signature is never looked for, so every upgrade
    # fails on an image that was signed correctly. build.sh section 9c takes
    # its policy scope from the workflow now, but keeps a literal for local
    # builds and rebrands /etc/os-release from the same values.
    "build_files/build.sh"
    "build_files/sysfiles/etc/containers/registries.d/sigstore-attachments.yaml"
    "scripts/build.sh"
    "scripts/build-disk.sh"
    "README.md"
)

# Two values overlap when either occurs inside the other at word boundaries -
# exactly the distinction the whole-word substitutions below cannot make.
# Every dangerous pairing is checked through this one rule: new name vs new
# owner, new name vs current owner, and current name vs current owner.
overlaps() {  # $1, $2: non-empty words. True if they collide whole-word.
    grep -q -i -w -F -e "$1" <<<"$2" || grep -q -i -w -F -e "$2" <<<"$1"
}

# The name and owner the template ships with. Every file above carries them
# until the first rename. Any that still does afterwards was copied down from
# the template after that rename - the one state this script could not
# repair, because it derives the value to replace from the very files it is
# about to rewrite and so ends up substituting the current name for itself
# while the freshly copied placeholders sit there untouched. The repair pass
# further down rewrites these as well, and --check fails when one survives.
TEMPLATE_NAME="myimage"
TEMPLATE_OWNER="myorg"

# README.md documents those two values as literals, in the section about
# copying files down from the template. They have to survive a rename, or that
# section starts describing the reader's own image instead of the template's -
# and --check would then flag its own documentation on every run. Lines between
# these markers are branched past by every substitution and ignored by --check,
# the same way the Donkey upstream URLs are. HTML comments, so they render as
# nothing.
LITERAL_BEGIN='<!-- template-literals -->'
LITERAL_END='<!-- /template-literals -->'

# The file as the substitutions see it: guarded lines blanked rather than
# deleted, so line numbers still match the real file. "#" delimits the
# addresses because the markers contain "/".
guarded_view() {  # $1: file
    sed -e "\\#${LITERAL_BEGIN}#,\\#${LITERAL_END}#s/.*//" -- "$1"
}

# The name and owner in use right now. build.yml is the source of truth for the
# name. The owner has no such file, so it is read from every
# ghcr.io/<owner>/<image> reference in the files above at once.
#
# Reading it from a single file is what this used to do - the ISO kickstart in
# disk_config/iso.toml - and that is one of the files a repository copies down
# from the template when it wants an upstream fix. Copy it down and the owner
# reads back as the placeholder, which turned the documented repair into a dead
# end: --check reported the leftovers but could not name the owner in the
# command it suggested, and running that command with the right owner was
# refused - "the owner ... already appears in files this script rewrites" -
# because from here the real owner looked like a brand new value that happened
# to be all over the repository. The only way out was a hand edit.
#
# So count the owners instead: drop the template's placeholder when any real
# owner is there to be had, and take the value the most files agree on. One
# copied-down file cannot outvote the rest.
read_current_values() {
    local file refs owners real

    OLD_NAME=$(sed -n 's/^  IMAGE_NAME: "\(.*\)"$/\1/p' .github/workflows/build.yml | head -n1)
    if [ -z "${OLD_NAME}" ]; then
        echo "Error: could not read IMAGE_NAME from .github/workflows/build.yml." >&2
        exit 1
    fi

    # Read through guarded_view, for the same reason every other scan does: the
    # README spells out ghcr.io/myorg/myimage between the literal markers to
    # explain what a placeholder is, and that sentence must not get a vote.
    refs=$({ for file in "${FILES[@]}"; do
                 if [ -f "${file}" ]; then guarded_view "${file}"; fi
             done; } | { grep -o -E 'ghcr\.io/[A-Za-z0-9._-]+/' || true; })
    owners=$(cut -d/ -f2 <<<"${refs}")

    OLD_OWNER=""
    if [ -n "${owners}" ]; then
        real=$({ grep -v -i -x -F -e "${TEMPLATE_OWNER}" <<<"${owners}" || true; })
        if [ -n "${real}" ]; then
            owners="${real}"
        fi
        # uniq -c prefixes the count; the second sort orders by it, descending,
        # with the name as a tiebreak so a tie is at least deterministic. awk
        # rather than "head -n1" because head closes the pipe on its first line
        # and the sort ahead of it dies of SIGPIPE under "set -o pipefail".
        OLD_OWNER=$(sort <<<"${owners}" | uniq -c | sort -k1,1nr -k2,2 \
                    | awk 'NR==1 {print $2}')
    fi
}

# --check: report template placeholders that outlived the rename. A
# placeholder is only stale when it is not the value actually in use, so the
# untouched template - where "myimage" and "myorg" ARE the current values -
# passes cleanly, and a repository that renamed only its image name keeps
# "myorg" as a legitimate owner.
#
# This is what CI runs before it builds anything: a stale placeholder there
# means the signature policy, the kickstart or the ISO name is pointing at a
# repository nobody publishes to, and that is much cheaper to hear about now
# than from a machine that cannot upgrade.
check_placeholders() {
    local file hits found placeholder skipped=0
    local -a pats=() scan=()

    # A placeholder is only worth looking for when it is neither a value in use
    # nor something that cannot be told apart from one. The second case is the
    # same stand-down the repair pass makes, for the same reason: under owner
    # "myorg-labs" a whole-word search for "myorg" matches every legitimate
    # reference ("-" is a word boundary), and a check that can only ever fail
    # is worse than no check.
    for placeholder in "${TEMPLATE_NAME}" "${TEMPLATE_OWNER}"; do
        if [ "${OLD_NAME,,}" = "${placeholder}" ] || [ "${OLD_OWNER,,}" = "${placeholder}" ]; then
            continue
        fi
        if overlaps "${placeholder}" "${OLD_NAME}" \
           || { [ -n "${OLD_OWNER}" ] && overlaps "${placeholder}" "${OLD_OWNER}"; }; then
            echo "Note: cannot check for '${placeholder}' - it overlaps this" >&2
            echo "      repository's own name or owner as a whole word. Look for" >&2
            echo "      it by hand after copying files from the template." >&2
            skipped=1
            continue
        fi
        pats+=(-e "${placeholder}")
    done

    if [ "${#pats[@]}" -eq 0 ]; then
        if [ "${skipped}" -eq 1 ]; then
            echo "Nothing left that can be checked automatically."
        else
            echo "Not renamed yet: '${TEMPLATE_NAME}' and '${TEMPLATE_OWNER}' are still"
            echo "this repository's own image name and owner. Nothing to check."
        fi
        exit 0
    fi

    for file in "${FILES[@]}"; do
        [ -f "${file}" ] && scan+=("${file}")
    done

    # One grep per file, because guarded_view has to read each one separately.
    # The newline is added back deliberately: a command substitution strips
    # trailing newlines, so appending one file's matches straight onto the
    # previous file's would run the last line of one into the first line of
    # the next.
    hits=""
    for file in "${scan[@]}"; do
        found=$({ guarded_view "${file}" | grep -n -i -w -F "${pats[@]}" || true; } \
                | sed "s#^#${file}:#")
        if [ -n "${found}" ]; then
            hits+="${found}"$'\n'
        fi
    done

    if [ -n "${hits}" ]; then
        # The owner reads back as the placeholder only when every file that
        # names one still says "myorg" - a repository copied down wholesale, or
        # one that never changed its owner at all. Either way there is no owner
        # to suggest, so ask for one rather than print the placeholder as if it
        # were the answer.
        local owner_arg=" <github-owner>"
        if [ -n "${OLD_OWNER}" ] && [ "${OLD_OWNER,,}" != "${TEMPLATE_OWNER}" ]; then
            owner_arg=" ${OLD_OWNER}"
        fi

        echo "Error: template placeholders left in a repository already renamed" >&2
        echo "to '${OLD_NAME}':" >&2
        echo >&2
        sed 's/^/  /' <<<"${hits%$'\n'}" >&2
        echo >&2
        echo "These are almost always files copied down from the template after" >&2
        echo "the rename. Rewrite them with:" >&2
        echo >&2
        echo "  ./scripts/set-image-name.sh ${OLD_NAME}${owner_arg}" >&2
        exit 1
    fi

    echo "No template placeholders left."
    exit 0
}

DRY_RUN=0
CHECK_ONLY=0
case "${1:-}" in
    --dry-run) DRY_RUN=1;    shift ;;
    --check)   CHECK_ONLY=1; shift ;;
esac

# --check needs no new values - it compares the files against the ones already
# in use - so it runs here, before any of the validation below has anything to
# validate.
if [ "${CHECK_ONLY}" -eq 1 ]; then
    if [ "$#" -gt 0 ]; then
        echo "Usage: $0 --check   (takes no further arguments)" >&2
        exit 1
    fi
    read_current_values
    check_placeholders
fi

NEW_NAME="${1:-}"
NEW_OWNER="${2:-}"

if [ -z "${NEW_NAME}" ]; then
    echo "Usage: $0 [--dry-run] <image-name> [github-owner]" >&2
    echo "       $0 --check" >&2
    exit 1
fi

# Accept the name in any case - it is normalised per file below. Registries
# only allow these characters, whatever the capitalisation. The first and
# last characters must be alphanumeric: registries reject trailing
# separators anyway, and a name ending in "." or "-" would slip past the
# collision scan below (grep -w) while still matching at sed's \b during a
# later rename - the mismatch that corrupts paths silently.
if ! [[ "${NEW_NAME}" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; then
    echo "Error: '${NEW_NAME}' is not a valid image name." >&2
    echo "Use letters, digits, dots, underscores and dashes; start and end" >&2
    echo "with a letter or digit." >&2
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

# Same trailing-alphanumeric requirement as the image name, for the same
# reason - and GitHub itself forbids a handle ending in "-".
if [ -n "${NEW_OWNER}" ] && ! [[ "${NEW_OWNER}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
    echo "Error: '${NEW_OWNER}' is not a valid GitHub owner name." >&2
    echo "Use the handle from your repository URL (github.com/<owner>/<repo>)," >&2
    echo "not your display name." >&2
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

# What is the name in use right now? Read by the same function --check uses,
# so the two can never disagree about what "current" means.
read_current_values

# The script can only rewrite an owner it can locate. When not one of the files
# above names a ghcr.io owner any more, a requested owner change has nothing to
# substitute - and completing anyway would leave the user believing the owner
# was set when no file received it. Refuse rather than silently ignore the
# argument.
if [ -n "${NEW_OWNER}" ] && [ -z "${OLD_OWNER}" ]; then
    echo "Error: cannot change the owner - no ghcr.io/<owner>/... reference is" >&2
    echo "left in the files this script manages to read the current owner" >&2
    echo "from. Set the owner by hand where it appears (search the repository" >&2
    echo "for ghcr.io), or restore one of those references and run this script" >&2
    echo "again." >&2
    exit 1
fi

# Refuse to run on a repository whose current name and owner already overlap
# (an older version of this script accepted e.g. image "zonk" with owner
# "zonk-labs"): the name substitution would rewrite the owner inside
# ghcr.io/<owner>/<image> along with the image, silently pointing the
# workflows and signature policy at an account that does not exist. There is
# no safe automated way out of that state.
if [ -n "${OLD_OWNER}" ] && overlaps "${OLD_NAME}" "${OLD_OWNER}"; then
    echo "Error: the current image name '${OLD_NAME}' and owner '${OLD_OWNER}'" >&2
    echo "overlap as whole words - renaming would rewrite one inside the" >&2
    echo "other. Hand-edit the current values apart first in the files this" >&2
    echo "script manages (see FILES at the top), then rerun." >&2
    exit 1
fi

# A repository can predate the collision check below with "donkey" already in
# use as its name or owner. Renaming away from that cannot be done safely: the
# substitutions cannot tell the image apart from the Donkey Emacs package
# paths in build.sh, and would rewrite both - consistently enough that the
# build still passes while config.el's donkey/donkey.el load path silently
# breaks. Stop rather than guess.
if [ "${OLD_NAME,,}" = "donkey" ] || [ "${OLD_OWNER,,}" = "donkey" ]; then
    echo "Error: the current image name or owner is 'donkey', which cannot be" >&2
    echo "told apart from the Donkey Emacs package references in" >&2
    echo "build_files/build.sh. This script cannot fix that itself - by hand:" >&2
    echo "  1. Edit the image references to the new name in the files this" >&2
    echo "     script manages (see FILES at the top; start with IMAGE_NAME in" >&2
    echo "     .github/workflows/build.yml and ghcr.io/... in disk_config/)," >&2
    echo "     leaving the Donkey package paths (donkey/donkey.el," >&2
    echo "     /etc/skel/.config/emacs/donkey, yardquit/donkey) untouched." >&2
    echo "  2. Compare build.sh section 1a and the README's Donkey section" >&2
    echo "     against the template and restore anything a past rename broke." >&2
    exit 1
fi

# The new name must not overlap the new owner: "zonkul zonkul" (or "zonk"
# with "zonk-labs") passes the file scan - neither value is in the files yet -
# but the next rename could not tell the two apart inside
# ghcr.io/<owner>/<image> and would rewrite both halves at once.
if [ -n "${NEW_OWNER}" ] && overlaps "${NAME_LOWER}" "${NEW_OWNER}"; then
    echo "Error: the image name '${NAME_LOWER}' and the owner '${NEW_OWNER}'" >&2
    echo "overlap as whole words - the substitutions could not tell them" >&2
    echo "apart in ghcr.io/<owner>/<image> references. Pick distinct values." >&2
    exit 1
fi

# Nor may the new name overlap the CURRENT owner - the value the owner
# substitution actually searches for, case-insensitively, after the name
# pass has already written the new name into the files. An image "myorg-x"
# under owner "myorg" would come out as "neworg-x" the moment the owner is
# changed - in this very run if both arguments were given, otherwise on the
# next owner change.
if [ -n "${OLD_OWNER}" ] && overlaps "${NAME_LOWER}" "${OLD_OWNER}"; then
    echo "Error: the new image name '${NAME_LOWER}' overlaps the current" >&2
    echo "owner '${OLD_OWNER}' as a whole word - the owner substitution (in" >&2
    echo "this run or a later one) would rewrite part of the image name." >&2
    echo "Pick a name that does not contain the owner, or change the owner" >&2
    echo "away from '${OLD_OWNER}' first." >&2
    exit 1
fi

# The Donkey upstream repository, as it appears in build.sh's fetch URL and
# the README's links. The collision scan below and the substitution guard
# further down both derive from this one value, so they cannot drift apart:
# lines matching it are never rewritten, and therefore never count as
# collisions either.
DONKEY_UPSTREAM='yardquit/donkey'

# Refuse a new value that already occurs in the files this script rewrites:
# after this rename those occurrences would be indistinguishable from image
# references, and the next rename would rewrite them too - "emacs" would drag
# the skel paths in build.sh with it, "donkey" the package references, and so
# on. The scan is case-insensitive (the owner substitution is too, and the
# README name passes cover three cases), skips the Donkey-upstream URLs that
# the substitutions below never touch, and for the image name skips
# README.md, whose prose collisions are the documented caveat above rather
# than build breakage. Renaming to the value already in use is a no-op, not
# a collision.
check_new_value() {  # $1 = "image name"|"owner"   $2 = candidate   $3 = current
    local label="$1" candidate="$2" current="$3" scan=() file hits found
    [ "${candidate,,}" = "${current,,}" ] && return 0
    for file in "${FILES[@]}"; do
        [ "${label}" = "image name" ] && [ "${file}" = "README.md" ] && continue
        [ -f "${file}" ] && scan+=("${file}")
    done
    # Read through guarded_view for the same reason the substitutions branch
    # past that range: those lines are never rewritten, so an occurrence there
    # can never be corrupted by a later rename and must not count as a
    # collision. Without this the README's own worked example - it names
    # "myorg-labs" to explain the overlap rule - would refuse an owner
    # genuinely called that. Same reasoning as the Donkey-upstream skip below.
    hits=""
    for file in "${scan[@]}"; do
        found=$({ guarded_view "${file}" | grep -n -i -w -F -e "${candidate}" \
                  | grep -v -i -F -e "${DONKEY_UPSTREAM}" || true; } \
                | sed "s#^#${file}:#")
        if [ -n "${found}" ]; then
            hits+="${found}"$'\n'
        fi
    done
    if [ -n "${hits}" ]; then
        echo "Error: the ${label} '${candidate}' already appears in files this" >&2
        echo "script rewrites, where it is not an image reference. A later" >&2
        echo "rename could not tell the two apart and would corrupt these:" >&2
        head -n 5 <<<"${hits%$'\n'}" | sed 's/^/  /' >&2
        echo "Pick a different ${label}." >&2
        exit 1
    fi
}
check_new_value "image name" "${NAME_LOWER}" "${OLD_NAME}"
# NEW_OWNER set implies OLD_OWNER is known - the refusal further up already
# rejected an owner change with no current owner to substitute.
if [ -n "${NEW_OWNER}" ]; then
    check_new_value "owner" "${NEW_OWNER}" "${OLD_OWNER}"
fi

# A sed address matching the lines of a fenced code block in Markdown, used for
# README.md below. Kept in a variable because backticks cannot appear unescaped
# inside the double-quoted sed scripts.
FENCE='/^```/,/^```/'

# Lines that reference the Donkey upstream repository (yardquit/donkey URLs in
# build.sh and README.md) are not image references: rewriting the owner there
# breaks the build-time fetch with a 404 and dead links. This address matches
# them case-insensitively; every substitution below branches past such lines.
# Derived from DONKEY_UPSTREAM above so guard and collision scan stay in step.
DONKEY_GUARD="\\#${DONKEY_UPSTREAM}#I"

# The same for the template-literal range in README.md. Both guards are passed
# to every substitution below, ahead of the substitution itself.
LITERAL_GUARD="\\#${LITERAL_BEGIN}#,\\#${LITERAL_END}#"

# One substitution pass over one file: rewrite the image name $2 and the owner
# $3 to the new values, leaving either half alone when its argument is empty.
# Prints the number of lines it rewrote.
#
# The values in use and the template placeholders both go through here, so a
# repair behaves exactly like a rename - same case handling, same Donkey guard,
# same counting. Nothing is written when the count is zero, so a pass with
# nothing to do costs one grep and touches no file.
rewrite_file() {  # $1 file, $2 old image name (""=skip), $3 old owner (""=skip)
    local file="$1" old_name="$2" old_owner="$3"
    local name_re cap_re upper_re owner_re hits=0
    local -a name_pats=()

    # Count the lines the substitutions below would actually rewrite - the
    # count decides whether the file is written at all, so it must see exactly
    # what the sed passes see. That means: the same case renderings each pass
    # rewrites (lowercase and UPPERCASE in every file, the Capitalised form
    # only in README.md - an arbitrary case variant like "MyImAgE" is never
    # rewritten and must not count), the owner case-insensitively (its sed uses
    # the I flag), and never a Donkey-upstream line, which the guard branches
    # past. The greps exit non-zero on no match, hence the || true under
    # set -o pipefail.
    if [ -n "${old_name}" ]; then
        name_pats=(-e "${old_name}" -e "${old_name^^}")
        if [ "${file}" = "README.md" ]; then
            name_pats+=(-e "${old_name^}")
        fi
        hits=$({ guarded_view "${file}" | grep -F -w "${name_pats[@]}" || true; } \
               | { grep -v -i -F -e "${DONKEY_UPSTREAM}" || true; } | wc -l)
    fi
    if [ -n "${old_owner}" ]; then
        hits=$(( hits + $({ guarded_view "${file}" | grep -i -F -w -e "${old_owner}" || true; } \
                          | { grep -v -i -F -e "${DONKEY_UPSTREAM}" || true; } | wc -l) ))
    fi

    if [ "${hits}" -eq 0 ] || [ "${DRY_RUN}" -eq 1 ]; then
        echo "${hits}"
        return 0
    fi

    if [ -n "${old_name}" ]; then
        # A name may contain dots, which mean "any character" to sed - escape
        # them. The README carries the name in three cases at once, so the old
        # value has to be matched in all three.
        name_re=$(printf '%s' "${old_name}" | sed 's/[].[^$*\\/]/\\&/g')
        cap_re=$(printf '%s' "${old_name^}" | sed 's/[].[^$*\\/]/\\&/g')
        upper_re=$(printf '%s' "${old_name^^}" | sed 's/[].[^$*\\/]/\\&/g')

        # The uppercase rendering appears in the ISO filename and in the
        # comments that quote it, in any file - so this pass runs everywhere.
        #
        # Unless the name has no letters to change case. "2024" uppercases to
        # itself, so this pass would match every ordinary lowercase reference
        # and rewrite the lot to the UPPERCASE form of the new name, before the
        # lowercase pass below ever saw them - leaving ghcr.io/owner/VAULTED
        # everywhere, which registries reject. The three passes only make sense
        # when the three renderings are actually distinct.
        if [ "${old_name^^}" != "${old_name}" ]; then
            sed -i -e "${DONKEY_GUARD}b" \
                   -e "${LITERAL_GUARD}b" \
                   -e "s#\b${upper_re}\b#${NAME_UPPER}#g" "${file}"
        fi

        if [ "${file}" = "README.md" ]; then
            # The README carries all three renderings at once: the ISO filename
            # is uppercase, an occurrence right after a "/" is part of an image
            # reference (ghcr.io/<owner>/<image>, localhost/<image>) and must
            # stay lowercase, and everything else is prose and gets the
            # capitalised form. Each pass is case-SENSITIVE and anchored, so
            # none of them can re-match what an earlier pass just produced -
            # that is what keeps repeated renames stable.
            #
            # A fenced code block is not prose: it quotes literal file content
            # and commands - os-release keys, image references, filenames -
            # where the name has to read exactly as it does in the file itself.
            # So the lowercase rule applies inside a fence, and only outside it
            # does the capitalised form take over.
            sed -i -e "${DONKEY_GUARD}b" \
                   -e "${LITERAL_GUARD}b" \
                   -e "${FENCE}{s#\b\(${name_re}\|${cap_re}\)\b#${NAME_LOWER}#g}" "${file}"
            # "b" branches past the rest of the script for lines inside a fence,
            # so the prose rules cannot undo the pass above.
            sed -i -e "${DONKEY_GUARD}b" \
                   -e "${LITERAL_GUARD}b" \
                   -e "${FENCE}b" \
                   -e "s#\(^\|[^/]\)\b\(${name_re}\|${cap_re}\)\b#\1${NAME_CAP}#g" \
                   -e "s#/\b${name_re}\b#/${NAME_LOWER}#g" "${file}"
        else
            # Outside the README the name is always a real image reference and
            # stays lowercase - except where a comment quotes the ISO filename,
            # which is uppercase and was handled by the pass above.
            sed -i -e "${DONKEY_GUARD}b" \
                   -e "${LITERAL_GUARD}b" \
                   -e "s#\b${name_re}\b#${NAME_LOWER}#g" "${file}"
        fi
    fi

    if [ -n "${old_owner}" ]; then
        owner_re=$(printf '%s' "${old_owner}" | sed 's/[].[^$*\\/]/\\&/g')
        sed -i -e "${DONKEY_GUARD}b" \
               -e "${LITERAL_GUARD}b" \
               -e "s#\b${owner_re}\b#${TARGET_OWNER}#gI" "${file}"
    fi

    echo "${hits}"
}

# The owner every substitution below writes. An owner argument sets it; without
# one it stays what it already was, which is what lets the repair pass fix a
# copied-in "myorg" even when the caller only passed an image name.
TARGET_OWNER="${NEW_OWNER:-${OLD_OWNER}}"

# The values actually in use, or empty when they already match what was asked
# for. Renaming a repository to the name it already has is a no-op, and saying
# so - rather than reporting every file "updated" - is the whole point: that
# silent no-op is how a repository ends up half-renamed after an upstream copy.
LIVE_NAME="${OLD_NAME}"
if [ "${OLD_NAME,,}" = "${NAME_LOWER}" ]; then
    LIVE_NAME=""
fi
LIVE_OWNER="${OLD_OWNER}"
if [ -z "${NEW_OWNER}" ] || [ "${OLD_OWNER,,}" = "${NEW_OWNER}" ]; then
    LIVE_OWNER=""
fi

# The repair pass: rewrite the template's own placeholders wherever they
# survived, so a file copied down from the template into an already-renamed
# repository is fixed by the same command that did the renaming.
#
# It has to stand down whenever a placeholder cannot be told apart from a value
# in use, because the substitutions are whole-word and "-" is a word boundary:
# under owner "myorg-labs" a pass for "myorg" would eat the first half and
# produce "neworg-labs-labs". Standing down silently is what caused this
# problem in the first place, so it says so - except where the placeholder IS
# the value in use, which is simply an unrenamed template with nothing to
# repair.
REPAIR_NAME="${TEMPLATE_NAME}"
if [ "${NAME_LOWER}" = "${TEMPLATE_NAME}" ] || [ "${OLD_NAME,,}" = "${TEMPLATE_NAME}" ]; then
    REPAIR_NAME=""
elif overlaps "${REPAIR_NAME}" "${NAME_LOWER}" \
     || { [ -n "${TARGET_OWNER}" ] && overlaps "${REPAIR_NAME}" "${TARGET_OWNER}"; }; then
    echo "Note: leaving '${TEMPLATE_NAME}' alone - it overlaps the values in use"
    echo "      as a whole word, so rewriting it would corrupt them. If a file"
    echo "      copied from the template still says '${TEMPLATE_NAME}', edit it by hand."
    REPAIR_NAME=""
fi

REPAIR_OWNER="${TEMPLATE_OWNER}"
if [ -z "${TARGET_OWNER}" ] || [ "${TARGET_OWNER}" = "${TEMPLATE_OWNER}" ] \
   || [ "${OLD_OWNER,,}" = "${TEMPLATE_OWNER}" ]; then
    REPAIR_OWNER=""
elif overlaps "${REPAIR_OWNER}" "${TARGET_OWNER}" || overlaps "${REPAIR_OWNER}" "${NAME_LOWER}"; then
    echo "Note: leaving '${TEMPLATE_OWNER}' alone - it overlaps the values in use"
    echo "      as a whole word, so rewriting it would corrupt them. If a file"
    echo "      copied from the template still says '${TEMPLATE_OWNER}', edit it by hand."
    REPAIR_OWNER=""
fi

if [ -n "${LIVE_NAME}" ]; then
    echo "image name : ${OLD_NAME} -> ${NAME_LOWER}  (README.md: ${NAME_CAP}, ISO: ${NAME_UPPER})"
else
    echo "image name : ${NAME_LOWER}  (unchanged)"
fi
if [ -n "${LIVE_OWNER}" ]; then
    # NEW_OWNER set implies OLD_OWNER is known - the refusal above guarantees it.
    echo "owner      : ${OLD_OWNER} -> ${NEW_OWNER}"
elif [ -n "${TARGET_OWNER}" ]; then
    echo "owner      : ${TARGET_OWNER}  (unchanged)"
fi
if [ -n "${REPAIR_NAME}" ] || [ -n "${REPAIR_OWNER}" ]; then
    echo "leftovers  : any surviving template placeholder is rewritten too -"
    if [ -n "${REPAIR_NAME}" ]; then
        echo "             ${REPAIR_NAME} -> ${NAME_LOWER}"
    fi
    if [ -n "${REPAIR_OWNER}" ]; then
        echo "             ${REPAIR_OWNER} -> ${TARGET_OWNER}"
    fi
fi
echo

for file in "${FILES[@]}"; do
    if [ ! -f "${file}" ]; then
        echo "  skipped (not found): ${file}"
        continue
    fi

    # The rename first, then the repair. Order matters: the repair pass reads
    # the file the rename just wrote, so a placeholder and a real reference on
    # the same line are both handled, in that order.
    hits=$(rewrite_file "${file}" "${LIVE_NAME}" "${LIVE_OWNER}")
    hits=$(( hits + $(rewrite_file "${file}" "${REPAIR_NAME}" "${REPAIR_OWNER}") ))

    if [ "${hits}" -eq 0 ]; then
        echo "  unchanged: ${file}"
    elif [ "${DRY_RUN}" -eq 1 ]; then
        echo "  would change ${hits} line(s): ${file}"
    else
        echo "  updated ${hits} line(s): ${file}"
    fi
done

echo
if [ "${DRY_RUN}" -eq 1 ]; then
    echo "Dry run - nothing was written. Drop --dry-run to apply."
else
    echo "Done. Review the changes with: git diff"
fi
