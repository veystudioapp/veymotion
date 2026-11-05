// POST /api/tts/speech — synthesize short text and return the audio bytes.
// Body: { text, voice?, format?, speed?, sampleRate?, stream?, aiRefine?, applyPronunciation? }
// Proxies VieNeu's OpenAI-compatible POST /v1/audio/speech (streamed straight through).
import { defineHandler } from "nitro";
import { readBody } from "nitro/h3";
import {
  SPEECH_FORMATS,
  badRequest,
  contentTypeFor,
  vieneuFetch,
  type SpeechFormat,
  type SpeechRequest,
} from "../../utils/vieneu.ts";

interface Body {
  text?: string;
  input?: string;
  voice?: string;
  format?: SpeechFormat;
  speed?: number;
  sampleRate?: number;
  /** Stream raw audio chunks as they are generated (pcm / ulaw only). */
  stream?: boolean;
  aiRefine?: boolean;
  applyPronunciation?: boolean;
  /** Suggested file name; sets Content-Disposition: attachment. */
  filename?: string;
}

export default defineHandler(async (event) => {
  const body = ((await readBody<Body>(event)) ?? {}) as Body;
  const text = (body.text ?? body.input ?? "").trim();
  if (!text) throw badRequest("`text` is required.");

  const format = body.format ?? "mp3";
  if (!SPEECH_FORMATS.includes(format)) {
    throw badRequest(`\`format\` must be one of: ${SPEECH_FORMATS.join(", ")}.`);
  }
  if (body.stream && format !== "pcm" && format !== "ulaw") {
    throw badRequest("`stream` only works with format `pcm` or `ulaw`.");
  }
  if (body.speed !== undefined && (typeof body.speed !== "number" || !(body.speed > 0))) {
    throw badRequest("`speed` must be a positive number (VieNeu clamps it to 0.5–2.0).");
  }

  const payload: SpeechRequest = {
    model: "vieneu-v4",
    input: text,
    voice: body.voice || undefined,
    response_format: format,
    speed: body.speed,
    sample_rate: body.sampleRate,
    stream_format: body.stream ? "audio" : undefined,
    aiRefine: body.aiRefine,
    applyPronunciation: body.applyPronunciation,
  };

  const upstream = await vieneuFetch("/audio/speech", {
    method: "POST",
    body: JSON.stringify(payload),
    signal: event.req.signal,
  });

  const headers = new Headers({
    "Content-Type": upstream.headers.get("Content-Type") || contentTypeFor(format),
    "Cache-Control": "no-store",
  });
  for (const name of ["X-Sample-Rate", "X-Request-Id", "Content-Length"]) {
    const value = upstream.headers.get(name);
    if (value) headers.set(name, value);
  }
  if (body.filename) {
    const name = body.filename.includes(".") ? body.filename : `${body.filename}.${format}`;
    headers.set("Content-Disposition", `attachment; filename*=UTF-8''${encodeURIComponent(name)}`);
  }
  return new Response(upstream.body, { status: 200, headers });
});
