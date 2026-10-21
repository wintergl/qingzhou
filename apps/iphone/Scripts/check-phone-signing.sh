#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${ROOT_DIR}/Config"
BASE_CONFIG="${CONFIG_DIR}/Signing.xcconfig"
LOCAL_CONFIG="${CONFIG_DIR}/Signing.local.xcconfig"
PROJECT="${ROOT_DIR}/SplitVpn.xcodeproj"
ACTION="${1:-check}"
STATUS=0

usage() {
  cat <<EOF
Usage:
  apps/iphone/Scripts/check-phone-signing.sh
  apps/iphone/Scripts/check-phone-signing.sh --build
  apps/iphone/Scripts/check-phone-signing.sh --init TEAM_ID APP_BUNDLE_ID [APP_GROUP]

Examples:
  apps/iphone/Scripts/check-phone-signing.sh --init ABCDE12345 com.yourname.splitvpn
  apps/iphone/Scripts/check-phone-signing.sh --init ABCDE12345 com.yourname.splitvpn group.com.yourname.splitvpn
EOF
}

ok() {
  printf 'OK   %s\n' "$1"
}

warn() {
  printf 'WARN %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  STATUS=1
}

value_for() {
  local key="$1"
  awk -F '=' -v key="${key}" '
    /^[[:space:]]*\/\// { next }
    /^[[:space:]]*#/ { next }
    {
      lhs=$1
      rhs=$0
      sub(/^[^=]*=/, "", rhs)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", rhs)
      if (lhs == key) {
        value=rhs
      }
    }
    END { print value }
  ' "${BASE_CONFIG}" "${LOCAL_CONFIG}" 2>/dev/null
}

resolved_value_for() {
  local key="$1"
  awk -F '=' -v key="${key}" '
    {
      lhs=$1
      rhs=$0
      sub(/^[^=]*=/, "", rhs)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", rhs)
      if (lhs == key) {
        value=rhs
      }
    }
    END { print value }
  ' /tmp/split-vpn-iphone-build-settings.log 2>/dev/null
}

init_local_config() {
  local team_id="${1:-}"
  local app_bundle_id="${2:-}"
  local app_group="${3:-group.${app_bundle_id}}"
  local tunnel_bundle_id="${app_bundle_id}.PacketTunnel"

  if [[ -z "${team_id}" || -z "${app_bundle_id}" ]]; then
    usage
    fail "--init requires TEAM_ID and APP_BUNDLE_ID"
    return
  fi

  if [[ -f "${LOCAL_CONFIG}" ]]; then
    fail "Config/Signing.local.xcconfig already exists; edit it directly or remove it before --init"
    return
  fi

  if [[ "${app_group}" != group.* ]]; then
    fail "APP_GROUP must start with group."
    return
  fi

  cat >"${LOCAL_CONFIG}" <<EOF
// Local phone-test values. This file is ignored by git.

SPLITVPN_DEVELOPMENT_TEAM = ${team_id}
SPLITVPN_APP_BUNDLE_ID = ${app_bundle_id}
SPLITVPN_PACKET_TUNNEL_BUNDLE_ID = ${tunnel_bundle_id}
SPLITVPN_APP_GROUP = ${app_group}
EOF

  ok "Created Config/Signing.local.xcconfig"
}

printf 'split-vpn iPhone phone-signing check\n'
printf 'Root: %s\n\n' "${ROOT_DIR}"

if [[ "${ACTION}" == "--help" || "${ACTION}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${ACTION}" == "--init" ]]; then
  init_local_config "${2:-}" "${3:-}" "${4:-}"
  if [[ "${STATUS}" -ne 0 ]]; then
    printf '\n'
    fail "Phone-signing initialization failed"
    exit "${STATUS}"
  fi
  printf '\n'
elif [[ $# -gt 1 ]]; then
  usage
  fail "Unexpected arguments for action: ${ACTION}"
fi

if [[ ! -f "${BASE_CONFIG}" ]]; then
  fail "Missing Config/Signing.xcconfig"
elif [[ ! -f "${LOCAL_CONFIG}" ]]; then
  fail "Missing Config/Signing.local.xcconfig; run --init TEAM_ID APP_BUNDLE_ID first"
else
  ok "Signing.local.xcconfig exists"
fi

TEAM_ID="$(value_for SPLITVPN_DEVELOPMENT_TEAM)"
APP_BUNDLE_ID="$(value_for SPLITVPN_APP_BUNDLE_ID)"
TUNNEL_BUNDLE_ID="$(value_for SPLITVPN_PACKET_TUNNEL_BUNDLE_ID)"
APP_GROUP="$(value_for SPLITVPN_APP_GROUP)"

[[ -n "${TEAM_ID}" && "${TEAM_ID}" != "YOURTEAMID" ]] \
  && ok "SPLITVPN_DEVELOPMENT_TEAM set" \
  || fail "SPLITVPN_DEVELOPMENT_TEAM is empty or placeholder"

[[ -n "${APP_BUNDLE_ID}" && "${APP_BUNDLE_ID}" != "dev.splitvpn.iphone" && "${APP_BUNDLE_ID}" != "com.example.splitvpn" ]] \
  && ok "SPLITVPN_APP_BUNDLE_ID set: ${APP_BUNDLE_ID}" \
  || fail "SPLITVPN_APP_BUNDLE_ID is still a placeholder"

[[ -n "${TUNNEL_BUNDLE_ID}" && "${TUNNEL_BUNDLE_ID}" != "dev.splitvpn.iphone.PacketTunnel" && "${TUNNEL_BUNDLE_ID}" != "com.example.splitvpn.PacketTunnel" ]] \
  && ok "SPLITVPN_PACKET_TUNNEL_BUNDLE_ID set: ${TUNNEL_BUNDLE_ID}" \
  || fail "SPLITVPN_PACKET_TUNNEL_BUNDLE_ID is still a placeholder"

[[ -n "${APP_GROUP}" && "${APP_GROUP}" != "group.dev.splitvpn.iphone" && "${APP_GROUP}" != "group.com.example.splitvpn" ]] \
  && ok "SPLITVPN_APP_GROUP set: ${APP_GROUP}" \
  || fail "SPLITVPN_APP_GROUP is still a placeholder"

if [[ "${APP_GROUP}" == group.* ]]; then
  ok "SPLITVPN_APP_GROUP uses group.* prefix"
else
  fail "SPLITVPN_APP_GROUP must start with group."
fi

if [[ "${TUNNEL_BUNDLE_ID}" == "${APP_BUNDLE_ID}".* ]]; then
  ok "Packet Tunnel bundle ID is nested under app bundle ID"
else
  warn "Packet Tunnel bundle ID is not nested under app bundle ID"
fi

if [[ "${STATUS}" -ne 0 ]]; then
  warn "Skipping xcodebuild signing checks until local signing values are valid"
elif command -v xcodebuild >/dev/null 2>&1; then
  if xcodebuild \
    -project "${PROJECT}" \
    -scheme SplitVpnIphone \
    -configuration Debug \
    -showBuildSettings >/tmp/split-vpn-iphone-build-settings.log 2>&1; then
    ok "xcodebuild resolved build settings"
    RESOLVED_APP_BUNDLE_ID="$(resolved_value_for PRODUCT_BUNDLE_IDENTIFIER)"
    RESOLVED_TEAM_ID="$(resolved_value_for DEVELOPMENT_TEAM)"
    RESOLVED_APP_GROUP="$(resolved_value_for SPLITVPN_APP_GROUP)"
    [[ "${RESOLVED_APP_BUNDLE_ID}" == "${APP_BUNDLE_ID}" ]] \
      && ok "Resolved app bundle ID matches local signing config" \
      || fail "Resolved app bundle ID mismatch: ${RESOLVED_APP_BUNDLE_ID}"
    [[ "${RESOLVED_TEAM_ID}" == "${TEAM_ID}" ]] \
      && ok "Resolved development team matches local signing config" \
      || fail "Resolved development team mismatch: ${RESOLVED_TEAM_ID}"
    [[ "${RESOLVED_APP_GROUP}" == "${APP_GROUP}" ]] \
      && ok "Resolved app group matches local signing config" \
      || fail "Resolved app group mismatch: ${RESOLVED_APP_GROUP}"
  else
    fail "xcodebuild could not resolve build settings; see /tmp/split-vpn-iphone-build-settings.log"
  fi
else
  fail "xcodebuild not found"
fi

if [[ "${STATUS}" -eq 0 && "${ACTION}" == "--build" ]]; then
  if xcodebuild \
    -project "${PROJECT}" \
    -scheme SplitVpnIphone \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath /private/tmp/split-vpn-iphone-phone-derived \
    build >/tmp/split-vpn-iphone-phone-build.log 2>&1; then
    ok "Signed generic iOS build passes"
  else
    fail "Signed generic iOS build failed; see /tmp/split-vpn-iphone-phone-build.log"
  fi
elif [[ "${ACTION}" != "check" && "${ACTION}" != "--build" && "${ACTION}" != "--init" ]]; then
  fail "Unknown action: ${ACTION}; use check or --build"
fi

printf '\n'
if [[ "${STATUS}" -eq 0 ]]; then
  ok "Phone-signing check completed"
else
  fail "Phone-signing check found issues"
fi

exit "${STATUS}"
