// GET /api/tts/balance — remaining VieNeu tokens for the configured API key.
import { defineHandler } from "nitro";
import { vieneuJSON } from "../../utils/vieneu.ts";

export default defineHandler(() => vieneuJSON("/balance"));
