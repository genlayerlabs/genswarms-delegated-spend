// Theme seam, name half: an optional config.productName renders into the
// page <title> and <h1>. Absent (the package default), each page keeps its
// built-in strings — "Fast payments" (index.html), "Opening your wallet..."
// (go.html). Pure + DOM-injected so it runs under node --test.

export function productName(config) {
  if (!config || typeof config.productName !== "string") return null;
  const name = config.productName.trim();
  return name === "" ? null : name;
}

export function applyProductName(doc, config) {
  const name = productName(config);
  if (!name) return;
  doc.title = name;
  const h1 = doc.querySelector("h1");
  if (h1) h1.textContent = name;
}
