# 移动端 aTrust

Android 和 iPhone 复用桌面认证协议与 TCP 适配器；资源授权和分流编译仍由 Rust 核心完成。移动端不启动第二个 VPN。

## 已接入

- HTTPS 入口、认证方式探测和用户明确确认的证书 SHA-256；指纹绑定每个会话，不通过可变进程环境传递。
- 密码认证、图形文字／点选验证码、动态口令、外部统一认证回调、到期改密和改名后的继续认证。网关未提供的认证方式不凭空增加。
- 授权资源获取／刷新、按授权地址和 TCP 端口连接；取消、断开、物理网络恢复、会话失效和业务地址单独验证。
- 系统安全存储记住密码。改密提交前持久化“不确定”状态；只有绑定当前 challenge 的明确成功，或重新认证成功后才清除。不确定时不会自动读取旧密码。
- 接入未就绪、失效、取消时，启用的资源保护继续阻断；用户明确断开后解除接管。授权范围之外的端口及 UDP 不进入接入后端。

Android 的 Go 认证／接入库在应用进程运行，应用 UID 必须排除在自身 VPN 之外；Mihomo 独立进程处理 TUN 转发。排除失败会停止启动。iPhone 的 App 负责交互认证，内存会话分块传给已有 Network Extension；组合的 Libbox + companymobile 运行库负责数据面和接入。Go 套接字绑定物理接口，避免回到自身 utun。两进程的核心配置事务用文件锁协调，界面只有确认实际加载版本后才显示接入成功。

会话、SID、cookie、改密临时值和外部回调只留内存；IPC 有顺序、总量和过期限制，不写共享容器。资源和非秘密设置保留未知字段，兼容既有数据。进程被系统终止后必须重新认证；不会用磁盘会话伪装恢复。

## 构建

先具备 Go、Rust 对应目标、Android SDK/NDK、Xcode，并按 iPhone 原有说明准备固定版本 sing-box 源码。构建器复制现有源码到自己持有的 `.local/mobile`，不 fetch/reset 用户的 `ThirdParty/sing-box-src`。

```bash
python3 packages/company-vpn/prepare_mobile.py
python3 packages/company-vpn/build_mobile.py host --skip-prepare
python3 packages/company-vpn/build_mobile.py android --skip-prepare
python3 packages/company-vpn/build_mobile.py ios --skip-prepare --reuse-stage
sh apps/android/scripts/build-core.sh
sh apps/iphone/Scripts/build-core-xcframework.sh
sh apps/iphone/Scripts/check-iphone-readiness.sh
```

输出为被忽略的 `packages/company-vpn/.local/mobile/CompanyCore.aar` 和 `Libbox.xcframework`，各自的源文件散列／依赖锁清单也写入此目录。iOS 工程的 App 和扩展必须使用同一个组合运行库，避免两个 Go 运行时。Android 目前随 Mihomo 只提供 arm64。SDK 构建使用锁定的 gomobile v0.1.12；局部工具补丁只保留构建所需 GOFLAGS，不修改全局工具。

## 验证

`prepare_mobile.py` 包含证书、桌面认证／改密、移动控制器和完整 auth 测试。`mobile/companymobile` 的测试还覆盖本地 TLS 登录到资源导出、取消和会话清除、过期／超大消息。Rust 的 `tests/mobile_company.rs` 验证规则优先级、端口／协议约束、配置绑定和原生持锁期间的并发读写。

实际引擎回环测试只绑定 `127.0.0.1`，不建立 TUN、不访问真实网关：

```bash
cargo rustc --manifest-path packages/vpn-core/Cargo.toml --locked --lib --crate-type cdylib
# 在隔离 Python 环境安装 PyYAML==6.0.2，提供本机构建的 sing-box 可执行文件。
python3 packages/vpn-core/tests/mobile_company_engines.py \
  --core packages/vpn-core/target/debug/libsplitvpn_core.dylib \
  --mihomo resources/mihomo/darwin-arm64/mihomo --singbox /tmp/qz-company-sing-box
```

测试后仍需真实 iPhone/Android 的账号认证、VPN 权限、业务、Wi-Fi/蜂窝切换和锁屏验收。当前接入能力与桌面适配器一致，限 TCP；UDP/L3 不是本实现的功能。

## 许可证与平台接口

zju-connect 为 AGPL-3.0，固定版本为 `923672dc927e43e04592595a0005ad90a7a3afb5`。sing-box 的许可证随源码保留。候选包附带许可证、源码说明和匹配源码压缩包；构建产物不提交到 Git。

系统接入依据：[Apple provider IPC](https://developer.apple.com/documentation/networkextension/netunnelprovidersession/sendprovidermessage(_:responsehandler:))、[Android VpnService.Builder](https://developer.android.com/reference/android/net/VpnService.Builder)。IPC 分块大小是本实现的保守限制，不宣称为 Apple 的文档上限。
