# OpenWrt x86_64 ImageBuilder 自动化构建项目

基于 OpenWrt 官方 SDK 与 ImageBuilder 的 x86_64 固件自动化构建方案，支持 **GitHub Actions 云端定时/手动构建** 与 **本地 WSL2 / Linux 构建**。

---

## 🌟 核心特性

- **动态拉取最新稳定版**：默认读取 OpenWrt 官方版本元数据并适配最新稳定版本；无法确认版本时立即停止，避免静默回退到旧固件。
- **现代化引导与分区**：采用纯 UEFI (GPT) 引导架构，根分区默认预分配 **2GB (2048 MB)**，输出纯净 Squashfs 镜像。
- **主流虚拟化与硬件就绪**：
  - 兼容 PVE、ESXi、KVM、Hyper-V 及各类 x86 物理机软路由；
  - 预装 `qemu-ga` 与 `open-vm-tools` 来宾集成服务；
  - 集成 Realtek 2.5G (`r8125-rss`) / 万兆 (`r8127-rss`) 网卡驱动与联发科 Wi-Fi 6/6E (`mt7921e` / `mt7922`) 固件。
- **开箱即用中文与实用组件**：
  - 全套 LuCI 简体中文界面，默认启用现代化 `footstrap` 侧边栏主题；
  - SQM CAKE 智能抗缓冲膨胀流控调度；
  - 浏览器免客户端网页终端 `ttyd`；
  - 从 ImmortalWrt HEAD 提取 nftables FullCone NAT 源码与补丁，并在完全同版 OpenWrt SDK 中重新编译完整调用链；
  - 按 fw876/helloworld 官方 CI 流程源码编译 SSR Plus、Xray 与 Mihomo，集成简体中文界面及 GeoIP/GeoSite 数据库；
  - 预设国内权威 NTP 授时服务池（阿里云、腾讯云、国家授时中心）。
- **自动化与差分报告**：
  - 镜像文件名自动附带构建时间戳；
  - 自动比对生成软件包清单差异报告 (`manifest.diff` / `manifest.md`)。

---

## 📁 项目目录结构

```text
.
├── .github/workflows/
│   ├── build.yml                 # 固件纯装配 CI (Assembly-Only，零编译/零SDK)
│   ├── build-helloworld.yml      # helloworld 预编译组件 CI
│   └── build-fullcone.yml        # FullCone 预编译组件 CI
├── config/
│   ├── custom-feeds.conf         # 第三方软件源列表 (支持 ${VERSION_SERIES} 动态分支)
│   └── extra-packages.txt        # 增量软件包清单 (支持行内与独立 # 注释)
├── files/                        # 自定义根文件系统覆盖目录 (打包时自动合入固件)
│   └── etc/uci-defaults/         # 首次开机自动初始化脚本
├── scripts/
│   ├── build-firmware.sh         # 固件纯装配独立流水线 (Assembly-Only)
│   ├── resolve-version.sh        # OpenWrt 官方最新稳定版解析工具
│   ├── diff_manifest.py          # 软件包清单差分比对工具
│   ├── setup-env.sh              # 本地编译依赖检测与自动安装
│   └── setup-sdk.sh              # 组件编译共享 SDK 环境准备工具
├── components/
│   ├── helloworld-builder/       # SSR Plus / Xray / Mihomo 预编译组件
│   └── fullcone-builder/         # FullCone runtime 与 LuCI 预编译组件
├── tests/                        # 契约测试、装配测试与 Rootfs 校验测试
├── Makefile                      # 常用构建命令快捷入口
└── README.md
```

---

## 🚀 快速上手

### 1. 云端构建 (GitHub Actions)
- **定时自动构建**：每天**北京时间中午 12:15**（即 `04:15 UTC`）自动拉取官方最新稳定版完成编译。
- **纯净提交策略**：代码推送 (Push) 不触发构建，避免不必要的 Actions 额度消耗。
- **手动触发构建**：在 GitHub 仓库 **Actions** -> **构建 OpenWrt 固件** 中点击 **Run workflow**：
  - `openwrt_version`: 默认 `latest`（自动拉取官方最新稳定版），亦可指定如 `25.12.5`；
  - `rootfs_partsize`: 默认 `2048` MB (2GB)；
  - `publish_release`: 是否发布到 Releases（默认 `false`，构建产物统一保存在 Artifacts 中保留 30 天）。

### 2. 本地纯装配构建 (Ubuntu / Debian / WSL2)
```bash
# 1. 检查并安装基本依赖
make env

# 2. 执行固件纯装配 (产物输出至 bin/ 目录)
make build

# 常用自定义参数示例:
ROOTFS_PARTSIZE=4096 make build        # 自定义根分区大小为 4GB
OPENWRT_VERSION=25.12.5 make build     # 指定特定版本进行构建
```

项目采用**解耦架构**：
- **组件预编译 CI**：在独立工作流中使用官方 SDK 编译各组件并发布为 GitHub Releases 资产。
- **固件装配 CI / 本地装配**：直接基于已有预编译组件目录或下载 Release 资产，调用官方 ImageBuilder 执行纯装配（无需下载 SDK，零编译，构建时间仅需约 1～3 分钟）。严禁使用 `--force-depends` 绕过内核 ABI。

### 3. 构建产物说明 (`bin/`)
- `openwrt-*-x86-64-generic-squashfs-combined-efi-YYYYMMDD-HHMM.img.gz`：UEFI 引导固件压缩包
- `sha256sums`：SHA256 校验和文件
- `*.manifest`：固件集成软件包完整清单
- `manifest.diff` / `manifest.md`：软件包版本变动差异对比报告
- `helloworld-build-info.txt`：本次 helloworld 源码提交与编译目标元数据记录
- `fullcone-runtime-build-info.txt`：本次 ImmortalWrt donor、nft-fullcone 上游提交、内核 ABI 记录
- `fullcone-luci-build-info.txt`：本次 LuCI 稳定分支 commit 与回溯补丁元数据记录

---

## 💻 默认系统配置与部署说明

| 项目 | 默认值 / 策略说明 |
| :--- | :--- |
| **引导方式** | **UEFI (GPT)**（虚拟机创建时引导类型务必选择 UEFI / OVMF） |
| **管理后台地址** | `http://192.168.2.1`（已调整为 192.168.2.1，彻底避免与上级光猫 192.168.1.1 冲突） |
| **子网掩码** | `255.255.255.0` |
| **管理账号** | `root` |
| **初始密码** | 无密码（首次登录后请在 Web 界面或终端立即设置密码） |
| **IPv6 策略** | 默认关闭 WebUI 中的 WAN6、自启、地址/前缀请求、前缀委派、RA、DHCPv6、NDP 和 AAAA 应答；保留 IPv6 协议栈、软件包、防火墙规则及附属恢复参数，可在 WebUI 恢复 |
| **FullCone NAT** | 默认启用 IPv4 FullCone，IPv6 FullCone 保持关闭；可通过 UCI/LuCI 防火墙配置调整 |
| **SSH 安全机制** | Dropbear 仅绑定 LAN 口监听并默认禁用密码登录，仅允许公钥免密认证 |

恢复 IPv6 时，可在 WebUI 依次重新启用 WAN 的 IPv6 获取、WAN6 接口及地址/前缀请求、LAN 的 IPv6 设备开关与前缀委派，并按需开启 RA、DHCPv6、SLAAC；最后在 DHCP/DNS 页面关闭“过滤 IPv6 AAAA 记录”。

### 快速部署步骤：
1. **解压固件**：将下载的 `.img.gz` 解压得到 `.img` 镜像文件；
2. **虚拟化部署**：在虚拟化平台（PVE / ESXi / KVM / 飞牛 OS 等）中导入为虚拟磁盘（推荐 VirtIO 总线，**引导模式务必设为 UEFI**）；
3. **物理机部署**：使用 Rufus、balenaEtcher 或 `dd` 将解压后的 `.img` 写入 U 盘或目标磁盘；
4. **访问管理**：网线接入设备的 LAN 口，浏览器打开 `http://192.168.2.1` 即可进入管理后台。

---

## ⚙️ 自定义配置指南

- **增减软件包**：编辑 [`config/extra-packages.txt`](config/extra-packages.txt)，每行一个软件包名称，支持使用 `#` 撰写中文注释（构建脚本会自动剥离注释与空行）。
- **SSR Plus 源码构建**：[`components/helloworld-builder/build.sh`](components/helloworld-builder/build.sh) 移植自 [fw876/helloworld 官方 APK CI](https://github.com/fw876/helloworld/blob/dev/.github/workflows/release-packages.yml)。它通过稳定的环境变量输入/输出接口供主编排器调用，动态下载与固件完全同版的官方 SDK，校验 SHA-256，使用 SDK 固定的官方 feeds，再编译官方列表中的 `luci-app-ssr-plus`、`xray-core`、`mihomo`；项目按需求排除了 `naiveproxy`，并从同版 OpenWrt 官方 packages feed 安装 `v2ray-geoip` 与 `v2ray-geosite`。
- **FullCone NAT**：[`components/fullcone-builder/build.sh`](components/fullcone-builder/build.sh) 动态跟随 ImmortalWrt HEAD，只提取 `fullconenat-nft` package 以及 libnftnl、nftables、firewall4 的 FullCone 补丁。所有组件都在与 ImageBuilder 完全相同版本、target、subtarget、architecture 和 kernel ABI 的官方 OpenWrt SDK 中重新编译。
- **FullCone LuCI**：[`components/fullcone-builder/build-luci.sh`](components/fullcone-builder/build-luci.sh) 在官方 OpenWrt LuCI 源码上应用 ImmortalWrt `openwrt-25.12` 的最小功能与简体中文补丁，重新编译 `luci-base`、`luci-app-firewall` 与 `luci-i18n-firewall-zh-cn`。防火墙页面仅在 `nft_fullcone`（或 donor 兼容的 `xt_FULLCONENAT`）模块实际加载时显示 IPv4/IPv6 FullCone 开关。
- **依赖与来源校验**：编译产生的 helloworld 与 FullCone APK 会组成签名的临时本地仓库；SSR Plus、Xray、Mihomo、中文包及 FullCone 四件套通过 `@custom` 标签锁定到本次源码产物。GeoIP/GeoSite 数据包来自同版 OpenWrt 官方源。构建结束后会检查 Manifest 和 GeoData 文件，缺少任一目标、kernel ABI 不一致或出现 `naiveproxy` 都会使构建失败。
- **管理第三方软件源**：在 [`config/custom-feeds.conf`](config/custom-feeds.conf) 中按行添加 APK 源地址，URL 支持 `${VERSION_SERIES}` 占位符自动匹配当前 OpenWrt 主版本系列。
- **自定义首次开机行为**：修改 [`files/etc/uci-defaults/99-custom-defaults`](files/etc/uci-defaults/99-custom-defaults)。该脚本只在固件首次启动时执行，成功后由 OpenWrt 删除，因此之后在 WebUI 中修改 IPv6、FullCone 等配置不会在重启时被重新覆盖。
- **追加自定义系统文件**：将需要预置的文件直接放入 [`files/`](files/) 目录（映射为路由器系统的根路径 `/`），编译时将自动合并进固件中。

---

## 🔄 FullCone 构建与验证

FullCone 仍以官方 OpenWrt 固件为基底，不使用 ImmortalWrt 的预编译 APK 或内核 ABI。构建路径如下：

```text
OpenWrt 官方稳定版版本与校验和
  → 完全同版 x86/64 SDK
  → ImmortalWrt HEAD FullCone package/patch donor
  → SDK 内重新编译 libnftnl11、nftables-json、kmod-nft-fullcone、firewall4
  → 官方 LuCI + 最小 FullCone UI/i18n patch，重新编译 luci-base、luci-app-firewall、luci-i18n-firewall-zh-cn
  → @custom 签名本地 APK 仓库
  → 完全同版 ImageBuilder
  → Manifest、kernel ABI 与最终 rootfs hard validation
```

FullCone 四件套通过一次顶层 `package/feeds/base/firewall4/compile` 调度。构建前会读取 SDK 实际生成的 `tmp/.packagedeps`，确认 firewall4 的传递依赖闭包能够到达 nftables、libnftnl、fullconenat-nft 和 `package/kernel/linux/compile`，以便 GNU make 在同一 DAG 中去重共享的内核编译前置任务。

构建采用 fail-fast，依次验证：

1. donor 补丁与注入官方 package 的目标补丁内容一致；
2. nftables prepared/generated source 包含 FULLCONE token、grammar、lexer、statement、linearize 与 delinearize 路径；
3. `nftables-json` 中 `/usr/sbin/nft` 是 ELF，且 NEEDED 指向实际 `libnftables.so.*`；
4. 实际 `libnftables.so.*` 包含 exact `fullcone` parser 证据，`libnftnl.so.*` 包含 FullCone expression；
5. APK 和最终 rootfs 均包含 `nft_fullcone.ko`、firewall4 运行时探测与 `zone-fullcone.uc`；
6. 最终 Manifest 包含全部四个 FullCone runtime APK 及两个 LuCI APK，且 kmod 的精确 kernel dependency 与固件内核一致；
7. 最终 rootfs 的 LuCI feature RPC 包含 FullCone 模块检测，防火墙页面包含受 capability 控制的 `fullcone` 与 `fullcone6` 开关；
8. 简体中文 PO 的两个 FullCone 翻译经过 `po2lmo` 构建进入自编译 `luci-i18n-firewall-zh-cn`，最终 rootfs 包含非空的 `firewall.zh-cn.lmo`。

`strings` 检查会先把完整输出写入临时文件再匹配，避免在 `set -o pipefail` 下因 `grep -q` 提前退出而产生 SIGPIPE 假阴性。

固件启动后可执行内置验收工具：

```bash
# 验证内核 expression、nft parser、fw4 输出和当前 ruleset
fullcone-check status

# 额外验证 firewall4 重启后仍正常
fullcone-check restart

# 验证 LuCI feature RPC 在模块加载后返回 fullcone=true
fullcone-check luci

# 只验证 nft 与 fw4 生成规则的语法，不要求当前 ruleset 已提交
fullcone-check syntax
```

也可以手工查看关键证据：

```bash
lsmod | grep -i fullcone
nft list ruleset | grep -i fullcone
fw4 print | grep -i fullcone
uci get firewall.@defaults[0].fullcone
```

关闭或重新启用 IPv4 FullCone：

```bash
uci set firewall.@defaults[0].fullcone='0'  # 改为 1 可重新启用
uci commit firewall
/etc/init.d/firewall restart
fullcone-check status
```

---

## ✅ 静态验证

修改构建脚本后可运行：

```bash
bash -n scripts/*.sh components/*/*.sh
shellcheck scripts/*.sh components/*/*.sh
python3 -m unittest discover -s tests -v
git diff --check
```
