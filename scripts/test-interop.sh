#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INTEROP_DIR="${PROJECT_DIR}/interoperability"

cd "${INTEROP_DIR}"
npm install --ignore-scripts
docker compose up -d --wait

cleanup() {
  docker compose down --volumes --remove-orphans
}
trap cleanup EXIT

npm test
