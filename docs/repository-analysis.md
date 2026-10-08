# openwrt-imagebuilder-ci 仓库分析

分析日期：2026-10-08。本文依据仓库源码梳理构建行为，文件行号对应本次修改后的源码；后续改动可能使行号移动。QEMU Guest Agent 的包、驱动和服务行为另依据文中链接的官方来源核实。

## 项目定位与架构

这是一个面向 OpenWrt 官方发行版 `x86/64`、`generic` profile 的固件装配工程。第三方组件使用目标版本的官方 SDK 编译；固件阶段使用官方 ImageBuilder 安装这些组件和官方软件包，并合入 `files/`。仓库不维护 OpenWrt 内核源码或独立完整发行版。

默认镜像是 squashfs 根文件系统、UEFI GPT 引导的 `combined-efi.img.gz`，根分区 2048 MB，GRUB 等待 0 秒。[构建参数](../scripts/build-firmware.sh#L47)允许调整版本、profile、分区和输出路径，但下载地址、rootfs 定位、产物路径仍按 `x86/64` 编写，不能仅修改 `ARCH` 就当作通用多架构构建器。

```mermaid
flowchart TD
    trigger["定时 / 手动"] --> resolve["解析并锁定 OpenWrt 版本"]
    resolve --> hw["官方同版 SDK：helloworld"]
    resolve --> fc["官方同版 SDK：FullCone runtime → LuCI"]
    hw --> hwa["当前运行的 helloworld Artifact"]
    fc --> fca["当前运行的 FullCone Artifact"]
    hwa --> assembly["官方 ImageBuilder 纯装配"]
    fca --> assembly
    official["同版官方 APK 源：LuCI / 驱动 / QGA / 依赖"] --> assembly
    overlay["files/：默认配置 / QGA init / FullCone 诊断"] --> assembly
    assembly --> validation["Manifest / ABI / rootfs 验收"]
    validation --> output["固件 Artifact，保留 30 天"]
    validation --> release["手动选择发布固件 Release"]
```

主工作流等待两个组件成功后才运行装配。组件通过**同一次 Actions 运行中的 Artifacts**传递，不查询历史组件 Release，不回退到旧版组件，也不在固件 job 内下载 SDK 或编译组件。

## 目录职责与构建入口

| 位置 | 职责 |
| --- | --- |
| `.github/workflows/daily-build.yml` | 统一版本解析、并行组件构建、下载本次组件、装配、差分缓存与固件发布 |
| `.github/workflows/build-helloworld.yml` | helloworld 组件独立手动 / 可复用构建与 Artifact 上传 |
| `.github/workflows/build-fullcone.yml` | FullCone runtime 和 LuCI 两阶段构建、验收与 Artifact 上传 |
| `components/helloworld-builder/` | SSR Plus / Xray / Mihomo 源码构建及输出契约 |
| `components/fullcone-builder/` | FullCone runtime、LuCI 补丁和构建依赖检查工具 |
| `scripts/resolve-version.sh` | 探测最新稳定版，或验证指定版本号格式 |
| `scripts/setup-sdk.sh` | 官方 SDK 下载、SHA256 校验、解包和可选签名密钥注入 |
| `scripts/build-firmware.sh` | 预编译组件验收、ImageBuilder 配置、镜像生成和最终验收 |
| `scripts/setup-env.sh` | Ubuntu / Debian / WSL2 的 apt 构建依赖检查与安装 |
| `scripts/diff_manifest.py` | 新旧软件包清单比对，生成文本 / Markdown 差分报告 |
| `config/extra-packages.txt` | 普通官方增量包与 `-包名` 移除项，支持中文注释 |
| `config/custom-feeds.conf` | 可选第三方 APK 源，支持 `${VERSION_SERIES}` 替换；当前没有额外源 |
| `files/` | rootfs 覆盖文件，包括首次默认配置、QGA init 和 `fullcone-check` |
| `Makefile` | 本地 `env`、`build` / `image`、`clean`、`distclean` 入口 |
| `.work/`、`.manifest-cache/`、`bin/` | 工作缓存、历史 Manifest 缓存和最终产物，均被 Git 忽略 |

### 云端入口

[主工作流](../.github/workflows/daily-build.yml#L3)每天 UTC 23:23，即北京时间次日 07:23 调度，也支持手动输入版本、分区大小、GRUB 等待时间和是否发布 Release。没有 push 触发器。`concurrency` 设置 `cancel-in-progress: false`，避免取消正在运行的同组构建。

两个组件工作流同时提供 `workflow_dispatch` 和 `workflow_call`。当前二者**每次都编译**，缓存仅用于构建工具归档和下载 / 源码目录；`force_rebuild` 参数虽然存在，执行步骤没有使用它作跳过判断。

### 本地入口

`make env` 准备宿主机依赖。`make build` 调用装配脚本，并尝试从 `.work/` 找到已有组件目录；它不会生成组件或下载 CI Artifact。[Makefile 的目录选择](../Makefile#L35)使用首个匹配路径，多版本缓存共存时应显式设置 `HELLOWORLD_COMPONENT_DIR`、`FULLCONE_RUNTIME_DIR` 和 `FULLCONE_LUCI_DIR`。

全新检出需先从同版组件 CI 下载并解压归档，或手动使用组件脚本构建，再指定对应的 `OPENWRT_VERSION` 进行装配。组件版本不一致会被前置校验拒绝。具体命令见 [README 本地构建步骤](../README.md#2-本地纯装配构建-ubuntu--debian--wsl2)。

## 版本与官方工具准备

1. [resolve-version.sh](../scripts/resolve-version.sh#L9)优先读取 `downloads.openwrt.org/.versions.json` 的 `stable_version`，失败后从 releases 目录提取数字版本并按版本排序。
2. 指定版本只检查 `X.Y.Z` / `X.Y.Z-rcN` 格式；官方发行目录、工具归档是否存在，在下载阶段确认。
3. 主工作流只探测一次 `latest`，把具体版本传给下游。组件再次调用解析脚本时处理的是具体值，不会重新探测最新版本。
4. [setup-sdk.sh](../scripts/setup-sdk.sh#L35)从官方目标目录找唯一 SDK 候选，读取官方 SHA256，并在下载 / 缓存命中时检查归档后解包。可通过 `CUSTOM_SIGNING_KEY` 注入统一私钥；否则使用 SDK 生成的本地签名密钥。
5. [ImageBuilder 准备](../scripts/build-firmware.sh#L133)同样使用官方 HTTPS 下载与 SHA256。已有解包目录且含 Makefile 时会直接复用，不重新从归档恢复目录。

SDK 与 ImageBuilder 同版锁定保证目标包格式和内核 ABI 的一致性。上游组件源码仍按各自分支更新，目标版本锁定不代表完整源码快照锁定。

## 两个组件构建器

### helloworld

[构建器输入](../components/helloworld-builder/build.sh#L19)包含目标版本、工作目录、输出目录、SDK 路径和可选上游仓库 / ref。默认上游是 `fw876/helloworld` 的 `dev`，每次更新并记录实际 commit。

[SDK feeds 初始化](../components/helloworld-builder/build.sh#L130)先恢复官方发行版固定的 feeds，再增加 helloworld。为保证使用 helloworld 的 xray-core，移除官方 packages 中的对应包定义。缺少 `golang1.27` 时，从 packages `master` 同步 Golang 定义；其余官方 feeds 保持 SDK 固定版本。

三个直接编译目标为 `luci-app-ssr-plus`、`xray-core`、`mihomo`，中文包随 LuCI 语言配置生成。SSR Plus 的额外代理选项按项目需求关闭，naiveproxy 明确排除。构建先清理和预下载，再逐目标编译；并行失败会以 `-j1 V=s` 重试。

输出包含 helloworld feed 产生的 APK、签名公钥、清单与安装约束。核心包使用 `@custom`；`v2ray-geoip` 和 `v2ray-geosite` 使用同版官方源。[helloworld CI 验收](../.github/workflows/build-helloworld.yml#L117)还要求 `dns2tcp`、`ipt2socks` 和 `lua-neturl` 出现在仓库清单中。

### FullCone runtime

[runtime 构建器](../components/fullcone-builder/build.sh#L62)每次克隆 ImmortalWrt HEAD，提取 `fullconenat-nft` 模块和 libnftnl / nftables / firewall4 的供体补丁，记录 donor commit、模块源码 commit 和 mirror hash。

它在官方 SDK 的包定义基础上注入补丁、必要的 `autoreconf` 和 `firewall4 → kmod-nft-fullcone` 依赖，不替换官方内核。供体 firewall 默认配置修改被剥离，默认开关由本仓库管理。

[依赖检查与构建调度](../components/fullcone-builder/build.sh#L317)读取 SDK 实际生成的 `tmp/.packagedeps`，要求 firewall4 可传递到 nftables、FullCone 模块和 kernel/linux，nftables 可传递到 libnftnl。之后一次顶层 firewall4 编译覆盖整个调用链，避免独立并行命令重复调度内核前置目标。

输出四个 APK：`kmod-nft-fullcone`、`libnftnl11`、`nftables-json`、`firewall4`。验收不仅检查包名，还检查 FullCone 生成源码、`nft` 的 ELF 与动态链接、实际承载 parser 的 `libnftables.so`、libnftnl expression、fw4 模板和模块文件。模块 APK 的精确 kernel 依赖单独导出供固件验收。

### FullCone LuCI

[LuCI 构建器](../components/fullcone-builder/build-luci.sh#L157)从 SDK 解析官方 LuCI 仓库，并使用目标系列 `openwrt-X.Y` 稳定分支的最新 commit。官方 Git 服务不可达时可使用官方 GitHub 镜像。

三个本地补丁使用 `--fuzz=0` 精确重放：增加 RPC capability、IPv4 / IPv6 FullCone UI 和中文翻译。上游结构不匹配时失败，不跳过补丁。重新编译后输出 `luci-base`、`luci-app-firewall`、`luci-i18n-firewall-zh-cn`，再解包检查 RPC、UI 和非空中文 LMO 文件。

[FullCone CI](../.github/workflows/build-fullcone.yml#L105)在同一 SDK 中顺序运行 runtime、LuCI，使用独立输出子目录，并检查两阶段签名公钥一致。

## 组件产物契约与 Artifact 流转

| 文件 | 含义 |
| --- | --- |
| `*.apk` | SDK 生成并签名的软件包 |
| `repository-packages.txt` | 本地仓库实际包名与版本，格式为 `name=version` |
| `install-packages.txt` | 最终固件应安装的包名清单 |
| `install-constraints.txt` | ImageBuilder 安装目标，核心组件使用 `name@custom` |
| `*-public-key.pem` | 对应 SDK 签名公钥，用于 ImageBuilder 安装验签 |
| `SHA256SUMS` | 当前输出目录内 APK 的 SHA256 清单 |
| `BUILD-INFO.txt` | 目标版本 / 架构、上游提交和包版本等组件信息 |
| `kernel-dependency.txt` | FullCone runtime 独有，记录模块的精确 kernel ABI 依赖 |

helloworld 归档为 `openwrt-component-helloworld-${version}-x86_64.tar.gz`，文件直接位于归档根目录。FullCone 归档为 `openwrt-component-fullcone-${version}-x86_64.tar.gz`，内部是 `runtime/`、`luci/` 两个独立目录，避免同名元数据覆盖。

两个组件工作流[上传 Artifacts](../.github/workflows/build-fullcone.yml#L214)，保留 1 天。主工作流通过[当前运行内的 Artifact 名](../.github/workflows/daily-build.yml#L115)下载，检查预期归档和目录结构，再调用装配脚本。组件 APK 校验和及版本一致性由装配脚本再次验证。

安装前会把三个目录的 APK 复制到 ImageBuilder `packages/`，同名 APK 冲突立即失败，导入公钥，配置 `@custom file://.../packages.adb`。解析增量包后，以组件约束替换同名条目，保证组件核心包来自本次本地仓库。

`SHA256SUMS` 当前只覆盖 APK，不覆盖清单、公钥和 BUILD-INFO；这是现有校验的实际范围。组件归档来自同一次 CI 运行，APK 安装阶段另有签名校验。

## 首次默认配置与最终验收

[99-custom-defaults](../files/etc/uci-defaults/99-custom-defaults#L37)集中管理首次启动配置：LAN 为 `192.168.2.1/24`，WAN 为 PPPoE，开启 packet steering / RFS；关闭 WAN6 自启、IPv6 请求 / 委派、设备 IPv6、RA / DHCPv6 / NDP 和 DNS AAAA 应答，同时保留协议栈、包和防火墙规则用于恢复。

防火墙默认启用 IPv4 FullCone、关闭 FullCone6，并执行 `fullcone-check syntax`。Dropbear 使用 LAN 设备绑定和仅公钥认证；系统时区为上海，配置国内 NTP，LuCI 使用中文和 footstrap。关键 UCI 写入失败会退出，启动流程保留此脚本以便下次重试，成功后统一提交并删除。

固件阶段的校验分为两层：

- **Manifest**：要求组件安装包存在，拒绝 naiveproxy；精确比对 FullCone LuCI 包版本，并比较模块 kernel 依赖与固件 kernel。[QGA 包校验](../scripts/build-firmware.sh#L397)另要求 `qemu-ga` 与 `virtio-console-helper`。
- **rootfs**：检查四份 GeoData、LuCI capability 与 FullCone UI、中文 LMO、内核模块、nft ELF / 共享库、FullCone parser 和 fw4 模板。[QGA rootfs 校验](../scripts/build-firmware.sh#L410)要求代理、init、两个 hotplug 脚本非空且可执行，代理为 ELF，init 与仓库维护文件完全一致，并要求 `S99qemu-ga` 链接指向 `../init.d/qemu-ga`。

构建阶段做静态装配验收，不启动生成的固件。FullCone 的运行态、热重启及 LuCI RPC 可由固件内 `fullcone-check status` / `restart` / `luci` 验证；QGA 的实际宿主机通信通过 PVE / libvirt 部署后查询确认。

交付目录 `bin/` 包含带时间戳的压缩 EFI 镜像、镜像 `sha256sums`、包 Manifest、差分报告和三份组件 `*-build-info.txt`。历史 Manifest 通过 Actions cache 保存，下一次构建生成包新增 / 移除 / 版本变化报告。固件 Artifact 保留 30 天；Release 默认关闭，手动选择时发布镜像及相关清单。

## QEMU Guest Agent 的接入依据

QGA 是官方包，可直接加入 `extra-packages.txt`，跟随当前 ImageBuilder 的同版官方源安装。`qemu-ga` 依赖 `virtio-console-helper`，所以不增加第三个组件工厂。[官方软件包定义](https://github.com/openwrt/packages/blob/openwrt-25.12/utils/qemu/Makefile)包含代理二进制、init 和 QGA hotplug 的安装规则。

官方 x86/64 内核配置已包含 `CONFIG_VIRTIO_CONSOLE=y`、`CONFIG_VIRTIO_PCI=y`，所需传输驱动内建，不新增 `kmod-virtio-console`。依据：[官方 x86/64 配置](https://github.com/openwrt/openwrt/blob/openwrt-25.12/target/linux/x86/64/config-6.12)。

官方 init 使用 `START=99` 和 procd，不提供 QGA UCI 配置。[仓库 init 覆盖](../files/etc/init.d/qemu-ga#L12)保留此服务管理方式，并在启动前要求 `/dev/virtio-ports/org.qemu.guest_agent.0` 为字符设备：实体机与未提供通道的虚拟机不会创建持续 respawn 的代理进程。官方 helper 在设备加入时建立命名端口，官方 QGA hotplug 再次调用服务启动，因此仍支持设备稍晚出现的情况。依据：[官方 init](https://github.com/openwrt/packages/blob/openwrt-25.12/utils/qemu/files/qemu-ga.init)、[官方 helper](https://github.com/openwrt/packages/blob/openwrt-25.12/utils/qemu/files/00-virtio-ports.hotplug)、[官方 QGA hotplug](https://github.com/openwrt/packages/blob/openwrt-25.12/utils/qemu/files/10-qemu-ga.hotplug)。

该接入不依赖 `99-custom-defaults`，FullCone 首次检查是否成功不会影响 QGA 的服务启用。宿主机仍需配置对应通道，并通过实际通信验收；详见 [README QGA 部署与验收](../README.md#qemu-guest-agent-部署与验收)。

使用自定义 `FILES_DIR` 时，也需包含与仓库 `files/etc/init.d/qemu-ga` 一致的启动脚本；最终 rootfs 会与项目维护的脚本逐字比较，以确认通道保护确实进入镜像。

## 已知限制与可改进项

以下是仍存在的源码行为，不代表此次 QGA 接入失败，也未在本次修改中扩展为其他代码改动。

| 项目 | 源码证据 | 实际影响 |
| --- | --- | --- |
| `force_rebuild` 输入未使用 | [helloworld workflow 定义](../.github/workflows/build-helloworld.yml#L10)、[无条件编译步骤](../.github/workflows/build-helloworld.yml#L104)；FullCone 对应为 [参数](../.github/workflows/build-fullcone.yml#L10)、[编译](../.github/workflows/build-fullcone.yml#L105) | 输入 true / false 当前都执行编译；缓存没有提供“已有组件就跳过”行为。README 已按实际行为修正。 |
| 接受版本格式不等于支持全部发行系列 | [版本格式检查](../scripts/resolve-version.sh#L35)、[ImageBuilder 归档格式](../scripts/build-firmware.sh#L133)、[APK 本地仓库](../scripts/build-firmware.sh#L232) | 实现按 25.12+ 的 zstd 工具归档、APK / ADB 和内核依赖格式设计；旧版和 snapshot 没有兼容处理。 |
| CI 导出的 SDK 来源字段丢失 | [setup-sdk 只输出路径](../scripts/setup-sdk.sh#L120)、[helloworld 外部 SDK 分支](../components/helloworld-builder/build.sh#L67)、[FullCone 对应分支](../components/fullcone-builder/build.sh#L119) | 官方 SDK 在准备阶段确实检查 SHA256，但组件 BUILD-INFO 的归档 / SHA256 被记成 `external-sdk`，不能直接从交付元数据追溯真实 SDK 归档。 |
| LuCI 对 runtime 元数据路径的假设与 CI 不同 | [CI 输出目录](../.github/workflows/build-fullcone.yml#L109)、[LuCI 读取路径](../components/fullcone-builder/build-luci.sh#L355) | runtime 实际在 `fullcone-component-${version}/runtime`；LuCI 查找 `fullcone-packages-${version}`，正常 CI 退回 donor Git commit，但 `nft-fullcone source commit` 保持 `unknown`。 |
| 镜像缺失没有独立硬校验 | [镜像收集](../scripts/build-firmware.sh#L335)、[SHA256 失败被忽略](../scripts/build-firmware.sh#L351) | 后续要求 Manifest 和 rootfs，却没有明确要求至少一个交付镜像且校验和非空。缺少镜像时，不能仅靠成功结束判断交付完整。 |
| 动态上游不保证位级重现 | [helloworld 分支](../components/helloworld-builder/build.sh#L26)、[ImmortalWrt HEAD](../components/fullcone-builder/build.sh#L62)、[LuCI 稳定分支 HEAD](../components/fullcone-builder/build-luci.sh#L171) | 同一 OpenWrt 版本的不同构建可能获取不同源码；已记录组件 commit，但复现还需要锁定这些输入。 |
| 固件构建参数没有独立元数据文件 | [只导出组件信息](../scripts/build-firmware.sh#L511) | 交付中的三份元数据描述组件，没有统一记录此次固件的分区大小、GRUB 参数、覆盖文件与仓库提交。 |

普通增量包目前也没有统一的逐包 Manifest 硬校验；专门验收覆盖组件和 QGA，不能把通过验收理解为所有可选配置项都经过同等深度检查。

## 验证边界

仓库工作流的主要质量检查嵌入组件构建和固件装配脚本，没有完整虚拟机启动验收 job。QGA 的端口检查、启动请求和 procd 调用可通过本地模拟验证，实际 PVE / KVM 通信仍需部署后的宿主机 `ping` 与接口查询。运行方法、平台前置条件及 ESXi 的工具区别均见 README。
