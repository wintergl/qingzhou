#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/ThirdParty/sing-box-for-apple-src"
REPO_URL="https://github.com/SagerNet/sing-box-for-apple.git"
BRANCH="${SING_BOX_APPLE_BRANCH:-dev}"

if ! command -v git >/dev/null 2>&1; then
  echo "git is required" >&2
  exit 1
fi

if [[ -d "${VENDOR_DIR}/.git" ]]; then
  git -C "${VENDOR_DIR}" fetch --depth 1 origin "${BRANCH}"
  git -C "${VENDOR_DIR}" checkout FETCH_HEAD
else
  git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${VENDOR_DIR}"
fi

cat <<MSG
Fetched sing-box-for-apple into:
  ${VENDOR_DIR}

Useful upstream files:
  Library/Network/ExtensionProvider.swift
  Extension/PacketTunnelProvider.swift
  Makefile

The upstream PacketTunnelProvider currently subclasses Library.ExtensionProvider.
That provider expects configContent in startTunnel options, which split-vpn now sends.
MSG
