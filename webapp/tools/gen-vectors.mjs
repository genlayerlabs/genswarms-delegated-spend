#!/usr/bin/env node
// Golden-vector generator (spec §8): builds permit typed data with the
// webapp's ACTUAL encoding module, signs it with `cast wallet sign --data`
// (Foundry's independent EIP-712 implementation), and writes
// vectors/permit/*.json. Deterministic: regenerating must be byte-identical
// (CI re-runs this and diffs).
//
// Pinned test-only constants (anvil dev key #1 — public, never real funds):
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildPermitTypedData, buildGrantEnvelope, splitSignature } from "../lib/permit.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const OUT = join(ROOT, "vectors", "permit");
const VERSION = readFileSync(join(ROOT, "VERSION"), "utf8").trim();

const CHAIN_ID = 31337;
const TOKEN = "0x000000000000000000000000000000000000aaaa";
const SPENDER = "0x000000000000000000000000000000000000bbbb";
const OWNER = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"; // anvil #1
const OWNER_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const TOKEN_NAME = "Mock USD Coin";
const TOKEN_VERSION = "2";

const cases = [
  { name: "permit-eoa-1", value: 25_000_000, deadline: 1_900_000_000 },
  { name: "permit-eoa-min", value: 1, deadline: 1_900_000_000 },
  { name: "permit-eoa-large", value: 1_000_000_000_000, deadline: 4_000_000_000 },
];

mkdirSync(OUT, { recursive: true });

for (const c of cases) {
  const typedData = buildPermitTypedData({
    chainId: CHAIN_ID,
    token: TOKEN,
    tokenName: TOKEN_NAME,
    tokenVersion: TOKEN_VERSION,
    owner: OWNER,
    spender: SPENDER,
    value: c.value,
    nonce: 0,
    deadline: c.deadline,
  });

  const signature = execFileSync(
    "cast",
    ["wallet", "sign", "--private-key", OWNER_KEY, "--data", JSON.stringify(typedData)],
    { encoding: "utf8" }
  ).trim();

  const envelope = buildGrantEnvelope({
    version: VERSION,
    chainId: CHAIN_ID,
    token: TOKEN,
    spender: SPENDER,
    owner: OWNER,
    value: c.value,
    deadline: c.deadline,
    signature,
  });

  const vector = {
    version: VERSION,
    account_state: "eoa",
    domain: { name: TOKEN_NAME, version: TOKEN_VERSION, chain_id: CHAIN_ID, token: TOKEN },
    permit: {
      owner: OWNER,
      spender: SPENDER,
      value: c.value,
      nonce: 0,
      deadline: c.deadline,
    },
    signature: { raw: signature, ...splitSignature(signature) },
    envelope,
    typed_data: typedData,
  };

  writeFileSync(join(OUT, `${c.name}.json`), JSON.stringify(vector, null, 2) + "\n");
  console.log(`wrote vectors/permit/${c.name}.json`);
}
