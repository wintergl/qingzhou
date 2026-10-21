#!/bin/sh
# Cross-build the Windows test package on macOS (no WebView2, no .NET runtime needed on the target):
#   brew install mingw-w64 dotnet && rustup target add x86_64-pc-windows-gnu
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
APP="$ROOT/apps/windows"
TARGET=x86_64-pc-windows-gnu
VERSION="$(sed -n 's/.*<Version>\(.*\)<\/Version>.*/\1/p' "$APP/Qingzhou/Qingzhou.csproj" | head -1)"
NAME="Qingzhou-$VERSION-windows-x64"
RELEASE_DIR="${SPLITVPN_WINDOWS_RELEASE_DIR:-$APP/release}"
OUT="$RELEASE_DIR/$NAME"
DOTNET="${DOTNET:-dotnet}"
if [ -e "$OUT" ] || [ -e "$OUT.zip" ]; then
  echo "输出目录或 ZIP 已存在，保留原包。请用 SPLITVPN_WINDOWS_RELEASE_DIR 指定新目录。" >&2
  exit 1
fi
export DOTNET_CLI_HOME="${DOTNET_CLI_HOME:-$APP/.local/dotnet-home}"
export NUGET_PACKAGES="${NUGET_PACKAGES:-$APP/.local/nuget-packages}"
export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc
# Panic locations and compiler file names must not disclose the build machine.
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$HOME=/user --remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$HOME/.rustup=/rustup --remap-path-prefix=$ROOT=/src"
python3 "$APP/script/check_tray_assets.py"

cargo build --release --locked --target "$TARGET" \
  --manifest-path "$ROOT/packages/vpn-core/Cargo.toml" --target-dir "$ROOT/packages/vpn-core/target"

# Refresh the authentication overlay before cross-building. Reusing stale source
# can silently package an older helper without the password-change protocol.
python3 "$ROOT/packages/company-vpn/prepare.py"
COMPANY="$ROOT/packages/company-vpn/.local"
(cd "$COMPANY/source" && GOOS=windows GOARCH=amd64 GOTOOLCHAIN=local GOCACHE="$COMPANY/go-cache" GOMODCACHE="$COMPANY/go-modules" \
  go build -trimpath -ldflags='-s -w' -o "$COMPANY/bin/company-account-helper-windows-amd64.exe" ./cmd/company-account-helper)

mkdir -p "$OUT/geodata"
# Self-contained single file: the .NET runtime ships inside Qingzhou.exe.
"$DOTNET" publish "$APP/Qingzhou/Qingzhou.csproj" -c Release -o "$OUT" --nologo \
  --disable-build-servers -p:UseSharedCompilation=false -p:PathMap="$ROOT=/src"
cp "$ROOT/packages/vpn-core/target/$TARGET/release/splitvpn-core.exe" "$OUT/"
cp "$ROOT/resources/mihomo/win32-x64/mihomo.exe" "$OUT/"
cp "$ROOT/resources/mihomo/geodata/"* "$OUT/geodata/"
cp "$COMPANY/bin/company-account-helper-windows-amd64.exe" "$OUT/company-account-helper.exe"
cp "$COMPANY/source/LICENSE" "$OUT/LICENSE-ZJU-Connect.txt"
cp "$ROOT/LICENSE" "$OUT/LICENSE-Qingzhou.txt"
# Retain licenses/notices for the exact runtime packs selected by restore.
python3 - "$APP/Qingzhou/obj/project.assets.json" "$NUGET_PACKAGES" "$OUT" <<'PY'
import json, shutil, sys
from pathlib import Path
assets, packages, out = map(Path, sys.argv[1:])
frameworks = json.loads(assets.read_text())["project"]["frameworks"]
notices = {
    "Microsoft.NETCore.App.Runtime.win-x64": [("LICENSE.TXT", "LICENSE-DotNet.txt"), ("THIRD-PARTY-NOTICES.TXT", "THIRD-PARTY-NOTICES-DotNet.txt")],
    "Microsoft.WindowsDesktop.App.Runtime.win-x64": [("LICENSE", "LICENSE-WindowsDesktop.txt")],
}
copied = set()
for framework in frameworks.values():
    for dep in framework.get("downloadDependencies", []):
        if dep["name"] not in notices:
            continue
        version = dep["version"].strip("[]").split(",")[0].strip()
        for source, destination in notices[dep["name"]]:
            shutil.copyfile(packages / dep["name"].lower() / version / source, out / destination)
        copied.add(dep["name"])
if copied != set(notices):
    raise RuntimeError("Missing runtime pack license metadata")
PY
# Company addresses are supplied by each user's local preferences.
printf '{}\n' > "$OUT/company-config.json"
# UTF-8 BOM so Notepad shows the Chinese text correctly.
printf '\357\273\277' > "$OUT/README.txt"
cat "$APP/README.txt" >> "$OUT/README.txt"
(cd "$RELEASE_DIR" && ditto -c -k --norsrc --noextattr --noacl --keepParent "$NAME" "$NAME.zip")
echo "Windows 测试包：$OUT.zip"
