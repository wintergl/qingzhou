#!/usr/bin/env bash
# Local device-test IPA. Reuses existing signing profiles; never uploads or installs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ROOT/../.." && pwd)"
VERSION="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' "$ROOT/SplitVpn.xcodeproj/project.pbxproj" | head -1)"
BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/p' "$ROOT/SplitVpn.xcodeproj/project.pbxproj" | head -1)"
OUT="${1:-$ROOT/dist/ios-$VERSION-build$BUILD}"
NAME="Qingzhou-$VERSION-ios-build$BUILD"
ARCHIVE="$OUT/$NAME.xcarchive"
[[ ! -e "$ARCHIVE" && ! -e "$OUT/$NAME.ipa" ]] || { echo '保留已有包，请指定新的输出目录。' >&2; exit 1; }
mkdir -p "$OUT" "$ROOT/.local"
OUT="$(cd "$OUT" && pwd)"
ARCHIVE="$OUT/$NAME.xcarchive"
if [[ "${SPLITVPN_SKIP_CORE_BUILD:-0}" != 1 ]]; then
  bash "$ROOT/Scripts/build-core-xcframework.sh"
fi
xcodebuild -quiet -project "$ROOT/SplitVpn.xcodeproj" -scheme SplitVpnIphone \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "${SPLITVPN_IPHONE_DERIVED_DATA:-$ROOT/.local/archive-derived}" \
  -archivePath "$ARCHIVE" \
  "OTHER_SWIFT_FLAGS=\$(inherited) -file-prefix-map $REPO=/src" \
  "OTHER_CFLAGS=\$(inherited) -ffile-prefix-map=$REPO=/src" \
  SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO archive

STAGE="$(mktemp -d "$ROOT/.local/export.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
python3 - "$ARCHIVE" "$STAGE" <<'PY'
import plistlib, sys
from pathlib import Path
archive, stage = map(Path, sys.argv[1:])
app = next((archive/'Products/Applications').glob('*.app'))
profiles = {}
teams = set()
for bundle in [app, *app.glob('PlugIns/*.appex')]:
    info = plistlib.loads((bundle/'Info.plist').read_bytes())
    raw = (bundle/'embedded.mobileprovision').read_bytes()
    # Decode the public CMS payload without accessing a private key.
    data = plistlib.loads(raw[raw.index(b'<?xml'):raw.index(b'</plist>')+8])
    profiles[info['CFBundleIdentifier']] = data['UUID']
    teams.update(data['TeamIdentifier'])
if len(teams) != 1:
    raise SystemExit('App and tunnel must use the same signing team')
options = {'method':'debugging', 'destination':'export', 'signingStyle':'automatic',
           'teamID':teams.pop(), 'stripSwiftSymbols':True,
           'manageAppVersionAndBuildNumber':False}
(stage/'ExportOptions.plist').write_bytes(plistlib.dumps(options))
PY
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$STAGE/export" -exportOptionsPlist "$STAGE/ExportOptions.plist"
IPA="$(find "$STAGE/export" -maxdepth 1 -name '*.ipa' -print -quit)"
[[ -n "$IPA" ]] || { echo 'Xcode 未生成 IPA。' >&2; exit 1; }
cp "$IPA" "$OUT/$NAME.ipa"
codesign --verify --deep --strict "$ARCHIVE/Products/Applications/$(/usr/bin/basename "$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name '*.app' -print -quit)")"
(cd "$OUT" && shasum -a 256 "$NAME.ipa" > SHA256SUMS)
echo "iOS 测试包：$OUT/$NAME.ipa"
