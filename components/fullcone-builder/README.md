# fullcone-builder 预编译组件

本项目内建组件，负责使用与目标固件版本完全匹配的官方 OpenWrt SDK，源码级重新编译 FullCone 运行时及最小化的 LuCI 防火墙集成。该组件直接由主仓库统一维护，绝不依赖或使用来自 ImmortalWrt 的第三方预编译二进制包或非官方内核 ABI。

## 构建接口规范 (Interface v1)

本组件提供两大独立构建脚本入口，均需要以下必需环境变量：

- `OPENWRT_VERSION`：目标 OpenWrt 发行版本号（例如 `25.12.5`）。
- `WORK_DIR`：与主编排器共享的持久化工作目录（例如 `.work`）。
- `OUTPUT_DIR`：组件产物的输出目录。

可选输入环境变量继承原有默认值：`ARCH`、`SDK_ARCH`、`TARGET_PATH` 与 `JOBS`。

---

## 核心入口与契约

### 1. 运行时组件构建 (`build.sh`)
动态跟随 ImmortalWrt HEAD 提取供体补丁，并在官方 SDK 中重构底层调用链：
- **输出产物**：
  - `kmod-nft-fullcone`（匹配官方内核 ABI 的内核模块）
  - `libnftnl11`（支持 fullcone expression 的底层 netlink 库）
  - `nftables-json`（支持 fullcone 语法的用户态规则解析器）
  - `firewall4`（支持 FullCone 规则注入的防火墙守护脚本与模板）
  - 签名公钥 `fullcone-public-key.pem`、内核 ABI 约束 `kernel-dependency.txt`、元数据清单、`SHA256SUMS` 与 `BUILD-INFO.txt`
- **安全与质量保证**：
  - SDK 依赖闭包检查：读取 `tmp/.packagedeps` 确认 firewall4 到各底层的传递依赖闭包；
  - 单顶层 firewall4 编译调度：通过 GNU make 在单 DAG 中消除内核重复编译；
  - 注入 `PKG_FIXUP:=autoreconf` 确保 netlink 补丁完整生效；
  - 静态提取 elf 符号，严格验证 `nftables` 与 `libnftnl` 中的 fullcone 语法解析器与 expression 证据。

### 2. LuCI 控制台组件构建 (`build-luci.sh`)
动态跟随目标 OpenWrt 版本系列（如 `openwrt-25.12`）的官方 LuCI 最新稳定分支 HEAD：
- **构建机制**：
  - 将 SDK 的 `feeds/luci` 精准更新至该分支最新 commit；
  - 精确应用来自 ImmortalWrt 的最小 FullCone WebUI 补丁与简体中文翻译；
  - 重新编译生成 `luci-base`、`luci-app-firewall` 与 `luci-i18n-firewall-zh-cn`。
- **输出产物**：
  - 3 个核心 LuCI APK；
  - 签名公钥 `luci-fullcone-public-key.pem`（与 runtime 阶段签名私钥一致）；
  - `BUILD-INFO.txt`（严格记录 Target、架构、LuCI 分支、LuCI commit SHA 以及 donor commit）。

---

## 固件装配契约

主固件纯装配流水线会将两阶段产物统一导入签名的 `@custom` 本地仓库，并在打包完成后执行严格的硬核验收（Hard Validation）：
- 检查内核依赖严格与固件内核一致；
- 检查 rootfs 内 `nft_fullcone.ko`、`fw4.uc` 规则模板及 `fullcone-check` 自检工具；
- 校验 LuCI 界面 capability RPC 特性；
- 验证简体中文 PO 翻译编译生成的二进制 `firewall.zh-cn.lmo` 非空生效。
