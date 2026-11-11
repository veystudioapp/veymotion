// POST /api/license/refresh — `Authorization: Bearer <token>` (an expired token is fine if its signature is valid).
// Re-validates the activation with Polar and returns { token, license } with a new validity window.
// 402 license_inactive when the order was refunded, the key disabled or the Mac deactivated.
import { HTTPError, defineHandler } from "nitro";
import { refresh, tokenFrom } from "../../utils/license.ts";

export default defineHandler(async (event) => {
  const payload = tokenFrom(event);
  if (!payload) throw new HTTPError({ status: 401, message: "Missing or invalid license token.", data: { code: "bad_token" } });
  return refresh(payload);
});
