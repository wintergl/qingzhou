# 轻舟 · Android

Kotlin 原生界面 + 共享 Rust 核心 + Android `VpnService`。Kotlin 负责界面、HTTP 下载与系统接入，订阅解析和 Mihomo 配置由 Rust 经 JNI `qz_core_call` 生成。当前原生数据面为 arm64，最低 Android API 26。

## 功能与目录

底部入口为连接、订阅、节点、规则和更多。支持 YAML / URI / base64 订阅、节点选择、VPN 域名、连通性、流量、风险和服务日志；节点页支持 `AUTO`、`BALANCE`、`DIRECT` 与具体节点。

| 路径 | 内容 |
|---|---|
| `app/src/main/java/dev/splitvpn/android/` | 界面、前台服务与核心调用 |
| `app/src/main/cpp/` | JNI 和 TUN fd 原生启动器 |
| `app/src/main/cpp/prebuilt/` | Rust 静态库，构建生成，Git 忽略 |
| `app/src/main/jniLibs/arm64-v8a/` | APK 使用的 `libmihomo.so` 与 `libtun2socks.so` |
| `app/src/main/assets/geodata/` | APK 内置 Geo 数据 |

## 从源码完整构建

在 macOS 或 Linux 上准备 Python 3.12+、`curl`、Go 1.21+（Go 自动下载锁定工具链）、Rust/rustup 和 JDK 17 或 21。Windows 可在 WSL 中构建数据面，Android Studio 负责 APK 构建。Android SDK 需安装 `platforms;android-35`、`build-tools;35.0.0`、`ndk;27.0.12077973`、`cmake;3.22.1`，并设置 `ANDROID_HOME`；macOS 默认 SDK 路径为 `$HOME/Library/Android/sdk`。SDK 安装示例：

```bash
sdkmanager "platforms;android-35" "build-tools;35.0.0" "ndk;27.0.12077973" "cmake;3.22.1"
```

以下在仓库根目录执行。首次运行需要访问 GitHub、Go 模块代理、Google Maven 和 Maven Central。Gradle Wrapper 固定为 8.14.3，下载时验证发行包 SHA-256。不要使用宿主机上不兼容的 Gradle 9.x。

```bash
# 根依赖脚本准备公开 Geo 数据，并将许可证文本放入应用资源。
python3 scripts/prepare-third-party.py --geodata
python3 apps/android/scripts/prepare-dependencies.py
rustup target add aarch64-linux-android
bash apps/android/scripts/build-core.sh
python3 apps/android/tests/native_process.py
apps/android/gradlew -p apps/android --no-daemon :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
python3 apps/android/tests/check_apk.py apps/android/app/build/outputs/apk/debug/app-debug.apk
```

APK 位于 `app/build/outputs/apk/debug/app-debug.apk`，使用本机 Android 调试证书。上述命令只构建和检查文件，不安装 APK、不启动 VPN。Android Studio 也可打开此目录，使用仓库内 Wrapper；先完成前三方和 Rust 准备步骤。

两个名为 `.so` 的数据面文件实际是**独立可执行程序**，不是给 `System.loadLibrary` 加载的 JNI 库。准备脚本读取 [固定版本清单](../../third_party/dependencies.lock.json)，下载公开源码、验证归档 SHA-256、使用上游 `go.mod` / `go.sum` 构建，再放入 `jniLibs/arm64-v8a/`：

| 组件 | 构建方式与接入 |
|---|---|
| Mihomo | Go 1.26.4，`GOOS=android GOARCH=arm64 CGO_ENABLED=1`，NDK API 26 Clang，`with_gvisor`、PIE、外部链接；`ProcessBuilder` 启动 |
| tun2socks | Go 1.23.1，`GOOS=linux GOARCH=arm64 CGO_ENABLED=0`，上游静态可执行程序；原生启动器 `exec`，继承 `fd://3` |

tun2socks 的旧 gVisor 与 Go 工具链紧密相关，因此单独锁定 Go 1.23.1。不能简单改为最新 Go，也不能用 `c-shared` 替代其可执行入口。准备脚本检查 AArch64、非零 ELF 入口、所有 `PT_LOAD` 至少 16 KB 对齐，并去除本机编译路径；CMake 的两个 JNI 库由 NDK 的 flexible-page-size 开关处理。`check_apk.py` 再核对 APK 内四个 ELF、Geo 文件、签名、ZIP 对齐和敏感路径。

缓存、构建报告、`go version -m` 证据位于仓库 `.local/android-dependencies/`，均不提交。若只需检查已经准备的内核，可运行 `python3 apps/android/scripts/prepare-dependencies.py --check`。源码包与许可证可以公开，下载缓存、个人签名证书和 APK 不应混入 Git。

准备脚本还会把两个 Go 工程的模块版本清单、模块目录中的 `LICENSE` / `COPYING` / `NOTICE` 等文件复制到 `app/src/main/assets/third-party-licenses/`，随 APK 分发；统一第三方许可文本由 Gradle `preBuild` 调用根脚本补齐。APK 分发者仍需同时提供对应源码、固定版本与构建脚本，并遵守 [第三方依赖说明](../../docs/THIRD_PARTY.md)；此处收集文件不等于自动完成所有分发义务。其他开发说明见 [开发指南](../../docs/DEVELOPMENT.md#android)。

## 数据面与生命周期

1. Rust 在 `filesDir/split-vpn/` 生成 `config.yaml` 与 VPN 域名 provider。Mihomo 自建 TUN 和 Geo 自动更新关闭，使用 APK 内置数据。
2. 启动 `libmihomo.so`，mixed-port 为 `127.0.0.1:7890`，Controller 使用核心生成的随机 secret。
3. 等待 Controller 可用，确认用户选择的 `VPN` 出口。
4. `VpnService.Builder.establish()` 建立 Android TUN，排除本应用流量以防回环，并放行系统默认短信应用，让彩信连接运营商专用网络；内核准备期间不提前接管 Wi-Fi 流量。
5. 启动 `libtun2socks.so`，将 TUN fd 流量交给本机 SOCKS 出口。

Android VPN 的 DNS 为隧道内虚拟地址 `172.19.0.2`。UDP / TCP 53 请求经 tun2socks 交给 Mihomo，核心生成的最高优先级规则将其送入内部 `dns` 出站，使用同一份 Fake-IP、加密上游和域名策略；无需应用绑定特权 53 端口。该规则先于局域网直连规则，国内域名仍沿用国内 DNS 策略。启动前准备内置 Geo 数据，避免首次生成配置时误用缺数据的退化策略。用户保存的订阅、节点和规则不因该接入而改写。

启动器通过 exec 确认管道返回结果。连接意图单独持久化：关闭界面或从最近任务中划走不会主动停止前台 VPN 服务；Android 重建服务后按原意图恢复。手动断开会取消全部重试，权限撤销、无效节点和缺失内核则停止并提示处理。

彩信放行通过系统查询默认短信应用后加入 VPN 排除列表实现，不需要读取短信权限。部分厂商未通过标准接口返回默认短信应用时，兼容系统短信包 `com.android.mms`；包不存在或无法放行时记录日志，不扩大其他应用的绕行范围。该短信应用的全部联网直接使用系统网络，其他应用继续遵循轻舟分流；更换默认短信应用后需重连 VPN 才能更新排除列表。Android 11 及以上通过 Manifest 的 `SMS_DELIVER` 和系统短信包查询声明识别短信应用。开启系统“阻止未通过 VPN 的连接”时，系统仍可能阻止短信应用的直连，需在设备上单独验证。

Mihomo / tun2socks 异常退出通过阻塞等待通知服务，随后关闭旧 TUN、回收子进程并重建连接。重试间隔依次为 2、5、10、20、30、60 秒；锁屏或省电模式下，连续失败从第 5 次起延长到 120 秒。连接稳定 60 秒后才重置失败次数，避免反复崩溃时高频启动。恢复期间保留前台通知，界面显示“恢复中”并提供“立即重试”。

监听物理网络与默认网络变化，合并短时间内的重复通知，过滤自身 VPN 接口。Wi-Fi / 移动网络切换，以及地址、默认路由、DNS 变化都会触发重建。断网时显示“等待网络”，停止连接重试，联网后自动恢复；切网或重新连接后清除旧的诊断结果。从 Doze 恢复时先复核物理网络与 HTTPS 出口，只在必要时重建连接。

普通家庭和办公 Wi-Fi 的变化通知合并 250 毫秒，随后等待 500 毫秒再连接，清除旧网络的失败退避并沿用原节点。重建使用系统新的默认网络，不保留旧网络的出口连接。上述时间是调度等待，不包含系统连网、内核启动和节点握手；真实访问恢复时间需要真机测量。开启系统“阻止未通过 VPN 的连接”时，重建期间仍会由系统阻止普通上网。

启动、重载、切换和停止使用同一生命周期队列；每次操作和隧道会话都有独立编号，已取消的重试与旧子进程回调不能影响新连接。固定节点失败不自动回退 `AUTO`，继续沿用原有节点和分流配置。

## 后台与省电

- 不再每 500 毫秒查询子进程，也不再每秒刷新界面；运行状态变化时才更新可见界面。
- 服务的兜底健康检查先核对本机 Controller，再通过本机 SOCKS 向上述虚拟 DNS 查询地址，并使用答复地址建立带原域名 SNI、严格校验证书的 TLS 连接，避免仅凭内核按域名自测成功就忽略应用 DNS 故障。连接后 5 秒首检；正常时界面可见 30 秒、普通后台 60 秒、锁屏或省电模式 120 秒。Controller 连续 2 次，或 DNS / HTTPS 连续 3 次失败才重建数据面；`DIRECT` 不做远端出口判定。Doze 期间不探测、不唤醒设备，退出 Doze 后先复核物理网络再检查出口。该检查不展开整个订阅的节点测速。应用自身被 VPN 排除，因此此探针不能单独证明系统 TUN / tun2socks 正常，仍需用 VPN 覆盖的普通应用或设备 shell 验证完整路径。
- tun2socks 默认只输出 warn/error，服务层仍记录启动、退出及连接恢复事件。固定节点或直连模式关闭订阅集合的周期测速；AUTO/BALANCE 保留 15 分钟的按需测速，手动测速仍可用。切换模式时重新生成并重载配置，设置文件和节点协议保活不变。
- 内核的 provider、AUTO / BALANCE 节点健康探测启用 `lazy`，间隔从 5 分钟延长到 15 分钟，未使用时跳过周期探测，仍保留自动选路能力。配置由 Rust 的 Android 生成入口统一处理，不更改桌面默认设置。语义见 [Mihomo provider 文档](https://wiki.metacubex.one/en/config/proxy-providers/#health-checklazy)。
- 仅单次重建期间申请最长 30 秒的部分唤醒锁，完成后立即释放；正常连接、等待网络和重试间隔不持有唤醒锁。
- “更多 → 后台运行”提供“始终开启 VPN”和电池优化设置入口。需要重启手机后自动启动时，可在系统中为轻舟启用“始终开启 VPN”；由系统管理时，应用内断开入口会跳转到系统 VPN 设置。
- 厂商手机管家可能仍需允许后台运行 / 自启动。系统“强行停止”后不能自行拉起，需重新打开应用；普通内存回收后的重启时机也由 Android 决定。

## 测试与验收

本机可运行 Kotlin 单元测试、Android Lint、Rust 移动端测试，以及 `tests/native_process.py` 的原生进程测试。它们不启动真实 VPN。Kotlin 测试覆盖重试退避、手动停止和旧回调竞争、连接意图持久化、切网选择、省电频率及日志脱敏；原生测试检查 exec 失败、退出监听与回收。

安装测试 APK 后建议依次验证：连接后退到后台和划走界面；Wi-Fi 与移动网络互切；飞行模式后恢复网络；锁屏 30 分钟后联网；恢复中手动断开；开启省电模式；系统强行停止后重新打开。内核异常可在测试设备上单独终止子进程验证，不能用“强行停止应用”代替。

Android VPN 授权、前台服务、TUN fd、真实切网、厂商后台限制及实际耗电需要设备验收；构建通过不代表这些已验证。系统行为参考 [Android VPN 指南](https://developer.android.com/develop/connectivity/vpn) 与 [Doze / App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby)。第三方组件与公开发布事项见 [第三方依赖说明](../../docs/THIRD_PARTY.md)。
