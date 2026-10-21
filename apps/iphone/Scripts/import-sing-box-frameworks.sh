#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  cat >&2 <<USAGE
Usage:
  apps/iphone/Scripts/import-sing-box-frameworks.sh /path/to/framework/output

The source directory must contain Libbox.xcframework built from the pinned
source in third_party/dependencies.lock.json. Library.xcframework is not used.
The script stages Libbox.xcframework into:
  apps/iphone/ThirdParty/SingBoxFrameworks
USAGE
  exit 1
fi

SOURCE_DIR="$(cd "$1" && pwd)"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${ROOT_DIR}/ThirdParty/SingBoxFrameworks"

mkdir -p "${DEST_DIR}"

found=0
for framework in Libbox.xcframework; do
  if [[ -d "${SOURCE_DIR}/${framework}" ]]; then
    rm -rf "${DEST_DIR:?}/${framework}"
    cp -R "${SOURCE_DIR}/${framework}" "${DEST_DIR}/${framework}"
    echo "Staged ${framework}"
    found=1
  fi
done

if [[ "${found}" -eq 0 ]]; then
  echo "No supported xcframeworks found in ${SOURCE_DIR}" >&2
  exit 1
fi

cat <<MSG

Frameworks staged in:
  ${DEST_DIR}

Next steps:
  1. Run apps/iphone/Scripts/check-iphone-readiness.sh.
  2. If Libbox.xcframework was replaced, verify SplitVpnPacketTunnel still builds.
  3. For phone testing, copy Config/Signing.local.example.xcconfig to Signing.local.xcconfig and run check-phone-signing.sh.
MSG
