export const DEFAULT_DAPP_LINK_PREFIX = "https://link.metamask.io/dapp/";

export function chooseRoute(userAgent, href, prefix = DEFAULT_DAPP_LINK_PREFIX) {
  const dapp = dappUrl(href);
  if (/Android|iPhone|iPad|iPod/i.test(userAgent || "")) {
    return { mode: "mobile", target: prefix + nestedDapp(dapp, prefix) };
  }
  return { mode: "desktop", target: dapp };
}

/**
 * Desktop hand-off is a same-origin hop to index.html and may navigate
 * programmatically. Mobile MUST NOT: the target is a wallet universal link,
 * and a JS-initiated navigation from an embedded webview (Telegram's in-app
 * browser) carries no user gesture, so iOS hands it to the App Store instead
 * of the installed app. The user's tap on the launch button is the only
 * reliable hand-off — go.html arms the button and waits.
 */
export function shouldAutoNavigate(mode) {
  return mode === "desktop";
}

function dappUrl(href) {
  const u = new URL(href);
  const dir = u.pathname.replace(/[^/]*$/, "");
  return u.origin + dir + "index.html" + u.search;
}

function nestedDapp(dapp, prefix) {
  const noScheme = dapp.replace(/^https?:\/\//, "");
  return prefix.includes("?") ? encodeURIComponent(noScheme) : noScheme;
}
