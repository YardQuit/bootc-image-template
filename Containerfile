## Containerfile - the recipe for your bootable container image.
##
## Everything happens in two stages:
##   1. "ctx" holds the build scripts and package lists, so they are available
##      during the build but never end up inside the finished image.
##   2. The real image: your base image + whatever build.sh does to it.

## Stage 1: build context. FROM scratch means "empty image" - it only carries files.
FROM scratch AS ctx
COPY build_files /

## Stage 2: the image itself.
##
## Pick the base image you want to build on top of. Examples:
##   quay.io/fedora-ostree-desktops/cosmic-atomic:44   # Fedora COSMIC
##   quay.io/fedora-ostree-desktops/silverblue:44      # Fedora GNOME
##   quay.io/fedora-ostree-desktops/kinoite:44         # Fedora KDE
##   quay.io/fedora/fedora-bootc:44                    # Fedora, no desktop
##   quay.io/centos-bootc/centos-bootc:stream10        # CentOS Stream
FROM quay.io/fedora-ostree-desktops/silverblue:44

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
RUN bootc container lint
