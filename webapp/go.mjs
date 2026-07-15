import { applyProductName } from "./lib/brand.mjs";
import { chooseRoute, DEFAULT_DAPP_LINK_PREFIX, shouldAutoNavigate } from "./lib/launch.mjs";

const config = await fetch("./config.json").then((r) => r.json()).catch(() => ({}));
applyProductName(document, config);
const route = chooseRoute(navigator.userAgent, location.href, config.dappLinkPrefix || DEFAULT_DAPP_LINK_PREFIX);

document.getElementById("open").href = route.target;

// Mobile stays tap-only (see shouldAutoNavigate): an auto-navigation to the
// wallet universal link from Telegram's in-app browser carries no user
// gesture and lands on the App Store, not the installed wallet.
if (shouldAutoNavigate(route.mode)) location.replace(route.target);
