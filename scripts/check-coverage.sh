#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORT="${1:-${PROJECT_DIR}/ws/.test/default/outputs/test/reports/coverageReport.json}"
MIN_LINES="${COVERAGE_MIN_LINES:-45}"
MIN_FUNCTIONS="${COVERAGE_MIN_FUNCTIONS:-30}"
MIN_BRANCHES="${COVERAGE_MIN_BRANCHES:-35}"

[[ -f "${REPORT}" ]] || { echo "Coverage report not found: ${REPORT}" >&2; exit 1; }

node - "${REPORT}" "${MIN_LINES}" "${MIN_FUNCTIONS}" "${MIN_BRANCHES}" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const limits = { lines: Number(process.argv[3]), functions: Number(process.argv[4]), branches: Number(process.argv[5]) };
let passed = true;
for (const name of ['lines', 'functions', 'branches']) {
  const actual = report.summary?.[name]?.pct;
  const minimum = limits[name];
  if (!Number.isFinite(actual) || !Number.isFinite(minimum)) {
    console.error(`Invalid coverage value for ${name}.`); passed = false; continue;
  }
  console.log(`${name}: ${actual.toFixed(2)}% (minimum ${minimum.toFixed(2)}%) ${actual >= minimum ? 'PASS' : 'FAIL'}`);
  if (actual < minimum) passed = false;
}
if (!passed) process.exit(1);
NODE
