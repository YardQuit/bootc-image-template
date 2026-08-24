#!/usr/bin/bash
#
# Turn the container image into a bootable ISO or VM disk, on your own machine.
# Needs podman and sudo; the builder must run privileged.
#
# Usage:
#   ./scripts/build-disk.sh                    # ISO from localhost/myimage:latest
#   ./scripts/build-disk.sh qcow2              # VM disk instead
#   ./scripts/build-disk.sh iso myimage v2     # a specific image and tag
#   ./scripts/build-disk.sh --check qcow2      # check the config, build nothing
#
# The tag picks which local image goes onto the ISO. What the installed machine
# upgrades from afterwards is set by the kickstart in disk_config/iso.toml, and
# that names the published image at :latest whatever is built here - which is
# the only reason an ISO built from localhost/... installs a machine that can
# upgrade at all.
#
# --check stops after the checks below - the config file it would use, and the
# placeholder-password refusal - and reports what it found. Useful for asking
# "would this build?" without waiting for one, and it is what the tests use:
# they exercise the refusal, and running the real thing would launch a
# privileged builder on every case that is meant to pass.
#
# Results land in ./output/
set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
    CHECK_ONLY=1
    shift
fi

DISK_TYPE="${1:-iso}"     # iso | qcow2 | raw
IMAGE_NAME="${2:-myimage}"
TAG="${3:-latest}"

BUILDER_IMAGE="quay.io/centos-bootc/bootc-image-builder:latest"
IMAGE="localhost/${IMAGE_NAME}:${TAG}"

cd "$(dirname "$0")/.."

# The ISO gets the installer config, disks get the partition config.
if [ "${DISK_TYPE}" = "iso" ]; then
    CONFIG="disk_config/iso.toml"
else
    CONFIG="disk_config/disk.toml"
fi

# disk.toml ships a placeholder password on an account that is in wheel. Build
# a qcow2 from it unedited and the result is a sudo-capable login whose
# password is published in the repository - so stop here instead. The ISO does
# not read this file at all: Anaconda asks for a user at install time.
# Anchored to the password setting itself. The comments above it in disk.toml
# quote "changeme" while explaining what the placeholder is, so an unanchored
# match finds those as well - and then this refuses on every run, including
# long after the password has been set properly.
if [ "${CONFIG}" = "disk_config/disk.toml" ] \
   && grep -qE '^[[:space:]]*password[[:space:]]*=[[:space:]]*"changeme"' "${CONFIG}"; then
    echo "Error: ${CONFIG} still has the placeholder password \"changeme\"." >&2
    echo >&2
    echo "That account is in wheel, so the disk image you are about to build" >&2
    echo "would have a sudo login with a password anyone can read in this" >&2
    echo "repository. Edit the [[customizations.user]] block first:" >&2
    echo >&2
    echo "  - an SSH key instead: uncomment \"key\", delete \"password\"" >&2
    echo "  - or a hash instead of plaintext: openssl passwd -6" >&2
    echo "  - or just a different password, if the image stays on this machine" >&2
    exit 1
fi

if [ "${CHECK_ONLY}" -eq 1 ]; then
    echo "Checks passed. A ${DISK_TYPE} build would use ${CONFIG} and ${IMAGE}."
    exit 0
fi

# The builder reads from root's container storage, but "podman build" without
# sudo writes to yours, so the image has to be copied across.
#
# Compare the two by image ID rather than asking whether the name exists.
# "podman image exists" matches on name:tag, so once the first copy has landed
# it answers yes forever - and every later run would then build the disk from
# whatever image was current when you first ran this, however many times you
# rebuild the container in between. Nothing says so; the disk is simply stale.
LOCAL_ID="$(podman image inspect "${IMAGE}" --format '{{.Id}}' 2>/dev/null || true)"
ROOT_ID="$(sudo podman image inspect "${IMAGE}" --format '{{.Id}}' 2>/dev/null || true)"

if [ -z "${LOCAL_ID}" ]; then
    echo "Error: ${IMAGE} does not exist." >&2
    echo >&2
    echo "Build it first:" >&2
    echo "  ./scripts/build.sh ${IMAGE_NAME} ${TAG}" >&2
    exit 1
fi

if [ "${LOCAL_ID}" != "${ROOT_ID}" ]; then
    echo "Copying ${IMAGE} into root's container storage ..."
    podman image save "${IMAGE}" | sudo podman image load
fi

mkdir -p output

echo "Building ${DISK_TYPE} from ${IMAGE} ..."
sudo podman run --rm --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    --volume "${PWD}/${CONFIG}:/config.toml:ro" \
    --volume "${PWD}/output:/output" \
    --volume /var/lib/containers/storage:/var/lib/containers/storage \
    "${BUILDER_IMAGE}" \
    --type "${DISK_TYPE}" \
    --rootfs btrfs \
    --chown "$(id -u):$(id -g)" \
    "${IMAGE}"

echo
echo "Done:"
find output -type f -printf '  %p (%s bytes)\n'
