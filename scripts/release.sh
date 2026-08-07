#!/bin/bash
# Helper to cut a release and print the values needed for the Homebrew formula.
#   ./scripts/release.sh 0.1.0
set -euo pipefail
VER="${1:?usage: release.sh <version>  (e.g. 0.1.0)}"
TAG="v${VER}"
OWNER="Zsoldier"
REPO="mic-music-pause"

git tag -a "${TAG}" -m "${REPO} ${TAG}"
echo "Created tag ${TAG}. Push it with:  git push origin ${TAG}"
echo
echo "After GitHub builds the archive, compute the sha256 for the formula:"
echo "  curl -sL https://github.com/${OWNER}/${REPO}/archive/refs/tags/${TAG}.tar.gz | shasum -a 256"
echo
echo "Then in Formula/mic-music-pause.rb set:"
echo "  version \"${VER}\""
echo "  url     \"https://github.com/${OWNER}/${REPO}/archive/refs/tags/${TAG}.tar.gz\""
echo "  sha256  \"<value from above>\""
