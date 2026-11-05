// GET /api/social/providers — which platforms are configured on this server.
// Returns { platforms: { youtube: { configured, scopes? }, …, facebook: { configured, appId?, graphVersion } } }.
// The Facebook app id is public; the app needs it to start a resumable upload session.
import { defineHandler } from "nitro";
import { PLATFORMS, graphVersion, providerConfig } from "../../utils/social.ts";

export default defineHandler(() => {
  const platforms: Record<string, Record<string, unknown>> = {};
  for (const p of PLATFORMS) {
    const c = providerConfig(p);
    platforms[p] = { configured: !!c, scopes: c?.scopes };
    if (p === "facebook") {
      platforms[p].appId = c?.clientId;
      platforms[p].graphVersion = graphVersion();
    }
  }
  return { platforms };
});
