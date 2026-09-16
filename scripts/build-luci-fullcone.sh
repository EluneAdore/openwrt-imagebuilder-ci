#!/usr/bin/env bash
set -euo pipefail

# Compatibility entry point. The implementation lives in the in-repository component.
COMPONENT_BUILD="$(cd "$(dirname "${BASH_SOURCE[0]}")/../components/fullcone-builder" && pwd)/build-luci.sh"
[ -x "${COMPONENT_BUILD}" ] || {
    echo "❌ Missing fullcone-builder LuCI component entry point: ${COMPONENT_BUILD}" >&2
    exit 1
}

exec "${COMPONENT_BUILD}" "$@"
