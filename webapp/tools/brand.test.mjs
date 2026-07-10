import { test } from "node:test";
import assert from "node:assert/strict";
import { applyProductName, productName } from "../lib/brand.mjs";

test("productName: absent, non-string, or blank config keeps the default", () => {
  assert.equal(productName(undefined), null);
  assert.equal(productName({}), null);
  assert.equal(productName({ productName: 7 }), null);
  assert.equal(productName({ productName: "   " }), null);
  assert.equal(productName({ productName: " Micro Markets " }), "Micro Markets");
});

function fakeDoc() {
  const h1 = { textContent: "Fast payments" };
  return { title: "Fast payments", querySelector: (sel) => (sel === "h1" ? h1 : null), h1 };
}

test("applyProductName renders title + h1 only when configured", () => {
  const untouched = fakeDoc();
  applyProductName(untouched, {});
  assert.equal(untouched.title, "Fast payments");
  assert.equal(untouched.h1.textContent, "Fast payments");

  const branded = fakeDoc();
  applyProductName(branded, { productName: "Micro Markets" });
  assert.equal(branded.title, "Micro Markets");
  assert.equal(branded.h1.textContent, "Micro Markets");
});
