# 轻舟 · iPhone

SwiftUI 主 App + Network Extension Packet Tunnel。主 App 通过共享 Rust 核心生成 sing-box 配置，Packet Tunnel 使用本地 Libbox 框架转发设备流量。构建和配置检查与真机联网分别验收。

版本号以 Xcode 工程的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 为准。

本文件说明 iPhone 框架准备、签名、数据面与设备验收。

## 结构与核心调用

| 路径 | 内容 |
|---|---|
| `App/` | SwiftUI 页面、VPN 管理、HTTP 下载与 Rust `CoreClient` |
| `PacketTunnel/` | `NEPacketTunnelProvider`、`TunnelDataPlane` 与 `LibboxPacketTunnelCore` |
| `Shared/` | 模型、App Group 存储、地址、日志与脱敏 |
| `Resources/` | 默认规则与 sing-box 规则集 |
| `Config/` | 签名配置和 Git 忽略的本机覆盖 |
| `ThirdParty/` | 本地源码与框架暂存，见下文 |
| `Tests/ConfigGenerationSmoke.swift` | 配置生成与诊断 smoke test |

Xcode scheme 为 `SplitVpnIphone`；扩展 target 为 `SplitVpnPacketTunnel`。底部页面为连接、订阅、节点、规则和更多。

订阅下载由 `URLSession` 完成，Rust 使用 `subscription:plan` / `subscription:accept` 解析与存储。核心数据在 `<App Group>/core/`，界面和隧道读取 `AppGroupStore` 镜像与 `generated/sing-box.json`。Rust 框架只链接主 App，扩展接收生成的配置。

## 从干净源码准备框架

需要 macOS、完整 Xcode（不能仅安装 Command Line Tools）、Rust stable / Cargo、Go 1.26.4、Git 和 Python 3。iOS 最低版本为 17.0。首次构建会从公开 GitHub 和 Go module proxy 下载依赖；不需要本项目维护者的缓存、Apple 账号或预制框架。

以下命令均在仓库根目录运行：

```sh
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path
xcrun --sdk iphonesimulator --show-sdk-path
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
apps/iphone/Scripts/build-core-xcframework.sh
apps/iphone/Scripts/build-sing-box-libbox.sh
```

若 `xcrun` 找不到 SDK，在 Xcode 的 Settings → Locations 中选择完整 Xcode；首次启动时完成 Xcode 的许可证和组件安装。没有 iOS Simulator SDK 时先通过 Xcode Settings → Components 安装相应平台。

| 输出路径 | 来源和目标架构 |
|---|---|
| `ThirdParty/CoreFrameworks/SplitVpnCore.xcframework` | 本仓库 `packages/vpn-core`；iOS arm64、Simulator arm64/x86_64 |
| `ThirdParty/SingBoxFrameworks/Libbox.xcframework` | `SagerNet/sing-box` 固定提交；iOS arm64、Simulator arm64/x86_64 |
| `ThirdParty/sing-box-src/` | 上述公开源码和对应 `go.mod` / `go.sum` |
| 仓库根 `.local/ios-go/` | 本项目独立安装的 gomobile / gobind 和 Go module 缓存 |
| 仓库根 `.local/ios-go-cache/`、`.local/ios-clang-cache/` | Go 与 Clang 编译缓存 |

sing-box 的提交与工具版本从 [`third_party/dependencies.lock.json`](../../third_party/dependencies.lock.json) 读取，当前提交为 `320146a106f9baaa57f5e0153675a613940ef91c`，gomobile / gobind 为 `v0.1.13`。脚本检查源码是否有修改，不会强制清理开发者的修改；切换依赖版本前先保存它们。Go 依赖由上游 `go.mod` 和 `go.sum` 校验。脚本使用上游 `build_libbox`，仅选择 iOS 与 Simulator，未修改上游业务源码。

这些源码副本、框架和缓存均被 Git 忽略。Xcode 已引用两个框架，生成后无需手动拖入工程；本项目实现自己的 `LibboxPacketTunnelCore`，不依赖 `sing-box-for-apple`、`Library.xcframework` 或其应用源码。兼容入口 `fetch-sing-box-for-apple.sh` 只显示说明。

如果从其他机器导入框架，可运行 `Scripts/import-sing-box-frameworks.sh /path/to/framework/output`，但须自行核对固定源码、架构和许可证；推荐直接运行上面的源码构建命令。

## 无账号构建检查

先按根目录 [开发指南](../../docs/DEVELOPMENT.md) 准备规则数据；iOS 使用 `Resources/geodata/` 中的三个 `.srs` 文件。然后执行：

```sh
xcodebuild -project apps/iphone/SplitVpn.xcodeproj \
  -scheme SplitVpnIphone -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .local/ios-simulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apps/iphone/SplitVpn.xcodeproj \
  -scheme SplitVpnIphone -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .local/ios-device CODE_SIGNING_ALLOWED=NO build
apps/iphone/Scripts/check-iphone-readiness.sh
```

这两项 `xcodebuild` 都不需要个人开发团队，不安装 App、不启动 VPN。readiness 会编译通用 iOS 目标、运行恢复与配置测试，并用固定源码执行 `sing-box check`，不建立真实隧道。每次运行会打印独立临时目录，日志保留在其中。若要验证完整配置，不应忽略缺失规则数据的警告。

Xcode 构建会运行仓库的 `scripts/stage-notices.py`，把许可证文本和依赖清单复制到 App 内的 `third-party-licenses/`；该阶段失败时应先解决缺失许可材料再重新构建。

无签名编译只证明工程和依赖能构建。真机安装、Packet Tunnel 权限和实际联网需要自己的 Apple 开发者签名与单独验收。

## 签名与构建顺序

完成上述框架和无签名构建检查后，若需真机安装，再打开：

```sh
open apps/iphone/SplitVpn.xcodeproj
```

签名值来自 `Config/Signing.xcconfig`，本机覆盖文件为被忽略的 `Config/Signing.local.xcconfig`。准备个人真机标识：

```sh
apps/iphone/Scripts/check-phone-signing.sh --init YOURTEAMID com.yourname.splitvpn
```

脚本会派生扩展 ID `com.yourname.splitvpn.PacketTunnel` 和 App Group `group.com.yourname.splitvpn`。可追加第三个参数指定自定义 App Group；已有本机文件直接编辑。主 App 与扩展启用 App Groups 和 Packet Tunnel 能力，使用实际开发团队。

```sh
apps/iphone/Scripts/check-phone-signing.sh
apps/iphone/Scripts/check-phone-signing.sh --build
apps/iphone/Scripts/check-iphone-readiness.sh
apps/iphone/Scripts/package-ios.sh /path/to/output
```

`--build` 尝试 signed generic iOS build。readiness 还检查工程、框架和图标，编译 host Rust 核心、运行 Swift 配置 smoke test，并在本地 sing-box 源码可用时执行生成配置的 `sing-box check`。这些结果不能代替设备安装和实际转发。

`package-ios.sh` 重建 Rust 框架、归档 Release 并用已有开发签名导出 IPA，不上传 Apple 或安装到设备。使用开发描述文件时，IPA 只能安装到其中登记的设备；主 App 和扩展均需匹配的 Packet Tunnel / App Group 能力。输出保留 `.xcarchive`，已有同名包不会覆盖。

## Packet Tunnel 数据面

接入边界为 `PacketTunnelCore.start(options:)` / `stop()`。`TunnelDataPlane` 将配置写入 App Group 并传入配置路径、`NEPacketTunnelFlow`、运行目录和选定代理。`Libbox` 可导入时使用 `LibboxPacketTunnelCore`，否则使用明确报错的 `MissingPacketTunnelCore`。

启动选项包含 `configContent`、`systemProxyEnabled`、`includeAllNetworks`、`excludeDefaultRoute`、`autoRouteUseSubRangesByDefault` 和 `excludeAPNsRoute`。Libbox 桥依次设置运行目录、调用 `LibboxSetup`、创建 `LibboxCommandServer`、`checkConfig`、启动服务和诊断客户端。`openTun` 返回 Network Extension 已创建的 utun fd；接口枚举使用 `getifaddrs`，默认接口变化由 `NWPathMonitor` 上报。

`NEPacketTunnelNetworkSettings` 和 sing-box TUN 地址共同来自 `TunnelAddressing`，MTU 共同读取 `packetTunnelMTU`。界面可比较 1280 / 1400 / 1500；节点 DNS 默认使用 `cloudflare-direct`，规则页可切换 `ali` 对照。

配置转换覆盖常见 HTTP、SS、Hysteria2、Trojan、TUIC、VLESS 和 VMess。手选节点不可转换或消失时阻止启动，不静默换节点；具体 Libbox 版本与真实节点的握手仍需验证。

## 诊断与功耗

连接页检查签名、App Group、订阅节点和可转换出口。更多页可导出脱敏 `.txt` 诊断，包含预检、配置摘要、近期隧道日志、流量与网络探测；已连接时通过 provider message 读取扩展内存状态。

标准诊断周期为 30 秒，不订阅连接事件；低电量模式至少 60 秒，睡眠时暂停诊断订阅。深度诊断为 5 秒、默认 10 分钟后恢复标准模式。状态采样同时提供本机健康心跳，普通模式的失联判定仍为 90 秒，不改变节点协议保活。状态变化立即落盘，流量检查点减少写入，日志按批量或时间刷盘；停止、warn/error 和导出时及时刷新。实际功耗与恢复行为需要在目标设备上分别验收。

低电量模式把状态采样延长到 60 秒并关闭连接事件，健康检查由 30 秒放宽到 120 秒。系统休眠时取消健康检查和重试，停止诊断订阅；保留系统隧道，唤醒后重新订阅并合并恢复。没有额外的周期性公网探测或常驻唤醒锁。

## 异常恢复与网络变化

- 原生内核操作和恢复控制分开排队。连续 90 秒收不到状态心跳（低电量 240 秒），或多个目标出现直连/代理连接错误时，尝试在当前隧道中重启数据面；零流量不算故障。
- 仅代理线路失败也参与检测；单个目标失败不会直接触发全隧道重启。重试按 2 / 5 / 10 / 20 / 30 / 60 秒退避，低电量连续失败时最长 120 秒，稳定运行 2 分钟后重置计数。恢复沿用原来选定的节点和规则，不自动换到其他节点。
- 上游路径监听排除自己的虚拟接口，比较物理接口、IPv4/IPv6 地址与网络能力；合并短时网络变化，无网时显示等待并暂停重试。费用或低数据模式变化本身不重建隧道。
- 切到新的可用 Wi-Fi 后等待 500 毫秒就安排恢复，不沿用蜂窝网络的长时间失败退避。相同失败路径的重复通知保留退避；重启旧网络时收到新的路径，会在当前操作结束后恢复最新路径，旧操作的失败不会推迟这次切换。Libbox 默认接口监听也排除虚拟接口，断网时报告无上游。500 毫秒是调度等待，实际联网恢复时间仍需真机测量。
- 原生重启超过 20 秒仍无响应时结束当前隧道，交给系统按需连接。停止回调设有 3 秒上限，避免被卡住的原生调用拖住。系统重新拉起的时机由 iOS 决定。
- 手动断开先保存跨进程的停止意图，再关闭按需连接；迟到的回调不能重新拉起。再次连接请在轻舟里点击连接。

`Tests/TunnelRecoverySmoke.swift` 使用可控时钟测试离线、连续切网、睡眠、退避、手动停止及迟到回调；配置 smoke test 覆盖仅代理线路异常与停止意图持久化。它们不启动真实 VPN。

## 真机验收

首次使用实际开发者签名安装后，需要核对：

1. 主 App 和扩展具备正确的 App Group / Packet Tunnel 能力，框架正常加载。
2. 启动进入 Libbox 桥，utun fd、默认接口和路由安装正确。
3. Safari 经手选出口访问，国内和局域网直连，VPN 域名走代理。
4. 导出诊断能说明实际出口、规则、接口变化和流量，且不泄露订阅信息。
5. 断开恢复正常网络；分别比较 MTU、协议兼容性和空闲功耗。
6. 锁屏 30 分钟后解锁、Wi-Fi 与蜂窝互切、飞行模式关闭后恢复，检查状态与实际访问一起恢复。
7. 测试节点短暂不可达后恢复，检查自动重试；重试中手动断开，再切网也不能自行连接。
8. 对比同一设备、同一节点、相近使用强度的 2 小时普通/低电量模式耗电，记录设备型号和 iOS 版本。

当前文档保留未完成的设备验收边界，不把历史构建成功作为真机通过。上游参考为 [sing-box](https://github.com/SagerNet/sing-box)、[sing-box-for-apple](https://github.com/SagerNet/sing-box-for-apple) 和 [Apple Packet Tunnel](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider)。许可证与对应源码事项见 [第三方依赖说明](../../docs/THIRD_PARTY.md)。

移动 aTrust 使用 App 与扩展共用的组合 Go 运行库。先运行 `python3 packages/company-vpn/prepare_mobile.py` 和 `python3 packages/company-vpn/build_mobile.py ios --skip-prepare`；不要以原单独 Libbox 替代组合库。具体架构、认证范围与测试见 [移动接入说明](../../packages/company-vpn/mobile/README.md)。
