#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${ROOT_DIR}/../.." && pwd)"
STATUS=0
export GOPATH="${REPO_DIR}/.local/ios-go"
export GOCACHE="${REPO_DIR}/.local/ios-go-cache"
export PATH="${GOPATH}/bin:${PATH}"
export GOTOOLCHAIN=local
export GOMAXPROCS="${GOMAXPROCS:-4}"
CHECK_DIR="$(mktemp -d /private/tmp/qingzhou-ios-readiness.XXXXXX)"
printf 'Readiness logs and temporary build outputs: %s\n' "${CHECK_DIR}"

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

exists() {
  [[ -e "${ROOT_DIR}/$1" ]]
}

printf 'split-vpn iPhone readiness\n'
printf 'Root: %s\n\n' "${ROOT_DIR}"

exists "SplitVpn.xcodeproj/project.pbxproj" && ok "Xcode project exists" || fail "Missing SplitVpn.xcodeproj"
exists "App/SplitVpnIphone.entitlements" && ok "App entitlements exist" || fail "Missing app entitlements"
exists "PacketTunnel/SplitVpnPacketTunnel.entitlements" && ok "Packet Tunnel entitlements exist" || fail "Missing packet tunnel entitlements"
exists "PacketTunnel/PacketTunnelProvider.swift" && ok "Packet Tunnel provider exists" || fail "Missing PacketTunnelProvider.swift"
exists "App/Services/CoreClient.swift" && ok "Rust core bridge exists" || fail "Missing App/Services/CoreClient.swift"
exists "ThirdParty/CoreFrameworks/SplitVpnCore.xcframework" && ok "SplitVpnCore.xcframework staged" || fail "SplitVpnCore.xcframework missing; run Scripts/build-core-xcframework.sh"
exists "Tests/ConfigGenerationSmoke.swift" && ok "Config smoke test exists" || warn "Missing config smoke test"
exists "Config/Signing.xcconfig" && ok "Signing.xcconfig exists" || fail "Missing Config/Signing.xcconfig"
exists "App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" && ok "App icon PNG exists" || fail "Missing AppIcon-1024.png"

if grep -q "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" "${ROOT_DIR}/SplitVpn.xcodeproj/project.pbxproj" &&
  grep -Eq '"filename"[[:space:]]*:[[:space:]]*"AppIcon-1024.png"' "${ROOT_DIR}/App/Assets.xcassets/AppIcon.appiconset/Contents.json"; then
  ok "App icon is wired into the asset catalog"
else
  fail "App icon is not fully wired into Xcode asset catalog"
fi

SIGNING_CONFIG="${ROOT_DIR}/Config/Signing.xcconfig"
SIGNING_LOCAL_CONFIG="${ROOT_DIR}/Config/Signing.local.xcconfig"

xcconfig_value() {
  local key="$1"
  awk -F= -v key="${key}" '
    /^[[:space:]]*\/\// { next }
    {
      lhs=$1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
      if (lhs == key) {
        rhs=$2
        sub(/[[:space:]]*\/\/.*/, "", rhs)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", rhs)
        value=rhs
      }
    }
    END { print value }
  ' "${SIGNING_CONFIG}" "${SIGNING_LOCAL_CONFIG}" 2>/dev/null
}

SIGNING_TEAM="$(xcconfig_value SPLITVPN_DEVELOPMENT_TEAM)"
SIGNING_APP_BUNDLE_ID="$(xcconfig_value SPLITVPN_APP_BUNDLE_ID)"
SIGNING_PACKET_TUNNEL_BUNDLE_ID="$(xcconfig_value SPLITVPN_PACKET_TUNNEL_BUNDLE_ID)"
SIGNING_APP_GROUP="$(xcconfig_value SPLITVPN_APP_GROUP)"

if [[ -z "${SIGNING_TEAM}" ]]; then
  warn "SPLITVPN_DEVELOPMENT_TEAM is empty; set it in Config/Signing.local.xcconfig before phone testing"
else
  ok "SPLITVPN_DEVELOPMENT_TEAM appears configured"
fi

if [[ "${SIGNING_APP_GROUP}" == "group.dev.splitvpn.iphone" ]]; then
  warn "SPLITVPN_APP_GROUP still uses placeholder group.dev.splitvpn.iphone"
else
  ok "SPLITVPN_APP_GROUP placeholder appears replaced"
fi

if [[ "${SIGNING_APP_BUNDLE_ID}" == "dev.splitvpn.iphone" || "${SIGNING_PACKET_TUNNEL_BUNDLE_ID}" == "dev.splitvpn.iphone.PacketTunnel" ]]; then
  warn "Bundle IDs still use dev.splitvpn.iphone placeholders"
else
  ok "Bundle ID placeholders appear replaced"
fi

if grep -R "\$(SPLITVPN_APP_GROUP)" "${ROOT_DIR}/App/SplitVpnIphone.entitlements" "${ROOT_DIR}/PacketTunnel/SplitVpnPacketTunnel.entitlements" >/dev/null 2>&1 &&
  grep -R "SplitVpnAppGroupIdentifier" "${ROOT_DIR}/App/Info.plist" "${ROOT_DIR}/PacketTunnel/Info.plist" >/dev/null 2>&1; then
  ok "App Group is build-setting driven in plist and entitlements"
else
  warn "App Group is not fully build-setting driven in plist and entitlements"
fi

if [[ -f "${ROOT_DIR}/ThirdParty/SingBoxFrameworks/Libbox.xcframework/Info.plist" ]]; then
  ok "Required Libbox.xcframework staged"
else
  fail "Missing Libbox.xcframework; run Scripts/build-sing-box-libbox.sh"
fi

if grep -R "core: PacketTunnelCore = MissingPacketTunnelCore()" "${ROOT_DIR}/PacketTunnel" >/dev/null 2>&1; then
  warn "Packet Tunnel still defaults directly to MissingPacketTunnelCore"
elif grep -R "return LibboxPacketTunnelCore()" "${ROOT_DIR}/PacketTunnel" >/dev/null 2>&1; then
  ok "Packet Tunnel defaults to LibboxPacketTunnelCore when Libbox is importable"
else
  warn "Packet Tunnel default core factory is unclear"
fi

if command -v go >/dev/null 2>&1; then
  ok "Go available: $(go version)"
  GOPATH_BIN="${REPO_DIR}/.local/ios-go/bin"
else
  warn "Go not found; needed to build sing-box libbox locally"
  GOPATH_BIN=""
fi

if command -v gomobile >/dev/null 2>&1; then
  ok "gomobile available: $(command -v gomobile)"
elif [[ -n "${GOPATH_BIN}" && -x "${GOPATH_BIN}/gomobile" ]]; then
  ok "gomobile available: ${GOPATH_BIN}/gomobile"
else
  warn "gomobile not found; run Scripts/build-sing-box-libbox.sh"
fi

if command -v gobind >/dev/null 2>&1; then
  ok "gobind available: $(command -v gobind)"
elif [[ -n "${GOPATH_BIN}" && -x "${GOPATH_BIN}/gobind" ]]; then
  ok "gobind available: ${GOPATH_BIN}/gobind"
else
  warn "gobind not found; run Scripts/build-sing-box-libbox.sh"
fi

if command -v xcodebuild >/dev/null 2>&1; then
  if xcodebuild -list -project "${ROOT_DIR}/SplitVpn.xcodeproj" >${CHECK_DIR}/split-vpn-xcodebuild-list.log 2>&1; then
    ok "xcodebuild can read the project"
  else
    warn "xcodebuild failed to read the project; see ${CHECK_DIR}/split-vpn-xcodebuild-list.log"
  fi

  if xcodebuild -quiet \
    -project "${ROOT_DIR}/SplitVpn.xcodeproj" \
    -scheme SplitVpnIphone \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath ${CHECK_DIR}/split-vpn-xcode-derived \
    CODE_SIGNING_ALLOWED=NO \
    build >${CHECK_DIR}/split-vpn-xcodebuild-iphone.log 2>&1; then
    ok "Unsigned generic iOS build passes"
  else
    fail "Unsigned generic iOS build failed; see ${CHECK_DIR}/split-vpn-xcodebuild-iphone.log"
  fi
else
  warn "xcodebuild not found"
fi

# Host (macOS) build of the Rust core so swiftc can typecheck and run the smoke test.
CORE_DIR="${REPO_DIR}/packages/vpn-core"
CORE_HEADERS="$(mktemp -d)"
trap 'rm -r "${CORE_HEADERS}"' EXIT
cp "${CORE_DIR}/include/qz_core.h" "${CORE_HEADERS}/"
printf 'module SplitVpnCore {\n  header "qz_core.h"\n  link "splitvpn_core"\n  export *\n}\n' >"${CORE_HEADERS}/module.modulemap"
if cargo rustc --quiet --manifest-path "${CORE_DIR}/Cargo.toml" --locked --lib --crate-type staticlib --release >${CHECK_DIR}/split-vpn-core-host.log 2>&1; then
  ok "Host Rust core builds"
else
  fail "Host Rust core build failed; see ${CHECK_DIR}/split-vpn-core-host.log"
fi
CORE_SWIFT_FLAGS=(-I "${CORE_HEADERS}" -L "${CARGO_TARGET_DIR:-${CORE_DIR}/target}/release")

if CLANG_MODULE_CACHE_PATH=${CHECK_DIR}/split-vpn-swift-module-cache \
  swiftc -parse-as-library "${ROOT_DIR}/Shared/TunnelRecoveryPolicy.swift" \
  "${ROOT_DIR}/Tests/TunnelRecoverySmoke.swift" -o ${CHECK_DIR}/split-vpn-iphone-recovery-smoke && \
  ${CHECK_DIR}/split-vpn-iphone-recovery-smoke; then
  ok "TunnelRecoverySmoke passes"
else
  fail "TunnelRecoverySmoke failed"
fi

if command -v swiftc >/dev/null 2>&1; then
  if (
    cd "${REPO_DIR}" &&
      CLANG_MODULE_CACHE_PATH=${CHECK_DIR}/split-vpn-swift-module-cache \
        swiftc -typecheck "${CORE_SWIFT_FLAGS[@]}" apps/iphone/App/*.swift apps/iphone/App/Services/*.swift apps/iphone/App/Screens/*.swift apps/iphone/Shared/*.swift apps/iphone/PacketTunnel/*.swift
  ); then
    ok "Swift typecheck passes"
  else
    fail "Swift typecheck failed"
  fi
else
  warn "swiftc not found"
fi

if (
  cd "${REPO_DIR}" &&
    CLANG_MODULE_CACHE_PATH=${CHECK_DIR}/split-vpn-swift-module-cache \
      swiftc -parse-as-library "${CORE_SWIFT_FLAGS[@]}" \
      apps/iphone/Tests/ConfigGenerationSmoke.swift apps/iphone/Shared/*.swift apps/iphone/App/Services/CoreClient.swift \
      -o ${CHECK_DIR}/split-vpn-iphone-config-smoke &&
    ${CHECK_DIR}/split-vpn-iphone-config-smoke >${CHECK_DIR}/split-vpn-iphone-config-smoke.log
); then
  ok "ConfigGenerationSmoke passes"
else
  fail "ConfigGenerationSmoke failed; see ${CHECK_DIR}/split-vpn-iphone-config-smoke.log"
fi

SING_BOX_SRC="${ROOT_DIR}/ThirdParty/sing-box-src"
GENERATED_SING_BOX_CONFIG="${CHECK_DIR}/split-vpn-iphone-generated-sing-box.json"
# The Swift fixture uses neutral /private/tmp paths; relocate only the exported
# check input so concurrent readiness runs never share rule-set files.
relocate_config_rules() {
  python3 - "${GENERATED_SING_BOX_CONFIG}" "${CHECK_DIR}" <<'PYCONFIG'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text())
for rule in config.get("route", {}).get("rule_set", []):
    if "path" in rule:
        rule["path"] = str(pathlib.Path(sys.argv[2]) / pathlib.Path(rule["path"]).name)
path.write_text(json.dumps(config, indent=2) + "\n")
PYCONFIG
}
if [[ -f "${SING_BOX_SRC}/go.mod" && -f "${SING_BOX_SRC}/cmd/sing-box/main.go" ]]; then
  if command -v go >/dev/null 2>&1; then
    if [[ -f "${ROOT_DIR}/Resources/geodata/geosite-cn.srs" &&
      -f "${ROOT_DIR}/Resources/geodata/geoip-cn.srs" &&
      -f "${ROOT_DIR}/Resources/geodata/geosite-geolocation-!cn.srs" ]]; then
      if (
        cp "${ROOT_DIR}/Resources/geodata/geosite-cn.srs" ${CHECK_DIR}/geosite-cn.srs &&
          cp "${ROOT_DIR}/Resources/geodata/geoip-cn.srs" ${CHECK_DIR}/geoip-cn.srs &&
          cp "${ROOT_DIR}/Resources/geodata/geosite-geolocation-!cn.srs" ${CHECK_DIR}/geosite-geolocation-!cn.srs &&
          SPLITVPN_SMOKE_WRITE_CONFIG="${GENERATED_SING_BOX_CONFIG}" ${CHECK_DIR}/split-vpn-iphone-config-smoke >${CHECK_DIR}/split-vpn-iphone-config-smoke-export.log &&
          relocate_config_rules &&
          cd "${SING_BOX_SRC}" &&
          go run -tags with_quic,with_utls,with_gvisor,with_wireguard,with_dhcp,with_clash_api ./cmd/sing-box check -c "${GENERATED_SING_BOX_CONFIG}" >${CHECK_DIR}/split-vpn-iphone-sing-box-check.log 2>&1
      ); then
        ok "Generated sing-box config passes local sing-box check"
      else
        fail "Generated sing-box config failed local sing-box check; see ${CHECK_DIR}/split-vpn-iphone-sing-box-check.log"
      fi
    else
      warn "Bundled rule-set files missing; skip generated sing-box config check"
    fi
  else
    warn "Go not found; skip generated sing-box config check"
  fi
else
  warn "Local sing-box source not staged; skip generated sing-box config check"
fi

printf '\n'
if [[ "${STATUS}" -eq 0 ]]; then
  ok "Readiness check completed without hard failures"
else
  fail "Readiness check found hard failures"
fi

exit "${STATUS}"
