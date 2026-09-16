#!/usr/bin/env bash
set -euo pipefail

# Compatibility entry point. The implementation lives in the in-repository component.
COMPONENT_BUILD="$(cd "$(dirname "${BASH_SOURCE[0]}")/../components/helloworld-builder" && pwd)/build.sh"
[ -x "${COMPONENT_BUILD}" ] || {
    echo "❌ Missing helloworld-builder component entry point: ${COMPONENT_BUILD}" >&2
    exit 1
}

exec "${COMPONENT_BUILD}" "$@"
