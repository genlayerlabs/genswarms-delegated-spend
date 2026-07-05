#!/usr/bin/env bash
# Deployment attestation (spec §4.4): "audited base" must not silently become
# "audited base, hopefully deployed unmodified."
#
#   scripts/attest.sh <rpc-url> <deployed-address> <ArtifactFile.sol> <ContractName> [contracts-dir]
#   e.g. scripts/attest.sh http://127.0.0.1:8545 0xabc… EchoSpendRouter.sol EchoSpendRouter
#
# 1. Diffs the DEPLOYED runtime bytecode against the local build's
#    deployedBytecode with the artifact's immutableReferences ranges masked —
#    i.e. byte equality modulo constructor-set immutables. Works on ANY chain
#    (no explorer needed). This is the "deployed unmodified" half; the
#    "only its declared selector" half is enforced at build time by the
#    inheritable ABI-pin test over the same artifact.
# 2. Prints the runtime codehash — the value to pin in the consuming app's
#    boot verification (e.g. SPEND_ROUTER_CODEHASH).
# 3. Prints the router's introspection views for operator eyeballing.
set -euo pipefail

RPC="$1"; ADDR="$2"; FILE="$3"; NAME="$4"; DIR="${5:-$(dirname "$0")/../contracts}"

cd "$DIR"
forge build --quiet
ARTIFACT="out/${FILE}/${NAME}.json"
[ -f "$ARTIFACT" ] || { echo "FAIL: missing artifact $ARTIFACT"; exit 1; }

CODE=$(cast code "$ADDR" --rpc-url "$RPC")
if [ "$CODE" = "0x" ]; then echo "FAIL: no code at $ADDR"; exit 1; fi

echo "── runtime bytecode diff (immutables masked) — $NAME @ $ADDR"
ONCHAIN="$CODE" ARTIFACT="$ARTIFACT" python3 - <<'PY'
import json, os, sys

artifact = json.load(open(os.environ["ARTIFACT"]))
local_hex = artifact["deployedBytecode"]["object"].removeprefix("0x")
onchain_hex = os.environ["ONCHAIN"].removeprefix("0x")

local_code = bytearray(bytes.fromhex(local_hex))
onchain = bytearray(bytes.fromhex(onchain_hex))

if len(local_code) != len(onchain):
    sys.exit(f"FAIL: length mismatch (local {len(local_code)} vs on-chain {len(onchain)}) — "
             "different source, compiler, or settings")

for refs in (artifact["deployedBytecode"].get("immutableReferences") or {}).values():
    for ref in refs:
        s, l = ref["start"], ref["length"]
        local_code[s:s+l] = b"\x00" * l
        onchain[s:s+l] = b"\x00" * l

if bytes(local_code) != bytes(onchain):
    diff = sum(1 for a, b in zip(local_code, onchain) if a != b)
    sys.exit(f"FAIL: runtime bytecode differs in {diff} bytes outside immutable slots — "
             "the deployed contract is NOT this source")

print(f"ok: {len(onchain)} bytes identical modulo "
      f"{len(artifact['deployedBytecode'].get('immutableReferences') or {})} immutable refs")
PY

echo "── runtime codehash (pin this in the app's boot verification)"
echo "codehash: $(cast keccak "$CODE")"

echo "── ISpendRouter introspection"
echo "token:             $(cast call "$ADDR" 'token()(address)' --rpc-url "$RPC")"
echo "anchor:            $(cast call "$ADDR" 'anchor()(address)' --rpc-url "$RPC")"
echo "delegationManager: $(cast call "$ADDR" 'delegationManager()(address)' --rpc-url "$RPC")"
echo "routerType:        $(cast call "$ADDR" 'routerType()(bytes32)' --rpc-url "$RPC")"
echo "version:           $(cast call "$ADDR" 'version()(string)' --rpc-url "$RPC")"
echo "attestation OK"
