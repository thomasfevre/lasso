// Authenticated native-messaging Relay client. Initial pairing derives a shared
// key with ephemeral ECDH after native user approval. On reconnect the Conductor
// must prove that key before this extension returns any DOM data, and the
// extension proves it without ever sending the key itself.

import { isInjectableUrl } from "./injectable-url.mjs";

const NATIVE_HOST = "xyz.allez.lasso.host";
const RECONNECT_MS = 3000;

let port = null;
let relayState = "disconnected";
let sessionNonce = null;
let activeCredential = null;
let pendingPairing = null;

function extensionOrigin() {
  return chrome.runtime.getURL("").replace(/\/$/, "");
}

async function storedCredential() {
  const { relayCredential, relayToken } = await chrome.storage.local.get([
    "relayCredential",
    "relayToken",
  ]);
  // Bearer tokens from the old protocol are deliberately not migrated.
  if (relayToken) await chrome.storage.local.remove("relayToken");
  if (!relayCredential?.id || !relayCredential?.key) return null;
  if (relayCredential.expiresAt && relayCredential.expiresAt <= Date.now()) {
    await chrome.storage.local.remove("relayCredential");
    return null;
  }
  return relayCredential;
}

async function storeCredential(credential) {
  await chrome.storage.local.set({ relayCredential: credential });
}

async function injectIntoOpenTabs() {
  try {
    const tabs = await chrome.tabs.query({});
    const injectableTabs = tabs.filter((tab) => tab.id != null && isInjectableUrl(tab.url));
    await Promise.allSettled(
      injectableTabs.map((tab) =>
        chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] }),
      ),
    );
  } catch {
    // Injection is best-effort; normal navigation still loads content.js.
  }
}

function ensureConnected() {
  if (port) return;
  connect();
}

function connect() {
  let connection;
  try {
    connection = chrome.runtime.connectNative(NATIVE_HOST);
  } catch {
    setTimeout(ensureConnected, RECONNECT_MS);
    return;
  }
  port = connection;
  relayState = "connecting";
  sessionNonce = null;
  activeCredential = null;
  pendingPairing = null;

  connection.onMessage.addListener((message) => {
    if (port === connection) void onMessage(message);
  });

  connection.onDisconnect.addListener(() => {
    if (port !== connection) return;
    port = null;
    relayState = "disconnected";
    sessionNonce = null;
    activeCredential = null;
    pendingPairing = null;
    setTimeout(ensureConnected, RECONNECT_MS);
  });

  void (async () => {
    if (port !== connection) return;
    const credential = await storedCredential();
    if (credential) {
      activeCredential = credential;
      relayState = "identifying";
      send({ type: "identify", origin: extensionOrigin(), credentialId: credential.id });
    } else {
      await beginPairing();
    }
  })();
}

async function beginPairing() {
  const clientNonce = randomNonce();
  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"],
  );
  const publicKey = await crypto.subtle.exportKey("raw", keyPair.publicKey);
  pendingPairing = { clientNonce, privateKey: keyPair.privateKey };
  relayState = "pairing";
  send({
    type: "pair",
    origin: extensionOrigin(),
    clientNonce,
    clientPublicKey: base64URL(new Uint8Array(publicKey)),
  });
}

function send(object) {
  if (!port) return;
  try {
    port.postMessage(object);
  } catch {
    port.disconnect();
  }
}

// Defense-in-depth: the only writer to this port is lasso-relay-host forwarding
// Conductor's already-validated UDS protocol, but bound recursive processing of
// any inbound object anyway rather than trusting the upstream chain implicitly.
function validJSONDepth(value, depth = 0) {
  if (depth > 8) return false;
  if (value === null || typeof value !== "object") return true;
  const children = Array.isArray(value) ? value : Object.values(value);
  return children.every((child) => validJSONDepth(child, depth + 1));
}

async function onMessage(message) {
  if (message === null || typeof message !== "object" || !validJSONDepth(message)) {
    return port?.disconnect();
  }
  switch (message.type) {
    case "paired":
      if (relayState !== "pairing") return port?.disconnect();
      await finishPairing(message);
      break;
    case "challenge":
      if (relayState !== "identifying") return port?.disconnect();
      await answerChallenge(message);
      break;
    case "authenticated":
      if (relayState !== "authenticating") return port?.disconnect();
      await finishAuthentication(message);
      break;
    case "resolve":
      if (relayState !== "authenticated" || message.sessionNonce !== sessionNonce) {
        return port?.disconnect();
      }
      await handleResolve(message);
      break;
    case "pong":
      if (relayState !== "authenticated") port?.disconnect();
      break;
    case "rejected":
      if (["invalidCredential", "expiredCredential"].includes(message.reason)) {
        await chrome.storage.local.remove("relayCredential");
      }
      port?.disconnect();
      break;
    default:
      port?.disconnect();
  }
}

async function finishPairing(message) {
  const pairing = pendingPairing;
  if (
    !pairing ||
    typeof message.credentialId !== "string" ||
    typeof message.serverNonce !== "string" ||
    typeof message.serverPublicKey !== "string"
  ) {
    port?.disconnect();
    return;
  }
  try {
    const serverPublicKey = await crypto.subtle.importKey(
      "raw",
      fromBase64URL(message.serverPublicKey),
      { name: "ECDH", namedCurve: "P-256" },
      false,
      [],
    );
    const sharedSecret = await crypto.subtle.deriveBits(
      { name: "ECDH", public: serverPublicKey },
      pairing.privateKey,
      256,
    );
    const hkdfKey = await crypto.subtle.importKey("raw", sharedSecret, "HKDF", false, ["deriveBits"]);
    const info = `lasso-pair-v1|${message.credentialId}|${pairing.clientNonce}`;
    const derived = await crypto.subtle.deriveBits(
      {
        name: "HKDF",
        hash: "SHA-256",
        salt: new TextEncoder().encode(message.serverNonce),
        info: new TextEncoder().encode(info),
      },
      hkdfKey,
      256,
    );
    activeCredential = {
      id: message.credentialId,
      key: base64URL(new Uint8Array(derived)),
      expiresAt: message.expiresAt,
    };
    await storeCredential(activeCredential);
    pendingPairing = null;
    relayState = "identifying";
    send({ type: "identify", origin: extensionOrigin(), credentialId: activeCredential.id });
  } catch {
    port?.disconnect();
  }
}

async function answerChallenge(message) {
  if (
    !activeCredential ||
    message.credentialId !== activeCredential.id ||
    typeof message.serverNonce !== "string" ||
    typeof message.sessionNonce !== "string" ||
    !Array.isArray(message.serverProofs)
  ) {
    port?.disconnect();
    return;
  }
  const key = await importHMACKey(activeCredential.key);
  const serverTranscript = `lasso-server-v1|${activeCredential.id}|${message.serverNonce}|${message.sessionNonce}`;
  const expected = new Uint8Array(await hmac(key, serverTranscript));
  const serverAuthenticated = message.serverProofs.some((proof) => {
    try {
      return timingSafeEqual(expected, fromBase64URL(proof));
    } catch {
      return false;
    }
  });
  // Nothing sensitive or command-capable is sent until the server proves the
  // credential. An untrusted UDS peer learns only the public id/origin.
  if (!serverAuthenticated) {
    port?.disconnect();
    return;
  }

  const clientNonce = randomNonce();
  const clientTranscript = `lasso-client-v1|${activeCredential.id}|${message.serverNonce}|${message.sessionNonce}|${clientNonce}`;
  const proof = new Uint8Array(await hmac(key, clientTranscript));
  sessionNonce = message.sessionNonce;
  relayState = "authenticating";
  send({
    type: "authenticate",
    credentialId: activeCredential.id,
    sessionNonce,
    clientNonce,
    proof: base64URL(proof),
  });
}

async function finishAuthentication(message) {
  if (
    !activeCredential ||
    message.sessionNonce !== sessionNonce ||
    typeof message.rotationNonce !== "string"
  ) {
    port?.disconnect();
    return;
  }
  const key = await importHMACKey(activeCredential.key);
  const rotated = new Uint8Array(
    await hmac(key, `lasso-rotate-v1|${activeCredential.id}|${message.rotationNonce}`),
  );
  activeCredential = {
    id: activeCredential.id,
    key: base64URL(rotated),
    expiresAt: message.expiresAt,
  };
  await storeCredential(activeCredential);
  relayState = "authenticated";
  await injectIntoOpenTabs();
}

async function handleResolve(message) {
  const fingerprint = await resolveInGesturedWindow(message.bbox);
  send({ type: "fingerprint", id: message.id, sessionNonce, fingerprint });
}

// Chrome does not expose a complete window z-order. Use the focused flag first,
// then getLastFocused to break overlaps. If neither establishes a unique target,
// return null so Conductor takes its OCR fallback rather than fingerprinting the
// wrong tab.
async function resolveInGesturedWindow(bbox) {
  try {
    const centerX = bbox.x + bbox.width / 2;
    const centerY = bbox.y + bbox.height / 2;
    const windows = await chrome.windows.getAll({ populate: true, windowTypes: ["normal"] });
    const containing = windows.filter(
      (w) =>
        w.left != null &&
        w.top != null &&
        w.width != null &&
        w.height != null &&
        centerX >= w.left &&
        centerX <= w.left + w.width &&
        centerY >= w.top &&
        centerY <= w.top + w.height,
    );
    let target = containing.length === 1 ? containing[0] : null;
    if (containing.length > 1) {
      const focused = containing.filter((w) => w.focused);
      if (focused.length === 1) {
        target = focused[0];
      } else {
        const lastFocused = await chrome.windows.getLastFocused({
          populate: true,
          windowTypes: ["normal"],
        });
        target = containing.find((w) => w.id === lastFocused?.id) || null;
      }
    }
    if (!target) return null;
    const tab = target.tabs?.find((t) => t.active);
    if (!tab || tab.id == null) return null;
    const response = await chrome.tabs.sendMessage(tab.id, { type: "lasso-resolve", bbox });
    return response?.fingerprint ?? null;
  } catch {
    return null;
  }
}

function randomNonce() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return base64URL(bytes);
}

async function importHMACKey(encoded) {
  return crypto.subtle.importKey(
    "raw",
    fromBase64URL(encoded),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

function hmac(key, text) {
  return crypto.subtle.sign("HMAC", key, new TextEncoder().encode(text));
}

function base64URL(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64URL(value) {
  if (typeof value !== "string" || value.length > 256) throw new Error("invalid base64url");
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  const binary = atob(base64);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i += 1) difference |= a[i] ^ b[i];
  return difference === 0;
}

chrome.runtime.onStartup.addListener(ensureConnected);
chrome.runtime.onInstalled.addListener(() => {
  ensureConnected();
  injectIntoOpenTabs();
});

ensureConnected();
