// VeyMotion Pro licenses: Polar license keys (https://polar.sh/docs/features/benefits/license-keys), turned into
// short-lived entitlement tokens signed with Ed25519 that the app checks offline.
//
// - The app activates a key once per Mac (POST /api/license/activate). Polar enforces the activation limit (devices)
//   and binds the activation to the Mac through `conditions.device`.
// - The token is `base64url(payload JSON) "." base64url(Ed25519 signature of the first part)`. It is valid for
//   OFFLINE_DAYS, and the app refreshes it daily (POST /api/license/refresh), so a revoked key (refund,
//   disabled by hand) stops working within that window, and immediately for server features (`requirePro`).
// - No database: Polar keeps the keys and activations, the token carries everything else.
//
// Config: NITRO_POLAR_ORGANIZATION_ID, NITRO_POLAR_API_URL (https://sandbox-api.polar.sh for testing),
// NITRO_POLAR_PRO_BENEFIT_IDS (comma-separated; empty = any license key of the organization),
// NITRO_LICENSE_PRIVATE_KEY (base64 Ed25519 seed, from `bun run license:keygen`),
// NITRO_LICENSE_CHECKOUT_URL, NITRO_LICENSE_PORTAL_URL.
import { createPrivateKey, createPublicKey, sign, verify, type KeyObject } from "node:crypto";
import { HTTPError, type H3Event } from "nitro";
import { useRuntimeConfig } from "nitro/runtime-config";

/** How long the app keeps Pro features without reaching the server. */
export const OFFLINE_DAYS = 14;
/** How long `requirePro` trusts a Polar answer about an activation. */
const RECHECK_MS = 60 * 60 * 1000;
const RECHECK_FAILED_MS = 5 * 60 * 1000;

export type Plan = "pro";

export interface LicensePayload {
  /** Token format version. */
  v: 1;
  plan: Plan;
  /** The license key (the app needs it to refresh; the token only lives on the user's Mac and this server). */
  key: string;
  /** Polar ids. */
  keyId: string;
  activation: string;
  benefit: string;
  customer: string;
  /** Hash of the Mac's hardware UUID, as sent by the app. */
  device: string;
  email?: string;
  name?: string;
  /** When the license itself ends (one-time purchases with an expiry), ISO 8601; absent = no end date. */
  licenseExpiresAt?: string;
  /** Issued at / valid until, Unix seconds. */
  iat: number;
  exp: number;
}

interface LicenseRuntimeConfig {
  polar?: { organizationId?: string; apiUrl?: string; proBenefitIds?: string };
  license?: { privateKey?: string; checkoutUrl?: string; portalUrl?: string };
}

function config() {
  const rc = useRuntimeConfig() as LicenseRuntimeConfig;
  const env = process.env;
  return {
    organizationId: rc.polar?.organizationId || env.NITRO_POLAR_ORGANIZATION_ID || "",
    apiUrl: (rc.polar?.apiUrl || env.NITRO_POLAR_API_URL || "https://api.polar.sh").replace(/\/+$/, ""),
    proBenefitIds: (rc.polar?.proBenefitIds || env.NITRO_POLAR_PRO_BENEFIT_IDS || "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
    privateKey: rc.license?.privateKey || env.NITRO_LICENSE_PRIVATE_KEY || "",
    checkoutUrl: rc.license?.checkoutUrl || env.NITRO_LICENSE_CHECKOUT_URL || "",
    portalUrl: rc.license?.portalUrl || env.NITRO_LICENSE_PORTAL_URL || "",
  };
}

/** Public links for the app's Account panel. */
export function licenseLinks() {
  const c = config();
  return {
    configured: !!(c.organizationId && c.privateKey),
    checkoutUrl: c.checkoutUrl || undefined,
    portalUrl: c.portalUrl || undefined,
    offlineDays: OFFLINE_DAYS,
  };
}

// MARK: - Keys

// PKCS#8 prefix of an Ed25519 private key; the 32-byte seed follows.
const ED25519_PKCS8_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");

let cachedKey: { source: string; key: KeyObject } | undefined;

function signingKey(): KeyObject {
  const source = config().privateKey;
  if (!source) {
    throw new HTTPError({ status: 503, message: "Licensing is not configured on this server (NITRO_LICENSE_PRIVATE_KEY)." });
  }
  if (cachedKey?.source === source) return cachedKey.key;
  const seed = Buffer.from(source, "base64");
  if (seed.length !== 32) {
    throw new HTTPError({ status: 500, message: "NITRO_LICENSE_PRIVATE_KEY must be a base64 32-byte Ed25519 seed." });
  }
  const key = createPrivateKey({ key: Buffer.concat([ED25519_PKCS8_PREFIX, seed]), format: "der", type: "pkcs8" });
  cachedKey = { source, key };
  return key;
}

/** The raw 32-byte public key, base64 (what the app embeds). */
export function publicKeyBase64(): string {
  const jwk = createPublicKey(signingKey()).export({ format: "jwk" }) as { x: string };
  return Buffer.from(jwk.x, "base64url").toString("base64");
}

export function signToken(payload: LicensePayload): string {
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const signature = sign(null, Buffer.from(body), signingKey()).toString("base64url");
  return `${body}.${signature}`;
}

/** The payload of a token signed by this server, or undefined. Expiry is NOT checked here. */
export function readToken(token: string | undefined | null): LicensePayload | undefined {
  if (!token) return undefined;
  const [body, signature, extra] = token.trim().split(".");
  if (!body || !signature || extra !== undefined) return undefined;
  try {
    const ok = verify(null, Buffer.from(body), createPublicKey(signingKey()), Buffer.from(signature, "base64url"));
    if (!ok) return undefined;
    const payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8")) as LicensePayload;
    return payload?.v === 1 && payload.plan === "pro" ? payload : undefined;
  } catch (error) {
    if (error instanceof HTTPError) throw error;
    return undefined;
  }
}

// MARK: - Polar

interface PolarCustomer {
  id: string;
  email?: string | null;
  name?: string | null;
}

interface PolarLicenseKey {
  id: string;
  organization_id: string;
  customer_id: string;
  customer?: PolarCustomer;
  benefit_id: string;
  status: string;
  limit_activations?: number | null;
  expires_at?: string | null;
  activation?: { id: string } | null;
}

interface PolarActivation {
  id: string;
  license_key: PolarLicenseKey;
}

class PolarError extends Error {
  readonly status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

async function polar<T>(path: string, body: Record<string, unknown>): Promise<T | undefined> {
  const { apiUrl, organizationId } = config();
  if (!organizationId) {
    throw new HTTPError({ status: 503, message: "Licensing is not configured on this server (NITRO_POLAR_ORGANIZATION_ID)." });
  }
  let res: Response;
  try {
    res = await fetch(`${apiUrl}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ ...body, organization_id: organizationId }),
    });
  } catch (cause) {
    throw new PolarError(0, `Could not reach Polar: ${(cause as Error)?.message ?? cause}`);
  }
  if (res.status === 204) return undefined;
  const text = await res.text();
  let json: any;
  try {
    json = text ? JSON.parse(text) : undefined;
  } catch {
    json = undefined;
  }
  if (!res.ok) {
    const detail = json?.detail;
    const message = typeof detail === "string" ? detail : Array.isArray(detail) ? detail.map((d) => d?.msg).join("; ") : text;
    throw new PolarError(res.status, message || res.statusText);
  }
  return json as T;
}

function checkBenefit(key: PolarLicenseKey) {
  const ids = config().proBenefitIds;
  if (ids.length && !ids.includes(key.benefit_id)) {
    throw new HTTPError({ status: 403, message: "This license key is not for VeyMotion Pro.", data: { code: "wrong_product" } });
  }
}

function buildToken(key: string, lk: PolarLicenseKey, activation: string, device: string) {
  const now = Math.floor(Date.now() / 1000);
  let exp = now + OFFLINE_DAYS * 86_400;
  const ends = lk.expires_at ? Math.floor(Date.parse(lk.expires_at) / 1000) : undefined;
  if (ends && ends < exp) exp = ends;
  const payload: LicensePayload = {
    v: 1,
    plan: "pro",
    key,
    keyId: lk.id,
    activation,
    benefit: lk.benefit_id,
    customer: lk.customer_id,
    device,
    email: lk.customer?.email ?? undefined,
    name: lk.customer?.name ?? undefined,
    licenseExpiresAt: lk.expires_at ?? undefined,
    iat: now,
    exp,
  };
  return { token: signToken(payload), license: describe(payload) };
}

/** What the app shows (never includes the full key). */
export function describe(p: LicensePayload) {
  return {
    plan: p.plan,
    email: p.email,
    name: p.name,
    keyHint: p.key.length > 8 ? `…${p.key.slice(-6)}` : undefined,
    licenseExpiresAt: p.licenseExpiresAt,
    validUntil: new Date(p.exp * 1000).toISOString(),
  };
}

/** Activates `key` on a Mac and returns a signed token. */
export async function activate(key: string, device: string, deviceName: string, appVersion?: string) {
  let activation: PolarActivation | undefined;
  try {
    activation = await polar<PolarActivation>("/v1/customer-portal/license-keys/activate", {
      key,
      label: deviceName.slice(0, 200) || "Mac",
      conditions: { device },
      meta: { device, app: (appVersion ?? "").slice(0, 40) },
    });
  } catch (error) {
    throw polarToHTTP(error, "activate");
  }
  if (!activation) throw new HTTPError({ status: 502, message: "Polar returned no activation." });
  checkBenefit(activation.license_key);
  return buildToken(key, activation.license_key, activation.id, device);
}

/** Checks the token's activation with Polar and returns a fresh token. Throws 402 if the license ended. */
export async function refresh(payload: LicensePayload) {
  const lk = await validateActivation(payload);
  checkBenefit(lk);
  return buildToken(payload.key, lk, payload.activation, payload.device);
}

export async function deactivate(payload: LicensePayload) {
  try {
    await polar("/v1/customer-portal/license-keys/deactivate", { key: payload.key, activation_id: payload.activation });
  } catch (error) {
    // Already gone counts as done.
    if (error instanceof PolarError && error.status === 404) return;
    throw polarToHTTP(error, "deactivate");
  }
}

async function validateActivation(payload: LicensePayload): Promise<PolarLicenseKey> {
  try {
    const lk = await polar<PolarLicenseKey>("/v1/customer-portal/license-keys/validate", {
      key: payload.key,
      activation_id: payload.activation,
      conditions: { device: payload.device },
    });
    if (!lk || lk.status !== "granted") throw new PolarError(404, "License is not active.");
    return lk;
  } catch (error) {
    throw polarToHTTP(error, "validate");
  }
}

function polarToHTTP(error: unknown, action: "activate" | "validate" | "deactivate"): HTTPError {
  if (error instanceof HTTPError) return error;
  if (!(error instanceof PolarError)) return new HTTPError({ status: 500, message: String(error) });
  const portal = config().portalUrl;
  switch (error.status) {
    case 0:
      return new HTTPError({ status: 502, message: error.message, data: { code: "polar_unreachable" } });
    case 403: {
      // Activation refused: revoked/disabled/expired key, or no activation left
      // (Polar says "License key only supports N activations.").
      const full = /limit|only supports|activations/i.test(error.message);
      return new HTTPError({
        status: 403,
        message: full
          ? `This license key is already active on its maximum number of Macs. Deactivate one${portal ? ` at ${portal}` : " in the customer portal"}, then try again.`
          : `This license key cannot be activated: ${error.message}`,
        data: { code: full ? "activation_limit" : "key_refused", portalUrl: portal || undefined },
      });
    }
    case 404:
      return new HTTPError({
        status: action === "activate" ? 404 : 402,
        message:
          action === "activate"
            ? "This license key does not exist."
            : "This license is no longer active (refunded, disabled, or this Mac was deactivated).",
        data: { code: action === "activate" ? "unknown_key" : "license_inactive" },
      });
    case 422:
      return new HTTPError({ status: 400, message: `Invalid license request: ${error.message}` });
    default:
      return new HTTPError({ status: 502, message: `Polar: ${error.message}`, data: { code: "polar_error" } });
  }
}

// MARK: - Gate for server features

const rechecks = new Map<string, { ok: boolean; until: number; error?: HTTPError }>();

/** The license token sent by the app (`Authorization: Bearer <token>`), verified, or undefined. */
export function tokenFrom(event: H3Event): LicensePayload | undefined {
  const auth = event.req.headers.get("Authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(auth);
  return readToken(match?.[1]);
}

/**
 * Throws unless the request carries a valid, unexpired Pro token whose activation Polar still accepts
 * (checked at most hourly per activation; if Polar is unreachable the signed token is trusted until it expires).
 */
export async function requirePro(event: H3Event, feature: string): Promise<LicensePayload> {
  const payload = tokenFrom(event);
  if (!payload) {
    throw new HTTPError({
      status: 402,
      message: `${feature} needs VeyMotion Pro.`,
      data: { code: "pro_required", checkoutUrl: config().checkoutUrl || undefined },
    });
  }
  if (payload.exp * 1000 < Date.now()) {
    throw new HTTPError({
      status: 402,
      message: "Your VeyMotion Pro license needs to be refreshed. Open the app's Account settings while online.",
      data: { code: "license_stale" },
    });
  }

  const now = Date.now();
  const cached = rechecks.get(payload.activation);
  if (cached && cached.until > now) {
    if (!cached.ok) throw cached.error!;
    return payload;
  }
  try {
    await validateActivation(payload);
    rechecks.set(payload.activation, { ok: true, until: now + RECHECK_MS });
  } catch (error) {
    const http = error as HTTPError;
    if (http.status === 402 || http.status === 403) {
      rechecks.set(payload.activation, { ok: false, until: now + RECHECK_FAILED_MS, error: http });
      throw http;
    }
    // Polar is down or misbehaving: the signed token stands. Retry soon.
    rechecks.set(payload.activation, { ok: true, until: now + RECHECK_FAILED_MS });
  }
  if (rechecks.size > 10_000) {
    for (const [k, v] of rechecks) if (v.until <= now) rechecks.delete(k);
  }
  return payload;
}

export function badRequest(message: string): HTTPError {
  return new HTTPError({ status: 400, message });
}
