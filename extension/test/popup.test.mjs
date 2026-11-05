// The extension's popup (popup.js) without a browser: the module runs in a
// fake DOM (fake-dom.mjs), the service worker is simulated. We check that
// a state shows at once, that a silent Verrou ends as "can't be reached",
// and that the logins are buttons.
//
//   node --test extension/test/popup.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";

import { createDom, i18n } from "./fake-dom.mjs";
import { eventually, LOGINS, source } from "./page.mjs";

function popupScript(timeouts) {
  const strip = (name) => source(name).replace(/^import .*$/gm, "").replace(/^export /gm, "");
  const popup = strip("popup.js");
  assert.match(popup, /STATUS_TIMEOUT_MS = 3000;/);
  assert.match(popup, /UNLOCK_RETRY_MS = 15_000;/);
  return `(() => { "use strict"; ${strip("browser.js")} ${strip("qr.js")}
    ${popup
      .replace("STATUS_TIMEOUT_MS = 3000;", `STATUS_TIMEOUT_MS = ${timeouts.status};`)
      .replace("UNLOCK_RETRY_MS = 15_000;", `UNLOCK_RETRY_MS = ${timeouts.retry};`)} })()`;
}

function openPopup(handle, { timeout = 100, retry = 15_000 } = {}) {
  const dom = createDom({ origin: "chrome-extension://extension" });
  const { context, document, h } = dom;
  const state = h("span", { id: "state", role: "status" });
  const main = h("main", { id: "main" });
  document.body.append(h("header", {}, state), main);
  const messages = [];
  let closed = false;
  context.chrome = {
    runtime: {
      id: "extension",
      getManifest: () => ({}),
      sendMessage: async (message) => {
        messages.push(message);
        return handle(message);
      },
    },
    i18n,
    storage: {
      session: { get: async () => ({}), remove: async () => {} },
      local: { get: async () => ({}), set: async () => {} },
      onChanged: { addListener: () => {} },
    },
    tabs: { query: async () => [{ url: "https://connect.maif.fr/" }] },
  };
  context.close = () => { closed = true; };
  dom.run(popupScript({ status: timeout, retry }));
  const buttons = () => main.querySelectorAll("button");
  return {
    ...dom,
    state,
    main,
    buttons,
    closed: () => closed,
    sent: (kind) => messages.filter((m) => m.kind === kind),
  };
}

test("the popup's text follows the browser's font size: no size in pixels", () => {
  const css = source("popup.css");
  assert.match(css, /body \{[^}]*font: \.8125rem/);
  assert.deepEqual(css.match(/font(-size)?:\s*[^;]*\d(\.\d+)?px/g), null);
});

test("a state at once; Verrou silent: \"can't be reached\", then its answer", async () => {
  let answer;
  const popup = openPopup((message) => (message.kind === "status"
    ? new Promise((resolve) => { answer = resolve; })
    : { state: "unlocked", items: LOGINS }));
  assert.equal(popup.state.textContent, "Connecting…", "before any answer");
  assert.match(popup.main.textContent, /Connecting to Verrou…/);
  await eventually(() => popup.main.textContent.includes("Verrou can't be reached"), "offline after the timeout");
  assert.equal(popup.state.textContent, "Offline");
  answer({ state: "unlocked" });
  await eventually(() => popup.main.textContent.includes("MAIF pro"), "logins once Verrou answers");
  assert.equal(popup.state.textContent, "Unlocked");
});

test("Verrou answers in time: no \"can't be reached\" on the way", async () => {
  const popup = openPopup((message) => (message.kind === "status" ? { state: "locked" } : {}));
  await eventually(() => popup.main.textContent.includes("Verrou is locked."), "locked");
  await new Promise((resolve) => setTimeout(resolve, 150));
  assert.doesNotMatch(popup.main.textContent, /can't be reached/);
});

test("Verrou locked: the popup asks for the unlock by itself", async () => {
  let unlocked = false;
  let finish;
  const popup = openPopup((message) => {
    if (message.kind === "status") return { state: unlocked ? "unlocked" : "locked" };
    if (message.kind === "suggestTab") return { state: "unlocked", items: LOGINS };
    if (message.kind === "unlock") {
      // The background answers once Verrou reports the vault open.
      return new Promise((resolve) => { finish = () => { unlocked = true; resolve({ ok: true }); }; });
    }
    return {};
  });
  await eventually(() => popup.sent("unlock").length === 1, "unlock asked at once");
  assert.match(popup.main.textContent, /Touch ID or master password/, "the hint while waiting");
  finish();
  await eventually(() => popup.main.textContent.includes("MAIF pro"), "logins once unlocked");
  assert.equal(popup.state.textContent, "Unlocked");
  assert.equal(popup.sent("unlock").length, 1, "once, not on each render");
});

test("Verrou locked, the unlock refused: the button comes back, no new prompt", async () => {
  const popup = openPopup((message) => {
    if (message.kind === "status") return { state: "locked" };
    if (message.kind === "unlock") return { ok: false };
    return {};
  });
  await eventually(() => popup.sent("unlock").length === 1, "first attempt");
  await eventually(() => popup.main.textContent.includes("Unlock Verrou"), "the button back");
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.equal(popup.sent("unlock").length, 1, "nothing by itself after a refusal");
});

test("the ask pending (Verrou never says refused): the button comes back for a retry", async () => {
  const popup = openPopup((message) => {
    if (message.kind === "status") return { state: "locked" };
    // The background waits up to two minutes: a cancelled Touch ID is
    // indistinguishable from one still waiting.
    if (message.kind === "unlock") return new Promise(() => {});
    return {};
  }, { retry: 200 });
  await eventually(() => popup.sent("unlock").length === 1, "asked at once");
  assert.doesNotMatch(popup.main.textContent, /Unlock Verrou/, "no button while the ask is young");
  await eventually(() => popup.main.textContent.includes("Unlock Verrou"), "the button back after the pause");
  popup.fire(popup.buttons()[0], "click");
  await eventually(() => popup.sent("unlock").length === 2, "a click asks again");
});

test("the site's logins are buttons: keyboard and screen reader reach them", async () => {
  const popup = openPopup((message) => {
    if (message.kind === "status") return { state: "unlocked" };
    if (message.kind === "suggestTab") return { state: "unlocked", items: LOGINS };
    if (message.kind === "fillTab") return { ok: true };
    return {};
  });
  await eventually(() => popup.main.textContent.includes("MAIF pro"), "logins");
  const rows = popup.buttons().filter((b) => b.className === "row");
  assert.equal(rows.length, 2);
  for (const row of rows) {
    assert.equal(row.parentNode.tagName, "LI");
    assert.equal(row.type, "button");
  }
  assert.match(rows[1].textContent, /MAIF pro.*dominique@exemple\.fr/);
  rows[1].focus();
  popup.fire(rows[1], "click");
  await eventually(() => popup.closed(), "popup closed after the fill");
  assert.deepEqual(popup.sent("fillTab").map((m) => m.item), ["dominique"]);
});
