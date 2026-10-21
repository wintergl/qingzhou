# 开发与工程维护

所有命令默认在仓库根目录执行。功能和架构见 [项目 README](../README.md)，平台行为见 [文档索引](README.md)，协作约束见 [AGENTS.md](../AGENTS.md)。

## 目录分工

业务逻辑放在 `packages/vpn-core`，平台壳负责界面、下载和系统接入。桌面通过 stdio JSON 行 RPC 调用核心；移动端通过 `qz_core_call` / `qz_core_free` 调用静态库。新增请求或返回字段时同步检查四端调用方。

`packages/company-vpn/overlay/` 是正式维护的 aTrust 适配补丁。`prepare.py` 下载固定版本上游、套用补丁并测试；`.local/source/` 是生成的源码副本，修改应回到 `overlay/` 或准备脚本中。

`resources/mihomo/`、各端的 `Resources/`、`assets/`、图标和 Android `jniLibs/` 都被构建或运行代码引用。即使有跨平台重复内容，也属于各自的打包输入。

## 源码快照的构建输入

首次构建先执行 [第三方依赖完整步骤](THIRD_PARTY.md) 中对应平台的准备命令，再使用本页的开发测试命令。锁文件固定运行内核、Geo、工具链与许可证输入；完整构建不依赖其他工作区的缓存、签名文件或生成框架。

## Rust 核心

依赖 Rust 工具链；最低版本由 `packages/vpn-core/Cargo.toml` 的 `rust-version` 定义。

```sh
cargo build --manifest-path packages/vpn-core/Cargo.toml --locked
SPLITVPN_ISOLATED=1 SPLITVPN_DATA_DIR="$(mktemp -d)" cargo test --manifest-path packages/vpn-core/Cargo.toml --locked
cargo clippy --manifest-path packages/vpn-core/Cargo.toml --all-targets --locked -- -D warnings
```

按修改范围执行现有专项检查：

```sh
python3 packages/vpn-core/tests/rpc_integration.py
python3 packages/vpn-core/tests/idle_runtime.py
python3 packages/vpn-core/tests/real_engine.py
SPLITVPN_ISOLATED=1 SPLITVPN_DATA_DIR="$(mktemp -d)" cargo test --manifest-path packages/vpn-core/Cargo.toml --locked --test lan_routing -- --ignored
python3 packages/vpn-core/tests/helper_daemon.py
python3 packages/vpn-core/tests/helper_install.py
SPLITVPN_ISOLATED=1 SPLITVPN_DATA_DIR="$(mktemp -d)" cargo test --manifest-path packages/vpn-core/Cargo.toml --locked --test mobile
```

RPC 检查用临时目录和回环假服务。`real_engine.py` 使用真实 Mihomo 与回环流量，但关闭系统 TUN、DNS、定期探测和 Geo 自动更新。helper 检查替换系统路径和网络命令。测试只停止自己启动的进程，不操作正式 VPN。

`lan_routing` 的真实内核用例单独启用，检查内网 IP 携带不同 HTTP Host 时仍命中直连；两种出口都终止在回环假代理，关闭 TUN / DNS，不访问测试目标地址。

同一组普通用例覆盖公司授权网段与本地物理网段重叠：保护本地直连路由，继续接管远程公司地址。RPC 假服务检查接管重载未确认 TUN 时回滚，并保留原设置、节点和已有连接；公司代理入口仍存在但 TUN 失效时，也不能继续报告已接管。这些用例不创建系统 TUN 或修改真实路由，安装后的办公网与远程接入仍需实测。

`idle_runtime.py` 在临时目录启动未连接的隔离核心，检查空闲时没有重复状态通知，退出可立即唤醒后台线程。可用 `--core <新核心> --baseline <旧核心> --seconds 15` 比较两个产物；统计包含启动与退出 CPU 时间，仅用于定位后台工作量，不代表真实 VPN 的电量消耗。`native:runtime-environment` 只接收临时的睡眠、低电量和网络通知可用标记，不写入用户设置；四端旧调用不需要新增字段。

## aTrust 接入适配器

依赖 Go。桌面首次打包前先准备源码：

```sh
python3 packages/company-vpn/prepare.py
```

脚本校验固定上游提交，执行证书、账号与节点刷新三组 Go 测试，再构建内核。准备目录和依赖缓存位于 `packages/company-vpn/.local/`。协议、安全边界和改密流程见 [适配器 README](../packages/company-vpn/README.md)。

## macOS

依赖 Swift / Xcode SDK、Rust 和 Go。

```sh
swift build --package-path apps/macos-native
swift test --package-path apps/macos-native
python3 apps/macos-native/Tests/package_dmg.py
```

在工具内运行 SwiftPM 若遇到嵌套沙箱或缓存权限限制，可指定独立 `.local/` scratch/cache 路径，并使用 `--disable-sandbox`；这个选项只影响编译过程。

构建本机架构的独立应用，默认输出 `apps/macos-native/dist/轻舟.app`：

```sh
bash apps/macos-native/script/build_and_run.sh --build-only
```

分别构建 Apple Silicon 和 Intel 的本地测试包：

```sh
SPLITVPN_ARCH=arm64 SPLITVPN_APP_BUNDLE="$PWD/release/mac-arm64/轻舟.app" bash apps/macos-native/script/build_and_run.sh --build-only
SPLITVPN_ARCH=x86_64 SPLITVPN_APP_BUNDLE="$PWD/release/mac-x64/轻舟.app" bash apps/macos-native/script/build_and_run.sh --build-only
```

本地构建默认使用 ad-hoc 签名，不自动选择钥匙串中的个人证书。需要分发签名时，通过 `SPLITVPN_SIGNING_IDENTITY` 显式指定；设为 `auto` 才会自动查找本机证书。构建不启动应用，目标包正在运行时拒绝覆盖。DMG 脚本要求 Developer ID Application 签名、空对象 `config.json`，并检查包内本机路径。已有同名 DMG 时停止，先保留或移走旧包再重建。`SPLITVPN_BUILD_CONFIGURATION=debug` 可用于 Swift 调试。

正式发布的 Apple 公证是单独步骤，会上传安装包。明确授权后执行不带 `SPLITVPN_SKIP_NOTARIZE=1` 的打包命令；默认凭据名为 `qingzhou-notary`，也可用 `SPLITVPN_NOTARY_PROFILE` 指定。签名、镜像校验、公证、安装和实机联网分别记录结果。

菜单栏交互有独立假服务预览，`--build-only` 只生成预览包：

```sh
bash apps/macos-native/script/menu_bar_preview.sh --build-only
```

其他预览启动参数和行为见 [macOS README](../apps/macos-native/README.md)。

## Windows

在 macOS 交叉打包需要 .NET SDK 10、`mingw-w64` 和 `x86_64-pc-windows-gnu` Rust target：

```sh
rustup target add x86_64-pc-windows-gnu
bash apps/windows/script/build.sh
```

默认输出 `apps/windows/release/Qingzhou-<版本>-windows-x64.zip`。`DOTNET` 指定 SDK 可执行文件，`SPLITVPN_WINDOWS_RELEASE_DIR` 指定独立输出目录；已有同名目录或 ZIP 时停止，保留原包。脚本会重新准备 Go 补丁，包内包含 .NET 运行时，目标机器无需另装 .NET 或 WebView2。NuGet 与 CLI 缓存默认保存在 `apps/windows/.local/`，可通过同名环境变量覆盖。

账号状态回归使用假内核和临时偏好：

```sh
dotnet run --project apps/windows/tests/CompanyAuthentication/CompanyAuthentication.csproj
dotnet run --project apps/windows/tests/RuntimeBehavior/RuntimeBehavior.csproj
dotnet run --project apps/windows/tests/TrayBehavior/TrayBehavior.csproj
dotnet run -c Release --project apps/windows/tests/ReaderMemory/ReaderMemory.csproj
x86_64-w64-mingw32-gcc -std=c11 -Wall -Werror -c apps/windows/tests/native_layout.c -o /tmp/qingzhou-native-layout.o
```

运行环境回归直接编译生产 `Store.cs`、刷新策略和网卡过滤逻辑，用假系统通知、假核心与可控计时器验证断开后不重连、通知合并、单次流量读取、低电量/休眠/可见性变化和迟到结果。原生布局检查只编译、不运行系统 API。交叉编译不能替代 Windows 窗口、DPAPI、系统权限、网络/电源通知和真实隧道验收。运行方式见 [Windows README](../apps/windows/README.md)。

同一运行环境回归也编译生产 `WindowLifetime.cs`，覆盖最小化/关闭收进托盘、恢复后补读、保留最大化状态、反复收起、显式退出只执行一次和系统注销放行。托盘适配用系统 `NotifyIcon`，主窗口保持同一个 HWND；真正退出仍由 `App.OnExit` 停止核心。真实图标、任务栏按钮、再次启动唤起已有窗口、资源管理器重启和注销需在 Windows 上验证。

`TrayBehavior` 直接编译生产 `TrayService`，用假 WPF / WinForms 边界验证点击与菜单、关闭事件取消、一千次收起只创建一个图标、释放资源和事件订阅，以及托盘创建失败的清理。打包禁用共享编译服务，避免复用其他权限上下文的编译进程。

Windows 托盘的帆与船身直接从 macOS `StatusBarController.icon` 导出，角标使用通用标点路径。资源包含浅色/深色、两路连接组合和四类角标，共 32 个 ICO，每个包含 16–128 像素的 8 个尺寸。打包前校验绘图源码哈希、资源清单与图标帧；修改 macOS 图标后重新导出：

```sh
SPLITVPN_WINDOWS_TRAY_EXPORT_DIR="$PWD/apps/windows/Qingzhou/Assets/Tray" swift test --package-path apps/macos-native --disable-sandbox --filter WindowsTrayIconExportTests
python3 apps/windows/script/check_tray_assets.py
```

状态、连接操作、读取失败后重新确认和迟到结果由运行环境回归覆盖；托盘回归另覆盖独立蓝帆/绿船、角标、主题切换和 1000 次变色后只保留一个当前图标。Windows 实际主题通知、DPI 与图标加载仍需实机验证。

发布后可用 `TrayAssets` 验证实际程序集内嵌的 32 个 ICO 与导出清单逐字节一致；该检查只解析 PE 元数据，不加载 Windows 界面：

```sh
dotnet run --project apps/windows/tests/TrayAssets/TrayAssets.csproj -- apps/windows/Qingzhou/bin/Release/net10.0-windows/win-x64/Qingzhou.dll apps/windows/Qingzhou/Assets/Tray/manifest.json
```

读取内存回归直接编译生产 `CoreClient` / `CompanyHelper`，以假子进程分别发送 12,250 条 16 KB 消息，检查回收后的托管堆、已消费事件对象、错误输出上限和退出后的待响应请求。macOS 只替换 Windows Job API，不启动 WPF 或真实 VPN。加 `-- --retain-events` 会故意保留部分消息，预期测试失败，用于确认内存断言能发现累积。该回归不能证明 WPF、Windows 原生资源或真实隧道长期运行的内存表现。

## iPhone

依赖 Xcode、Rust iOS targets、Go 与本地 Libbox。框架和签名的配置顺序见 [iPhone README](../apps/iphone/README.md)。常用入口：

```sh
apps/iphone/Scripts/build-core-xcframework.sh
apps/iphone/Scripts/build-sing-box-libbox.sh
apps/iphone/Scripts/check-phone-signing.sh
apps/iphone/Scripts/check-iphone-readiness.sh
apps/iphone/Scripts/package-ios.sh /path/to/output
```

核心框架输出到 `ThirdParty/CoreFrameworks/`，Libbox 输出到 `ThirdParty/SingBoxFrameworks/`。readiness 会编译、运行配置与恢复策略 smoke test，并在存在本地 sing-box 源码时校验生成配置。打包脚本使用现有签名归档和导出本地 IPA，开发签名只覆盖描述文件登记的设备。真机能力和联网仍需单独验收。

## Android

依赖 JDK 17 或更新版本、Android SDK 35、NDK `27.0.12077973`、仓库提供的 Gradle 8.14.3 Wrapper，以及 Rust `aarch64-linux-android` target。本次测试使用 Gradle 8.14.3：

```sh
rustup target add aarch64-linux-android
apps/android/scripts/build-core.sh
```

仓库提交了校验官方 SHA 的 Gradle Wrapper。可在 Android Studio 打开 `apps/android` 并同步，也可在仓库根目录执行：

```sh
python3 apps/android/tests/native_process.py
./apps/android/gradlew -p apps/android :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
python3 apps/android/tests/check_apk.py apps/android/app/build/outputs/apk/debug/app-debug.apk
```

APK 位于 `apps/android/app/build/outputs/apk/debug/app-debug.apk`，使用本机调试证书签名。发给已有测试用户前需核对签名证书与旧包一致，Android `versionCode` 必须递增。Rust 静态库先重建再打 APK，避免 Kotlin 新壳搭配旧核心。JNI 桥启用 16 KB ELF 页对齐；打包时还需核对两个预置内核的对齐。

后台恢复设计、限制和设备验收步骤见 [Android README](../apps/android/README.md#测试与验收)。本机测试不得启动真实 VPN、修改系统网络，或把宿主机测试结果当成手机实测。

## 版本、产物与整理

发版时同时更新 Rust `Cargo.toml`、macOS 构建脚本、Windows `Qingzhou.csproj` 和 iOS `MARKETING_VERSION`，同时检查 Android `versionName` / `versionCode`。生成的包保存在被忽略的 `release/` 或各端 `dist/` / `release/`，来源与哈希随包保存。

| 文件类别 | 维护方式 |
|---|---|
| `src/`、`Sources/`、`overlay/`、测试、构建脚本 | 正式源码，保留未提交修改 |
| `resources/`、图标、Android `jniLibs/` | 当前打包输入，保留 |
| `target/`、`.build/`、模块缓存、`bin/` / `obj/` | 无活动构建时可重建清理；下次编译会重新生成 |
| Go / NuGet 依赖缓存、本地 SDK | 保留可复用依赖，避免离线构建失效 |
| `.local/source/`、本地 sing-box 源码与已集成框架 | 保留当前构建及对应源码材料；可移除已核对一致的重复框架副本 |
| `release/` | 保留各平台最新包和一份可用回退；移除已被替代的历史包 |

清理前先检查活动进程和目录，核对备份、当前包与回退文件。若候选目录被构建更新，重新盘点后再清理。用户数据、已安装应用、特权 helper、真实 DNS 和路由位于工程之外，工程整理不涉及它们。
