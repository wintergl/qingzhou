# iOS 第三方输入与许可证

可执行的准备命令见 [iPhone README](../README.md#从干净源码准备框架)。第三方版本由仓库根 [`third_party/dependencies.lock.json`](../../../third_party/dependencies.lock.json) 固定；不提交 `.xcframework`、源码克隆或编译缓存。

| 本地内容 | 角色 | 许可证和对应源码 |
|---|---|---|
| `CoreFrameworks/SplitVpnCore.xcframework` | 本仓库 Rust 核心的静态库 | 本仓库许可证与 `packages/vpn-core/Cargo.lock` 中的传递依赖许可证 |
| `SingBoxFrameworks/Libbox.xcframework` | 链接到 Packet Tunnel 的 sing-box 数据面 | GPL-3.0-or-later，附上游名称/关联限制说明；见下文 |
| `sing-box-src/` | 固定提交 `320146a106f9baaa57f5e0153675a613940ef91c` | 公开源码由脚本下载；`LICENSE`、`go.mod`、`go.sum` 留在该目录 |
| 根目录 `.local/ios-go/bin/` | `gomobile` / `gobind` v0.1.13 构建工具 | 由公开 Go module 安装；仅构建工具，不直接打入 App |

上游的 [sing-box LICENSE 原文](https://github.com/SagerNet/sing-box/blob/320146a106f9baaa57f5e0153675a613940ef91c/LICENSE) 声明 GPL 第 3 版或以后版本，并另有不得未经许可使用上游名称或暗示关联的说明。不得将框架当作无义务的二进制依赖。向他人分发链接 Libbox 的应用前，须按其实际适用许可证提供完整对应源码、自己的修改和重建脚本、许可证文本及版权声明；只提供一个上游项目主页链接并不足以替代对应源码。细项和本项目发布边界见 [统一第三方说明](../../../docs/THIRD_PARTY.md)。

`go.mod` / `go.sum` 固定的其他 Go 模块也可能带有独立版权和 NOTICE。保留实际构建所用模块源码及其许可证；`go mod download` / `go mod verify` 成功只证明依赖校验通过，不代表已经完成所有再分发义务。不要把本地编译成功误写成已获 App Store 上架许可。

本项目没有引入 `sing-box-for-apple` 的 `Library` 应用层框架。`fetch-sing-box-for-apple.sh` 保留为说明入口，不再克隆漂移分支。需要查阅参考实现时可访问其公开项目，参考源码不属于本项目构建输入。
