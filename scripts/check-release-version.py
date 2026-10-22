#!/usr/bin/env python3
"""Check that every platform advertises the same release version."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
import tomllib


ROOT = Path(__file__).resolve().parents[1]
TAG_PATTERN = re.compile(r"v(?P<version>\d+\.\d+\.\d+)")


class VersionError(RuntimeError):
    """The checked release metadata is missing, ambiguous, or inconsistent."""


def _single_match(path: Path, pattern: str, label: str) -> str:
    values = re.findall(pattern, path.read_text(), flags=re.MULTILINE)
    unique = sorted(set(values))
    if len(unique) != 1:
        rendered = ", ".join(unique) if unique else "未找到"
        raise VersionError(f"{label} 版本字段必须唯一，当前为：{rendered}")
    return unique[0]


def collect_versions(root: Path = ROOT) -> dict[str, str]:
    root = Path(root)
    cargo = tomllib.loads((root / "packages/vpn-core/Cargo.toml").read_text())
    return {
        "rust": str(cargo["package"]["version"]),
        "macos": _single_match(
            root / "apps/macos-native/script/build_and_run.sh",
            r"'CFBundleShortVersionString'\s*:\s*'([^']+)'",
            "macOS",
        ),
        "windows": _single_match(
            root / "apps/windows/Qingzhou/Qingzhou.csproj",
            r"<Version>\s*([^<]+?)\s*</Version>",
            "Windows",
        ),
        "ios": _single_match(
            root / "apps/iphone/SplitVpn.xcodeproj/project.pbxproj",
            r"MARKETING_VERSION\s*=\s*([^;\s]+)\s*;",
            "iOS",
        ),
        "android": _single_match(
            root / "apps/android/app/build.gradle.kts",
            r'versionName\s*=\s*"([^"]+)"',
            "Android",
        ),
    }


def check_versions(root: Path = ROOT, tag: str | None = None) -> tuple[str, dict[str, str]]:
    versions = collect_versions(root)
    unique = sorted(set(versions.values()))
    if len(unique) != 1:
        details = ", ".join(f"{platform}={version}" for platform, version in versions.items())
        raise VersionError(f"各平台版本不一致：{details}")

    version = unique[0]
    if tag is not None:
        match = TAG_PATTERN.fullmatch(tag)
        if not match:
            raise VersionError(f"发布标签必须使用 vX.Y.Z 格式：{tag}")
        if match.group("version") != version:
            raise VersionError(f"标签 {tag} 与源码版本 {version} 不一致")
    return version, versions


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="仓库根目录")
    parser.add_argument("--tag", help="可选的 Git 发布标签，例如 v0.6.5")
    parser.add_argument("--json", action="store_true", help="以 JSON 输出检查结果")
    parser.add_argument("--print-version", action="store_true", help="只输出统一版本号")
    args = parser.parse_args(argv)

    try:
        version, versions = check_versions(args.root, args.tag)
    except (KeyError, OSError, tomllib.TOMLDecodeError, VersionError) as error:
        print(f"版本检查失败：{error}", file=sys.stderr)
        return 1

    if args.print_version:
        print(version)
    elif args.json:
        print(json.dumps({"version": version, "tag": args.tag, "platforms": versions}, ensure_ascii=False))
    else:
        suffix = f"，标签 {args.tag}" if args.tag else ""
        print(f"版本一致：{version}{suffix}")
        for platform, platform_version in versions.items():
            print(f"- {platform}: {platform_version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
