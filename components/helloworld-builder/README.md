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

## SSR Plus 运行时兼容修复

源码检出后、SDK feeds 初始化前，构建脚本会精确应用 `patches/` 中的三个补丁：

- 组件更新页使用 `form()` 分发，与 `SimpleForm` 模型保持一致。
- 日志消息作为完整参数传给 BusyBox `logger`，并用 `--` 隔开选项与消息。
- nftables 和 iptables 共用策略路由表检查：不存在的表视为正常状态，其他查询错误和路由添加、删除失败保留诊断并返回失败。

补丁缺失或无法应用时终止构建，不使用模糊匹配或跳过补丁。源码及实际生成的 `luci-app-ssr-plus` APK 都会执行隔离回归检查，CI 使用 BusyBox 验证 shell 和 logger 行为，补丁名称记录到 `BUILD-INFO.txt`。

可对已经应用补丁的源码包目录或解包后的 APK 目录单独运行检查：

```bash
python3 components/helloworld-builder/tests/test-runtime-fixes.py /path/to/helloworld/luci-app-ssr-plus
# 可选：指定 BusyBox 二进制，额外验证真实 logger 对箭头、前导短横线和中文的处理。
BUSYBOX=/path/to/busybox python3 components/helloworld-builder/tests/test-runtime-fixes.py /path/to/extracted-apk
```

这些修复需要重建 helloworld 组件后再装配固件；使用旧组件 APK 重新装配不会获得修复。
