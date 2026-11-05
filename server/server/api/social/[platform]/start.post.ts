// POST /api/social/:platform/start { state, challenge } — the app registers a connection, then opens the
// returned `url` (the platform's consent page) in the browser and polls POST /api/social/session.
// Registering first means the app's polling can never run ahead of the browser.
// `state` is random (base64url, 32–128 chars); `challenge` is base64url(sha256(secret)).
import { defineHandler } from "nitro";
import { getRouterParam, readBody } from "nitro/h3";
import {
  authorizeUrl,
  badRequest,
  isPlatform,
  redirectUri,
  requireProvider,
  startPending,
} from "../../../utils/social.ts";

export default defineHandler(async (event) => {
  const platform = getRouterParam(event, "platform");
  if (!isPlatform(platform)) throw badRequest("Unknown platform.");
  const cfg = requireProvider(platform);
  const body = ((await readBody<{ state?: string; challenge?: string }>(event)) ?? {}) as {
    state?: string;
    challenge?: string;
  };
  if (!body.state || !body.challenge) throw badRequest("`state` and `challenge` are required.");
  const entry = startPending(platform, body.state, body.challenge, redirectUri(platform, event.url.origin));
  return { url: authorizeUrl(platform, cfg, body.state, entry) };
});
