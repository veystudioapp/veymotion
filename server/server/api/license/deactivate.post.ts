// POST /api/license/deactivate — `Authorization: Bearer <token>`. Frees this Mac's activation so the key can be
// used on another one. Returns { ok: true } (also when the activation was already gone).
import { HTTPError, defineHandler } from "nitro";
import { deactivate, tokenFrom } from "../../utils/license.ts";

export default defineHandler(async (event) => {
  const payload = tokenFrom(event);
  if (!payload) throw new HTTPError({ status: 401, message: "Missing or invalid license token.", data: { code: "bad_token" } });
  await deactivate(payload);
  return { ok: true };
});
