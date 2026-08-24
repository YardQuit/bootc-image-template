## Containerfile - the recipe for your bootable container image.
##
## Everything happens in two stages:
##   1. "ctx" holds the build scripts and package lists, so they are available
##      during the build but never end up inside the finished image.
##   2. The real image: your base image + whatever build.sh does to it.

## Stage 1: build context. FROM scratch means "empty image" - it only carries files.
FROM scratch AS ctx
COPY build_files /
## build_files/ carries the signing public key too (build_files/cosign.pub,
## installed by build.sh section 9c) - it needs no line of its own here.

## Stage 2: the image itself.
##
## Pick the base image you want to build on top of. Examples:
##   quay.io/fedora-ostree-desktops/cosmic-atomic:44   # Fedora COSMIC
##   quay.io/fedora-ostree-desktops/silverblue:44      # Fedora GNOME
##   quay.io/fedora-ostree-desktops/kinoite:44         # Fedora KDE
##   quay.io/fedora/fedora-bootc:44                    # Fedora, no desktop
##   quay.io/centos-bootc/centos-bootc:stream10        # CentOS Stream
##
## The CentOS option builds, but its repositories carry a different package set
## from Fedora's: of the 27 names in rpm_packages, 16 do not exist there. The
## build does not fail on that - it records them, see section 3 of build.sh -
## but expect to reconcile the list rather than inherit it.
FROM quay.io/fedora-ostree-desktops/silverblue:44

## The repository this image gets published to, passed in by the workflow.
## build.sh section 9c checks the scope of the signature policy it writes
## against this, so a policy that guards a repository you never publish to
## cannot slip through. Empty for local builds, which skip that check.
ARG IMAGE_REPO=""

## Run the build script.
##
##   --mount=type=bind,from=ctx  makes /ctx/build.sh and /ctx/rpm_packages readable
##                               without copying them into a layer
##   --mount=type=cache          keeps dnf's cache and logs out of the image
##   --mount=type=tmpfs,dst=/tmp gives the build a scratch dir that is discarded
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

## Sanity check: fails the build if the image is not a valid bootable container.
##
## lint's fatal checks fail the build here; its warnings do not. That split is
## deliberate, and it was briefly the other way round.
##
## The warnings are worth reading - they describe a system that boots and then
## misbehaves, most often a directory written to /var that no tmpfiles.d rule
## recreates, so it is silently empty on every machine that installs the image.
## But they fire on ordinary packages, not on mistakes: add cups and postgresql
## to rpm_packages and you get /run/cups and /var/lib/pgsql, which is simply
## what those packages are. With --fatal-warnings that is a failed build for
## doing the one thing this template exists to let you do.
##
## So they are reported rather than enforced: the workflow lifts them onto the
## run summary next to the skipped-package list, where they are hard to miss
## and cost nothing when you decide a given one does not matter.
##
## To enforce them anyway, add --fatal-warnings below - and expect to pair it
## with "--skip <name>" as your package list grows. "bootc container lint
## --list" names every check and says which are fatal and which warn.
RUN bootc container lint
