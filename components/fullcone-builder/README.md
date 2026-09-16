# fullcone-builder component

This in-repository component rebuilds the FullCone runtime and its minimal LuCI
integration with the official OpenWrt SDK that matches the firmware. It has no
separate Git repository and does not consume prebuilt packages from
ImmortalWrt.

## Build interface v1

Both entry points require these environment variables:

- `OPENWRT_VERSION`: OpenWrt release version.
- `WORK_DIR`: persistent workspace shared with the orchestrator.
- `OUTPUT_DIR`: destination for the entry point's component output.

Optional inputs retain their prior defaults: `ARCH`, `SDK_ARCH`, `TARGET_PATH`,
and `JOBS`.

`build.sh` tracks ImmortalWrt HEAD and produces the unchanged runtime contract:

- `kmod-nft-fullcone`, `libnftnl11`, `nftables-json`, and `firewall4` APKs;
- `fullcone-public-key.pem`, `kernel-dependency.txt`, package/install metadata,
  `SHA256SUMS`, and `BUILD-INFO.txt`.

It retains the SDK dependency-closure check, one-top-level-firewall4 build DAG,
autoreconf injection, donor checks, prepared/generated parser validation, and
APK runtime evidence validation.

`build-luci.sh` tracks the latest official LuCI stable feed revision for the
target OpenWrt release series (`openwrt-${VERSION_SERIES}`), updates the SDK's
`feeds/luci` to that revision, precisely reapplies FullCone patches with strict
fail-fast validation, and compiles `luci-base`, `luci-app-firewall`, and
`luci-i18n-firewall-zh-cn`. It produces:

- `luci-base`, `luci-app-firewall`, and `luci-i18n-firewall-zh-cn` APKs;
- `luci-fullcone-public-key.pem`, package/install metadata, `SHA256SUMS`, and
  `BUILD-INFO.txt` (recording Target, Subtarget, Arch, LuCI repository, LuCI ref,
  LuCI commit SHA, and donor commit).

The main orchestrator imports both outputs into `@custom` and retains firmware,
manifest, kernel ABI, exact LuCI package version matching, and final rootfs
validation.
