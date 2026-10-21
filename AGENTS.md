# AGENTS.md

轻舟（split-vpn）：跨平台网络分流与连接管理工具，Rust 核心 + macOS / Windows / iOS / Android 原生壳。总体说明见 [README.md](README.md)。

## 沟通与文档

- 默认用简体中文回复、写文档和提交信息；代码、命令、路径保持英文。
- 提交信息格式：首行中文概述，空一行后用 `- ` 列出要点（见 `git log`）。

## 仓库结构

- `packages/vpn-core`：Rust 业务核心，所有平台共用。桌面走 `src/main.rs` 的 stdio JSON 行 RPC（通道分发在 `src/runtime.rs`）；移动端走 `src/mobile.rs` 的 `qz_core_call`（头文件 `include/qz_core.h`）。
- `apps/macos-native`：SwiftUI，`Services/CoreService.swift` 调用核心，`Stores/VPNStore.swift` 是主状态。
- `apps/windows/Qingzhou`：WPF，`CoreClient.cs` 调用核心，`Store.cs` 是主状态。
- `apps/iphone`：`App/`（主 App）、`PacketTunnel/`（sing-box 数据面）、`Shared/`（App Group 存储）。
- `apps/android`：Kotlin，`core/CoreClient.kt` 通过 JNI 调用核心，`SplitVpnService.kt` 管理 mihomo + tun2socks。
- `packages/company-vpn`：私有网络认证内核（Go），`prepare.py` 套用 `overlay/` 补丁并构建；源码与产物在被忽略的 `.local/`。
- `resources/mihomo`：桌面各平台 mihomo 内核与 geodata，打包时复制。
- `docs/THIRD_PARTY.md`：未随源码分发的内核、Geo 数据与框架准备说明。

## 常用命令（仓库根目录）

```bash
cargo test --manifest-path packages/vpn-core/Cargo.toml --locked
cargo clippy --manifest-path packages/vpn-core/Cargo.toml --all-targets --locked -- -D warnings
swift build --package-path apps/macos-native
sh apps/macos-native/script/build_and_run.sh --build-only
apps/macos-native/script/package_dmg.sh <轻舟.app>   # 签名 + 公证 DMG
python3 packages/company-vpn/prepare.py              # 接入内核，首次打桌面包前
sh apps/windows/script/build.sh
apps/iphone/Scripts/build-core-xcframework.sh
apps/android/scripts/build-core.sh
```

## 验证方式

- 改 `packages/vpn-core`：必须跑 `cargo test`；改动 RPC 通道时再跑 `python3 packages/vpn-core/tests/rpc_integration.py`；改 `mobile.rs` / `singbox.rs` 时跑 `cargo test --test mobile`。
- 改 macOS：`swift build --package-path apps/macos-native`，再跑 `swift test --package-path apps/macos-native`。
- 改 `packages/company-vpn`：`python3 packages/company-vpn/prepare.py`（内含三组 Go 测试）。
- 改 macOS helper 脚本：`python3 packages/vpn-core/tests/helper_daemon.py` 与 `helper_install.py`。
- 改 iOS：先重建 xcframework，再用 Xcode 编译 `SplitVpnIphone` scheme；`apps/iphone/Scripts/check-iphone-readiness.sh` 做冒烟检查。
- Windows、Android、真机联网和系统权限行为无法在本机自动验证时，明确告诉用户哪些没验证。

## 约束

- 业务逻辑放在 Rust 核心，平台壳只做界面和系统接入；不要在 Swift / Kotlin / C# 里重写订阅解析或配置生成。
- 改核心通道的请求或返回字段时，同步检查四端调用方：macOS `VPNStore.swift`、Windows `Store.cs`、iOS `CoreClient.swift`、Android `CoreClient.kt`。
- 用户数据目录与旧版共用（macOS `~/Library/Application Support/@split-vpn/desktop`、Windows `%APPDATA%\@split-vpn\desktop`），设置格式必须向后兼容，保留未知字段。
- 测试不得启动真实 VPN、修改系统 DNS/路由或替换 `/Applications/轻舟.app`；核心测试用 `SPLITVPN_ISOLATED=1` 加临时 `SPLITVPN_DATA_DIR`。
- 日志和诊断中的订阅 URL、密钥、私有网络凭据必须脱敏；接入密码只进钥匙串。
- 源码和安装包里不得写入个人或私有网络信息（接入网关、内网地址、本机路径）；私有网络地址只存在用户本机偏好里，测试数据用 `10.0.0.8`、`example.test` 等中性值。
- 不提交构建产物：`packages/vpn-core/target/`、`apps/*/dist/`、`release/`、`**/.local/`、`apps/iphone/ThirdParty/*Frameworks/*.xcframework`、Android `cpp/prebuilt/`。
- 发版时版本号要一起改：`packages/vpn-core/Cargo.toml`、`apps/macos-native/script/build_and_run.sh`（`CFBundleShortVersionString` / `CFBundleVersion`）、`apps/windows/Qingzhou/Qingzhou.csproj`（`<Version>`）、iOS 工程的 `MARKETING_VERSION`。
