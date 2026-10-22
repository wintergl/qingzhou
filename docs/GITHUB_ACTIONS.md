# GitHub Actions 自动构建与预发布

仓库使用 `.github/workflows/build-and-release.yml` 在干净的 GitHub-hosted runner 上重新准备固定版本的第三方依赖、运行检查并生成各平台测试包。

## 触发规则

| 事件 | 行为 |
|---|---|
| Pull Request | 运行源码检查、版本检查、Rust 检查和各平台测试构建；上传短期 Artifact |
| 推送到 `main` | 与 Pull Request 相同；同一分支的新运行会取消旧运行 |
| 推送 `vX.Y.Z` 标签 | 先要求标签与源码版本一致，再构建全部平台；全部成功后创建 GitHub prerelease |
| 手动运行 | 只构建和上传 Artifact，不创建 Release |

普通任务只有 `contents: read` 权限。只有标签发布任务取得 `contents: write`，并使用当前运行自带的 `GITHUB_TOKEN` 创建或更新对应 prerelease。

## 当前产物的含义

第一阶段不读取个人证书或签名密钥，产物均明确标记其边界：

| 平台 | 自动产物 | 当前边界 |
|---|---|---|
| macOS arm64 / x86_64 | ad-hoc 签名的 `.app` ZIP | 未使用 Developer ID、未公证、未安装验证 |
| Windows x64 | 自包含 ZIP | 未做 Authenticode 签名，未在 Windows 实机运行 |
| Android arm64 | debug APK | 使用 runner 临时调试签名，不保证覆盖安装，未做真机联网验证 |
| iOS | 未签名 Simulator App ZIP | 不能安装到真机，不是 IPA、TestFlight 或 App Store 包 |

每个平台同时导出与该二进制对应的应用源码、固定上游源码、依赖锁和构建说明。标签发布任务重新计算全部文件的 SHA-256，并把 `SHA256SUMS` 与产物一起上传。

Actions 成功只证明源码能在该 runner 上重新构建，并不证明系统权限、VPN、DNS、路由、睡眠恢复、真机联网或升级覆盖已经通过。

## 正式签名发布的后续门槛

正式发布时应把签名任务放进受审批保护的 `release` Environment，并只从 GitHub Secrets 临时导入：

- macOS：Developer ID Application 证书、证书密码和 Apple 公证凭据；任务结束后销毁临时钥匙串。
- Windows：Authenticode 证书或可信远程签名服务。
- Android：稳定的 release keystore、alias 和密码，并增加 `assembleRelease` 或 AAB 流程。
- iOS：发行证书、主 App 与 Packet Tunnel 的描述文件、Team ID、Bundle ID、App Group 及正式导出方式。

接入正式签名后，移除对应文件名中的 `adhoc`、`unsigned` 或 `debug` 前，必须同时增加签名验证、公证/平台验证和安装验收；不能只改文件名。

## 本地检查

```sh
python3 scripts/check_public_source.py
python3 scripts/check-release-version.py
python3 scripts/check-release-version.py --tag v0.6.5
python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
```

版本发布前需同步更新 Rust、macOS、Windows、iOS 和 Android 的版本字段。`check-release-version.py --tag` 会阻止标签与源码版本不一致的 Release。

## Runner 空间与缓存

各平台独立运行，避免把所有工具链和第三方源码堆在同一台 runner 上。工作流不保存包含生成二进制或签名材料的共享缓存；iOS 在对应源码包和第三方声明生成后，会删除可重新下载的 Go/Cargo 缓存，再由 Xcode 校验并装入已生成的声明，以降低临时磁盘峰值。

构建失败时不会创建 Release。已经存在同名 prerelease 的重跑只覆盖同名附件，不删除其他 Release，也不会改动仓库源码。
