// GET /api/license — licensing info for the app: { configured, checkoutUrl?, portalUrl?, offlineDays, publicKey? }.
// `publicKey` (base64 raw Ed25519) must match the key embedded in the app (License.swift).
import { defineHandler } from "nitro";
import { licenseLinks, publicKeyBase64 } from "../../utils/license.ts";

export default defineHandler(() => {
  const info = licenseLinks();
  return { ...info, publicKey: info.configured ? publicKeyBase64() : undefined };
});
