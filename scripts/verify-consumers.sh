#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE_DIR="${PROJECT_DIR}/external-consumer"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hmkit-ws-consumers.XXXXXX")"
source "${SCRIPT_DIR}/env.sh"
trap 'rm -rf "${TEMP_DIR}"' EXIT

for artifact in \
  ws/build/default/outputs/default/ws.har \
  ws_server/build/server/outputs/default/ws_server.har \
  native/hmkit-ws-native.har; do
  [[ -s "${PROJECT_DIR}/${artifact}" ]] || { echo "Missing ${artifact}." >&2; exit 1; }
done

for scenario in ${CONSUMER_SCENARIOS:-core server native}; do
  consumer="${TEMP_DIR}/${scenario}"
  rsync -a --exclude build --exclude oh_modules --exclude .hvigor --exclude .test \
    "${FIXTURE_DIR}/" "${consumer}/"
  mkdir -p "${consumer}/packages"
  cp "${PROJECT_DIR}/ws/build/default/outputs/default/ws.har" "${consumer}/packages/ws.har"
  cp "${PROJECT_DIR}/ws_server/build/server/outputs/default/ws_server.har" "${consumer}/packages/ws_server.har"
  cp "${PROJECT_DIR}/native/hmkit-ws-native.har" "${consumer}/packages/hmkit-ws-native.har"
  cp "${SCRIPT_DIR}/consumer-${scenario}.ets" "${consumer}/entry/src/main/ets/pages/Index.ets"
  cp "${SCRIPT_DIR}/consumer-${scenario}-oh-package.json5" "${consumer}/entry/oh-package.json5"
  if [[ "${scenario}" == "server" ]]; then
    perl -0pi -e 's/5\.0\.0\(12\)/5.1.1(19)/g' "${consumer}/build-profile.json5"
  fi

  cd "${consumer}"
  "${OHPM}" install --all
  build_log="${consumer}/consumer-build.log"
  bash "${HVIGORW}" assembleHap --mode module -p product=default -p module=entry@default \
    -p buildMode=release --no-daemon 2>&1 | tee "${build_log}"
  if grep -Fq 'src/main/module.json does not exist' "${build_log}"; then
    echo "${scenario} package is missing its merged module manifest." >&2; exit 1
  fi
  hap="${consumer}/entry/build/default/outputs/default/entry-default-unsigned.hap"
  [[ -s "${hap}" ]] || { echo "${scenario} consumer HAP was not produced." >&2; exit 1; }
  echo "${scenario} consumer passed ($(wc -c < "${hap}" | tr -d ' ') bytes)."
done
