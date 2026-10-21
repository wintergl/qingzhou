# 开源源码的构建验证

本记录对应第三方依赖准备脚本及许可证整理后的源码。完整命令见 [第三方构建步骤](THIRD_PARTY.md)，许可范围见 [许可证说明](LICENSES.md)。验证没有安装或启动应用，没有连接真实 VPN 或修改 DNS/路由，也没有推送源码或上传 Apple 公证。

| 项目 | 实际结果 |
|---|---|
| 固定源码与 Geo 准备 | macOS arm64、Windows x64、Android arm64、iOS 四个统一入口均运行通过；随后 `--check` 通过 |
| macOS arm64 | Rust / Swift / Go / Mihomo 完整 App 构建成功，ad-hoc 签名深度校验通过，包内配置为空对象 |
| Windows x64 | macOS 上交叉构建成功，自包含 ZIP 已生成；含所需内核、Geo 和声明 |
| Android arm64 | 两内核与 Rust JNI 从固定源码构建，28 项 Kotlin 单测及 7 项原生进程测试通过，Lint 0 错误 / 4 警告，完整 APK 构建通过 |
| Android APK | 四个 ELF 的 16 KB 对齐、入口、签名、zipalign、Geo 与敏感路径检查通过；许可资源随包进入 |
| iOS device | Rust / Libbox XCFramework 从锁定输入重建，无签名 generic iOS 构建成功 |
| iOS Simulator | 无签名 arm64 / x86_64 通用模拟器目标构建成功；未运行模拟器 App |
| iOS readiness | host Rust、57 项恢复检查、Swift typecheck、配置与固定 sing-box 校验通过 |
| SwiftPM 回归 | 117 项通过；可选 Windows 图标导出按设计跳过；Swift/Rust IPC 使用本次核心通过 |
| 准备脚本完整性 | 4 项离线测试通过，覆盖缓存篡改保留、归档路径与链接拒绝、缺失 / 修改产物拒绝 |
| 桌面产物声明 | 按二进制实际链接模块收集；macOS 为 Mihomo 108 / helper 12 个 Go 模块，Windows 为 110 / 14 个，均找到许可文本 |
| 源码材料导出 | 应用与直接上游源码材料包实际导出通过，不携带旧 Git 或本机缓存 |

本次工具环境：macOS Apple Silicon、Xcode 27.1 / Swift 6.4、Rust 1.93.0、Go 1.26.4（tun2socks 由锁选择 1.23.1）、.NET SDK 10.0.401、Gradle 8.14.3。首次 iOS 受限沙箱的 Swift 宏与旧 SDK 缓存失败，已在正常构建环境及新的 DerivedData 中重跑通过，未以修改业务源码绕过。

尚未验证 macOS Intel 完整 App、Windows 实机窗口和权限、手机安装与真机联网、系统 VPN 授权、长时间运行与实际耗电。开发签名、公证和对外二进制分发材料按平台单独处理；本记录不把交叉构建或无签名构建等同于运行验收。
