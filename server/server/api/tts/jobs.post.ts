// POST /api/tts/jobs — submit long text (up to 50 000 characters) as an async job.
// Body: { text, voiceId? (or voice), emotion?, speed? (0.5–2), aiRefine?, applyPronunciation? }
// Returns { jobId, status: "queued" | "completed", audioUrl?, duration?, ... }; poll GET /api/tts/jobs/:id.
// An `Idempotency-Key` request header is forwarded so retries are not charged twice.
import { defineHandler } from "nitro";
import { readBody } from "nitro/h3";
import { badRequest, vieneuJSON, type TtsJobRequest } from "../../utils/vieneu.ts";
import { requirePro } from "../../utils/license.ts";

type Body = Partial<TtsJobRequest> & { voice?: string };

export default defineHandler(async (event) => {
  await requirePro(event, "Vietnamese voice-over (VieNeu)");
  const body = ((await readBody<Body>(event)) ?? {}) as Body;
  const text = (body.text ?? "").trim();
  if (!text) throw badRequest("`text` is required.");
  if (text.length > 50_000) throw badRequest("`text` is limited to 50 000 characters.");
  if (body.speed !== undefined && !(body.speed >= 0.5 && body.speed <= 2)) {
    throw badRequest("`speed` must be between 0.5 and 2.");
  }

  const payload: TtsJobRequest = {
    text,
    voiceId: body.voiceId || body.voice || undefined,
    emotion: body.emotion,
    speed: body.speed,
    engine: "v4",
    aiRefine: body.aiRefine,
    applyPronunciation: body.applyPronunciation,
  };

  const headers: Record<string, string> = {};
  const idempotencyKey = event.req.headers.get("Idempotency-Key");
  if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;

  return vieneuJSON("/tts", { method: "POST", headers, body: JSON.stringify(payload) });
});
