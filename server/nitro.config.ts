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
    // Stock video (server/utils/stock.ts). Overridden by NITRO_PEXELS_API_KEY / NITRO_PIXABAY_API_KEY
    // (PEXELS_API_KEY / PIXABAY_API_KEY are also read). A source without a key is skipped.
    pexels: { apiKey: "" },
    pixabay: { apiKey: "" },
    // Publishing (server/utils/social.ts). Overridden by NITRO_SOCIAL_<PLATFORM>_CLIENT_ID /
    // _CLIENT_SECRET / _SCOPES, NITRO_SOCIAL_PUBLIC_URL and NITRO_SOCIAL_FACEBOOK_GRAPH_VERSION.
    social: {
      publicUrl: "",
      facebookGraphVersion: "",
      youtube: { clientId: "", clientSecret: "", scopes: "" },
      tiktok: { clientId: "", clientSecret: "", scopes: "" },
      facebook: { clientId: "", clientSecret: "", scopes: "" },
      x: { clientId: "", clientSecret: "", scopes: "" },
    },
  },
});
