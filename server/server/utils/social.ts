// OAuth broker for publishing to social platforms (YouTube, TikTok, Facebook Pages, X).
//
// The app never sees the client secrets. Flow:
//  1. The app makes a random `state` and `secret`, registers them with
//     POST /api/social/:platform/start { state, challenge: base64url(sha256(secret)) } and opens the returned
//     consent-page URL in the browser (GET /api/social/:platform/connect does both for a browser-only flow).
//  2. The platform redirects back to /api/social/:platform/callback, where the code is exchanged for tokens.
//  3. The app polls POST /api/social/session { state, secret } and picks the tokens up once.
// Access tokens are refreshed through POST /api/social/:platform/refresh. Uploads go straight
// from the app to the platform APIs; no video passes through this server.
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { HTTPError } from "nitro";
import { useRuntimeConfig } from "nitro/runtime-config";

export const PLATFORMS = ["youtube", "tiktok", "facebook", "x"] as const;
export type Platform = (typeof PLATFORMS)[number];

const NAMES: Record<Platform, string> = { youtube: "YouTube", tiktok: "TikTok", facebook: "Facebook", x: "X" };

const DEFAULT_SCOPES: Record<Platform, string> = {
  youtube: "https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.readonly",
  tiktok: "user.info.basic,video.upload,video.publish",
  facebook: "pages_show_list,pages_read_engagement,pages_manage_posts",
  x: "tweet.read tweet.write users.read media.write offline.access",
};

/** Tokens as returned to the app (same shape for every platform). */
export interface TokenSet {
  accessToken: string;
  refreshToken?: string;
  /** Seconds until `accessToken` expires. */
  expiresIn?: number;
  scope?: string;
  /** Platform user id when the token response includes one (TikTok `open_id`). */
  userId?: string;
}

interface ProviderConfig {
  clientId: string;
  clientSecret: string;
  scopes: string;
}

type SocialRuntimeConfig = {
  social?: {
    publicUrl?: string;
    facebookGraphVersion?: string;
  } & Partial<Record<Platform, Partial<ProviderConfig>>>;
};

function rc(): NonNullable<SocialRuntimeConfig["social"]> {
  return (useRuntimeConfig() as SocialRuntimeConfig).social ?? {};
}

export function isPlatform(p: string | undefined): p is Platform {
  return !!p && (PLATFORMS as readonly string[]).includes(p);
}

/** Client id/secret from runtime config (NITRO_SOCIAL_<PLATFORM>_CLIENT_ID / _CLIENT_SECRET / _SCOPES). */
export function providerConfig(platform: Platform): ProviderConfig | undefined {
  const c = rc()[platform] ?? {};
  const env = (k: string) => process.env[`NITRO_SOCIAL_${platform.toUpperCase()}_${k}`];
  const clientId = c.clientId || env("CLIENT_ID") || "";
  const clientSecret = c.clientSecret || env("CLIENT_SECRET") || "";
  if (!clientId || !clientSecret) return undefined;
  return { clientId, clientSecret, scopes: c.scopes || env("SCOPES") || DEFAULT_SCOPES[platform] };
}

export function requireProvider(platform: Platform): ProviderConfig {
  const c = providerConfig(platform);
  if (!c) {
    const p = platform.toUpperCase();
    throw new HTTPError({
      status: 501,
      message: `${NAMES[platform]} is not configured on the server (set NITRO_SOCIAL_${p}_CLIENT_ID and NITRO_SOCIAL_${p}_CLIENT_SECRET).`,
    });
  }
  return c;
}

export function graphVersion(): string {
  return rc().facebookGraphVersion || process.env.NITRO_SOCIAL_FACEBOOK_GRAPH_VERSION || "v27.0";
}

/** The callback URL registered with each platform: <public URL>/api/social/<platform>/callback. */
export function redirectUri(platform: Platform, requestOrigin: string): string {
  const base = (rc().publicUrl || process.env.NITRO_SOCIAL_PUBLIC_URL || requestOrigin).replace(/\/+$/, "");
  return `${base}/api/social/${platform}/callback`;
}

export function platformName(platform: Platform): string {
  return NAMES[platform];
}

// MARK: Pending connections (in memory; one server instance)

interface Pending {
  platform: Platform;
  /** base64url(sha256(secret)) sent by the app; the pickup must present the secret. */
  challenge: string;
  /** PKCE verifier for platforms that use it (YouTube, X). */
  verifier: string;
  redirectUri: string;
  createdAt: number;
  result?: { tokens: TokenSet } | { error: string };
}

const TTL_MS = 15 * 60 * 1000;
const pending = new Map<string, Pending>();

function sweep() {
  const now = Date.now();
  for (const [k, v] of pending) if (now - v.createdAt > TTL_MS) pending.delete(k);
}

const B64URL = /^[A-Za-z0-9_-]{32,128}$/;

export function base64url(buf: Buffer): string {
  return buf.toString("base64url");
}

export function startPending(platform: Platform, state: string, challenge: string, redirect: string): Pending {
  if (!B64URL.test(state)) throw badRequest("`state` must be 32–128 base64url characters.");
  if (!B64URL.test(challenge)) throw badRequest("`challenge` must be base64url(sha256(secret)).");
  sweep();
  if (pending.has(state)) throw badRequest("This `state` was already used.");
  const entry: Pending = {
    platform,
    challenge,
    verifier: base64url(randomBytes(48)),
    redirectUri: redirect,
    createdAt: Date.now(),
  };
  pending.set(state, entry);
  return entry;
}

export function findPending(state: string | undefined): Pending | undefined {
  sweep();
  return state ? pending.get(state) : undefined;
}

/** Returns the result once (and forgets the entry), "pending" while the user is still consenting. */
export function pickUp(state: string, secret: string): Pending["result"] | "pending" {
  sweep();
  const entry = pending.get(state);
  if (!entry) throw new HTTPError({ status: 404, message: "Unknown or expired connection. Try connecting again." });
  const expected = Buffer.from(entry.challenge);
  const got = Buffer.from(base64url(createHash("sha256").update(secret).digest()));
  if (expected.length !== got.length || !timingSafeEqual(expected, got)) {
    throw new HTTPError({ status: 403, message: "Wrong secret for this connection." });
  }
  if (!entry.result) return "pending";
  pending.delete(state);
  return entry.result;
}

export function pkceChallenge(verifier: string): string {
  return base64url(createHash("sha256").update(verifier).digest());
}

// MARK: Authorize URLs

export function authorizeUrl(platform: Platform, cfg: ProviderConfig, state: string, entry: Pending): string {
  const q = new URLSearchParams();
  let base: string;
  switch (platform) {
    case "youtube":
      base = "https://accounts.google.com/o/oauth2/v2/auth";
      q.set("client_id", cfg.clientId);
      q.set("redirect_uri", entry.redirectUri);
      q.set("response_type", "code");
      q.set("scope", cfg.scopes);
      q.set("access_type", "offline");
      // Always show the account / channel chooser, so "Add account" can pick another channel (Brand Account).
      q.set("prompt", "select_account consent");
      q.set("include_granted_scopes", "true");
      q.set("code_challenge", pkceChallenge(entry.verifier));
      q.set("code_challenge_method", "S256");
      break;
    case "tiktok":
      base = "https://www.tiktok.com/v2/auth/authorize/";
      q.set("client_key", cfg.clientId);
      q.set("redirect_uri", entry.redirectUri);
      q.set("response_type", "code");
      q.set("scope", cfg.scopes);
      break;
    case "facebook":
      base = `https://www.facebook.com/${graphVersion()}/dialog/oauth`;
      q.set("client_id", cfg.clientId);
      q.set("redirect_uri", entry.redirectUri);
      q.set("response_type", "code");
      q.set("scope", cfg.scopes);
      break;
    case "x":
      base = "https://x.com/i/oauth2/authorize";
      q.set("client_id", cfg.clientId);
      q.set("redirect_uri", entry.redirectUri);
      q.set("response_type", "code");
      q.set("scope", cfg.scopes);
      q.set("code_challenge", pkceChallenge(entry.verifier));
      q.set("code_challenge_method", "S256");
      break;
  }
  q.set("state", state);
  return `${base}?${q}`;
}

// MARK: Token endpoints

async function tokenRequest(platform: Platform, url: string, init: RequestInit): Promise<any> {
  let res: Response;
  try {
    res = await fetch(url, init);
  } catch (cause) {
    throw new HTTPError({ status: 502, message: `Could not reach ${NAMES[platform]}.`, cause });
  }
  const text = await res.text();
  let body: any;
  try {
    body = JSON.parse(text);
  } catch {
    body = undefined;
  }
  // TikTok answers 200 with { error, error_description } on failure.
  const err = body?.error;
  if (!res.ok || (err && typeof err === "string" && err !== "ok") || !body?.access_token) {
    const message =
      body?.error_description ||
      (typeof err === "object" ? err?.message : err) ||
      body?.message ||
      text.slice(0, 300) ||
      res.statusText;
    throw new HTTPError({ status: res.ok ? 502 : res.status, message: `${NAMES[platform]}: ${message}` });
  }
  return body;
}

function form(params: Record<string, string>): RequestInit {
  return {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
    body: new URLSearchParams(params).toString(),
  };
}

function normalize(body: any): TokenSet {
  return {
    accessToken: body.access_token,
    refreshToken: body.refresh_token || undefined,
    expiresIn: typeof body.expires_in === "number" ? body.expires_in : Number(body.expires_in) || undefined,
    scope: body.scope || undefined,
    userId: body.open_id || undefined,
  };
}

function basicAuth(cfg: ProviderConfig): string {
  return "Basic " + Buffer.from(`${encodeURIComponent(cfg.clientId)}:${encodeURIComponent(cfg.clientSecret)}`).toString("base64");
}

/** Exchanges an authorization code for tokens (Facebook: a long-lived user token). */
export async function exchangeCode(platform: Platform, cfg: ProviderConfig, code: string, entry: Pending): Promise<TokenSet> {
  switch (platform) {
    case "youtube":
      return normalize(
        await tokenRequest(platform, "https://oauth2.googleapis.com/token", form({
          code,
          client_id: cfg.clientId,
          client_secret: cfg.clientSecret,
          redirect_uri: entry.redirectUri,
          grant_type: "authorization_code",
          code_verifier: entry.verifier,
        })),
      );
    case "tiktok":
      return normalize(
        await tokenRequest(platform, "https://open.tiktokapis.com/v2/oauth/token/", form({
          client_key: cfg.clientId,
          client_secret: cfg.clientSecret,
          code,
          grant_type: "authorization_code",
          redirect_uri: entry.redirectUri,
        })),
      );
    case "x": {
      const init = form({
        code,
        grant_type: "authorization_code",
        redirect_uri: entry.redirectUri,
        code_verifier: entry.verifier,
      });
      (init.headers as Record<string, string>).Authorization = basicAuth(cfg);
      return normalize(await tokenRequest(platform, "https://api.x.com/2/oauth2/token", init));
    }
    case "facebook": {
      const v = graphVersion();
      const short = await tokenRequest(
        platform,
        `https://graph.facebook.com/${v}/oauth/access_token?` +
          new URLSearchParams({
            client_id: cfg.clientId,
            client_secret: cfg.clientSecret,
            redirect_uri: entry.redirectUri,
            code,
          }),
        { headers: { Accept: "application/json" } },
      );
      // Short-lived user tokens last ~1–2 hours; exchange for a long-lived one (~60 days).
      // Page tokens fetched with a long-lived user token do not expire.
      const long = await tokenRequest(
        platform,
        `https://graph.facebook.com/${v}/oauth/access_token?` +
          new URLSearchParams({
            grant_type: "fb_exchange_token",
            client_id: cfg.clientId,
            client_secret: cfg.clientSecret,
            fb_exchange_token: short.access_token,
          }),
        { headers: { Accept: "application/json" } },
      );
      return normalize(long);
    }
  }
}

/** Refreshes an access token. TikTok and X rotate the refresh token: store the new one. */
export async function refreshTokens(platform: Platform, cfg: ProviderConfig, refreshToken: string): Promise<TokenSet> {
  switch (platform) {
    case "youtube": {
      const t = normalize(
        await tokenRequest(platform, "https://oauth2.googleapis.com/token", form({
          client_id: cfg.clientId,
          client_secret: cfg.clientSecret,
          refresh_token: refreshToken,
          grant_type: "refresh_token",
        })),
      );
      return { ...t, refreshToken: t.refreshToken ?? refreshToken };
    }
    case "tiktok":
      return normalize(
        await tokenRequest(platform, "https://open.tiktokapis.com/v2/oauth/token/", form({
          client_key: cfg.clientId,
          client_secret: cfg.clientSecret,
          grant_type: "refresh_token",
          refresh_token: refreshToken,
        })),
      );
    case "x": {
      const init = form({ grant_type: "refresh_token", refresh_token: refreshToken });
      (init.headers as Record<string, string>).Authorization = basicAuth(cfg);
      return normalize(await tokenRequest(platform, "https://api.x.com/2/oauth2/token", init));
    }
    case "facebook":
      throw badRequest("Facebook tokens cannot be refreshed; connect the account again.");
  }
}

export function badRequest(message: string): HTTPError {
  return new HTTPError({ status: 400, message });
}

export function escapeHTML(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

/** The page the browser lands on after consenting. */
export function resultPage(title: string, detail: string, ok: boolean): Response {
  const color = ok ? "#1f9d55" : "#d64545";
  const body = `<!doctype html><html lang="vi"><head><meta charset="utf-8"><title>VeyMotion — ${escapeHTML(title)}</title>
<style>body{font:15px -apple-system,system-ui,sans-serif;background:#0e0e12;color:#e8e8ee;display:grid;place-items:center;height:100vh;margin:0}
main{max-width:420px;text-align:center}h1{font-size:20px;color:${color}}p{color:#a0a0ad;line-height:1.5}</style></head>
<body><main><h1>${escapeHTML(title)}</h1><p>${escapeHTML(detail)}</p></main></body></html>`;
  return new Response(body, {
    status: ok ? 200 : 400,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
  });
}
