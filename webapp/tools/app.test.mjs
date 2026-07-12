import { test } from "node:test";
import assert from "node:assert/strict";
import { entryRef, paintStatus } from "../app.mjs";

test("entryRef accepts order refs, bind refs, and Telegram start_param", () => {
  assert.equal(entryRef(null, new URLSearchParams("order=o1&token=t")), "o1");
  assert.equal(entryRef(null, new URLSearchParams("bind=b1&token=t")), "b1");
  assert.equal(
    entryRef({ initDataUnsafe: { start_param: "tg-ref" } }, new URLSearchParams("order=o1&bind=b1")),
    "tg-ref"
  );
});

test("paintStatus stamps terminal states and clears the stamp on progress text", () => {
  const el = { textContent: "", dataset: {} };

  paintStatus(el, "Payment failed (x).", "error");
  assert.equal(el.textContent, "Payment failed (x).");
  assert.equal(el.dataset.state, "error");

  paintStatus(el, "Connecting wallet…");
  assert.equal(el.textContent, "Connecting wallet…");
  assert.equal(el.dataset.state, undefined);

  paintStatus(el, "Payment submitted ✓", "success");
  assert.equal(el.dataset.state, "success");
});
