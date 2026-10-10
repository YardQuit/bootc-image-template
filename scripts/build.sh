#!/usr/bin/bash
#
# Build the container image on your own machine, exactly like CI does.
#
# Usage:
#   ./scripts/build.sh                 # builds localhost/myimage:latest
#   ./scripts/build.sh myimage v2      # builds localhost/myimage:v2
#   NO_CACHE=1 ./scripts/build.sh      # ignore cached layers
set -euo pipefail

IMAGE_NAME="${1:-myimage}"
TAG="${2:-latest}"

# Run from the repository root no matter where the script is called from.
cd "$(dirname "$0")/.."

ARGS=(--file ./Containerfile --tag "localhost/${IMAGE_NAME}:${TAG}")

# --format docker matches CI, so the local image is identical.
ARGS+=(--format docker)

if [ "${NO_CACHE:-0}" = "1" ]; then
    ARGS+=(--no-cache)
fi

echo "Building localhost/${IMAGE_NAME}:${TAG} ..."
podman build "${ARGS[@]}" .

echo
echo "Done. Inspect it with:"
echo "  podman run --rm -it localhost/${IMAGE_NAME}:${TAG} /bin/bash"
