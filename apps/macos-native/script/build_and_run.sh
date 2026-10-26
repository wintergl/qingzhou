#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
APP_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$APP_PROJECT/../.." && pwd)"
APP_BUNDLE="${SPLITVPN_APP_BUNDLE:-$APP_PROJECT/dist/轻舟.app}"
ICON_DIRECTORY="$REPO_ROOT/design/app-icon-qingzhou-ink"
LOCAL_DIR="$APP_PROJECT/.local"
case "$MODE" in run|--build-only|--verify|--debug|--logs|--telemetry) ;; *) echo "用法：$0 [--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
mkdir -p "$LOCAL_DIR"
ARCH="${SPLITVPN_ARCH:-$(uname -m)}"
BUILD_CONFIGURATION="${SPLITVPN_BUILD_CONFIGURATION:-release}"
# Local builds use ad-hoc signing. A named identity or automatic selection must
# be explicitly requested by the person preparing a distribution package.
SIGNING_IDENTITY="${SPLITVPN_SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "auto" ]]; then
  SIGNING_IDENTITY="$(python3 - <<'PY'
import re, subprocess
result = subprocess.run(['/usr/bin/security', 'find-identity', '-p', 'codesigning', '-v'], capture_output=True, text=True, check=True)
identities = re.findall(r'\) ([A-Fa-f0-9]{40}) "([^"]+)"', result.stdout)
for kind in ['Developer ID Application:', 'Apple Development:']:
    matches = [identity for identity, name in identities if name.startswith(kind)]
    if len(matches) == 1:
        print(matches[0]); break
    if len(matches) > 1:
        raise SystemExit('有多个可用签名身份，请通过 SPLITVPN_SIGNING_IDENTITY 明确指定。')
else:
    print('-')
PY
)"
fi
case "$ARCH" in
  arm64|aarch64) RUST_TARGET="aarch64-apple-darwin"; SWIFT_TARGET="arm64-apple-macosx14.0"; MIHOMO_ARCH="darwin-arm64"; GO_ARCH="arm64" ;;
  x86_64|x64) RUST_TARGET="x86_64-apple-darwin"; SWIFT_TARGET="x86_64-apple-macosx14.0"; MIHOMO_ARCH="darwin-x64"; GO_ARCH="amd64" ;;
  *) echo "不支持的 macOS 架构：$ARCH" >&2; exit 2 ;;
esac
# Fail before compilation when a clean checkout has not prepared its inputs.
if [[ "$MIHOMO_ARCH" == darwin-arm64 ]]; then DEPENDENCY_PLATFORM=macos-arm64; else DEPENDENCY_PLATFORM=macos-x64; fi
python3 "$REPO_ROOT/scripts/prepare-third-party.py" --platform "$DEPENDENCY_PLATFORM" --check
# Strip build-machine paths (user name, folders) from panic locations and
# compiler-embedded file names, so the shipped app carries no local details.
REMAP_RUST="--remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$HOME/.rustup=/rustup --remap-path-prefix=$REPO_ROOT=/src"
RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }$REMAP_RUST" cargo build --manifest-path "$REPO_ROOT/packages/vpn-core/Cargo.toml" --target-dir "$REPO_ROOT/packages/vpn-core/target" --locked --release --target "$RUST_TARGET"
CORE_BINARY="$REPO_ROOT/packages/vpn-core/target/$RUST_TARGET/release/splitvpn-core"
COMPANY_BINARY="$REPO_ROOT/packages/company-vpn/.local/bin/company-account-helper-$GO_ARCH"
COMPANY_SOURCE="$REPO_ROOT/packages/company-vpn/.local/source"
COMPANY_GO_VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["dependencies"]["zju_connect"]["go_version"])' "$REPO_ROOT/third_party/dependencies.lock.json")"
if [[ ! -f "$COMPANY_SOURCE/go.mod" ]]; then
  echo "缺少已准备的私有网络适配源码，请先运行 packages/company-vpn/prepare.py。" >&2; exit 1
fi
(cd "$COMPANY_SOURCE" && unset GOROOT && GOOS=darwin GOARCH="$GO_ARCH" GOTOOLCHAIN="go$COMPANY_GO_VERSION" GOWORK=off GOFLAGS= GOCACHE="$REPO_ROOT/packages/company-vpn/.local/go-cache" GOMODCACHE="$REPO_ROOT/packages/company-vpn/.local/go-modules" go build -mod=readonly -trimpath -buildvcs=false -ldflags='-s -w' -o "$COMPANY_BINARY" ./cmd/company-account-helper)
export CLANG_MODULE_CACHE_PATH="$LOCAL_DIR/clang-module-cache"
# The linker would otherwise record every object file's absolute path.
SWIFT_REMAP=(-Xswiftc -file-prefix-map -Xswiftc "$REPO_ROOT=/src" -Xlinker -S)
swift build -c "$BUILD_CONFIGURATION" --package-path "$APP_PROJECT" --scratch-path "$LOCAL_DIR/swift-build-$MIHOMO_ARCH" --triple "$SWIFT_TARGET" "${SWIFT_REMAP[@]}" --disable-sandbox
BUILD_DIR="$(swift build -c "$BUILD_CONFIGURATION" --package-path "$APP_PROJECT" --scratch-path "$LOCAL_DIR/swift-build-$MIHOMO_ARCH" --triple "$SWIFT_TARGET" "${SWIFT_REMAP[@]}" --show-bin-path)"
if [[ -x "$APP_BUNDLE/Contents/MacOS/SplitVPNNative" ]]; then
  python3 - "$APP_BUNDLE" <<'PY'
import subprocess, sys
from pathlib import Path
executable=str(Path(sys.argv[1]).resolve()/'Contents/MacOS/SplitVPNNative')
result=subprocess.run(['/bin/ps','-axo','comm='],text=True,capture_output=True)
if result.returncode or executable in [line.strip() for line in result.stdout.splitlines()]:
    raise SystemExit('无法确认目标包已停止，构建未覆盖应用。请退出这个 SwiftUI 包，或将 SPLITVPN_APP_BUNDLE 指向另一个输出目录。')
PY
fi
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/SplitVPNNative" "$APP_BUNDLE/Contents/MacOS/SplitVPNNative"
cp "$CORE_BINARY" "$APP_BUNDLE/Contents/Resources/splitvpn-core"
# A stopped candidate can be rebuilt in place; remove its former JS runtime.
rm -f "$APP_BUNDLE/Contents/Resources/node" "$APP_BUNDLE/Contents/Resources/backend.mjs"
cp -f "$REPO_ROOT/resources/mihomo/$MIHOMO_ARCH/mihomo" "$APP_BUNDLE/Contents/Resources/mihomo"
cp -f "$COMPANY_BINARY" "$APP_BUNDLE/Contents/Resources/company-account-helper"
mkdir -p "$APP_BUNDLE/Contents/Resources/geodata"
cp -f "$REPO_ROOT/resources/mihomo/geodata/"* "$APP_BUNDLE/Contents/Resources/geodata/"
cp "$REPO_ROOT/packages/company-vpn/.local/source/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE-ZJU-Connect.txt"
python3 "$REPO_ROOT/scripts/stage-notices.py" --platform "$DEPENDENCY_PLATFORM" --output "$APP_BUNDLE/Contents/Resources/third-party-licenses"
cp "$ICON_DIRECTORY/qingzhou.icns" "$APP_BUNDLE/Contents/Resources/icon.icns"
cp "$ICON_DIRECTORY/qingzhou.png" "$APP_BUNDLE/Contents/Resources/qingzhou-icon.png"
python3 - "$REPO_ROOT" "$APP_BUNDLE" <<'PY'
import plistlib, sys
from pathlib import Path
bundle=Path(sys.argv[2])
# Company addresses belong to local preferences, never distribution resources.
(bundle/'Contents/Resources/config.json').write_text('{}')
info={'CFBundleExecutable':'SplitVPNNative','CFBundleIdentifier':'dev.split-vpn.desktop.swiftui.v032',
 'CFBundleName':'轻舟','CFBundleDisplayName':'轻舟','CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':'0.6.9','CFBundleVersion':'2026102503','LSMinimumSystemVersion':'14.0',
 'NSPrincipalClass':'NSApplication','NSHighResolutionCapable':True,'CFBundleIconFile':'icon.icns'}
with (bundle/'Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
# Repository-relative paths only: no build-machine user or folder names.
(bundle/'Contents/Resources/SOURCE.txt').write_text('Rust 业务核心：packages/vpn-core\n轻舟 SwiftUI 源码：apps/macos-native\n私有网络适配源码与固定版本构建：packages/company-vpn/prepare.py\n认证适配：AGPL-3.0，完整源码由 packages/company-vpn/prepare.py 准备于 packages/company-vpn/.local/source\n')
PY
for EXECUTABLE in splitvpn-core mihomo company-account-helper; do chmod 755 "$APP_BUNDLE/Contents/Resources/$EXECUTABLE"; codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_BUNDLE/Contents/Resources/$EXECUTABLE"; done
codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"
echo "SwiftUI 版已构建：$APP_BUNDLE"
case "$MODE" in
  --build-only) ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/SplitVPNNative" ;;
  --logs|--telemetry) /usr/bin/open "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "SplitVPNNative"' ;;
  --verify) /usr/bin/open "$APP_BUNDLE"; sleep 1; pgrep -x SplitVPNNative >/dev/null ;;
  run) /usr/bin/open "$APP_BUNDLE" ;;
esac
