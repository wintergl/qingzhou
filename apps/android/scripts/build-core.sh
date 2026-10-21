#!/usr/bin/env bash
# Builds the Rust core (packages/vpn-core) as a static library for the
# Android app. CMake links it into libsplitvpncore.so, which exposes
# qz_core_call to Kotlin through dev.splitvpn.android.core.CoreClient.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$(cd "${ROOT_DIR}/../../packages/vpn-core" && pwd)"
REPO_DIR="$(cd "${CORE_DIR}/../.." && pwd)"
# Keep build-machine paths out of shipped panic locations and file names.
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$HOME=/user --remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$HOME/.rustup=/rustup --remap-path-prefix=$REPO_DIR=/src"
export CFLAGS="${CFLAGS:+$CFLAGS }-ffile-prefix-map=$HOME=/user -ffile-prefix-map=$HOME/.cargo=/cargo -ffile-prefix-map=$REPO_DIR=/src -fdebug-compilation-dir=/build"
OUT_DIR="${ROOT_DIR}/app/src/main/cpp/prebuilt"
TARGET_DIR="${CARGO_TARGET_DIR:-${CORE_DIR}/target}"
PROFILE="${SPLITVPN_CORE_PROFILE:-release}"
API_LEVEL=26
# Android ABI -> Rust target. Only arm64 ships, matching libmihomo.so.
ABIS=(arm64-v8a:aarch64-linux-android)

SDK_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"
NDK_DIR="${ANDROID_NDK_HOME:-${SDK_DIR}/ndk/27.0.12077973}"
case "$(uname -s)" in
  Darwin) HOST_TAG=darwin-x86_64 ;;
  Linux) HOST_TAG=linux-x86_64 ;;
  *) echo "Unsupported host $(uname -s)" >&2; exit 1 ;;
esac
TOOLCHAIN="${NDK_DIR}/toolchains/llvm/prebuilt/${HOST_TAG}/bin"
if [[ ! -d "${TOOLCHAIN}" ]]; then
  echo "Android NDK not found at ${NDK_DIR}; set ANDROID_NDK_HOME" >&2
  exit 1
fi

for tool in cargo rustup; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "${tool} is required" >&2
    exit 1
  fi
done

profile_flag=()
profile_dir="debug"
if [[ "${PROFILE}" == "release" ]]; then
  profile_flag=(--release)
  profile_dir="release"
fi

installed="$(rustup target list --installed)"
for pair in "${ABIS[@]}"; do
  abi="${pair%%:*}"
  target="${pair#*:}"
  if ! grep -qx "${target}" <<<"${installed}"; then
    echo "Missing Rust target ${target}; run: rustup target add ${target}" >&2
    exit 1
  fi
  env_target="$(tr '[:lower:]-' '[:upper:]_' <<<"${target}")"
  clang="${TOOLCHAIN}/${target}${API_LEVEL}-clang"
  export "CC_${target//-/_}=${clang}"
  export "AR_${target//-/_}=${TOOLCHAIN}/llvm-ar"
  export "CARGO_TARGET_${env_target}_LINKER=${clang}"

  echo "Building splitvpn-core for ${target} (${PROFILE})..."
  cargo rustc \
    --manifest-path "${CORE_DIR}/Cargo.toml" \
    --locked \
    --lib \
    --crate-type staticlib \
    --target "${target}" \
    --target-dir "${TARGET_DIR}" \
    "${profile_flag[@]+"${profile_flag[@]}"}"
  mkdir -p "${OUT_DIR}/${abi}"
  cp "${TARGET_DIR}/${target}/${profile_dir}/libsplitvpn_core.a" "${OUT_DIR}/${abi}/"
  echo "Staged ${OUT_DIR}/${abi}/libsplitvpn_core.a"
done
