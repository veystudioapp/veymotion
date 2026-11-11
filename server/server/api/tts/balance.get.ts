// GET /api/tts/balance — remaining VieNeu tokens for the configured API key.
import { defineHandler } from "nitro";
import { vieneuJSON } from "../../utils/vieneu.ts";
import { requirePro } from "../../utils/license.ts";

export default defineHandler(async (event) => {
  await requirePro(event, "The VieNeu balance");
  return vieneuJSON("/balance");
});
