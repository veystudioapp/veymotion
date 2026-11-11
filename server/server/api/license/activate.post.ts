// POST /api/license/activate { key, device, deviceName?, appVersion? } — activates a Polar license key on one Mac.
// `device` is the app's hash of the Mac's hardware UUID. Returns { token, license }: the app stores the signed token
// and sends it as `Authorization: Bearer <token>` to Pro server features.
// Errors: 404 unknown_key, 403 activation_limit / key_refused / wrong_product, 503 not configured.
import { defineHandler } from "nitro";
import { readBody } from "nitro/h3";
import { activate, badRequest } from "../../utils/license.ts";

interface Body {
  key?: string;
  device?: string;
  deviceName?: string;
  appVersion?: string;
}

export default defineHandler(async (event) => {
  const body = ((await readBody<Body>(event)) ?? {}) as Body;
  const key = (body.key ?? "").trim();
  const device = (body.device ?? "").trim();
  if (!key || key.length > 200) throw badRequest("`key` is required.");
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(device)) throw badRequest("`device` must be 16–128 base64url characters.");
  return activate(key, device, (body.deviceName ?? "").trim(), body.appVersion);
});
