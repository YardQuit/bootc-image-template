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
## Pick the base image you want to build on top of.
##
## Fedora Atomic Desktops - a full desktop, and what this template is written
## around. Same base, different session:
##
##   quay.io/fedora-ostree-desktops/silverblue:44        GNOME  (the default)
##   quay.io/fedora-ostree-desktops/kinoite:44           KDE Plasma
##   quay.io/fedora-ostree-desktops/cosmic-atomic:44     COSMIC
##   quay.io/fedora-ostree-desktops/sway-atomic:44       Sway
##   quay.io/fedora-ostree-desktops/xfce-atomic:44       Xfce
##   quay.io/fedora-ostree-desktops/budgie-atomic:44     Budgie
##   quay.io/fedora-ostree-desktops/lxqt-atomic:44       LXQt
##   quay.io/fedora-ostree-desktops/base-atomic:44       no desktop session
##
## Server and minimal bases - no desktop at all, so a desktop image built on one
## of these is yours to assemble:
##
##   quay.io/fedora/fedora-bootc:44                      Fedora
##   quay.io/centos-bootc/centos-bootc:stream10          CentOS Stream
##   quay.io/hummingbird-community/bootc-os:latest       Project Hummingbird
##   registry.redhat.io/rhel10/rhel-bootc:latest         RHEL - see "Subscription" below
##
## The further you go from the desktop bases, the less the defaults here can
## assume. Three cases, measured rather than guessed:
##
##   fedora-bootc      no tuned, firewalld, cron or plymouth in the base, but
##                     all four are in Fedora's repositories, so section 8 and
##                     section 9b install them and the build is unchanged.
##
##   centos-bootc      the same, plus a different package set: of the 21 names
##                     in rpm_packages, 16 do not exist there. That does not
##                     fail the build - section 3 records them - but expect to
##                     reconcile the list rather than inherit it.
##
##   bootc-os          a minimal image for virtual machines, and it shows: 20 of
##   (Hummingbird)     the 21 names do not arrive, and its repositories carry no
##                     tuned, crontabs, cronie-anacron or plymouth either. So
##                     section 8 stops at its pkg_install line until you drop
##                     what it cannot provide, and section 9b has nothing to
##                     install - which is no loss, because a splash screen on a
##                     virtual machine is decoration nobody sees. Trimmed to
##                     that, it builds clean and lints clean. ISOs are out:
##                     bootc-image-builder has no Anaconda definition for it
##                     ("could not find def file for distro hummingbird-..."),
##                     though disk images build normally.
FROM quay.io/fedora-ostree-desktops/silverblue:44

## Subscription: the RHEL bases, and only those, need credentials - two of them,
## for two different things, and having one does not get you the other.
##
##   1. To PULL the base. registry.redhat.io refuses anonymous requests, so
##      "podman build" fails before it starts. It answers 401 rather than 404,
##      so a missing login and a mistyped image name do at least look different.
##      Log in once on your own machine:
##
##          podman login registry.redhat.io
##
##      For CI, make a service account at access.redhat.com (Service Accounts),
##      keep its token as a repository secret, and log in the same way in a step
##      before the build. Both scripts/build.sh and the workflow shell out to
##      podman, so they pick up an existing login with no further argument.
##
##   2. To INSTALL from RHEL repositories while the build runs. That needs an
##      entitlement certificate, which the pull credential is not. On a
##      subscribed RHEL host podman mounts the host's entitlements into the
##      build by itself and there is nothing to do. Anywhere else - a Fedora
##      laptop, a GitHub runner - hand them in:
##
##          podman build --secret id=entitlement,src=/etc/pki/entitlement/NNN.pem \
##                       --secret id=entitlement-key,src=/etc/pki/entitlement/NNN-key.pem ...
##
##      and uncomment the two mounts in the RUN below, which put them where dnf
##      looks for them.
##
## Not exercised here: every base above it is built and tested on is public.
## Treat this half as the shape of the answer rather than a recipe known to run.

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
    # RHEL entitlement, off by default - see "Subscription" above.
    # --mount=type=secret,id=entitlement,target=/etc/pki/entitlement/client.pem \
    # --mount=type=secret,id=entitlement-key,target=/etc/pki/entitlement/client-key.pem \
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
