# helloworld-builder component

This component builds the SSR Plus package set from `fw876/helloworld` with the
official OpenWrt SDK matching the target firmware. It remains part of the main
repository and does not have its own Git repository.

## Build interface v1

Run `build.sh` with these required environment variables:

- `OPENWRT_VERSION`: OpenWrt release version.
- `WORK_DIR`: persistent workspace shared with the orchestrator.
- `OUTPUT_DIR`: destination for the component output.

Optional inputs retain their existing defaults: `ARCH`, `SDK_ARCH`,
`TARGET_PATH`, `HELLOWORLD_REPOSITORY`, `HELLOWORLD_REF`, `GO_FEED_BRANCH`, and
`JOBS`.

On success, `OUTPUT_DIR` contains the unchanged integration contract:

- all locally built helloworld APKs, excluding `naiveproxy`;
- `helloworld-public-key.pem`;
- `repository-packages.txt`, `install-packages.txt`, and
  `install-constraints.txt`;
- `SHA256SUMS` and `BUILD-INFO.txt`.

The orchestrator consumes `install-constraints.txt` to require the local APKs
from its `@custom` repository. `v2ray-geoip` and `v2ray-geosite` remain listed
as official-package installation constraints.
