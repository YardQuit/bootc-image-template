#!/usr/bin/bash
#
# Turn the container image into a bootable ISO or VM disk, on your own machine.
# Needs podman and sudo; the builder must run privileged.
#
# Usage:
#   ./scripts/build-disk.sh                    # ISO from localhost/myimage:latest
#   ./scripts/build-disk.sh qcow2              # VM disk instead
#   ./scripts/build-disk.sh iso myimage v2     # a specific image and tag
#
# Results land in ./output/
set -euo pipefail

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
if [ "${CONFIG}" = "disk_config/disk.toml" ] && grep -q '"changeme"' "${CONFIG}"; then
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

# The builder reads from root's container storage, but "podman build" without
# sudo writes to yours. Copy the image over if it isn't there yet.
if ! sudo podman image exists "${IMAGE}"; then
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
