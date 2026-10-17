#!/usr/bin/env bash

set -euo pipefail

HAR="$1"
EXPECTED_NAME="$2"
EXPECTED_VERSION="${3:-0.1.2}"
KIND="${4:-arkts}"

[[ -s "${HAR}" ]] || { echo "HAR not found: ${HAR}" >&2; exit 1; }
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hmkit-ws-har.XXXXXX")"
trap 'rm -rf "${TEMP_DIR}"' EXIT
tar -xzf "${HAR}" -C "${TEMP_DIR}"

if grep -R -n -E 'BEGIN (RSA |OPENSSH |EC |ENCRYPTED )?PRIVATE KEY|publish_id|key_path|OHPM_KEY_PASSPHRASE' "${TEMP_DIR}"; then
  echo "Sensitive publishing material found in ${HAR}." >&2; exit 1
fi

node - "${TEMP_DIR}/package/oh-package.json5" "${EXPECTED_NAME}" "${EXPECTED_VERSION}" "${KIND}" <<'NODE'
const fs = require('fs');
const [metaPath, expectedName, expectedVersion, kind] = process.argv.slice(2);
const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
const fail = message => { console.error(message); process.exit(1); };
if (meta.name !== expectedName) fail(`Expected ${expectedName}, found ${meta.name}.`);
if (meta.version !== expectedVersion) fail(`Expected ${expectedVersion}, found ${meta.version}.`);
if (meta.license !== 'MIT' || !meta.homepage || !meta.repository || !meta.author?.url) fail('Public package metadata is incomplete.');
if (kind === 'arkts' && (meta.obfuscated !== true || meta.metadata?.debug !== false)) fail('ArkTS HAR is not release/obfuscated.');
if (expectedName !== '@hmkit/ws' && meta.dependencies?.['@hmkit/ws'] !== expectedVersion) fail('Core dependency is not pinned to the release version.');
NODE

for required in package/README.md package/CHANGELOG.md package/LICENSE; do
  [[ -s "${TEMP_DIR}/${required}" ]] || { echo "Missing ${required} in ${HAR}." >&2; exit 1; }
done

if [[ "${KIND}" == "native" ]]; then
  [[ -s "${TEMP_DIR}/package/index.d.ets" && -s "${TEMP_DIR}/package/NativeTransport.d.ets" ]] || {
    echo "Native ArkTS declarations are incomplete." >&2; exit 1;
  }
  for abi in arm64-v8a armeabi-v7a x86_64; do
    [[ -s "${TEMP_DIR}/package/libs/${abi}/libhmkit_ws_native.so" ]] || {
      echo "Missing native ABI ${abi}." >&2; exit 1;
    }
  done
fi

echo "HAR security and metadata checks passed: ${EXPECTED_NAME}@${EXPECTED_VERSION}."
