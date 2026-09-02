#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/env.sh"
cd "${PROJECT_DIR}"

"${HVIGORW}" assembleHar --mode module -p module=ws@default -p product=default -p buildMode=release
"${HVIGORW}" assembleHar --mode module -p module=ws_server@default -p product=server -p buildMode=release

if [[ "${BUILD_NATIVE:-1}" == "1" ]]; then
  "${PROJECT_DIR}/native/scripts/build.sh"
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
