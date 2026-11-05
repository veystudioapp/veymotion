// GET /api/tts/voices — v4 voice catalogue (plus cloned voices when an API key is set).
// The `id` of a voice is what /api/tts/speech takes as `voice` and /api/tts/jobs as `voiceId`.
import { defineHandler } from "nitro";
import { vieneuJSON } from "../../utils/vieneu.ts";

interface Voice {
  id: string;
  name?: string;
  description?: string;
  gender: string | null;
  region: string | null;
  engine: "v4";
  kind: "catalog" | "cloned";
}

export default defineHandler(async () => {
  return vieneuJSON<{ voices: Voice[]; count: number; error?: string }>("/voices?engine=v4", {
    auth: "optional",
  });
});
