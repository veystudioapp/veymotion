// POST /api/social/:platform/refresh { refreshToken } — new access token (YouTube, TikTok, X).
// TikTok and X rotate refresh tokens: the response's `refreshToken` replaces the old one.
import { defineHandler } from "nitro";
import { getRouterParam, readBody } from "nitro/h3";
import { badRequest, isPlatform, refreshTokens, requireProvider } from "../../../utils/social.ts";

export default defineHandler(async (event) => {
  const platform = getRouterParam(event, "platform");
  if (!isPlatform(platform)) throw badRequest("Unknown platform.");
  const body = ((await readBody<{ refreshToken?: string }>(event)) ?? {}) as { refreshToken?: string };
  if (!body.refreshToken) throw badRequest("`refreshToken` is required.");
  return { tokens: await refreshTokens(platform, requireProvider(platform), body.refreshToken) };
});
