# 私有网络认证内核

轻舟 macOS / Windows 版“私有网络”页面使用的 aTrust 认证与 TCP 隧道内核（`company-account-helper`）。应用通过 stdin/stdout 与它交换 JSON 行：探测入口与证书、账号登录（含验证码 / 短信）、拉取授权资源、建立只监听本机的 SOCKS5 出口；Rust 核心再把授权网段编译成 Mihomo 规则，接到这个出口上（见 `packages/vpn-core/src/company.rs`）。

目前这个适配器只接入 aTrust。固定版本的 ZJU Connect 上游也实现了 EasyConnect，但轻舟的账号认证、资源转换和隧道管理尚未接入该协议，不能直接当作 EasyConnect 客户端使用。内部目录名、`company-*` 程序名和 RPC 字段保留，以兼容现有构建、配置及用户数据。

## 目录

| 路径 | 说明 |
|---|---|
| `prepare.py` | 下载固定版本的上游源码，套用本目录补丁，跑 Go 测试并构建内核 |
| `overlay/cmd/company-account-helper/` | 认证内核主程序：探测、登录、资源、隧道 |
| `overlay/internal/companycert/` | 网关证书指纹校验与系统证书链验证 |
| `overlay/internal/companyprocess/` | 向网关上报的真实进程信息 |
| `overlay/client/atrust/company_nodes.go` | 节点刷新时保留仍可用的 TCP 出口 |
| `.local/`（git 忽略） | 上游源码、Go 模块缓存和构建出的内核 |

## 构建

可单独准备源码与构建内核；Windows 打包脚本也会执行此步骤，确保使用最新补丁：

```sh
python3 packages/company-vpn/prepare.py
```

脚本会核对上游提交、套用补丁、运行 `companycert`、`company-account-helper`、`client/atrust` 三组 Go 测试，再构建内核。补丁上下文与固定版本不一致时直接失败，不会带着未审阅的改动继续。

## 安全约束

- 密码只经 stdin 管道传给内核，不进命令行参数、环境变量、日志或诊断。
- 网关证书按 HTTPS 主机和端口记住 SHA-256 指纹；变化、过期或未确认时拒绝登录和隧道握手。
- 授权资源请求失败直接报错，不会当成空资源列表。
- 只支持 TCP；授权网段的 UDP 和未授权端口由 Mihomo 规则拒绝，不回退直连。
- 内核按真实进程信息上报，不伪装成受信任的应用。

## 登录时要求修改密码

当网关返回 `auth/modifyPwd`，macOS / Windows 会弹出改密窗口，显示接入网关下发的密码要求，输入旧密码、新密码和确认密码后，直接在轻舟中提交。如果接入网关同时要求更改账号名，窗口会增加新账号名字段。

内核沿用本次登录的证书校验、会话 Cookie、CSRF 和最新防重放随机数，将旧密码和新密码分别 RSA 加密后，以表单提交 `/passport/v1/auth/modifyPwd`。服务器拒绝时显示脱敏后的原因并允许重填；成功后继续服务器下发的认证步骤（包括短信或动态口令），完整认证通过后才读取授权资源。

`challenge` 的 `kind` 为 `password_change`；响应通过 stdin 的 `challenge_response` 携带 `oldPassword`、`newPassword` 和可选 `newUsername`。服务器明确确认改密后发送带本次挑战 `id` 的 `password_changed`，客户端才更新已勾选记住的凭据；即使后续验证码失败，也不会把旧密码重新写回。macOS 密码只保存在钥匙串，Windows 沿用现有本机加密凭据存储。

取消不会发起新的改密请求。提交后若发生超时、异常响应或重定向，内核不会自动重复改密，而是返回 `password_change_uncertain`，提示先用新密码重新登录并暂停自动读取旧密码。这个状态按网关保存在本机偏好中，重启后仍有效；成功登录或确认新密码已保存后解除。已发出的改密请求可能被服务器执行。旧内核不支持改密时，macOS / Windows 仍保留官方客户端改密指引。

## 上游与许可证

基于 [ZJU Connect](https://github.com/Mythologyli/zju-connect/tree/923672dc927e43e04592595a0005ad90a7a3afb5)，固定提交 `923672dc927e43e04592595a0005ad90a7a3afb5`，沿用 [AGPL-3.0 许可证](LICENSE)。本目录对上游的补丁和基于上游的适配代码按该许可证提供；仓库根目录的 Apache-2.0 不能替代这部分的许可证。

准备脚本保留上游源码与许可证，生成的应用包附 `LICENSE-ZJU-Connect.txt` 和源码位置说明。`.local/source/` 是本机构建目录，发布二进制时仍须让接收者实际取得匹配版本的完整源码、补丁和构建脚本。stdin/stdout 通信本身不能作为整个应用的许可证边界已经成立的依据。各平台发布范围和待处理事项见 [第三方依赖说明](../../docs/THIRD_PARTY.md)。
