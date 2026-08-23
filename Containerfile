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
## --fatal-warnings makes lint's warnings fail too, not just its errors. Those
## warnings are the ones that describe a system that boots but misbehaves - a
## directory written to /var that no tmpfiles.d rule recreates, say, which is
## silently empty on every machine that installs the image. They are easy to
## miss in a build log and expensive to find later.
##
## Drop the flag if a warning ever blocks you and you have decided it is not
## worth fixing; "bootc container lint --list" names every check, and --skip
## turns off one by name, which is better than turning them all off.
RUN bootc container lint --fatal-warnings
