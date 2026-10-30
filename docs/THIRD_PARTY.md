# 第三方依赖：从干净源码到完整构建

本文件中的命令均在仓库根目录执行。需要 Git、curl、Python **3.12+**、Rust **1.85+** 与可自动下载指定工具链的 Go **1.21+**。运行时依赖、Geo 数据和框架会从公开上游准备到被忽略的目录，不需要原作者的缓存、二进制或签名。

固定提交、Go 版本、源码归档 SHA-256、Geo 文件 SHA-256、许可证文本哈希和 Gradle 校验值统一保存在 [dependencies.lock.json](../third_party/dependencies.lock.json)。下载失败或校验不匹配会停止；缓存已被修改时也会停止，保留现场。默认准备流程不会启动应用、连接 VPN、修改系统 DNS/路由、安装软件或上传包。

## 构建环境

| 目标 | 额外工具 |
|---|---|
| macOS | macOS 14+、完整 Xcode 与 Command Line Tools；用 `xcode-select -p` 确认选择了 Xcode |
| Windows x64 安装包 | 当前打包入口在 macOS 交叉构建；需要 .NET SDK 10、MinGW-w64 和 Rust GNU Windows target |
| iOS | 完整 Xcode、iOS 17+ SDK、Rust 三个 Apple 移动目标；Go 1.26.4、gomobile/gobind v0.1.12 由脚本选择 |
| Android arm64 | macOS 或 Linux；JDK 17+、Android SDK 35、NDK 27.0.12077973、CMake 3.22.1；Gradle 8.14.3 使用已提交的 Wrapper |

可在 macOS 用 Homebrew 安装 Git、curl、Python、Go、MinGW-w64 和 .NET；Rust 按官方 rustup 安装。Android SDK/NDK/CMake 可由 Android Studio SDK Manager 安装。先自行安装这些工具，准备脚本不自动修改系统 SDK。工具安装入口：[Rust](https://www.rust-lang.org/tools/install)、[Go](https://go.dev/dl/)、[Xcode](https://developer.apple.com/xcode/)、[.NET](https://dotnet.microsoft.com/download)、[Android Studio](https://developer.android.com/studio)。

## macOS Apple Silicon

```sh
rustup target add aarch64-apple-darwin
python3 scripts/prepare-third-party.py --platform macos-arm64
python3 scripts/prepare-third-party.py --platform macos-arm64 --check
bash apps/macos-native/script/build_and_run.sh --build-only
```

输出 `apps/macos-native/dist/轻舟.app`。准备步骤从固定源码构建带 `with_gvisor` 的 Mihomo，下载固定 Geo 文件，运行接入适配的三组测试并生成补丁源码。打包入口检查准备收据，再构建 Rust、Swift 和目标架构的 Go helper；许可证声明随 App 进入 `Contents/Resources/third-party-licenses/`。本地默认 ad-hoc 签名，不使用个人证书、不启动 App。

## macOS Intel

```sh
rustup target add x86_64-apple-darwin
python3 scripts/prepare-third-party.py --platform macos-x64
SPLITVPN_ARCH=x86_64 SPLITVPN_APP_BUNDLE="$PWD/release/mac-x64/轻舟.app" bash apps/macos-native/script/build_and_run.sh --build-only
```

正式分发签名、公证与本地构建是不同步骤。`package_dmg.sh` 要求 Developer ID 签名；ad-hoc App 不能直接走该分发入口。需要时由构建者自行通过 `SPLITVPN_SIGNING_IDENTITY` 指定证书；Apple 公证会上传文件，不包含在以上命令中。

## Windows x64（在 macOS 交叉构建）

```sh
rustup target add x86_64-pc-windows-gnu
python3 scripts/prepare-third-party.py --platform windows-x64
python3 scripts/prepare-third-party.py --platform windows-x64 --check
bash apps/windows/script/build.sh
```

输出 `apps/windows/release/Qingzhou-<版本>-windows-x64.zip`，包含 .NET 运行时、Rust 核心、源码构建的 Mihomo/helper、Geo 数据和第三方声明。目标机器无需安装 .NET。重复构建时通过 `SPLITVPN_WINDOWS_RELEASE_DIR` 指定新目录，脚本不会覆盖旧包。此流程验证交叉构建与包内容；Windows 窗口、权限、网络仍需在 Windows 上验收。

## Android arm64

设置 `ANDROID_HOME` 指向已安装的 SDK，确认 `java -version` 为 JDK 17 或更新版本。NDK、CMake 和 SDK 平台必须已安装。

```sh
rustup target add aarch64-linux-android
python3 scripts/prepare-third-party.py --platform android-arm64
python3 scripts/prepare-third-party.py --platform android-arm64 --check
./apps/android/gradlew -p apps/android :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
python3 apps/android/tests/check_apk.py apps/android/app/build/outputs/apk/debug/app-debug.apk
```

输出 `apps/android/app/build/outputs/apk/debug/app-debug.apk`。准备脚本从固定源码构建 Mihomo 与 tun2socks，生成 Rust JNI 静态库，并构建 aTrust CompanyCore AAR；不会把普通 Linux 可执行文件随意改名充当 Android 内核。tun2socks 使用本项目已验证的无 libc 静态构建，Mihomo 使用 NDK API 26 编译。构建入口核对源码收据、入口点和 16 KB 对齐。Gradle 预构建任务自动收集许可到 APK 的 `assets/third-party-licenses/`。

Gradle Wrapper 的 ZIP 与 JAR 均固定官方 SHA-256。调试构建使用构建者自己的本地调试签名；正式发行 keystore 不进入源码。SDK、JDK、缓存隔离和真机限制见 [Android README](../apps/android/README.md)。

## iOS

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
python3 scripts/prepare-third-party.py --platform ios
python3 scripts/prepare-third-party.py --platform ios --check
apps/iphone/Scripts/check-iphone-readiness.sh
xcodebuild -project apps/iphone/SplitVpn.xcodeproj -scheme SplitVpnIphone -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath .local/ios-simulator CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

准备步骤固定 sing-box、Go 与 gomobile，重建 Rust XCFramework 和 Libbox + companymobile 组合 XCFramework，包含设备 arm64 和模拟器 arm64/x86_64。组合库保存在 `packages/company-vpn/.local/mobile/Libbox.xcframework`，应用和扩展共用一个 Go 运行时。`readiness` 编译无签名设备目标并运行主机配置、恢复及 sing-box 校验。完整 Xcode 构建会把许可清单放入 App。完整命令与本地签名配置见 [iPhone README](../apps/iphone/README.md)。没有开发者团队或设备描述文件也能做无签名构建；安装到真机需构建者自行配置团队、App Group、Packet Tunnel 权限与签名。

## Geo 数据和许可文件

只准备固定 Geo 文件、或离线核对现有文件：

```sh
python3 scripts/prepare-third-party.py --geodata
python3 scripts/prepare-third-party.py --geodata --check
```

桌面/Android 的 `GeoSite.dat`、`country.mmdb`、`geoip.metadb` 以及 iOS 的三份 `.srs` 都有固定提交 URL 与哈希，不跟随 `latest`。程序运行后的自动更新是用户配置行为，不改变本仓库的首次构建输入。

[许可证说明](LICENSES.md) 区分原创代码、AGPL 接入适配、GPL 内核、MIT tun2socks、标准库、间接依赖和 Geo 数据来源。构建产物会带声明，源码压缩包保留已核验的上游许可证原文。发布二进制时还需按该说明提供对应源码与数据来源，不能仅提供本机 `.local/` 路径。
