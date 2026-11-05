// POST /api/social/session { state, secret } — the app polls this after opening /connect.
// 202 { status: "pending" } while the user is consenting; 200 { status: "connected", tokens } once
// (the entry is then forgotten); 400 with the platform's message if the user declined or the exchange failed.
import { HTTPError, defineHandler } from "nitro";
import { readBody } from "nitro/h3";
import { badRequest, pickUp } from "../../utils/social.ts";

export default defineHandler(async (event) => {
  const body = ((await readBody<{ state?: string; secret?: string }>(event)) ?? {}) as {
    state?: string;
    secret?: string;
  };
  if (!body.state || !body.secret) throw badRequest("`state` and `secret` are required.");
  const result = pickUp(body.state, body.secret);
  if (result === "pending") {
    return new Response(JSON.stringify({ status: "pending" }), {
      status: 202,
      headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
    });
  }
  if (!result || "error" in result) throw new HTTPError({ status: 400, message: result?.error ?? "Connection failed." });
  return { status: "connected", tokens: result.tokens };
});
