# FullCone source provenance

The files in this directory were reviewed and copied from
[`coolsnowwolf/lede`](https://github.com/coolsnowwolf/lede) master commit
`611233e63e3e0aefbb6fbac67252e9c44791a7a9` (2026-09-15).

| Local path | LEDE source path | Upstream implementation |
| --- | --- | --- |
| `package/fullconenat-nft/Makefile` and `patches/001-fix-build.patch` | `package/network/services/fullconenat-nft/` | `fullcone-nat-nftables/nft-fullcone` commit `07d93b626ce5ea885cd16f9ab07fac3213c355d9` |
| `patches/libnftnl/001-*.patch` | `package/libs/libnftnl/patches/001-*.patch` | FullCone netlink expression encoding |
| `patches/nftables/100-*.patch` | `package/network/utils/nftables/patches/100-*.patch` | `fullcone` parser, linearizer and delinearizer |
| `patches/firewall4/001-*.patch` | `package/network/config/firewall4/patches/001-*.patch` | UCI parsing, capability probe and fw4 templates |

The last LEDE commits touching the copied content are
`89e46be1869f842509a6013e1a8f16c335fb149f` for `fullconenat-nft`,
`771e27b030950401034beb92d2e6d638f0868201` for the libnftnl and firewall4
patches, and `5e4be536f87fb3faf9d44d0d6c98f5c85adbbedf` for the nftables 1.1.6
refresh. The `From` identifiers retained inside the three patch files preserve
their original patch provenance as well.

The firewall4 patch omits LEDE's changes to `/etc/config/firewall`. This project
sets only `fullcone=1` and `fullcone6=0` in its existing one-time
`99-custom-defaults` script, avoiding LEDE's unrelated flow-offload defaults.

LEDE's `target/linux/generic/hack-*/982-add-bcm-fullconenat-support.patch` and
`983-add-bcm-fullconenat-to-nft.patch` are deliberately excluded. They implement
the separate Broadcom NAT1 masquerade method and are not required by the
`nft_fullcone` expression module used here. The iptables `fullconenat` package,
`xt_FULLCONENAT`, firewall3 patches and iptables patches are excluded as well.
