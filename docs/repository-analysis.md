# openwrt-imagebuilder-ci 仓库分析

分析日期：2026-10-09。本文依据仓库源码梳理构建行为，文件行号对应本次修改后的源码；后续改动可能使行号移动。QEMU Guest Agent 的包、驱动和服务行为另依据文中链接的官方来源核实。

## 项目定位与架构

这是一个面向 OpenWrt 官方发行版 `x86/64`、`generic` profile 的固件装配工程。第三方组件使用目标版本的官方 SDK 编译；固件阶段使用官方 ImageBuilder 安装这些组件和官方软件包，并合入 `files/`。仓库不维护 OpenWrt 内核源码或独立完整发行版。

默认镜像是 squashfs 根文件系统、UEFI GPT 引导的 `combined-efi.img.gz`，根分区 2048 MB，GRUB 等待 0 秒。[构建参数](../scripts/build-firmware.sh#L47)允许调整版本、profile、分区和输出路径，但下载地址、rootfs 定位、产物路径仍按 `x86/64` 编写，不能仅修改 `ARCH` 就当作通用多架构构建器。

```mermaid
flowchart TD
    trigger["定时 / 手动"] --> resolve["解析并锁定 OpenWrt 版本"]
    resolve --> hw["官方同版 SDK：helloworld"]
    resolve --> fc["官方同版 SDK：FullCone runtime → LuCI"]
    hw --> hwr["独立 helloworld 软件源 Release 快照"]
    hw --> hwa["当前运行的 helloworld Artifact"]
    fc --> fcr["独立 FullCone 软件源 Release 快照"]
    fc --> fca["当前运行的 FullCone Artifact"]
    hwa --> assembly["官方 ImageBuilder 纯装配"]
    fca --> assembly
    official["同版官方 APK 源：LuCI / 驱动 / QGA / 依赖"] --> assembly
    overlay["files/：默认配置 / QGA init / FullCone 诊断"] --> assembly
    assembly --> validation["Manifest / ABI / rootfs 验收"]
    validation --> regression["同版 APK 工具运行软件源回归"]
    regression --> output["固件 Artifact，保留 30 天"]
    regression --> release["手动选择发布固件 Release"]
    hwr --> deployed["部署后的 APK 安装 / 更新"]
    fcr --> deployed
    output --> deployed
```

主工作流等待两个组件构建、验收及软件源快照发布成功后才运行装配。组件通过**同一次 Actions 运行中的 Artifacts**传递；软件源 Release 提供部署后的长期下载地址，固件装配不查询历史 Release 来选择组件，不回退到旧版组件，也不在固件 job 内下载 SDK 或编译组件。

## 目录职责与构建入口

| 位置 | 职责 |
| --- | --- |
| `.github/workflows/daily-build.yml` | 统一版本解析、并行组件构建、下载本次组件、装配、差分缓存与固件发布 |
| `.github/workflows/build-helloworld.yml` | helloworld 组件独立手动 / 可复用构建、软件源快照发布与 Artifact 上传 |
| `.github/workflows/build-fullcone.yml` | FullCone runtime 和 LuCI 两阶段构建、验收、软件源快照发布与 Artifact 上传 |
| `components/helloworld-builder/` | SSR Plus / Xray / Mihomo 源码构建及输出契约 |
| `components/fullcone-builder/` | FullCone runtime、LuCI 补丁和构建依赖检查工具 |
| `scripts/resolve-version.sh` | 探测最新稳定版，或验证指定版本号格式 |
| `scripts/setup-sdk.sh` | 官方 SDK 下载、SHA256 校验、解包和可选签名密钥注入 |
| `scripts/build-firmware.sh` | 预编译组件 / 发布源验收、ImageBuilder 配置、运行时源覆盖、镜像生成和最终验收 |
| `scripts/prepare-component-feed.sh` | 生成签名 ADB 索引、APK 身份约束、运行时 URL 和完整 SHA256 清单 |
| `scripts/publish-component-feed.sh` | 创建 draft Release，上传 APK / 索引 / 公钥后公开独立软件源快照 |
| `scripts/runtime-custom-feed.sh` | 验证固定公开索引并生成源 / 公钥覆盖文件；检查最终 world，在 rootfs 副本中更新源和模拟普通包安装 |
| `scripts/configure-imagebuilder-apk.py` | 调整本地 ImageBuilder 的 `FormatPackages`，完整传递带摘要的 APK 身份约束，保留普通包版本与 ABI 后缀逻辑 |
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

主工作流的 firmware job 在装配脚本成功后，指定同版 ImageBuilder 的 APK 工具运行 `python3 -m unittest discover -s tests -v` 软件源回归。随后才生成发布元数据、上传固件 Artifact，并按 `publish_release` 开关决定是否发布固件 Release。

### 本地入口

`make env` 准备宿主机依赖。`make build` 调用装配脚本，并尝试从 `.work/` 找到已有组件目录；它不会生成组件或下载 CI Artifact。[Makefile 的目录选择](../Makefile#L35)使用首个匹配路径，多版本缓存共存时应显式设置 `HELLOWORLD_COMPONENT_DIR`、`FULLCONE_RUNTIME_DIR` 和 `FULLCONE_LUCI_DIR`。

全新检出需先从修复后的同版组件 CI 下载并解压归档，再指定对应的 `OPENWRT_VERSION` 进行装配。手动运行组件构建脚本时，还需要调用软件源准备和发布脚本，获得真实公开的快照 URL；只有 APK 的旧归档不再满足装配契约。组件版本不一致、缺少源元数据或发布索引内容不一致都会被前置校验拒绝。具体命令见 [README 本地构建步骤](../README.md#2-本地纯装配构建-ubuntu--debian--wsl2)。

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

输出包含 helloworld feed 产生的 APK、签名公钥、清单与安装约束。软件源准备阶段给核心 `@custom` 目标附加索引中的 APK 身份约束，以区分官方同名同版本包；`v2ray-geoip` 和 `v2ray-geosite` 使用同版官方源。[helloworld CI 验收](../.github/workflows/build-helloworld.yml#L117)还要求 `dns2tcp`、`ipt2socks` 和 `lua-neturl` 出现在仓库清单中。

### FullCone runtime

[runtime 构建器](../components/fullcone-builder/build.sh#L62)每次克隆 ImmortalWrt HEAD，提取 `fullconenat-nft` 模块和 libnftnl / nftables / firewall4 的供体补丁，记录 donor commit、模块源码 commit 和 mirror hash。

它在官方 SDK 的包定义基础上注入补丁、必要的 `autoreconf` 和 `firewall4 → kmod-nft-fullcone` 依赖，不替换官方内核。供体 firewall 默认配置修改被剥离，默认开关由本仓库管理。

[依赖检查与构建调度](../components/fullcone-builder/build.sh#L317)读取 SDK 实际生成的 `tmp/.packagedeps`，要求 firewall4 可传递到 nftables、FullCone 模块和 kernel/linux，nftables 可传递到 libnftnl。之后一次顶层 firewall4 编译覆盖整个调用链，避免独立并行命令重复调度内核前置目标。

输出四个 APK：`kmod-nft-fullcone`、`libnftnl11`、`nftables-json`、`firewall4`。验收不仅检查包名，还检查 FullCone 生成源码、`nft` 的 ELF 与动态链接、实际承载 parser 的 `libnftables.so`、libnftnl expression、fw4 模板和模块文件。模块 APK 的精确 kernel 依赖单独导出供固件验收。

### FullCone LuCI

[LuCI 构建器](../components/fullcone-builder/build-luci.sh#L157)从 SDK 解析官方 LuCI 仓库，并使用目标系列 `openwrt-X.Y` 稳定分支的最新 commit。官方 Git 服务不可达时可使用官方 GitHub 镜像。

三个本地补丁使用 `--fuzz=0` 精确重放：增加 RPC capability、IPv4 / IPv6 FullCone UI 和中文翻译。上游结构不匹配时失败，不跳过补丁。重新编译后输出 `luci-base`、`luci-app-firewall`、`luci-i18n-firewall-zh-cn`，再解包检查 RPC、UI 和非空中文 LMO 文件。

[FullCone CI](../.github/workflows/build-fullcone.yml#L105)在同一 SDK 中顺序运行 runtime、LuCI，使用独立输出子目录，并检查两阶段签名公钥一致。

## 组件产物契约、软件源发布与 Artifact 流转

| 文件 | 含义 |
| --- | --- |
| `*.apk` | SDK 生成并签名的软件包 |
| `repository-packages.txt` | 本地仓库实际包名与版本，格式为 `name=version` |
| `install-packages.txt` | 最终固件应安装的包名清单 |
| `install-constraints.txt` | ImageBuilder 安装目标，核心组件使用 `@custom` 并固定 APK 身份，防止同名同版本官方包替代 |
| `*-public-key.pem` | 对应 SDK 签名公钥，用于 ImageBuilder 与运行时的软件源 / APK 验签 |
| `SHA256SUMS` | 软件源准备后覆盖 APK、索引、URL、公钥、构建信息及安装 / 仓库清单的 SHA256 清单 |
| `*-packages.adb` | 已签名的 helloworld、FullCone runtime 或 LuCI 软件源索引，三者分别命名 |
| `runtime-repository.url` | 当前组件已发布快照中的 HTTPS 索引 URL，每个组件目录独立保存 |
| `BUILD-INFO.txt` | 目标版本 / 架构、上游提交和包版本等组件信息 |
| `kernel-dependency.txt` | FullCone runtime 独有，记录模块的精确 kernel ABI 依赖 |

helloworld 归档为 `openwrt-component-helloworld-${version}-x86_64.tar.gz`，文件直接位于归档根目录。FullCone 归档为 `openwrt-component-fullcone-${version}-x86_64.tar.gz`，内部是 `runtime/`、`luci/` 两个独立目录，避免同名元数据覆盖。

两个组件工作流在原有 Hard Validation 后调用软件源准备脚本，使用 SDK 的 `apk` 生成并签名索引，再追加 `@custom` 目标的 APK 身份约束。hash pin 取自生成的索引，保护 FullCone / LuCI 与官方同名同版本包之间的差别；不得仅用普通版本号代替。软件源 URL、安装约束及所有关键元数据统一加入 SHA256 清单。

发布标签分别为 `custom-helloworld-${version}-x86_64-${run_id}-${run_attempt}` 和 `custom-fullcone-${version}-x86_64-${run_id}-${run_attempt}`。同一次 FullCone 发布包含独立 runtime 和 LuCI 索引。发布脚本要求公开仓库和写权限，先创建 draft Release 并上传全部 APK、签名索引和公钥，再核对服务端资产名称和大小后公开；相同标签不能覆盖，发布不改变 Latest Release。重跑组件 job 会按新的尝试次数发布快照，同时 Artifact 上传设置 `overwrite: true` 以替换本次运行中原有同名中转归档。只重跑固件 job 可以复用同次运行中已成功的组件快照和未过期 Artifact，helloworld 与 FullCone 的尝试次数无需相同。

组件源发布成功后才[上传 Artifacts](../.github/workflows/build-fullcone.yml)，保留 1 天。主工作流通过[当前运行内的 Artifact 名](../.github/workflows/daily-build.yml)下载，检查预期归档、子目录、运行时 URL 和签名索引，再调用装配脚本。软件源 Release 不受 Artifact 保留期影响；Artifacts 只用于当前流水线的组件交接。

安装前会把三个目录的 APK 复制到 ImageBuilder `packages/`，同名 APK 冲突立即失败，导入公钥，配置构建期 `@custom file://.../packages.adb`。解析增量包后，以组件约束替换同名条目，保证组件核心包来自本次本地仓库。`runtime-custom-feed.sh stage` 同时下载三个公开索引，逐字节比对归档中的索引，并验证签名；不存在、未发布或内容不一致的 URL 会阻止构建。FullCone runtime 与 LuCI 还必须引用同一快照。

身份约束格式为 `name@custom><Q1...=`，摘要取自 ADB 索引条目的身份，而非 APK 文件的普通 SHA256。官方 ImageBuilder 的 `FormatPackages` 会按 `=` 拆分包版本，未加引号的 `><` 也会被 shell 当作重定向。[装配前的兼容处理](../scripts/build-firmware.sh#L165)调用 `configure-imagebuilder-apk.py`，仅对这种身份约束保留完整参数并加 shell 引号，普通版本约束和 ABI 后缀继续采用原逻辑。修改可重复执行；上游 `FormatPackages` 结构无法识别时会停止装配。

运行时覆盖文件为 `/etc/apk/repositories.d/custom-components.list`，包含三条 `@custom` HTTPS 索引地址，对应公钥一并进入 `/etc/apk/keys/`。[生成覆盖文件](../scripts/build-firmware.sh#L168)时先复制项目 `FILES_DIR` 到临时目录，再写入当前快照配置，由 `make image` 合入镜像。固件保留安装时的 world 标签和 APK 身份约束，运行时存在与之对应的真实仓库，因此添加官方普通包时不会再因缺失 `@custom` 标签而拒绝事务。

[最终运行时源验收](../scripts/build-firmware.sh#L524)调用 `runtime-custom-feed.sh verify`，逐字节检查 rootfs 中的源配置、公钥，并核对定制 world 身份约束集合。随后在 rootfs 副本和独立缓存中执行 `apk update` 与 `apk add --no-scripts --simulate coremark`，要求事务成功且不替换定制组件；待交付 rootfs 不被修改。这是宿主机上的求解器检查，不启动固件。

组件签名无需必填额外 secret：默认使用 SDK 生成密钥，并把每个快照对应的公钥固定在固件中。`CUSTOM_SIGNING_KEY` 仍可选，用于希望多个构建采用同一签名身份的场景。运行时不需要 GitHub token，公开 Release 可以直接下载索引和 APK。

## 首次默认配置与最终验收

[99-custom-defaults](../files/etc/uci-defaults/99-custom-defaults#L37)集中管理首次启动配置：LAN 为 `192.168.2.1/24`，WAN 为 PPPoE，开启 packet steering / RFS；关闭 WAN6 自启、IPv6 请求 / 委派、设备 IPv6、RA / DHCPv6 / NDP 和 DNS AAAA 应答，同时保留协议栈、包和防火墙规则用于恢复。

防火墙默认启用 IPv4 FullCone、关闭 FullCone6，并执行 `fullcone-check syntax`。Dropbear 使用 LAN 设备绑定和仅公钥认证；系统时区为上海，配置国内 NTP，LuCI 使用中文和 footstrap。关键 UCI 写入失败会退出，启动流程保留此脚本以便下次重试，成功后统一提交并删除。

固件阶段的校验分为两层：

- **Manifest**：要求组件安装包存在，拒绝 naiveproxy；精确比对 FullCone LuCI 包版本，并比较模块 kernel 依赖与固件 kernel。[QGA 包校验](../scripts/build-firmware.sh#L410)另要求 `qemu-ga` 与 `virtio-console-helper`。
- **rootfs**：检查四份 GeoData、LuCI capability 与 FullCone UI、中文 LMO、内核模块、nft ELF / 共享库、FullCone parser 和 fw4 模板。[QGA rootfs 校验](../scripts/build-firmware.sh#L423)要求代理、init、两个 hotplug 脚本非空且可执行，代理为 ELF，init 与仓库维护文件完全一致，并要求 `S99qemu-ga` 链接指向 `../init.d/qemu-ga`。定制源验收另检查 HTTPS 地址、公钥、world 身份，并在副本中验证普通包安装事务。

构建阶段做静态装配验收，不启动生成的固件。FullCone 的运行态、热重启及 LuCI RPC 可由固件内 `fullcone-check status` / `restart` / `luci` 验证；QGA 的实际宿主机通信通过 PVE / libvirt 部署后查询确认。

交付目录 `bin/` 包含带时间戳的压缩 EFI 镜像、镜像 `sha256sums`、包 Manifest、差分报告和三份组件 `*-build-info.txt`。历史 Manifest 通过 Actions cache 保存，下一次构建生成包新增 / 移除 / 版本变化报告。固件 Artifact 保留 30 天；固件 Release 默认关闭，手动选择时发布镜像及相关清单。组件软件源 Release 始终发布，`publish_release: false` 不关闭运行时的软件源发布。

## QEMU Guest Agent 的接入依据

QGA 是官方包，可直接加入 `extra-packages.txt`，跟随当前 ImageBuilder 的同版官方源安装。`qemu-ga` 依赖 `virtio-console-helper`，所以不增加第三个组件工厂。[官方软件包定义](https://github.com/openwrt/packages/blob/openwrt-25.12/utils/qemu/Makefile)包含代理二进制、init 和 QGA hotplug 的安装规则。

官方 x86/64 内核配置已包含 `CONFIG_VIRTIO_CONSOLE=y`、`CONFIG_VIRTIO_PCI=y`，所需传输驱动内建，不新增 `kmod-virtio-console`。依据：[官方 x86/64 配置](https://github.com/openwrt/openwrt/blob/openwrt-25.12/target/linux/x86/64/config-6.12)。

官方 init 使用 `START=99` 和 procd，不提供 QGA UCI 配置。[仓库 init 覆盖](../files/etc/init.d/qemu-ga#L12)保留此服务管理方式，并在启动前要求 `/dev/virtio-ports/org.qemu.guest_agent.0` 为字符设备：实体机与未提供通道的虚拟机不会创建持续 respawn 的代理进程。官方 helper 在设备加入时建立命名端口，官方 QGA hotplug 再次调用服务启动，因此仍支持设备稍晚出现的情况。依据：[官方 init](https://github.com/openwrt/packages/blob/openwrt-25.12/utils/qemu/files/qemu-ga.init)、[官方 helper](https://github.com/openwrt/packages/blob/openwrt-25.12/utils/qemu/files/00-virtio-ports.hotplug)、[官方 QGA hotplug](https://github.com/openwrt/packages/blob/openwrt-25.12/utils/qemu/files/10-qemu-ga.hotplug)。

该接入不依赖 `99-custom-defaults`，FullCone 首次检查是否成功不会影响 QGA 的服务启用。宿主机仍需配置对应通道，并通过实际通信验收；详见 [README QGA 部署与验收](../README.md#qemu-guest-agent-部署与验收)。

使用自定义 `FILES_DIR` 时，也需包含与仓库 `files/etc/init.d/qemu-ga` 一致的启动脚本；最终 rootfs 会与项目维护的脚本逐字比较，以确认通道保护确实进入镜像。

## 软件源首次部署与旧固件恢复

这次代码改动不代表公网资产已经存在。首次生效需要在公开仓库运行完整主工作流；组件 job 成功公开对应的 Release 后，固件 job 才能构建带有真实 URL、公钥和身份约束的新镜像。独立组件工作流也会公开其快照，但不会替已有固件修改配置。

GitHub Release 资产没有 Actions Artifact 的自动到期限制，长期可用依赖于保留仓库、tag、Release 及资产。仍有固件使用的组件快照不得删除、覆盖或更改 URL；仓库改名、转为私有也会影响下载。旧固件若手动修复，需恢复与其已安装 APK 完全匹配的原始组件索引、公钥及内核 ABI，不能直接指向任意新快照。推荐部署修复后完整构建的固件。

首次部署后可运行 `apk update` 与 `apk add --simulate coremark` 验证索引访问和普通包事务。构建时的下载验证与模拟安装没有取代设备网络连通性检查；路由器仍需能够访问 GitHub Release 及 OpenWrt 官方软件源。

## 已知限制与可改进项

以下是当前仍存在的源码行为与验证限制。

| 项目 | 源码证据 | 实际影响 |
| --- | --- | --- |
| `force_rebuild` 输入未使用 | [helloworld workflow 定义](../.github/workflows/build-helloworld.yml#L10)、[无条件编译步骤](../.github/workflows/build-helloworld.yml#L104)；FullCone 对应为 [参数](../.github/workflows/build-fullcone.yml#L10)、[编译](../.github/workflows/build-fullcone.yml#L105) | 输入 true / false 当前都执行编译；缓存没有提供“已有组件就跳过”行为。README 已按实际行为修正。 |
| 接受版本格式不等于支持全部发行系列 | [版本格式检查](../scripts/resolve-version.sh#L35)、[ImageBuilder 归档格式](../scripts/build-firmware.sh#L133)、[APK 本地仓库](../scripts/build-firmware.sh#L246) | 实现按 25.12+ 的 zstd 工具归档、APK / ADB 和内核依赖格式设计；旧版和 snapshot 没有兼容处理。 |
| CI 导出的 SDK 来源字段丢失 | [setup-sdk 只输出路径](../scripts/setup-sdk.sh#L120)、[helloworld 外部 SDK 分支](../components/helloworld-builder/build.sh#L67)、[FullCone 对应分支](../components/fullcone-builder/build.sh#L119) | 官方 SDK 在准备阶段确实检查 SHA256，但组件 BUILD-INFO 的归档 / SHA256 被记成 `external-sdk`，不能直接从交付元数据追溯真实 SDK 归档。 |
| LuCI 对 runtime 元数据路径的假设与 CI 不同 | [CI 输出目录](../.github/workflows/build-fullcone.yml#L109)、[LuCI 读取路径](../components/fullcone-builder/build-luci.sh#L355) | runtime 实际在 `fullcone-component-${version}/runtime`；LuCI 查找 `fullcone-packages-${version}`，正常 CI 退回 donor Git commit，但 `nft-fullcone source commit` 保持 `unknown`。 |
| 镜像缺失没有独立硬校验 | [镜像收集](../scripts/build-firmware.sh#L341)、[SHA256 失败被忽略](../scripts/build-firmware.sh#L363) | 后续要求 Manifest 和 rootfs，却没有明确要求至少一个交付镜像且校验和非空。缺少镜像时，不能仅靠成功结束判断交付完整。 |
| 动态上游不保证位级重现 | [helloworld 分支](../components/helloworld-builder/build.sh#L26)、[ImmortalWrt HEAD](../components/fullcone-builder/build.sh#L62)、[LuCI 稳定分支 HEAD](../components/fullcone-builder/build-luci.sh#L171) | 同一 OpenWrt 版本的不同构建可能获取不同源码；已记录组件 commit，但复现还需要锁定这些输入。 |
| 固件构建参数没有独立元数据文件 | [只导出组件信息](../scripts/build-firmware.sh#L529) | 交付中的三份元数据描述组件，没有统一记录此次固件的分区大小、GRUB 参数、覆盖文件与仓库提交。 |

普通增量包目前也没有统一的逐包 Manifest 硬校验；专门验收覆盖组件和 QGA，不能把通过验收理解为所有可选配置项都经过同等深度检查。

## 验证边界

本次 `@custom` 修复的本地回归位于 [tests/test_custom_feed.py](../tests/test_custom_feed.py)，33 项全部通过，使用真实 OpenWrt ImageBuilder APK v3 工具和临时签名密钥，覆盖以下范围：

- 三类组件的签名索引、正确的 APK 身份约束和完整 SHA256 覆盖，以及错误密钥、篡改 APK、缺失包、错版 / 错架构的拒绝行为。
- 官方源与定制源存在同名同版本、不同内容 APK 时，普通包安装和升级保持定制身份；移除 `@custom` 源可重现原始 `missing repository tag` 故障。
- 从实际 ImageBuilder Makefile 提取 `FormatPackages` 并执行 GNU make，确认完整身份约束、普通版本约束及 ABI 后缀正确传入程序，兼容修改可重复执行，未知格式会失败。
- `runtime-custom-feed.sh` 的三条源配置、公钥、world 和 rootfs 副本模拟安装；HTTPS 下载通过本地文件映射，签名和 APK 求解使用真实工具。检查错误索引、缺失元数据覆盖、错误公钥或身份被拒绝，并确认原 rootfs 不被修改。
- 发布流程使用本地 `gh` 替身，检查 draft → 全部资产上传 / 核验 → publish、`latest=false`、FullCone 两索引同快照，以及重复 tag、私有仓库、认证错误、上传失败或资产缺失时的阻断行为。

运行命令为：

```bash
python3 -m unittest discover -s tests -v
```

测试默认查找 `.work/` 中的 OpenWrt SDK / ImageBuilder APK v3 工具，也可通过 `CUSTOM_FEED_APK` 指定路径。真实 APK 测试需要该工具及 `openssl`；ImageBuilder 参数测试需要已解压的官方 Makefile 和 GNU make。缺少这些前置条件会跳过相关测试，不能将跳过视为通过。

本地签名、求解器和流程回归尚未完成真实 GitHub Release 发布，也没有代替完整组件编译和完整固件构建。首次上线仍需在公开仓库执行 CI，确认全部组件快照可匿名下载、最终镜像生成并通过运行时源验收，再部署到设备检查实际 `apk update` / 普通包安装。代码修改和本地测试通过均不代表公网源已经存在。

仓库工作流的主要质量检查嵌入组件构建和固件装配脚本，没有完整虚拟机启动验收 job。QGA 的端口检查、启动请求和 procd 调用可通过本地模拟验证，实际 PVE / KVM 通信仍需部署后的宿主机 `ping` 与接口查询。运行方法、平台前置条件及 ESXi 的工具区别均见 README。
