// GET /api/app/download/:assetId — redirects to a release file of a private repo (signed, short-lived URL).
import { defineHandler } from "nitro";
import { getRouterParam } from "nitro/h3";
import { assetDownloadUrl } from "../../../utils/releases.ts";

export default defineHandler(async (event) => {
  const url = await assetDownloadUrl(getRouterParam(event, "id") ?? "");
  return Response.redirect(url, 302);
});
