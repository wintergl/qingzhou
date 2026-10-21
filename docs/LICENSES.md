# 许可证与第三方声明

本仓库保留各部分已有许可证，不把所有平台安装包统一标为 Apache-2.0。原始许可文本位于根目录 `LICENSE`、`packages/company-vpn/LICENSE` 与 `third_party/licenses/`；固定版本和文本校验值见 `third_party/dependencies.lock.json`。

| 范围 | 保留的许可证与来源 |
|---|---|
| 轻舟原创源码 | 根目录 Apache-2.0；不覆盖第三方组件或接入适配的派生代码 |
| aTrust 适配补丁及生成的接入内核 | 固定 ZJU Connect 源码与本仓库补丁，沿用 AGPL-3.0，见该目录 LICENSE 与 README |
| 桌面与 Android Mihomo | 固定上游源码的 GPL-3.0；两个平台的提交分别记录 |
| iOS Libbox / sing-box | GPL-3.0-or-later；上游 LICENSE 中关于名称与关联的附加说明也须原样保留 |
| Android tun2socks | MIT；保留版权与许可文本 |
| Go 标准库、Gradle Wrapper | 分别保留 Go 的 BSD 风格 LICENSE/PATENTS、Gradle 的 Apache-2.0 LICENSE |
| Rust / Go 的间接依赖 | 使用锁定依赖图中的各包许可；生成清单包含包名、版本及原始许可证，不用顶层许可替代 |
| Geo 数据与规则集 | 数据来源、固定数据提交与 SHA-256 单独列入清单；生成器仓库的许可不替代其数据源条款 |

Mihomo 的 [GPLv3 第 1、5、6 节](https://github.com/MetaCubeX/mihomo/blob/fc8c5a24b16991f98cd736950c17d1aa306a5041/LICENSE) 说明对应源码、修改版本与目标代码分发条件。ZJU Connect 的 [AGPLv3](https://github.com/Mythologyli/zju-connect/blob/923672dc927e43e04592595a0005ad90a7a3afb5/LICENSE) 另有网络交互条款。Apache 官方说明了 [Apache-2.0 与 GPLv3 的兼容方向](https://www.apache.org/licenses/GPL-compatibility.html)。这些说明不表示根目录声明能覆盖整个组合应用；尤其 iOS 将 Libbox 链接进 Packet Tunnel，分发组合程序时需要满足对应组合范围的 GPL 条款。不同进程、静态库或 stdio 通信本身不能决定许可边界。

## 构建时生成的声明

准备脚本保留固定上游源码、补丁和锁文件。`scripts/stage-notices.py` 按平台放入直接依赖许可、Geo 来源以及 Rust 包许可；Android 内核准备脚本另外收集 Go 模块许可。打包流程会把声明复制进本次生成的应用资源，不读取个人账户、证书或凭据。

## 对应源码与分发材料

本仓库源码与锁文件描述可获取的构建输入。分发自己生成的安装包时，请同时提供本次应用源码、选用的完整第三方源码、适配补丁、锁文件、构建命令、生成器及所用数据来源。若修改第三方源码，应把修改和日期一并提供，不能继续声称使用未经修改的上游二进制。

完成对应平台的准备后，可导出应用源码与本次使用的直接上游源码材料：

```sh
python3 scripts/export-corresponding-source.py --platform macos-arm64 --output release/qingzhou-macos-source-materials.tar.gz
```

其他平台使用同名 `--platform` 参数。脚本保留补丁后的适配源码、上游原始许可与锁文件，排除旧 Git、个人配置、缓存及生成框架；输出已有时停止。该材料包中的 Go / Rust 间接依赖仍通过所附锁文件获取，不是无网络的完整供应链镜像。发布前应把实际分发组件所需的间接源码和原生依赖源码一并落实到接收者可获取的提供方式。

构建清单与本机 `.local/` 目录名不能代替接收者可实际取得的源码。尚未发布的 GitHub 地址也不能写成已可访问的源码地址。对外发布时应将相应源码材料与二进制一同交付或采用所适用许可证允许的其他提供方式。

## Geo 数据来源

桌面与 Android 数据来自固定提交的 MetaCubeX/meta-rules-dat。该项目说明其国家数据库沿用 Loyalsoldier/v2ray-rules-dat 的内容；不能仅凭 meta-rules-dat 的 GPL 生成器许可证，将数据库中所有来源也认定为 GPL。iOS 规则集来自固定的 SagerNet/sing-geosite、sing-geoip 数据提交。准备脚本固定下载内容用于本地构建；对外再分发数据时，还须保留所选数据版本及上游列出的来源、署名和适用条款。

默认开源源码压缩包不包含这些生成数据、运行内核、设备描述文件或个人签名。正式安装包的分发材料应在实际目标平台与组件集合确定后单独核对。

Libbox 的上游构建标签包含 `with_naive_outbound`，其锁定的 cronet-go 模块带有预编译的 Chromium/Cronet 静态库。这里重建的是固定 sing-box 源码和其 `go.sum` 依赖组合，不把它描述为所有原生依赖均从 C/C++ 源码重编译。许可收集会保留这些模块中的 LICENSE/NOTICE；原生库对应源码与完整第三方声明也属于实际二进制分发材料，不能用 sing-box 顶层许可证替代。
