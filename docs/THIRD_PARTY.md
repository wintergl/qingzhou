# 第三方构建输入

本仓库提供应用源码、测试、接入适配补丁和图标，不附带预编译内核、Geo 数据、生成框架或安装包。先准备所需平台的输入，再运行对应打包脚本。Rust 单元测试与 macOS SwiftPM 构建不需要这些预编译资源。

| 组件 | 源码与准备入口 | 本地放置位置 |
|---|---|---|
| 桌面 Mihomo | [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)，按目标平台从可核对的源码构建 | `resources/mihomo/darwin-arm64/mihomo`、`darwin-x64/mihomo`、`linux-x64/mihomo`、`win32-x64/mihomo.exe` |
| 桌面 Geo 数据 | [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)，核对所用文件的来源与版本 | `resources/mihomo/geodata/GeoSite.dat`、`country.mmdb`、`geoip.metadb` |
| aTrust 适配器 | `python3 packages/company-vpn/prepare.py` 获取固定上游提交并应用本仓库补丁 | `packages/company-vpn/.local/source/` 与 `.local/bin/` |
| iOS Rust 框架 | `apps/iphone/Scripts/build-core-xcframework.sh` | `apps/iphone/ThirdParty/CoreFrameworks/` |
| iOS Libbox | `apps/iphone/Scripts/build-sing-box-libbox.sh`；上游为 [SagerNet/sing-box](https://github.com/SagerNet/sing-box) | `apps/iphone/ThirdParty/SingBoxFrameworks/` |
| iOS 规则集 | 核对 [SagerNet/sing-geosite](https://github.com/SagerNet/sing-geosite) 与 [SagerNet/sing-geoip](https://github.com/SagerNet/sing-geoip) 的适用版本 | `apps/iphone/Resources/geodata/geosite-cn.srs`、`geosite-geolocation-!cn.srs`、`geoip-cn.srs` |
| Android 内核 | [Mihomo](https://github.com/MetaCubeX/mihomo) 与 [tun2socks](https://github.com/xjasonlyu/tun2socks)，准备兼容 Android arm64 的可执行构建；应用用 `.so` 文件名打包它们 | `apps/android/app/src/main/jniLibs/arm64-v8a/libmihomo.so`、`libtun2socks.so` |
| Android Geo 数据 | 与桌面 Geo 数据分别核对版本 | `apps/android/app/src/main/assets/geodata/` 下的 `GeoSite.dat`、`country.mmdb`、`geoip.metadb` |

这些输入被 Git 忽略，不应将本机已有安装包或缓存整体复制进仓库。iOS 和 Android 的编译、ABI、页对齐及目标设备要求见各平台 README。这里只列出输入接口，不提供已经验证过的第三方二进制集合。

根目录 `LICENSE` 适用于原创代码。`packages/company-vpn/LICENSE` 和 README 保留接入适配部分的上游许可证与固定版本信息。Mihomo、sing-box、tun2socks 及 Geo 数据各自的版权、许可证和声明应随实际选用版本保留。发布组合安装包前，另行整理实际构建版本、修改、完整对应源码、构建步骤与第三方声明；本源码快照没有完成安装包的发布准备。

请勿在仓库中保存真实接入网关、授权资源、订阅地址、账号、密钥、开发证书或设备描述文件。iOS 使用被忽略的 `Signing.local.xcconfig` 配置本机签名；macOS 本地构建默认使用 ad-hoc 签名，分发签名需显式选择身份。
