// Mini App permit-lane flow (spec §6.3 steps 2–4), DOM-free and
// dependency-injected so it runs identically under the browser glue
// (app.mjs) and the node --test mock-provider suite.
//
// deps: { provider (EIP-1193), fetchFn, config, initData }
// config: { version, chainId, token, tokenName, tokenVersion, router,
//           intakeUrl, actionLabel }
//
// Every failure is a TYPED state — the chat card's transfer-lane fallback is
// the product-side answer to all of them; the Mini App only reports.

import { buildPermitTypedData, buildGrantEnvelope } from "./permit.mjs";

export async function connectWallet({ provider }) {
  const accounts = await provider.request({ method: "eth_requestAccounts" });
  if (!accounts || accounts.length === 0) return { ok: false, reason: "no_account" };
  const chainHex = await provider.request({ method: "eth_chainId" });
  return { ok: true, account: accounts[0], chainId: parseInt(chainHex, 16) };
}

export async function fetchOrder({ fetchFn, config, initData }, orderRef) {
  const res = await fetchFn(`${config.intakeUrl}/orders`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ init_data: initData, order_ref: orderRef }),
  });
  if (res.status === 404) return { ok: false, reason: "order_not_found" };
  if (res.status === 401) return { ok: false, reason: "unauthorized" };
  if (res.status !== 200) return { ok: false, reason: `http_${res.status}` };
  return { ok: true, order: await res.json() };
}

/** Read the token nonce for the owner straight from the chain (eth_call). */
export async function fetchPermitNonce({ provider, config }, owner) {
  // nonces(address) selector 0x7ecebe00
  const data = "0x7ecebe00" + owner.replace(/^0x/, "").toLowerCase().padStart(64, "0");
  const result = await provider.request({
    method: "eth_call",
    params: [{ to: config.token, data }, "latest"],
  });
  return parseInt(result, 16);
}

export async function signAndSubmit(deps, { orderRef, order, account, nonce }) {
  const { provider, fetchFn, config, initData } = deps;

  const typedData = buildPermitTypedData({
    chainId: config.chainId,
    token: config.token,
    tokenName: config.tokenName,
    tokenVersion: config.tokenVersion,
    owner: account,
    spender: config.router,
    value: order.amount,
    nonce,
    deadline: order.expires_at,
  });

  let signature;
  try {
    signature = await provider.request({
      method: "eth_signTypedData_v4",
      params: [account, JSON.stringify(typedData)],
    });
  } catch (e) {
    if (e && e.code === 4001) return { ok: false, reason: "user_rejected" };
    return { ok: false, reason: "sign_failed" };
  }

  const envelope = buildGrantEnvelope({
    version: config.version,
    chainId: config.chainId,
    token: config.token,
    spender: config.router,
    owner: account,
    value: order.amount,
    deadline: order.expires_at,
    signature,
  });

  const res = await fetchFn(`${config.intakeUrl}/grants`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ init_data: initData, order_ref: orderRef, permit: envelope }),
  });

  if (res.status === 409) return { ok: false, reason: "version_mismatch" };
  if (res.status === 401) return { ok: false, reason: "unauthorized" };
  const body = await res.json();
  if (res.status !== 200) return { ok: false, reason: body.reason || body.error || `http_${res.status}` };
  return { ok: true, status: body.status, tx: body.tx };
}

/** The whole §6.3 handshake: connect → fetch order → sign → submit. */
export async function runPermitFlow(deps, orderRef) {
  const conn = await connectWallet(deps);
  if (!conn.ok) return conn;
  if (conn.chainId !== deps.config.chainId)
    return { ok: false, reason: "wrong_chain", expected: deps.config.chainId };

  const fetched = await fetchOrder(deps, orderRef);
  if (!fetched.ok) return fetched;

  const nonce = await fetchPermitNonce(deps, conn.account);

  return signAndSubmit(deps, {
    orderRef,
    order: fetched.order,
    account: conn.account,
    nonce,
  });
}
