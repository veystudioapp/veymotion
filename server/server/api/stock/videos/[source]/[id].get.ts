// GET /api/stock/videos/:source/:id — one video (same shape as a search result), for refs like "pexels:123".
import { HTTPError, defineHandler } from "nitro";
import { getRouterParam } from "nitro/h3";
import { badRequest, isVideoSource, videoById } from "../../../../utils/stock.ts";

export default defineHandler(async (event) => {
  const source = getRouterParam(event, "source");
  const id = getRouterParam(event, "id") ?? "";
  if (!isVideoSource(source)) throw badRequest("`source` must be pexels or pixabay.");
  const video = await videoById(source, id);
  if (!video) throw new HTTPError({ status: 404, message: `${source} has no video ${id}.` });
  return video;
});
