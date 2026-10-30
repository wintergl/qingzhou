#!/usr/bin/env bash
# Build the pinned public Libbox source; no private framework/cache is required.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${ROOT_DIR}/../.." && pwd)"
SRC_DIR="${ROOT_DIR}/ThirdParty/sing-box-src"
OUT_DIR="${ROOT_DIR}/ThirdParty/SingBoxFrameworks"
LOCK_FILE="${REPO_DIR}/third_party/dependencies.lock.json"
for tool in git go python3 xcodebuild; do
  command -v "${tool}" >/dev/null || { echo "${tool} is required" >&2; exit 1; }
done
[[ "$(uname -s)" == Darwin ]] || { echo "Build Libbox on macOS with full Xcode selected." >&2; exit 1; }
xcrun --sdk iphoneos --show-sdk-path >/dev/null
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null
read_lock() {
  python3 - "${LOCK_FILE}" "$1" <<'PYLOCK'
import json, sys
print(json.load(open(sys.argv[1]))["dependencies"]["sing_box"][sys.argv[2]])
PYLOCK
}
REPO_URL="$(read_lock repository)"
COMMIT="$(read_lock commit)"
GOMOBILE_VERSION="$(read_lock gomobile_version)"
[[ "${COMMIT}" =~ ^[0-9a-f]{40}$ ]] || { echo "Lock must contain a full source commit." >&2; exit 1; }
mkdir -p "${ROOT_DIR}/ThirdParty" "${OUT_DIR}"
NEW_SOURCE=0
if [[ ! -d "${SRC_DIR}/.git" ]]; then
  [[ ! -e "${SRC_DIR}" ]] || { echo "Source path exists without Git metadata; move it aside first." >&2; exit 1; }
  git clone --filter=blob:none --no-checkout "${REPO_URL}" "${SRC_DIR}"
  NEW_SOURCE=1
fi
if [[ "${NEW_SOURCE}" -eq 0 && -n "$(git -C "${SRC_DIR}" status --porcelain --untracked-files=no)" ]]; then
  echo "Libbox source has local changes; preserve them before rebuilding." >&2
  exit 1
fi
if ! git -C "${SRC_DIR}" cat-file -e "${COMMIT}^{commit}" 2>/dev/null; then
  git -C "${SRC_DIR}" fetch --depth 1 "${REPO_URL}" "${COMMIT}"
fi
git -C "${SRC_DIR}" checkout --detach "${COMMIT}"
[[ "$(git -C "${SRC_DIR}" rev-parse HEAD)" == "${COMMIT}" ]]
if [[ "${1:-}" == "--source-only" ]]; then exit 0; fi
# Upstream FindMobile reads GOPATH/bin, so install both tools into a project-local
# GOPATH. Go's public module checksums remain enforced through go.sum.
export GOPATH="${REPO_DIR}/.local/ios-go"
export GOBIN="${GOPATH}/bin"
export GOCACHE="${REPO_DIR}/.local/ios-go-cache"
export CLANG_MODULE_CACHE_PATH="${REPO_DIR}/.local/ios-clang-cache"
# Clang's default Darwin module cache may be outside a restricted workspace.
export CGO_CFLAGS="${CGO_CFLAGS:+${CGO_CFLAGS} }-fmodules-cache-path=\"${CLANG_MODULE_CACHE_PATH}\""
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+${CGO_CXXFLAGS} }-fmodules-cache-path=\"${CLANG_MODULE_CACHE_PATH}\""
export PATH="${GOBIN}:${PATH}"
export GOTOOLCHAIN="go$(read_lock go_version)"
export GOWORK=off
unset GOFLAGS GOROOT
export GOMAXPROCS="${GOMAXPROCS:-4}"
mkdir -p "${GOBIN}" "${GOCACHE}" "${CLANG_MODULE_CACHE_PATH}"
printf 'Installing gomobile/gobind %s into the project cache...\n' "${GOMOBILE_VERSION}"
go install "github.com/sagernet/gomobile/cmd/gomobile@${GOMOBILE_VERSION}"
go install "github.com/sagernet/gomobile/cmd/gobind@${GOMOBILE_VERSION}"
gomobile init
(
  cd "${SRC_DIR}"
  echo "Downloading and verifying the pinned Go module graph..."
  go mod download
  go mod verify
  # Restrict the upstream default (which also builds macOS/tvOS) to our iOS targets.
  echo "Building Libbox for iOS and iOS Simulator..."
  go run -mod=readonly ./cmd/internal/build_libbox -target apple -platform ios,iossimulator
)
FRAMEWORK="${SRC_DIR}/Libbox.xcframework"
[[ -f "${FRAMEWORK}/Info.plist" ]] || { echo "Missing Libbox.xcframework output" >&2; exit 1; }
STAGE_DIR="$(mktemp -d "${OUT_DIR}/.libbox-build.XXXXXX")"
cleanup() {
  if [[ -d "${STAGE_DIR}/previous.xcframework" && ! -e "${OUT_DIR}/Libbox.xcframework" ]]; then
    mv "${STAGE_DIR}/previous.xcframework" "${OUT_DIR}/Libbox.xcframework"
  fi
  rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT
cp -R "${FRAMEWORK}" "${STAGE_DIR}/Libbox.xcframework"
if [[ -e "${OUT_DIR}/Libbox.xcframework" ]]; then
  mv "${OUT_DIR}/Libbox.xcframework" "${STAGE_DIR}/previous.xcframework"
fi
mv "${STAGE_DIR}/Libbox.xcframework" "${OUT_DIR}/Libbox.xcframework"
printf 'Staged Libbox.xcframework from %s\n' "${COMMIT}"
printf 'Keep this source commit, go.mod/go.sum, and the upstream LICENSE with redistributions.\n'
