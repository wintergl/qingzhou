#!/usr/bin/env bash
# 把已构建的 轻舟.app 打成签名并公证的 DMG（应用拖入 Applications 的布局）。
# 用法：apps/macos-native/script/package_dmg.sh <轻舟.app> [输出目录]
# 公证凭据只需保存一次：xcrun notarytool store-credentials qingzhou-notary --apple-id <Apple ID> --team-id <Team ID>
# SPLITVPN_NOTARY_PROFILE 指定其他凭据名；SPLITVPN_SKIP_NOTARIZE=1 只签名不公证。
set -euo pipefail
APP="${1:?用法：$0 <轻舟.app> [输出目录]}"
OUT="${2:-$(dirname "$APP")}"
PROFILE="${SPLITVPN_NOTARY_PROFILE:-qingzhou-notary}"
# Distribution resources must contain an empty object, even for older bundles.
python3 - "$APP/Contents/Resources/config.json" <<'PY'
import json, sys

try:
    with open(sys.argv[1], encoding='utf-8') as file:
        config = json.load(file)
except (OSError, ValueError):
    raise SystemExit('私有网络配置缺失或格式无效，请重新构建发布包。')
if not isinstance(config, dict) or config:
    raise SystemExit('应用中包含非空私有网络配置，请重新构建空配置发布包。')
PY
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
case "$(lipo -archs "$APP/Contents/MacOS/SplitVPNNative")" in
  arm64) ARCH=arm64 ;;
  x86_64) ARCH=x64 ;;
  *) echo "不支持的应用架构。" >&2; exit 1 ;;
esac
IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)"
[[ -n "$IDENTITY" ]] || { echo "应用未使用 Developer ID Application 签名，无法公证。" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
# The shipped app must not carry build-machine paths (user name, folders).
if grep -rlF "$HOME" "$APP" >/dev/null 2>&1; then
  echo "应用中包含本机路径 $HOME，请用 build_and_run.sh 重新构建。" >&2; exit 1
fi
DMG="$OUT/轻舟-$VERSION-$ARCH.dmg"
[[ ! -e "$DMG" ]] || { echo "已存在 $DMG，请先移走旧镜像。" >&2; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/轻舟.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname 轻舟 -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" "$DMG"
if [[ "${SPLITVPN_SKIP_NOTARIZE:-0}" != 1 ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  # Stapling fails unless Apple accepted the submission.
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
fi
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" >> SHA256SUMS)
echo "DMG：$DMG"
