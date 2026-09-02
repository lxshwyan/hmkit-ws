#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_DIR="$(cd "${NATIVE_DIR}/.." && pwd)"
OHOS_NDK_HOME="${OHOS_NDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony}"
OHRS_BIN="${OHRS_BIN:-${PROJECT_DIR}/.tools/ohrs/bin/ohrs}"

if [[ ! -x "${OHRS_BIN}" ]]; then
  if command -v ohrs >/dev/null 2>&1; then
    OHRS_BIN="$(command -v ohrs)"
  else
    echo "ohrs not found. Install with: cargo install ohrs --root ${PROJECT_DIR}/.tools/ohrs --locked" >&2
    exit 1
  fi
fi

export OHOS_NDK_HOME
cd "${NATIVE_DIR}"
NATIVE_ARCHES="${NATIVE_ARCHES:-arm64 arm x86_64}"
read -r -a ARCH_VALUES <<< "${NATIVE_ARCHES}"
ARCH_ARGS=()
for arch in "${ARCH_VALUES[@]}"; do ARCH_ARGS+=(--arch "${arch}"); done
"${OHRS_BIN}" build --release "${ARCH_ARGS[@]}" --dist "${NATIVE_DIR}/dist"
"${OHRS_BIN}" artifact --no-workspace --name hmkit-ws-native --dist "${NATIVE_DIR}/dist"
