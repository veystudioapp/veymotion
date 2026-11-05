import { defineConfig } from "nitro";

export default defineConfig({
  serverDir: "./server",
  runtimeConfig: {
    // Overridden at runtime by NITRO_VIENEU_API_KEY / NITRO_VIENEU_BASE_URL
    // (VIENEU_API_KEY is also read as a fallback).
    vieneu: {
      apiKey: "",
      baseUrl: "https://api.vieneu.io/api/v1",
    },
  },
});
