#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/env.sh"
cd "${PROJECT_DIR}"

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hmkit-ws-build.XXXXXX")"
trap 'rm -rf "${LOG_DIR}"' EXIT

bash "${HVIGORW}" clean --no-daemon

build_har() {
  local label="$1"
  shift
  local log="${LOG_DIR}/${label}.log"
  "${HVIGORW}" "$@" 2>&1 | tee "${log}"
  if grep -Fq 'Function may throw exceptions. Special handling is required.' "${log}"; then
    echo "Unhandled ArkTS exception warning found while building ${label}." >&2
    exit 1
  fi
}

build_har core assembleHar --mode module -p module=ws@default -p product=default -p buildMode=release --no-daemon
build_har server assembleHar --mode module -p module=ws_server@default -p product=server -p buildMode=release --no-daemon

if [[ "${BUILD_NATIVE:-1}" == "1" ]]; then
  bash "${PROJECT_DIR}/native/scripts/build.sh"
fi

CORE_HAR="${PROJECT_DIR}/ws/build/default/outputs/default/ws.har"
SERVER_HAR="${PROJECT_DIR}/ws_server/build/server/outputs/default/ws_server.har"
NATIVE_HAR="${PROJECT_DIR}/native/hmkit-ws-native.har"

[[ -s "${CORE_HAR}" ]] || { echo "Missing core HAR: ${CORE_HAR}" >&2; exit 1; }
[[ -s "${SERVER_HAR}" ]] || { echo "Missing server HAR: ${SERVER_HAR}" >&2; exit 1; }
if [[ "${BUILD_NATIVE:-1}" == "1" ]]; then
  [[ -s "${NATIVE_HAR}" ]] || { echo "Missing native HAR: ${NATIVE_HAR}" >&2; exit 1; }
fi

echo "Release artifacts verified:"
echo "${CORE_HAR}"
echo "${SERVER_HAR}"
if [[ "${BUILD_NATIVE:-1}" == "1" ]]; then
  echo "${NATIVE_HAR}"
fi
