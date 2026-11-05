// VieNeu Cloud API client (https://docs.vieneu.io/docs/cloud-api/overview/).
// The API key stays on the server: routes under /api/tts proxy to VieNeu.
import { HTTPError } from "nitro";
import { useRuntimeConfig } from "nitro/runtime-config";

export const SPEECH_FORMATS = ["mp3", "wav", "opus", "pcm", "ulaw"] as const;
export type SpeechFormat = (typeof SPEECH_FORMATS)[number];

const CONTENT_TYPES: Record<SpeechFormat, string> = {
  mp3: "audio/mpeg",
  wav: "audio/wav",
  opus: "audio/ogg",
  pcm: "audio/L16",
  ulaw: "audio/basic",
};

/** Body of POST /v1/audio/speech (OpenAI-compatible, synchronous). */
export interface SpeechRequest {
  input: string;
  model?: string;
  voice?: string;
  response_format?: SpeechFormat;
  speed?: number;
  sample_rate?: number;
  stream_format?: "audio" | "sse";
  aiRefine?: boolean;
  applyPronunciation?: boolean;
}

/** Body of POST /v1/tts (async job, up to 50 000 characters). */
export interface TtsJobRequest {
  text: string;
  voiceId?: string;
  emotion?: string;
  speed?: number;
  engine?: "v4";
  aiRefine?: boolean;
  applyPronunciation?: boolean;
}

function config() {
  const rc = useRuntimeConfig() as { vieneu?: { apiKey?: string; baseUrl?: string } };
  return {
    apiKey: rc.vieneu?.apiKey || process.env.VIENEU_API_KEY || "",
    baseUrl: (rc.vieneu?.baseUrl || "https://api.vieneu.io/api/v1").replace(/\/+$/, ""),
  };
}

/**
 * Calls the VieNeu API. Upstream errors are rethrown as HTTPError with the same status,
 * keeping VieNeu's `code`, `traceId` and retry hints in `data`.
 */
export async function vieneuFetch(
  path: string,
  init: RequestInit & { auth?: "required" | "optional" } = {},
): Promise<Response> {
  const { apiKey, baseUrl } = config();
  const { auth = "required", ...rest } = init;
  const headers = new Headers(rest.headers);
  if (apiKey) headers.set("Authorization", `Bearer ${apiKey}`);
  else if (auth === "required") {
    throw new HTTPError({
      status: 500,
      message: "VieNeu API key is not configured (set NITRO_VIENEU_API_KEY or VIENEU_API_KEY).",
    });
  }
  if (rest.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");

  let res: Response;
  try {
    res = await fetch(`${baseUrl}${path}`, { ...rest, headers });
  } catch (cause) {
    throw new HTTPError({ status: 502, message: "Could not reach the VieNeu API.", cause });
  }
  if (!res.ok) throw await upstreamError(res);
  return res;
}

export async function vieneuJSON<T>(
  path: string,
  init?: RequestInit & { auth?: "required" | "optional" },
): Promise<T> {
  return (await vieneuFetch(path, init)).json() as Promise<T>;
}

async function upstreamError(res: Response): Promise<HTTPError> {
  const text = await res.text().catch(() => "");
  let body: any;
  try {
    body = JSON.parse(text);
  } catch {
    body = undefined;
  }
  // Native errors: { statusCode, message (string | string[]), code, traceId, ... }.
  // /v1/audio/speech uses OpenAI's shape: { error: { message, type, code } }.
  const err = body?.error && typeof body.error === "object" ? body.error : body;
  const rawMessage = err?.message ?? (text || res.statusText);
  const message = Array.isArray(rawMessage) ? rawMessage.join("; ") : String(rawMessage);

  const headers = new Headers();
  const retryAfter = res.headers.get("Retry-After");
  if (retryAfter) headers.set("Retry-After", retryAfter);

  return new HTTPError({
    status: res.status,
    message: `VieNeu: ${message}`,
    headers,
    data: {
      code: err?.code,
      traceId: body?.traceId ?? res.headers.get("X-Request-Id") ?? undefined,
      retryAfterSeconds: body?.retryAfterSeconds,
      resetAt: body?.resetAt,
      remaining: body?.remaining,
      required: body?.required,
    },
  });
}

export function contentTypeFor(format: SpeechFormat): string {
  return CONTENT_TYPES[format];
}

export function badRequest(message: string): HTTPError {
  return new HTTPError({ status: 400, message });
}
