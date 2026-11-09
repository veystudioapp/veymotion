// App updates from GitHub Releases. The app asks GET /api/app/latest; the newest published (non-draft,
// non-prerelease) release of NITRO_UPDATES_REPO ("owner/name") with a .zip asset holding "Vey Motion.app" is it.
// The tag is the version ("v0.2.0" or "0.2.0"); the release body is the notes.
// For a private repo set NITRO_UPDATES_GITHUB_TOKEN (read access to contents): the download URL then points at
// /api/app/download/:assetId, which redirects to GitHub's short-lived signed URL so the token never leaves here.
import { HTTPError } from "nitro";
import { useRuntimeConfig } from "nitro/runtime-config";

/** What the app decodes (`AppRelease` in Sources/VeyMotionCore/AppVersion.swift). */
export interface AppRelease {
  version: string;
  build?: string;
  notes?: string;
  /** Absolute, or relative to this server (private repos). */
  url: string;
  size?: number;
  sha256?: string;
  publishedAt?: string;
  minimumSystemVersion?: string;
  pageUrl?: string;
}

interface UpdatesRuntimeConfig {
  updates?: { repo?: string; githubToken?: string; minimumSystemVersion?: string };
}

interface GitHubAsset {
  id: number;
  name: string;
  size: number;
  state: string;
  browser_download_url: string;
  digest?: string | null;
}

interface GitHubRelease {
  tag_name: string;
  name?: string | null;
  body?: string | null;
  draft: boolean;
  prerelease: boolean;
  published_at?: string | null;
  html_url: string;
  assets: GitHubAsset[];
}

function config() {
  const rc = (useRuntimeConfig() as UpdatesRuntimeConfig).updates ?? {};
  return {
    repo: rc.repo || process.env.UPDATES_REPO || "",
    token: rc.githubToken || process.env.UPDATES_GITHUB_TOKEN || "",
    minimumSystemVersion: rc.minimumSystemVersion || "14.0",
  };
}

function requireRepo(): string {
  const { repo } = config();
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) {
    throw new HTTPError({ status: 503, message: "Updates are not configured on this server (NITRO_UPDATES_REPO)." });
  }
  return repo;
}

function githubHeaders(accept = "application/vnd.github+json"): Record<string, string> {
  const h: Record<string, string> = {
    Accept: accept,
    "User-Agent": "VeyMotion-update-server",
    "X-GitHub-Api-Version": "2022-11-28",
  };
  const { token } = config();
  if (token) h.Authorization = `Bearer ${token}`;
  return h;
}

/** The app's zip: a .zip asset, preferring one whose name mentions mac. */
function pickAsset(assets: GitHubAsset[]): GitHubAsset | undefined {
  const zips = assets.filter((a) => a.state === "uploaded" && a.name.toLowerCase().endsWith(".zip"));
  return zips.find((a) => /mac/i.test(a.name)) ?? zips[0];
}

const CACHE_MS = 5 * 60 * 1000;
let cache: { at: number; release: AppRelease | null } | undefined;

/** The newest release with an app zip, or null when there is none. Cached for five minutes. */
export async function latestRelease(): Promise<AppRelease | null> {
  if (cache && Date.now() - cache.at < CACHE_MS) return cache.release;
  const repo = requireRepo();
  const res = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=20`, { headers: githubHeaders() });
  if (!res.ok) {
    throw new HTTPError({ status: 502, message: `GitHub returned HTTP ${res.status} for ${repo}'s releases.` });
  }
  const releases = (await res.json()) as GitHubRelease[];
  let release: AppRelease | null = null;
  for (const r of releases) {
    if (r.draft || r.prerelease) continue;
    const asset = pickAsset(r.assets);
    if (!asset) continue;
    const { token, minimumSystemVersion } = config();
    const sha = asset.digest?.startsWith("sha256:") ? asset.digest.slice(7) : undefined;
    release = {
      version: r.tag_name.replace(/^v/i, ""),
      notes: r.body ?? undefined,
      url: token ? `/api/app/download/${asset.id}` : asset.browser_download_url,
      size: asset.size,
      sha256: sha,
      publishedAt: r.published_at ?? undefined,
      minimumSystemVersion,
      pageUrl: token ? undefined : r.html_url,
    };
    break; // GitHub lists newest first
  }
  cache = { at: Date.now(), release };
  return release;
}

/** GitHub's signed download URL for an asset of the configured repo. */
export async function assetDownloadUrl(assetId: string): Promise<string> {
  if (!/^\d+$/.test(assetId)) throw new HTTPError({ status: 400, message: "Invalid asset id." });
  const repo = requireRepo();
  const res = await fetch(`https://api.github.com/repos/${repo}/releases/assets/${assetId}`, {
    headers: githubHeaders("application/octet-stream"),
    redirect: "manual",
  });
  const location = res.headers.get("location");
  if (res.status >= 300 && res.status < 400 && location) return location;
  if (res.status === 404) throw new HTTPError({ status: 404, message: "No such release file." });
  throw new HTTPError({ status: 502, message: `GitHub returned HTTP ${res.status} for the release file.` });
}
