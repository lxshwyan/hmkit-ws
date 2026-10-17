#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="0.1.2"

cd "${PROJECT_DIR}"

grep -Eq '"name"[[:space:]]*:[[:space:]]*"@hmkit/ws"' ws/oh-package.json5
grep -Eq '"name"[[:space:]]*:[[:space:]]*"@hmkit/ws-server"' ws_server/oh-package.json5
grep -Eq '"name"[[:space:]]*:[[:space:]]*"@hmkit/ws-native"' native/package/oh-package.json5
for manifest in oh-package.json5 ws/oh-package.json5 ws_server/oh-package.json5 native/package/oh-package.json5; do
  grep -Eq "\"version\"[[:space:]]*:[[:space:]]*\"${VERSION}\"" "${manifest}" || {
    echo "Version ${VERSION} is missing from ${manifest}." >&2; exit 1;
  }
done
grep -Eq '"@hmkit/ws"[[:space:]]*:[[:space:]]*"@module:ws"' ws_server/oh-package.json5
grep -Eq "\"@hmkit/ws\"[[:space:]]*:[[:space:]]*\"${VERSION}\"" native/package/oh-package.json5
grep -Eq '"@ohos/hypium"[[:space:]]*:[[:space:]]*"1\.0\.29"' oh-package.json5
grep -Eq '"versionName"[[:space:]]*:[[:space:]]*"0\.1\.2"' AppScope/app.json5
grep -Eq '^version = "0\.1\.2"$' native/Cargo.toml

for manifest in ws/oh-package.json5 ws_server/oh-package.json5 native/package/oh-package.json5; do
  grep -Fq '"homepage": "https://github.com/lxshwyan/hmkit-ws"' "${manifest}"
  grep -Fq '"repository": "https://github.com/lxshwyan/hmkit-ws.git"' "${manifest}"
  grep -Fq '"license": "MIT"' "${manifest}"
done

for package_dir in ws ws_server native/package; do
  for required in README.md CHANGELOG.md LICENSE; do
    [[ -s "${package_dir}/${required}" ]] || { echo "Missing ${package_dir}/${required}." >&2; exit 1; }
  done
done

grep -Fq '当前稳定版本 `0.1.2`' README.md
if grep -Fq '当前版本 `0.1.1`' README.md; then
  echo "README still describes 0.1.1 as current." >&2; exit 1
fi

sensitive_pattern='BEGIN (RSA |OPENSSH |EC |ENCRYPTED )?PRIVATE'" KEY"
while IFS= read -r -d '' candidate; do
  [[ "${candidate}" == "scripts/check-public-metadata.sh" ]] && continue
  grep -Iq . "${candidate}" || continue
  if grep -Il -E "${sensitive_pattern}" "${candidate}" >/dev/null; then
    echo "Private key material found in ${candidate}." >&2; exit 1
  fi
done < <(git ls-files --cached --others --exclude-standard -z)

while IFS= read -r script; do bash -n "${script}"; done < <(find scripts native/scripts -type f -name '*.sh' | sort)
echo "Public metadata, version consistency, and static safety checks passed."
