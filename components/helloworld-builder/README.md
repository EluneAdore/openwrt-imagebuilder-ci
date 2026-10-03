# helloworld-builder 预编译组件

本项目内建组件，负责使用与目标固件版本完全一致的 OpenWrt 官方 SDK，从 `fw876/helloworld` 源码构建 SSR Plus 软件包套件。该组件作为主仓库的一等公民维护，无需独立的 Git 仓库。

## 构建接口规范 (Interface v1)

运行 `build.sh` 需要提供以下必需环境变量：

- `OPENWRT_VERSION`：目标 OpenWrt 发行版本号（例如 `25.12.5`）。
- `WORK_DIR`：与主编排器共享的持久化工作目录（例如 `.work`）。
- `OUTPUT_DIR`：组件编译产物的输出目录。

可选输入参数保留默认值：
- `ARCH`：目标架构（默认 `x86-64`）
- `SDK_ARCH`：SDK 工具链架构（默认 `x86_64`）
- `TARGET_PATH`：官方目标路径（默认 `x86/64`）
- `HELLOWORLD_REPOSITORY`：上游源码仓库地址（默认 `https://github.com/fw876/helloworld.git`）
- `HELLOWORLD_REF`：源码分支/标签（默认 `dev`）
- `GO_FEED_BRANCH`：Golang feed 分支（默认 `master`）
- `JOBS`：编译并发线程数（默认 `$(nproc)`）

## 输出产物与集成契约

编译成功后，`OUTPUT_DIR` 将包含以下标准产物：

- 本地源码构建的所有 helloworld 目标 APK（按项目需求排除 `naiveproxy`）：
  - `luci-app-ssr-plus`
  - `luci-i18n-ssr-plus-zh-cn`
  - `xray-core`
  - `mihomo`
  - `dns2tcp`
  - `ipt2socks`
  - `lua-neturl`
- 签名公钥：`helloworld-public-key.pem`
- 软件包清单与安装约束：`repository-packages.txt`、`install-packages.txt`、`install-constraints.txt`
- 完整性与审计元数据：`SHA256SUMS`、`BUILD-INFO.txt`

主固件装配流水线通过读取 `install-constraints.txt` 将上述核心包锁定至本次编译的 `@custom` 本地签名仓库；同时将 `v2ray-geoip` 与 `v2ray-geosite` 作为同版 OpenWrt 官方 packages 源依赖自动拉取安装。
