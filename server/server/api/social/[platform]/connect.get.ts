// GET /api/social/:platform/connect?state=…&challenge=… — opened in the browser by the app.
// `state` is random (base64url, 32–128 chars); `challenge` is base64url(sha256(secret)), where the app
// keeps `secret` to pick the tokens up from POST /api/social/session. Redirects to the consent page.
import { defineHandler } from "nitro";
import { getQuery, getRouterParam } from "nitro/h3";
import {
  authorizeUrl,
  badRequest,
  isPlatform,
  redirectUri,
  requireProvider,
  startPending,
} from "../../../utils/social.ts";

export default defineHandler((event) => {
  const platform = getRouterParam(event, "platform");
  if (!isPlatform(platform)) throw badRequest("Unknown platform.");
  const cfg = requireProvider(platform);
  const { state, challenge } = getQuery<{ state?: string; challenge?: string }>(event);
  if (!state || !challenge) throw badRequest("`state` and `challenge` are required.");
  const entry = startPending(platform, state, challenge, redirectUri(platform, event.url.origin));
  return Response.redirect(authorizeUrl(platform, cfg, state, entry), 302);
});
