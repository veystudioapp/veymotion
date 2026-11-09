// GET /api/app/latest — the newest app release (see server/utils/releases.ts):
// { version, notes, url, size, sha256, publishedAt, minimumSystemVersion, pageUrl }. 404 when there is none.
import { HTTPError, defineHandler } from "nitro";
import { latestRelease } from "../../utils/releases.ts";

export default defineHandler(async () => {
  const release = await latestRelease();
  if (!release) throw new HTTPError({ status: 404, message: "No release has been published yet." });
  return release;
});
