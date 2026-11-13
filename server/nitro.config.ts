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
    // App updates (server/utils/releases.ts). Overridden by NITRO_UPDATES_REPO ("owner/name"),
    // NITRO_UPDATES_GITHUB_TOKEN (private repos) and NITRO_UPDATES_MINIMUM_SYSTEM_VERSION.
    updates: { repo: "", githubToken: "", minimumSystemVersion: "14.0" },
    // Pro licenses (server/utils/license.ts). Overridden by NITRO_POLAR_ORGANIZATION_ID, NITRO_POLAR_API_URL,
    // NITRO_POLAR_PRO_BENEFIT_IDS, NITRO_LICENSE_PRIVATE_KEY, NITRO_LICENSE_CHECKOUT_URL and NITRO_LICENSE_PORTAL_URL.
    polar: { organizationId: "", apiUrl: "https://api.polar.sh", proBenefitIds: "" },
    license: { privateKey: "", checkoutUrl: "", portalUrl: "" },
  },
});
