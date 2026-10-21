# 轻舟 Rust 业务核心

所有平台共用的业务核心。桌面构建为 `splitvpn-core` 可执行文件，通过 stdin/stdout JSON 行 RPC 调用；移动端链接静态库，使用 `qz_core_call` / `qz_core_free`，头文件为 `include/qz_core.h`。实际代理数据面由 Mihomo 或 sing-box 执行，aTrust 认证由 Go 适配器处理。

## 模块

| 模块 | 职责 |
|---|---|
| `storage.rs` | 设置、订阅、节点身份、manifest、原子写入、缓存及日志脱敏 |
| `subscription.rs` | YAML / URI / base64 解析、AnyTLS 参数兼容、格式回退与自动更新 |
| `config.rs` | Mihomo 配置、规则顺序、局域网 / Tailscale、QUIC 与兼容规则 |
| `runtime.rs` | RPC 分发、内核生命周期、事务恢复、节点、测速、风险、流量与网络恢复 |
| `network.rs` | 系统与 VPN DNS 核对、普通系统 HTTPS 检测与连接诊断 |
| `company.rs` | 按授权范围生成私有网络 TCP 规则、共享内核出口恢复与主动业务验证 |
| `platform.rs` | 有界系统命令、进程身份、互斥、物理路由与 macOS helper 协议 |
| `main.rs` | 桌面 stdio RPC，请求上限 2 MB，完整排空回复后退出 |
| `mobile.rs` | C ABI、订阅下载计划和结果接收、节点与移动配置生成 |
| `singbox.rs` | iOS sing-box 配置生成 |

## 数据与连接边界

沿用旧版设置版本、订阅格式与用户目录，保留未知字段、收藏、节点组和规则。订阅原始协议内容交给 Mihomo 校验，保留 Reality、gRPC、TLS 等选项；`STATUS=` / `REMARKS=` 等说明行不参与节点索引。没有真实节点、畸形 URI 或未知协议仍会失败，下载失败保留原节点和 provider 指针。

节点组用于整理与批量检测，整组连接禁用。批量风险和 UDP 检测结束后恢复控制器中的原出口，不关闭无关 TCP 连接。私有网络验证与外网检测只在明确操作时执行，验证失败保留隧道。

`native:bootstrap` 只读；`native:startup-connect` 每个后台生命周期只尝试一次，已有内核直接接续，手动断开后不自动重连。后台恢复仅针对本后台主动启动的内核，按物理接口、网关与 IPv4 签名等待网络稳定，并限制重试次数。

helper 更新由明确的连接、节点切换或配置应用触发。后台附着、轮询和自动重连不弹管理员安装窗口。升级备份并原子替换服务文件，失败回滚并尝试接续旧服务；未知身份与其他数据目录受到保护。进程时间使用 UTC，配置重载后核对身份并刷新 DNS，断开按快照恢复。

密码、验证码和认证会话由平台 / Go 管理，不由 Rust 持久化。风险密钥经私有管道传入内存。内部 `company` 字段和通道名保持兼容，用户界面统一使用“私有网络”。

## 移动端协议

平台 HTTP 栈负责下载：先调用 `subscription:plan` 取得地址和 `token`，再将同一 token 与响应交给 `subscription:accept`。链接改变、新请求开始或请求完成后，旧结果返回 `stale: true`，不覆盖数据或失败状态；旧缓存迁移也先取得下载计划。

iOS 主 App 调用 `singbox:generate`，Packet Tunnel 只读取生成的 JSON。Android 调用 `mihomo:generate`，复用 `config::build`，关闭 Mihomo 自建 TUN 和 Geo 自动更新，并根据 `selectionValid` / `selectionError` 判断是否能启动或重载。

## 开发与验证

### 0.5.1 桌面网络恢复

网络恢复策略在 `network_recovery.rs`，由桌面运行时执行。物理路由签名变化、网络中断后恢复及 macOS 物理路径事件或睡眠唤醒都会使原配置需要重新确认；连续稳定 3 秒后加载新网卡配置，并确认内核网卡、TUN 设置与系统 DNS。恢复失败会保留错误并等待后重试，最多 3 次；新的网络变化或用户手动重试可重置次数，手动断开清除恢复意图。

桌面状态新增可选 `mihomo.networkRecovery`，原来的 `mihomo.state` 继续描述进程状态。新字段包含 `state`、脱敏 `error`、`attempts` 和 `helperUpdateRequired`，不包含物理网络签名。状态值为 `idle`、`ready`、`waiting-network`、`recovering`、`failed`、`helper-update-required`。macOS 根据该字段显示恢复情况，异常状态不再保留已连接颜色；旧桌面客户端可忽略新增字段，移动端 C ABI 不变。

macOS `native:network-changed` 只传递可选的路径可用状态，不在 Swift 中执行恢复策略。`native:upgrade-helper` 只供用户主动更新连接服务：后台及启动自动连接不安装服务；旧服务需要更新时先显示提示，不先启动一个无法恢复切网的连接。新服务独立核对原进程身份后接续原节点；取消系统授权保留连接。恢复只清理确认走个人 VPN 或直连的旧连接，保留私有网络和未知归属的连接。

构建和按修改范围执行的检查统一见 [开发指南](../../docs/DEVELOPMENT.md#rust-核心)。测试使用 `SPLITVPN_ISOLATED=1` 和临时 `SPLITVPN_DATA_DIR`；回环真实内核测试也关闭系统 TUN / DNS。编译与协议检查不代替安装、权限和真实联网验收。

### 连接失效检测与脱敏诊断

桌面后台对自己持有且处于 ready 状态的连接，每 30 秒核对一次控制器、出口网卡和 TUN；macOS 另外只读检查实际 utun 设备是否启用并具有 IPv4 地址。连续 3 次失败，即使物理网络签名未变，也进入现有的有限次数恢复流程。单次抖动不会触发恢复；睡眠、手动断开、其他进程持有的内核及隔离测试不会自动运行检测。

开启现有微信兼容选项时，`connection_health.rs` 在内存中跟踪微信连接。首次快照只建立基线；后续新连接已发送数据但未收到回应，或已有连接新增发送数据却没有接收增长，才开始计时。持续 120 秒没有回应、最近 30 秒收发计数都不变且有至少 3 次采样时，仅清理一条疑似失效连接，让微信自行重试；不切换节点或重启整个 VPN。每 2 分钟最多一次、每 10 分钟最多三次，关闭失败也占用次数。收到回应、计数重置、连接消失、采样失败或间隔超过 75 秒会撤销该连接的旧判断；私有网络连接始终排除。正常空闲和持续有数据进展的上传不触发清理。

这属于基于流量计数的保守启发式，无法证明微信业务请求成功，也无法识别所有失败（例如未识别进程、首次采样前已卡住或连接不断有其他回应）。非常缓慢的单向业务仍有误判可能。日志的 `connection-health` 事件只记录固定原因、直连/代理类别、触发与执行结果；不记录连接 ID、IP、域名、节点名、进程路径、订阅或凭据。`socket-closed-awaiting-app-retry` 仅表示连接已清理，不表示图片已发送成功。
