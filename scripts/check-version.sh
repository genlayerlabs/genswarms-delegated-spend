#!/usr/bin/env bash
# Co-versioning check (spec §3.1): one version, stamped everywhere, CI-fails on
# divergence. Later plans extend this with the gsp manifest and webapp stamps.
set -euo pipefail
cd "$(dirname "$0")/.."

v="$(cat VERSION)"

grep -q "return \"${v}\";" contracts/src/SpendRouter.sol \
  || { echo "FAIL: SpendRouter.version() literal != ${v}"; exit 1; }

[ "$(cat vectors/VERSION)" = "${v}" ] \
  || { echo "FAIL: vectors/VERSION != ${v}"; exit 1; }

grep -q "version: \"${v}\"" mix.exs \
  || { echo "FAIL: mix.exs version != ${v}"; exit 1; }

grep -q "\"version\": \"${v}\"" webapp/config.json \
  || { echo "FAIL: webapp/config.json version != ${v}"; exit 1; }

echo "version stamp OK: ${v}"
