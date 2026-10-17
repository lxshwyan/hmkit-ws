#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

check_contract() {
  local artifact="$1"
  local contract="$2"
  shift 2
  [[ -s "${artifact}" ]] || { echo "Artifact not found: ${artifact}" >&2; exit 1; }
  local public_api=''
  local entry
  for entry in "$@"; do
    public_api+="$(tar -xOzf "${artifact}" "${entry}")"
    public_api+=$'\n'
  done
  while IFS= read -r symbol; do
    [[ -z "${symbol}" || "${symbol}" == \#* ]] && continue
    grep -Eq "(^|[^[:alnum:]_])${symbol}([^[:alnum:]_]|$)" <<<"${public_api}" || {
      echo "Public API contract missing ${symbol} in ${artifact}." >&2; exit 1;
    }
  done < "${contract}"
  echo "API contract passed for $(basename "${artifact}") ($(grep -cvE '^[[:space:]]*(#|$)' "${contract}") symbols)."
}

check_contract "${PROJECT_DIR}/ws/build/default/outputs/default/ws.har" \
  "${SCRIPT_DIR}/api-contract-core.txt" package/Index.d.ets
check_contract "${PROJECT_DIR}/ws_server/build/server/outputs/default/ws_server.har" \
  "${SCRIPT_DIR}/api-contract-server.txt" package/Index.d.ets
check_contract "${PROJECT_DIR}/native/hmkit-ws-native.har" \
  "${SCRIPT_DIR}/api-contract-native.txt" package/index.d.ets package/NativeTransport.d.ets package/libs/index.d.ts
