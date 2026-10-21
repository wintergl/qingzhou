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

构建依赖和命令见 [开发指南](../../docs/DEVELOPMENT.md#android)。仓库没有 Gradle Wrapper，可使用已安装的 Gradle 或 Android Studio。

## 数据面与生命周期

1. Rust 在 `filesDir/split-vpn/` 生成 `config.yaml` 与 VPN 域名 provider。Mihomo 自建 TUN 和 Geo 自动更新关闭，使用 APK 内置数据。
2. 启动 `libmihomo.so`，mixed-port 为 `127.0.0.1:7890`，Controller 使用核心生成的随机 secret。
3. 等待 Controller 可用，确认用户选择的 `VPN` 出口。
4. `VpnService.Builder.establish()` 建立 Android TUN，排除本应用流量以防回环，并放行系统默认短信应用，让彩信连接运营商专用网络；内核准备期间不提前接管 Wi-Fi 流量。
5. 启动 `libtun2socks.so`，将 TUN fd 流量交给本机 SOCKS 出口。

启动器通过 exec 确认管道返回结果。连接意图单独持久化：关闭界面或从最近任务中划走不会主动停止前台 VPN 服务；Android 重建服务后按原意图恢复。手动断开会取消全部重试，权限撤销、无效节点和缺失内核则停止并提示处理。

彩信放行通过系统查询默认短信应用后加入 VPN 排除列表实现，不需要读取短信权限。部分厂商未通过标准接口返回默认短信应用时，兼容系统短信包 `com.android.mms`；包不存在或无法放行时记录日志，不扩大其他应用的绕行范围。该短信应用的全部联网直接使用系统网络，其他应用继续遵循轻舟分流；更换默认短信应用后需重连 VPN 才能更新排除列表。Android 11 及以上通过 Manifest 的 `SMS_DELIVER` 和系统短信包查询声明识别短信应用。开启系统“阻止未通过 VPN 的连接”时，系统仍可能阻止短信应用的直连，需在设备上单独验证。

Mihomo / tun2socks 异常退出通过阻塞等待通知服务，随后关闭旧 TUN、回收子进程并重建连接。重试间隔依次为 2、5、10、20、30、60 秒；锁屏或省电模式下，连续失败从第 5 次起延长到 120 秒。连接稳定 60 秒后才重置失败次数，避免反复崩溃时高频启动。恢复期间保留前台通知，界面显示“恢复中”并提供“立即重试”。

监听物理网络与默认网络变化，合并短时间内的重复通知，过滤自身 VPN 接口。Wi-Fi / 移动网络切换，以及地址、默认路由、DNS 变化都会触发重建。断网时显示“等待网络”，停止连接重试，联网后自动恢复；切网或重新连接后清除旧的诊断结果。从 Doze 恢复时重建连接，避免沿用休眠前的失效连接。

普通家庭和办公 Wi-Fi 的变化通知合并 250 毫秒，随后等待 500 毫秒再连接，清除旧网络的失败退避并沿用原节点。重建使用系统新的默认网络，不保留旧网络的出口连接。上述时间是调度等待，不包含系统连网、内核启动和节点握手；真实访问恢复时间需要真机测量。开启系统“阻止未通过 VPN 的连接”时，重建期间仍会由系统阻止普通上网。

启动、重载、切换和停止使用同一生命周期队列；每次操作和隧道会话都有独立编号，已取消的重试与旧子进程回调不能影响新连接。固定节点失败不自动回退 `AUTO`，继续沿用原有节点和分流配置。

## 后台与省电

- 不再每 500 毫秒查询子进程，也不再每秒刷新界面；运行状态变化时才更新可见界面。
- 服务的兜底健康检查仅访问本机 Controller：界面可见时 30 秒，后台 60 秒，锁屏或省电模式 120 秒，Doze 180 秒。不定时唤醒设备，也不自动运行界面的外网站点测速。它能发现本机内核无响应，不等同于远端节点可用性检测。
- tun2socks 默认只输出 warn/error，服务层仍记录启动、退出及连接恢复事件。固定节点或直连模式关闭订阅集合的周期测速；AUTO/BALANCE 保留 15 分钟的按需测速，手动测速仍可用。切换模式时重新生成并重载配置，设置文件和节点协议保活不变。
- 内核的 provider、AUTO / BALANCE 节点健康探测启用 `lazy`，间隔从 5 分钟延长到 15 分钟，未使用时跳过周期探测，仍保留自动选路能力。配置由 Rust 的 Android 生成入口统一处理，不更改桌面默认设置。语义见 [Mihomo provider 文档](https://wiki.metacubex.one/en/config/proxy-providers/#health-checklazy)。
- 仅单次重建期间申请最长 30 秒的部分唤醒锁，完成后立即释放；正常连接、等待网络和重试间隔不持有唤醒锁。
- “更多 → 后台运行”提供“始终开启 VPN”和电池优化设置入口。需要重启手机后自动启动时，可在系统中为轻舟启用“始终开启 VPN”；由系统管理时，应用内断开入口会跳转到系统 VPN 设置。
- 厂商手机管家可能仍需允许后台运行 / 自启动。系统“强行停止”后不能自行拉起，需重新打开应用；普通内存回收后的重启时机也由 Android 决定。

## 测试与验收

本机可运行 Kotlin 单元测试、Android Lint、Rust 移动端测试，以及 `tests/native_process.py` 的原生进程测试。它们不启动真实 VPN。Kotlin 测试覆盖重试退避、手动停止和旧回调竞争、连接意图持久化、切网选择、省电频率及日志脱敏；原生测试检查 exec 失败、退出监听与回收。

安装测试 APK 后建议依次验证：连接后退到后台和划走界面；Wi-Fi 与移动网络互切；飞行模式后恢复网络；锁屏 30 分钟后联网；恢复中手动断开；开启省电模式；系统强行停止后重新打开。内核异常可在测试设备上单独终止子进程验证，不能用“强行停止应用”代替。

Android VPN 授权、前台服务、TUN fd、真实切网、厂商后台限制及实际耗电需要设备验收；构建通过不代表这些已验证。系统行为参考 [Android VPN 指南](https://developer.android.com/develop/connectivity/vpn) 与 [Doze / App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby)。第三方组件与公开发布事项见 [第三方依赖说明](../../docs/THIRD_PARTY.md)。
