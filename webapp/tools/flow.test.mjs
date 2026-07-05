// node --test suite for the Mini App flow logic with a mock EIP-1193
// provider + mock fetch (spec §8 "mock EIP-1193 provider flows automated").
// Run: node --test webapp/tools/flow.test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { runPermitFlow } from "../lib/flow.mjs";
import { buildGrantEnvelope } from "../lib/permit.mjs";

const CONFIG = {
  version: "0.1.0",
  chainId: 84532,
  token: "0x000000000000000000000000000000000000aaaa",
  tokenName: "Mock USD Coin",
  tokenVersion: "2",
  router: "0x000000000000000000000000000000000000bbbb",
  intakeUrl: "https://app.example/spend",
  actionLabel: "Open position",
};

const ACCOUNT = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const SIG = "0x" + "11".repeat(32) + "22".repeat(32) + "1b";
const ORDER = { order_ref: "oref-1", amount: 25_000_000, expires_at: 1_900_000_000 };

function mockProvider(overrides = {}) {
  const calls = [];
  return {
    calls,
    request: async ({ method, params }) => {
      calls.push({ method, params });
      if (method in overrides) return overrides[method]({ method, params });
      switch (method) {
        case "eth_requestAccounts":
          return [ACCOUNT];
        case "eth_chainId":
          return "0x14a34"; // 84532
        case "eth_call":
          return "0x" + "0".repeat(64); // nonce 0
        case "eth_signTypedData_v4":
          return SIG;
        default:
          throw new Error(`unmocked ${method}`);
      }
    },
  };
}

function mockFetch(routes) {
  const posts = [];
  const fn = async (url, opts) => {
    const body = JSON.parse(opts.body);
    posts.push({ url, body });
    const route = url.endsWith("/orders") ? routes.orders : routes.grants;
    const { status, json } = route(body);
    return { status, json: async () => json };
  };
  fn.posts = posts;
  return fn;
}

const happyRoutes = {
  orders: () => ({ status: 200, json: ORDER }),
  grants: () => ({ status: 200, json: { status: "submitted", tx: "0xabc" } }),
};

test("happy path: connect → fetch → sign → submit; envelope is EXACTLY the encoder's output", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch(happyRoutes);
  const deps = { provider, fetchFn, config: CONFIG, initData: "id-blob" };

  const result = await runPermitFlow(deps, "oref-1");
  assert.equal(result.ok, true);
  assert.equal(result.status, "submitted");

  const grantPost = fetchFn.posts.find((p) => p.url.endsWith("/grants"));
  assert.ok(grantPost, "grant POSTed");
  assert.equal(grantPost.body.init_data, "id-blob");
  assert.equal(grantPost.body.order_ref, "oref-1");

  const expectedEnvelope = buildGrantEnvelope({
    version: CONFIG.version,
    chainId: CONFIG.chainId,
    token: CONFIG.token,
    spender: CONFIG.router,
    owner: ACCOUNT,
    value: ORDER.amount,
    deadline: ORDER.expires_at,
    signature: SIG,
  });
  assert.deepEqual(grantPost.body.permit, expectedEnvelope);

  // the typed data sent to the wallet binds spender = ROUTER and the order amount
  const signCall = provider.calls.find((c) => c.method === "eth_signTypedData_v4");
  const typed = JSON.parse(signCall.params[1]);
  assert.equal(typed.message.spender, CONFIG.router);
  assert.equal(typed.message.value, String(ORDER.amount));
  assert.equal(typed.domain.verifyingContract, CONFIG.token);
});

test("user rejects the signature → typed failure, NO grant POSTed", async () => {
  const provider = mockProvider({
    eth_signTypedData_v4: () => {
      const e = new Error("rejected");
      e.code = 4001;
      throw e;
    },
  });
  const fetchFn = mockFetch(happyRoutes);
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "user_rejected" });
  assert.equal(fetchFn.posts.filter((p) => p.url.endsWith("/grants")).length, 0);
});

test("order not found → typed failure before any wallet interaction beyond connect", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({ ...happyRoutes, orders: () => ({ status: 404, json: {} }) });
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "gone");
  assert.deepEqual(result, { ok: false, reason: "order_not_found" });
  assert.ok(!provider.calls.some((c) => c.method === "eth_signTypedData_v4"));
});

test("intake version mismatch (stale build) → version_mismatch", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({ ...happyRoutes, grants: () => ({ status: 409, json: {} }) });
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "version_mismatch" });
});

test("wrong chain → typed failure, nothing signed, nothing POSTed", async () => {
  const provider = mockProvider({ eth_chainId: () => "0x1" });
  const fetchFn = mockFetch(happyRoutes);
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.equal(result.ok, false);
  assert.equal(result.reason, "wrong_chain");
  assert.equal(fetchFn.posts.length, 0);
});

test("fetchPermitNonce: eth_call shape is nonces(owner) on the pinned token; nonce + deadline propagate into the typed data", async () => {
  const provider = mockProvider({
    // nonce 5
    eth_call: () => "0x" + "0".repeat(63) + "5",
  });
  const fetchFn = mockFetch(happyRoutes);
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.equal(result.ok, true);

  // (a) the eth_call is nonces(address) against the pinned token
  const call = provider.calls.find((c) => c.method === "eth_call");
  assert.ok(call, "eth_call recorded");
  const [tx, block] = call.params;
  assert.equal(tx.to, CONFIG.token);
  assert.equal(tx.data, "0x7ecebe00" + "0".repeat(24) + ACCOUNT.slice(2).toLowerCase());
  assert.equal(block, "latest");

  // (b) the signed typed data carries the chain nonce and the order deadline
  const signCall = provider.calls.find((c) => c.method === "eth_signTypedData_v4");
  const typed = JSON.parse(signCall.params[1]);
  assert.equal(typed.message.nonce, "5");
  assert.equal(typed.message.deadline, String(ORDER.expires_at));
});

test("wallet returns no accounts → no_account, nothing fetched or signed", async () => {
  const provider = mockProvider({ eth_requestAccounts: () => [] });
  const fetchFn = mockFetch(happyRoutes);
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "no_account" });
  assert.equal(fetchFn.posts.length, 0);
  assert.ok(!provider.calls.some((c) => c.method === "eth_signTypedData_v4"));
});

test("non-4001 signing error → sign_failed (not user_rejected), NO grant POSTed", async () => {
  const provider = mockProvider({
    eth_signTypedData_v4: () => {
      throw new Error("wallet exploded"); // no .code
    },
  });
  const fetchFn = mockFetch(happyRoutes);
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "sign_failed" });
  assert.equal(fetchFn.posts.filter((p) => p.url.endsWith("/grants")).length, 0);
});

test("401 from fetchOrder → unauthorized, nothing signed", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({ ...happyRoutes, orders: () => ({ status: 401, json: {} }) });
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "unauthorized" });
  assert.ok(!provider.calls.some((c) => c.method === "eth_signTypedData_v4"));
});

test("typed keeper failure (expired) surfaces as the reason", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({
    ...happyRoutes,
    grants: () => ({ status: 422, json: { status: "failed", reason: "expired" } }),
  });
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "expired" });
});
