// Free stock video from Pexels (https://www.pexels.com/api/documentation/#videos) and Pixabay
// (https://pixabay.com/api/docs/#api_search_videos). The API keys stay on the server: the app calls
// /api/stock/videos and downloads the files straight from the CDNs (their URLs need no key).
import { HTTPError } from "nitro";
import { useRuntimeConfig } from "nitro/runtime-config";

export const VIDEO_SOURCES = ["pexels", "pixabay"] as const;
export type VideoSource = (typeof VIDEO_SOURCES)[number];
export type Orientation = "landscape" | "portrait" | "square";

/** One downloadable rendition (MP4). */
export interface VideoFile {
  url: string;
  width: number;
  height: number;
  fps?: number;
  size?: number;
}

/** A search result in the same shape for both sources. `ref` is what the app stores ("pexels:123"). */
export interface StockVideo {
  ref: string;
  source: VideoSource;
  id: string;
  title: string;
  creator?: string;
  creatorUrl?: string;
  pageUrl: string;
  thumbnail?: string;
  width: number;
  height: number;
  duration: number;
  tags: string[];
  /** Smallest first. */
  files: VideoFile[];
  license: string;
  licenseUrl: string;
}

interface StockRuntimeConfig {
  pexels?: { apiKey?: string };
  pixabay?: { apiKey?: string };
}

/** NITRO_PEXELS_API_KEY / NITRO_PIXABAY_API_KEY (PEXELS_API_KEY / PIXABAY_API_KEY also work). */
export function apiKey(source: VideoSource): string {
  const rc = useRuntimeConfig() as StockRuntimeConfig;
  return rc[source]?.apiKey || process.env[`${source.toUpperCase()}_API_KEY`] || "";
}

export function configuredSources(): VideoSource[] {
  return VIDEO_SOURCES.filter((s) => !!apiKey(s));
}

export function isVideoSource(s: string | undefined): s is VideoSource {
  return !!s && (VIDEO_SOURCES as readonly string[]).includes(s);
}

export function badRequest(message: string): HTTPError {
  return new HTTPError({ status: 400, message });
}

export function notConfigured(): HTTPError {
  return new HTTPError({
    status: 503,
    message:
      "Stock video is not configured on the server: set NITRO_PEXELS_API_KEY (https://www.pexels.com/api/) " +
      "and/or NITRO_PIXABAY_API_KEY (https://pixabay.com/api/docs/) in server/.env and restart it.",
  });
}

async function getJSON(source: VideoSource, url: string, headers: Record<string, string> = {}): Promise<any> {
  let res: Response;
  try {
    res = await fetch(url, { headers });
  } catch (cause) {
    throw new HTTPError({ status: 502, message: `Could not reach ${name(source)}.`, cause });
  }
  if (res.status === 404) return undefined;
  if (!res.ok) {
    const text = (await res.text().catch(() => "")).slice(0, 300);
    const headers = new Headers();
    const retryAfter = res.headers.get("Retry-After");
    if (retryAfter) headers.set("Retry-After", retryAfter);
    throw new HTTPError({
      status: res.status === 429 ? 429 : 502,
      message: `${name(source)} returned HTTP ${res.status}${text ? `: ${text}` : ""}`,
      headers,
    });
  }
  return res.json();
}

function name(source: VideoSource): string {
  return source === "pexels" ? "Pexels" : "Pixabay";
}

function orientationOf(w: number, h: number): Orientation {
  if (w > h * 1.1) return "landscape";
  if (h > w * 1.1) return "portrait";
  return "square";
}

// MARK: Pexels

/** Pexels videos have no title; the page URL's slug describes them ("/video/aerial-view-of-a-city-123/"). */
function titleFromSlug(pageUrl: string, id: string): string {
  const slug = pageUrl.split("/").filter(Boolean).pop() ?? "";
  const words = slug.replace(new RegExp(`-?${id}$`), "").replace(/-/g, " ").trim();
  return words ? words[0].toUpperCase() + words.slice(1) : `Pexels video ${id}`;
}

function pexelsVideo(v: any): StockVideo | undefined {
  if (!v?.id) return undefined;
  const id = String(v.id);
  const files: VideoFile[] = (v.video_files ?? [])
    .filter((f: any) => f?.link && f.width && f.height && (f.file_type ?? "video/mp4") === "video/mp4")
    .map((f: any) => ({ url: f.link, width: f.width, height: f.height, fps: f.fps ? Math.round(f.fps * 100) / 100 : undefined }))
    .sort((a: VideoFile, b: VideoFile) => a.width * a.height - b.width * b.height);
  if (!files.length) return undefined;
  const pageUrl = v.url ?? `https://www.pexels.com/video/${id}/`;
  return {
    ref: `pexels:${id}`,
    source: "pexels",
    id,
    title: titleFromSlug(pageUrl, id),
    creator: v.user?.name,
    creatorUrl: v.user?.url,
    pageUrl,
    thumbnail: v.image ?? v.video_pictures?.[0]?.picture,
    width: v.width,
    height: v.height,
    duration: v.duration ?? 0,
    tags: (v.tags ?? []).filter((t: unknown) => typeof t === "string"),
    files,
    license: "Pexels License (free to use, no credit needed)",
    licenseUrl: "https://www.pexels.com/license/",
  };
}

async function searchPexels(q: string, page: number, perPage: number, orientation?: Orientation): Promise<StockVideo[]> {
  const url = new URL("https://api.pexels.com/videos/search");
  url.searchParams.set("query", q);
  url.searchParams.set("page", String(page));
  url.searchParams.set("per_page", String(perPage));
  if (orientation) url.searchParams.set("orientation", orientation);
  const body = await getJSON("pexels", url.href, { Authorization: apiKey("pexels") });
  return (body?.videos ?? []).map(pexelsVideo).filter(Boolean) as StockVideo[];
}

// MARK: Pixabay

function pixabayVideo(h: any): StockVideo | undefined {
  if (!h?.id) return undefined;
  const id = String(h.id);
  const sizes = Object.values(h.videos ?? {}) as any[];
  const files: VideoFile[] = sizes
    .filter((f) => f?.url && f.width && f.height)
    .map((f) => ({ url: f.url, width: f.width, height: f.height, size: f.size || undefined }))
    .sort((a, b) => a.width * a.height - b.width * b.height);
  if (!files.length) return undefined;
  const largest = files[files.length - 1];
  const tags = String(h.tags ?? "")
    .split(",")
    .map((t) => t.trim())
    .filter(Boolean);
  // Newer responses carry a thumbnail per size; older ones only a Vimeo picture id.
  const thumbnail =
    h.videos?.small?.thumbnail ||
    h.videos?.medium?.thumbnail ||
    (h.picture_id ? `https://i.vimeocdn.com/video/${h.picture_id}_640x360.jpg` : undefined);
  return {
    ref: `pixabay:${id}`,
    source: "pixabay",
    id,
    title: tags.length ? tags.slice(0, 3).join(", ") : `Pixabay video ${id}`,
    creator: h.user,
    creatorUrl: h.user && h.user_id ? `https://pixabay.com/users/${h.user}-${h.user_id}/` : undefined,
    pageUrl: h.pageURL ?? `https://pixabay.com/videos/id-${id}/`,
    thumbnail,
    width: largest.width,
    height: largest.height,
    duration: h.duration ?? 0,
    tags,
    files,
    license: "Pixabay Content License (free to use, no credit needed)",
    licenseUrl: "https://pixabay.com/service/license-summary/",
  };
}

async function pixabayHits(params: Record<string, string>): Promise<any[]> {
  const url = new URL("https://pixabay.com/api/videos/");
  url.searchParams.set("key", apiKey("pixabay"));
  url.searchParams.set("safesearch", "true");
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const body = await getJSON("pixabay", url.href);
  return body?.hits ?? [];
}

async function searchPixabay(q: string, page: number, perPage: number, orientation?: Orientation): Promise<StockVideo[]> {
  // Pixabay's video search has no orientation filter: ask for more and filter here.
  const hits = await pixabayHits({
    q: q.slice(0, 100),
    page: String(page),
    per_page: String(Math.max(3, Math.min(orientation ? perPage * 2 : perPage, 200))),
  });
  let videos = hits.map(pixabayVideo).filter(Boolean) as StockVideo[];
  if (orientation) videos = videos.filter((v) => orientationOf(v.width, v.height) === orientation).slice(0, perPage);
  return videos;
}

// MARK: Public API

/**
 * Searches every configured source and interleaves the results (one from each in turn), so neither
 * source buries the other. A source that fails is skipped as long as another one answered.
 */
export async function searchVideos(
  q: string,
  opts: { page: number; perPage: number; orientation?: Orientation; source?: VideoSource },
): Promise<{ results: StockVideo[]; sources: VideoSource[]; errors: string[] }> {
  const sources = configuredSources().filter((s) => !opts.source || s === opts.source);
  if (!sources.length) throw notConfigured();
  const each = Math.ceil(opts.perPage / sources.length);
  const settled = await Promise.allSettled(
    sources.map((s) =>
      s === "pexels" ? searchPexels(q, opts.page, each, opts.orientation) : searchPixabay(q, opts.page, each, opts.orientation),
    ),
  );
  const lists: StockVideo[][] = [];
  const errors: string[] = [];
  settled.forEach((r, i) => {
    if (r.status === "fulfilled") lists.push(r.value);
    else errors.push(r.reason instanceof Error ? r.reason.message : `${name(sources[i])} failed`);
  });
  if (!lists.length) {
    const first = settled.find((r) => r.status === "rejected") as PromiseRejectedResult | undefined;
    throw first?.reason instanceof HTTPError ? first.reason : new HTTPError({ status: 502, message: errors.join("; ") });
  }
  const results: StockVideo[] = [];
  for (let i = 0; lists.some((l) => i < l.length); i++) {
    for (const l of lists) if (i < l.length) results.push(l[i]);
  }
  return { results, sources, errors };
}

/** One video by source and id, or undefined if the source does not have it. */
export async function videoById(source: VideoSource, id: string): Promise<StockVideo | undefined> {
  if (!apiKey(source)) throw notConfigured();
  if (!/^\d+$/.test(id)) throw badRequest("Video ids are numeric.");
  if (source === "pexels") {
    return pexelsVideo(await getJSON("pexels", `https://api.pexels.com/videos/videos/${id}`, { Authorization: apiKey("pexels") }));
  }
  return pixabayVideo((await pixabayHits({ id }))[0]);
}
