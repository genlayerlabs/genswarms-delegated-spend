// DOM glue for the permit-lane Mini App. All decision logic lives in
// lib/flow.mjs (tested headlessly); this file only wires Telegram WebApp
// boot, the injected EIP-1193 provider, and the two DOM elements.

import { connectWallet, fetchOrder, fetchPermitNonce, signAndSubmit } from "./lib/flow.mjs";

const $ = (id) => document.getElementById(id);

const MESSAGES = {
  order_not_found: "This payment link expired or was already used. Go back to the chat and tap again.",
  unauthorized: "Could not verify your Telegram session. Reopen this page from the chat button.",
  version_mismatch: "This page is outdated. Close and reopen it from the chat.",
  user_rejected: "Signature declined — nothing was paid.",
  wrong_chain: "Your wallet is on the wrong network for this payment.",
  no_account: "No wallet account connected.",
  expired: "This order expired. Go back to the chat and tap again.",
};

async function main() {
  const tg = globalThis.Telegram && globalThis.Telegram.WebApp;
  const initData = tg ? tg.initData : "";
  const params = new URLSearchParams(location.search);
  const orderRef = (tg && tg.initDataUnsafe && tg.initDataUnsafe.start_param) || params.get("order");

  const config = await (await fetch("./config.json")).json();
  const provider = globalThis.ethereum;

  if (!provider) {
    $("summary").textContent =
      "No wallet detected in this browser. Open this page inside your wallet's browser, or use the transfer option in chat.";
    return;
  }

  const deps = { provider, fetchFn: fetch.bind(globalThis), config, initData };

  const fetched = await fetchOrder(deps, orderRef);
  if (!fetched.ok) {
    $("summary").textContent = MESSAGES[fetched.reason] || `Could not load the order (${fetched.reason}).`;
    return;
  }

  const amount = (fetched.order.amount / 1_000_000).toFixed(2);
  $("summary").textContent = `${config.actionLabel}: ${amount} USDC (gasless — the operator pays network fees).`;
  $("pay").disabled = false;

  $("pay").onclick = async () => {
    $("pay").disabled = true;
    $("status").textContent = "Connecting wallet…";

    const conn = await connectWallet(deps);
    if (!conn.ok || conn.chainId !== config.chainId) {
      $("status").textContent = MESSAGES[conn.ok ? "wrong_chain" : conn.reason];
      $("pay").disabled = false;
      return;
    }

    $("status").textContent = "Waiting for your signature…";
    const nonce = await fetchPermitNonce(deps, conn.account);

    const result = await signAndSubmit(deps, {
      orderRef,
      order: fetched.order,
      account: conn.account,
      nonce,
    });

    if (result.ok) {
      $("status").textContent = "Payment submitted ✓ — you can return to the chat.";
      if (tg) setTimeout(() => tg.close(), 1500);
    } else {
      $("status").textContent = MESSAGES[result.reason] || `Payment failed (${result.reason}). The transfer option in chat still works.`;
      $("pay").disabled = false;
    }
  };
}

main();
