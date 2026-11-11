// GET /api/tts/jobs/:id — status of an async job.
// status: queued | processing | completed | failed. `audioUrl` (presigned, valid 24 h) once completed.
import { defineHandler } from "nitro";
import { getRouterParam } from "nitro/h3";
import { badRequest, vieneuJSON } from "../../../utils/vieneu.ts";
import { requirePro } from "../../../utils/license.ts";

export default defineHandler(async (event) => {
  await requirePro(event, "Vietnamese voice-over (VieNeu)");
  const id = getRouterParam(event, "id");
  if (!id) throw badRequest("Missing job id.");
  return vieneuJSON(`/tts/${encodeURIComponent(id)}`);
});
