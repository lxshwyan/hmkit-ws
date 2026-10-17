#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/env.sh"

cd "${PROJECT_DIR}"
"${OHPM}" install --all
"${SCRIPT_DIR}/check-public-metadata.sh"
"${SCRIPT_DIR}/test-local.sh"
"${SCRIPT_DIR}/build-release.sh"
"${SCRIPT_DIR}/check-api-contract.sh"
"${SCRIPT_DIR}/scan-har.sh" ws/build/default/outputs/default/ws.har @hmkit/ws 0.1.2 arkts
"${SCRIPT_DIR}/scan-har.sh" ws_server/build/server/outputs/default/ws_server.har @hmkit/ws-server 0.1.2 arkts
"${SCRIPT_DIR}/scan-har.sh" native/hmkit-ws-native.har @hmkit/ws-native 0.1.2 native

if [[ "${RUN_CONSUMERS:-1}" == "1" ]]; then
  bash "${SCRIPT_DIR}/verify-consumers.sh"
fi
if [[ "${RUN_INTEROP:-0}" == "1" ]]; then
  bash "${SCRIPT_DIR}/test-interop.sh"
fi
if [[ "${RUN_PREPUBLISH:-0}" == "1" ]]; then
  "${OHPM}" prepublish ws/build/default/outputs/default/ws.har
  "${OHPM}" prepublish ws_server/build/server/outputs/default/ws_server.har
  "${OHPM}" prepublish native/hmkit-ws-native.har
fi

echo "@hmkit/ws 0.1.2 verification passed."
