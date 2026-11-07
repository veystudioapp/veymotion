// GET /api/stock/videos?q=…&page=1&perPage=20&orientation=landscape|portrait|square&source=pexels|pixabay
// Free stock video from every configured source (see server/utils/stock.ts), results interleaved.
// Returns { results: StockVideo[], sources: ["pexels", …], errors: [ …sources that failed ] }.
import { defineHandler } from "nitro";
import { getQuery } from "nitro/h3";
import { badRequest, isVideoSource, searchVideos, type Orientation, type VideoSource } from "../../utils/stock.ts";

const ORIENTATIONS = ["landscape", "portrait", "square"];

export default defineHandler(async (event) => {
  const query = getQuery<{ q?: string; page?: string; perPage?: string; orientation?: string; source?: string }>(event);
  const q = (query.q ?? "").trim();
  if (!q) throw badRequest("`q` is required.");
  const page = Math.max(1, Number.parseInt(query.page ?? "1", 10) || 1);
  const perPage = Math.min(Math.max(Number.parseInt(query.perPage ?? "20", 10) || 20, 2), 80);
  const orientation = query.orientation || undefined;
  if (orientation && !ORIENTATIONS.includes(orientation)) throw badRequest(`\`orientation\` must be one of ${ORIENTATIONS.join(", ")}.`);
  const source = query.source || undefined;
  if (source !== undefined && !isVideoSource(source)) throw badRequest("`source` must be pexels or pixabay.");
  return searchVideos(q, { page, perPage, orientation: orientation as Orientation | undefined, source: source as VideoSource | undefined });
});
