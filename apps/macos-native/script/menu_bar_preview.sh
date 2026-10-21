#!/bin/sh
# Development-only bundle: fake RPC/helper/keychain and separate preferences.
set -eu
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_only=false
if [ "${1:-}" = "--build-only" ]; then build_only=true; shift; fi
swift build --disable-sandbox --package-path "$package_dir" --cache-path "$package_dir/.local/swift-cache" \
    -Xswiftc -module-cache-path -Xswiftc "$package_dir/.local/module-cache"
bin_dir=$(swift build --disable-sandbox --package-path "$package_dir" --cache-path "$package_dir/.local/swift-cache" --show-bin-path)
bundle="$package_dir/.local/MenuBarPreview/轻舟菜单栏预览.app"
mkdir -p "$bundle/Contents/MacOS"
cp "$bin_dir/SplitVPNNative" "$bundle/Contents/MacOS/QingzhouMenuBarPreview"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.split-vpn.menu-bar-preview</string>
<key>CFBundleExecutable</key><string>QingzhouMenuBarPreview</string>
<key>CFBundleName</key><string>轻舟菜单栏预览</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>QZMenuBarPreview</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$bundle"
printf '%s\n' "$bundle"
if [ "$build_only" = false ]; then open -n "$bundle" --args --menu-bar-preview "$@"; fi
