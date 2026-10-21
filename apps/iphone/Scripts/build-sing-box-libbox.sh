#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${ROOT_DIR}/ThirdParty/sing-box-src"
OUT_DIR="${ROOT_DIR}/ThirdParty/SingBoxFrameworks"
REPO_URL="${SING_BOX_REPO_URL:-https://github.com/SagerNet/sing-box.git}"
BRANCH="${SING_BOX_BRANCH:-testing}"

if ! command -v git >/dev/null 2>&1; then
  echo "git is required" >&2
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "go is required" >&2
  exit 1
fi

GOPATH_VALUE="$(go env GOPATH)"
export PATH="${GOPATH_VALUE}/bin:${PATH}"

if [[ -d "${SRC_DIR}/.git" ]]; then
  git -C "${SRC_DIR}" fetch --depth 1 origin "${BRANCH}"
  git -C "${SRC_DIR}" checkout FETCH_HEAD
else
  git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${SRC_DIR}"
fi

if ! command -v gomobile >/dev/null 2>&1 || ! command -v gobind >/dev/null 2>&1; then
  echo "Installing sagernet gomobile/gobind into GOPATH/bin..."
  (
    cd "${SRC_DIR}"
    make lib_install
  )
fi

echo "Initializing gomobile..."
gomobile init

echo "Building sing-box libbox for Apple..."
(
  cd "${SRC_DIR}"
  make lib_apple
)

mkdir -p "${OUT_DIR}"

found=0
while IFS= read -r -d '' framework; do
  name="$(basename "${framework}")"
  rm -rf "${OUT_DIR:?}/${name}"
  cp -R "${framework}" "${OUT_DIR}/${name}"
  echo "Staged ${name}"
  found=1
done < <(find "${SRC_DIR}" -name '*.xcframework' -print0)

if [[ "${found}" -eq 0 ]]; then
  cat >&2 <<MSG
No .xcframework output was found after make lib_apple.
Check sing-box build output under:
  ${SRC_DIR}
MSG
  exit 1
fi

cat <<MSG

Apple libbox artifacts are staged in:
  ${OUT_DIR}

Next:
  1. Add the staged xcframeworks to SplitVpnPacketTunnel in Xcode.
  2. Implement a real PacketTunnelCore bridge or subclass upstream Library.ExtensionProvider.
MSG
