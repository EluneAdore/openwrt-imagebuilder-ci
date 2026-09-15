# nftables FullCone NAT

## Audited baseline

The build resolves `latest` through OpenWrt's official `.versions.json`. On
2026-09-15 this is OpenWrt 25.12.5, tag commit
`f0a60eee2fe051741c643ea6118718aae1ef17fb`, for `x86/64` (`x86_64`). Both the
SDK and ImageBuilder come from that release target directory and are verified
against its `sha256sums`. OpenWrt 25.12 uses APK packages.

OpenWrt 25.12.5 uses Linux 6.12.94, libnftnl 1.3.1, nftables 1.1.6 and firewall4
source commit `b6e5157527d361f99ad52eaa6da273cb0f2dfd59`. Searches of the release source,
its fixed SDK feeds and official ImageBuilder repositories found no
`fullconenat-nft`, `kmod-nft-fullcone`, FullCone nftables expression or fw4 UCI
support.

LEDE master commit `611233e63e3e0aefbb6fbac67252e9c44791a7a9` uses libnftnl 1.3.1 and
nftables 1.1.6, while its x86 target currently defaults to Linux 6.18.52 and
retains a 6.12 compatibility patch set. Its nftables FullCone implementation is
made of:

1. `fullconenat-nft`, which builds `nft_fullcone.ko` from
   `fullcone-nat-nftables/nft-fullcone` commit
   `07d93b626ce5ea885cd16f9ab07fac3213c355d9`;
2. a libnftnl patch that serializes the `fullcone` expression;
3. an nftables patch that parses and emits the expression;
4. a firewall4 patch that reads `fullcone`/`fullcone6`, probes expression support
   and emits prerouting/postrouting rules.

The module's LEDE `001-fix-build.patch` selects the Linux 6.12 form of
`nft_expr_ops.validate`. It was dry-run checked against the OpenWrt 25.12.5 SDK
kernel tree. The libnftnl and nftables patches apply to the same upstream
versions used by OpenWrt 25.12.5. The fw4 patch also applies to the newer
OpenWrt 25.12.5 fw4 source. CI recompiles these four packages instead of
replacing unrelated firewall components.

The BCM NAT1 kernel patches and every iptables/`xt_FULLCONENAT` component are
not part of this port. They belong to different implementations and would
needlessly alter official kernel NAT code.

## Build path and failure policy

`scripts/build-fullcone.sh` performs this path:

1. resolve the exact OpenWrt release, `x86/64` target and SDK archive;
2. verify the SDK SHA-256 and the version recorded inside it;
3. restore the SDK's release-pinned official feeds;
4. inject the reviewed LEDE package and three userspace patches;
5. compile `kmod-nft-fullcone`, `libnftnl11`, `nftables-json` and `firewall4`;
6. inspect the APK contents and record the module's exact `kernel=...` ABI;
7. add the signed APKs to the ImageBuilder local `@custom` repository;
8. force all four packages to come from that repository;
9. let APK enforce dependencies, then compare the module ABI with the final
   Manifest kernel version and inspect the assembled root filesystem.

There is no `--force-depends` path. A download, patch, compile, APK inspection,
dependency, ABI, ImageBuilder, Manifest or root filesystem check aborts the
workflow.

## UCI and runtime acceptance

IPv4 FullCone is enabled once on first boot; IPv6 FullCone stays disabled:

```sh
uci show firewall.@defaults[0] | grep fullcone
fullcone-check restart
lsmod | grep -i fullcone
nft list ruleset | grep -i fullcone
fw4 print | grep -i fullcone
```

Test the disabled path and ordinary masquerade, then restore it:

```sh
uci set firewall.@defaults[0].fullcone='0'
uci commit firewall
/etc/init.d/firewall restart
fullcone-check status
fw4 print | grep -E 'masquerade|fullcone'

uci set firewall.@defaults[0].fullcone='1'
uci commit firewall
fullcone-check restart
```

`fullcone-check` loads the module, asks the kernel to validate temporary
prerouting and postrouting FullCone rules, checks `fw4 print` with `nft --check`,
and confirms that enabled/disabled UCI state changes the generated rules. Its
`restart` mode also validates a real firewall restart and the active ruleset.

LuCI GUI changes are intentionally deferred. LEDE's current GUI implementation
also modifies `luci-base` feature detection and exposes legacy xtables and BCM
NAT1 choices. Rebuilding and replacing `luci-base` solely for one switch is a
larger and less stable change than the UCI interface above.

## Upgrade maintenance

The likely maintenance points are the Linux `nft_expr_ops.validate` signature,
nftables/libnftnl parser structures, fw4 template and UCI parser context, and
the module's exact kernel ABI dependency. The strict patch and artifact checks
make a future incompatible stable OpenWrt release fail before ImageBuilder can
publish a firmware without FullCone.
