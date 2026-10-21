#!/usr/bin/env bash
# Builds the Rust core (packages/vpn-core) as SplitVpnCore.xcframework for
# the iPhone app target. Swift imports it with `import SplitVpnCore`.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$(cd "${ROOT_DIR}/../../packages/vpn-core" && pwd)"
REPO_DIR="$(cd "${CORE_DIR}/../.." && pwd)"
# Keep build-machine paths out of shipped panic locations and file names.
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$HOME=/user --remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$HOME/.rustup=/rustup --remap-path-prefix=$REPO_DIR=/src"
export CFLAGS="${CFLAGS:+$CFLAGS }-ffile-prefix-map=$HOME=/user -ffile-prefix-map=$HOME/.cargo=/cargo -ffile-prefix-map=$REPO_DIR=/src -fdebug-compilation-dir=/build"
OUT_DIR="${SPLITVPN_CORE_FRAMEWORK_DIR:-${ROOT_DIR}/ThirdParty/CoreFrameworks}"
FRAMEWORK="${OUT_DIR}/SplitVpnCore.xcframework"
TARGET_DIR="${CARGO_TARGET_DIR:-${CORE_DIR}/target}"
PROFILE="${SPLITVPN_CORE_PROFILE:-release}"
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)

for tool in cargo rustup xcodebuild lipo; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "${tool} is required" >&2
    exit 1
  fi
done

installed="$(rustup target list --installed)"
for target in "${TARGETS[@]}"; do
  if ! grep -qx "${target}" <<<"${installed}"; then
    echo "Missing Rust target ${target}; run: rustup target add ${target}" >&2
    exit 1
  fi
done

profile_flag=()
profile_dir="debug"
if [[ "${PROFILE}" == "release" ]]; then
  profile_flag=(--release)
  profile_dir="release"
fi

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

mkdir -p "${OUT_DIR}"
stage_dir="$(mktemp -d "${OUT_DIR}/.core-build.XXXXXX")"
cleanup() {
  if [[ -d "${stage_dir}/previous.xcframework" && ! -e "${FRAMEWORK}" ]]; then
    mv "${stage_dir}/previous.xcframework" "${FRAMEWORK}"
  fi
  rm -rf "${stage_dir}"
}
trap cleanup EXIT
headers_dir="${stage_dir}/Headers"
mkdir -p "${headers_dir}"
cp "${CORE_DIR}/include/qz_core.h" "${headers_dir}/"
cat >"${headers_dir}/module.modulemap" <<'MAP'
module SplitVpnCore {
  header "qz_core.h"
  link "splitvpn_core"
  export *
}
MAP

for target in "${TARGETS[@]}"; do
  echo "Building splitvpn-core for ${target} (${PROFILE})..."
  cargo rustc \
    --manifest-path "${CORE_DIR}/Cargo.toml" \
    --locked \
    --lib \
    --crate-type staticlib \
    --target "${target}" \
    --target-dir "${TARGET_DIR}" \
    "${profile_flag[@]+"${profile_flag[@]}"}"
done

# Both simulator architectures must share one XCFramework platform slice.
lipo -create \
  "${TARGET_DIR}/aarch64-apple-ios-sim/${profile_dir}/libsplitvpn_core.a" \
  "${TARGET_DIR}/x86_64-apple-ios/${profile_dir}/libsplitvpn_core.a" \
  -output "${stage_dir}/libsplitvpn_core.a"
xcodebuild -create-xcframework \
  -library "${TARGET_DIR}/aarch64-apple-ios/${profile_dir}/libsplitvpn_core.a" -headers "${headers_dir}" \
  -library "${stage_dir}/libsplitvpn_core.a" -headers "${headers_dir}" \
  -output "${stage_dir}/SplitVpnCore.xcframework" >/dev/null
if [[ -e "${FRAMEWORK}" ]]; then
  mv "${FRAMEWORK}" "${stage_dir}/previous.xcframework"
fi
mv "${stage_dir}/SplitVpnCore.xcframework" "${FRAMEWORK}"

echo "Staged ${FRAMEWORK}"
du -sh "${FRAMEWORK}"
