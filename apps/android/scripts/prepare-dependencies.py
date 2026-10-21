#!/usr/bin/env python3
"""Build Android's two executable data-plane inputs from checksum-pinned sources.

Only downloads/builds files. Never installs an APK or opens a TUN/VPN interface.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[3]
ANDROID = ROOT / "apps/android"
CACHE = ROOT / ".local/android-dependencies"
NDK_VERSION = "27.0.12077973"


def run(command, *, cwd=None, env=None, capture=False):
    print("+ " + " ".join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), cwd=cwd, env=env, check=True,
                          text=True, stdout=subprocess.PIPE if capture else None).stdout


def elf_report(path):
    blob = path.read_bytes()
    if blob[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", blob, 18)[0] != 183:
        raise RuntimeError(f"{path.name}: expected little-endian AArch64 ELF")
    entry = struct.unpack_from("<Q", blob, 24)[0]
    offset = struct.unpack_from("<Q", blob, 32)[0]
    size, count = struct.unpack_from("<HH", blob, 54)
    alignments = [struct.unpack_from("<Q", blob, offset + i * size + 48)[0]
                  for i in range(count) if struct.unpack_from("<I", blob, offset + i * size)[0] == 1]
    if not entry or not alignments or min(alignments) < 16384:
        raise RuntimeError(f"{path.name}: missing executable entry point or 16 KB LOAD alignment")
    if str(Path.home()).encode() in blob:
        raise RuntimeError(f"{path.name}: contains local home path")
    return {"sha256": hashlib.sha256(blob).hexdigest(), "entryPoint": entry,
            "loadAlignments": alignments, "bytes": len(blob)}


def unpack(name, dependency):
    commit = dependency["commit"]
    if len(commit) != 40 or any(c not in "0123456789abcdef" for c in commit):
        raise RuntimeError(f"{name}: lock must contain a full commit hash")
    repository = dependency["repository"].removesuffix(".git")
    if not repository.startswith("https://github.com/"):
        raise RuntimeError("Only pinned public GitHub source repositories are supported")
    repository_path = repository.removeprefix("https://github.com/")
    archive = CACHE / f"{name}-{commit}.tar.gz"
    expected = dependency["archive_sha256"]
    if not archive.exists():
        temporary = archive.with_suffix(".download")
        run(["curl", "--fail", "--location", "--retry", "3", "--proto", "=https",
             f"https://codeload.github.com/{repository_path}/tar.gz/{commit}", "--output", temporary])
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        raise RuntimeError(f"{archive.name}: checksum mismatch; delete this cache file and retry")
    destination = CACHE / f"source-{name}-{commit}"
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir()
    with tarfile.open(archive) as source:
        members = source.getmembers()
        # GitHub tarballs have one enclosing directory; reject links and traversal.
        for member in members:
            parts = Path(member.name).parts
            if not parts or member.name.startswith("/") or ".." in parts or not (member.isdir() or member.isfile()):
                raise RuntimeError("Unexpected path or link in source archive")
            relative = Path(*parts[1:])
            target = destination / relative
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif len(parts) > 1:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as reader, target.open("wb") as writer:
                    shutil.copyfileobj(reader, writer)
                target.chmod(member.mode & 0o777)
    return destination


def licenses(name, source, env):
    """Keep the complete resolved Go module list and license/notice files."""
    run(["go", "mod", "download", "all"], cwd=source, env=env)
    raw = run(["go", "list", "-mod=readonly", "-m", "-json", "all"], cwd=source, env=env, capture=True)
    decoder, rest, modules = json.JSONDecoder(), raw, []
    while rest.strip():
        value, end = decoder.raw_decode(rest.lstrip())
        modules.append(value)
        rest = rest.lstrip()[end:]
    destination = ANDROID / "app/src/main/assets/third-party-licenses" / name
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    manifest = []
    for module in modules:
        resolved = module.get("Replace", module)
        directory = Path(resolved.get("Dir", source if module.get("Main") else ""))
        notices = []
        if directory.is_dir():
            for candidate in sorted(directory.rglob("*")):
                if candidate.is_file() and candidate.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT")):
                    filename = resolved["Path"].replace("/", "_") + "--" + str(candidate.relative_to(directory)).replace("/", "_")
                    shutil.copyfile(candidate, destination / filename)
                    notices.append(filename)
        manifest.append({"module": module["Path"], "version": module.get("Version", "source commit in dependencies.lock.json"),
                         "resolvedModule": resolved["Path"], "resolvedVersion": resolved.get("Version"), "notices": notices})
    (destination / "modules.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check existing native executables without downloading/building")
    args = parser.parse_args()
    output = ANDROID / "app/src/main/jniLibs/arm64-v8a"
    if args.check:
        receipt = CACHE / "build-report.json"
        if not receipt.is_file():
            raise RuntimeError("Missing native build receipt; run python3 apps/android/scripts/prepare-dependencies.py first")
        recorded = json.loads(receipt.read_text())
        lock = json.loads((ROOT / "third_party/dependencies.lock.json").read_text())["dependencies"]
        report = {}
        for name, key, filename in (("mihomo", "mihomo_android", "libmihomo.so"), ("tun2socks", "tun2socks", "libtun2socks.so")):
            actual = elf_report(output / filename)
            if recorded[name]["commit"] != lock[key]["commit"] or recorded[name]["goVersion"] != lock[key]["go_version"] or recorded[name]["sha256"] != actual["sha256"]:
                raise RuntimeError(f"{filename}: differs from pinned build receipt; rerun prepare-dependencies.py")
            if not (ANDROID / "app/src/main/assets/third-party-licenses" / name / "modules.json").is_file():
                raise RuntimeError(f"{name}: missing module/license manifest; rerun prepare-dependencies.py")
            report[filename] = actual
        print(json.dumps(report, indent=2))
        return
    for tool in ("go", "curl"):
        if not shutil.which(tool):
            raise RuntimeError(f"Install {tool} first")
    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or Path.home() / "Library/Android/sdk")
    ndk = Path(os.environ.get("ANDROID_NDK_HOME") or sdk / "ndk" / NDK_VERSION)
    host = {"Darwin": "darwin-x86_64", "Linux": "linux-x86_64"}.get(platform.system())
    if host is None:
        raise RuntimeError("Use macOS or Linux to cross-build Android dependencies")
    compiler = ndk / "toolchains/llvm/prebuilt" / host / "bin/aarch64-linux-android26-clang"
    if not compiler.is_file():
        raise RuntimeError(f"Install Android NDK {NDK_VERSION} or set ANDROID_NDK_HOME")
    CACHE.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    lock = json.loads((ROOT / "third_party/dependencies.lock.json").read_text())["dependencies"]
    report = {}
    for name, key, filename in (("mihomo", "mihomo_android", "libmihomo.so"), ("tun2socks", "tun2socks", "libtun2socks.so")):
        dependency = lock[key]
        source = unpack(name, dependency)
        env = os.environ.copy()
        env.update({"GOTOOLCHAIN": "go" + dependency["go_version"], "GOPATH": str(CACHE / "go"),
                    "GOMODCACHE": str(CACHE / "go/pkg/mod"), "GOCACHE": str(CACHE / "go-build"), "GOWORK": "off",
                    "GOOS": "android" if name == "mihomo" else "linux", "GOARCH": "arm64",
                    "CGO_ENABLED": "1" if name == "mihomo" else "0", "CC": str(compiler),
                    "CGO_CFLAGS": f"-ffile-prefix-map={Path.home()}=/user -fdebug-compilation-dir=/build",
                    "CGO_LDFLAGS": "-Wl,-z,max-page-size=16384"})
        # Do not inherit workstation-specific compiler options or Go build tags.
        env.pop("GOFLAGS", None)
        env.pop("GOROOT", None)
        licenses(name, source, env)
        temporary = CACHE / filename
        command = ["go", "build", "-mod=readonly", "-trimpath", "-buildvcs=false", "-o", temporary]
        if name == "mihomo":
            command += ["-tags", "with_gvisor", "-buildmode=pie", "-ldflags",
                        "-s -w -linkmode external -extldflags=-Wl,-z,max-page-size=16384 "
                        f"-X github.com/metacubex/mihomo/constant.Version=source-{dependency['commit'][:12]}"]
        else:
            # A static Linux executable can use inherited fd://3 on Android;
            # buildmode=exe preserves the original, libc-free upstream build.
            command += ["-buildmode=exe", "-ldflags", "-s -w -R 16384"]
        command += ["."]
        run(command, cwd=source, env=env)
        report[name] = {"commit": dependency["commit"], "goVersion": dependency["go_version"], **elf_report(temporary)}
        shutil.copyfile(temporary, output / filename)
        (output / filename).chmod(0o755)
        (CACHE / f"{name}-buildinfo.txt").write_text(run(["go", "version", "-m", temporary], env=env, capture=True))
    (CACHE / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
