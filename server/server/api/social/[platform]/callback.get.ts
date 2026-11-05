// GET /api/social/:platform/callback — where the platform sends the browser after consent.
// Register <public URL>/api/social/<platform>/callback as the redirect URI in each developer console.
import { defineHandler } from "nitro";
import { getQuery, getRouterParam } from "nitro/h3";
import {
  exchangeCode,
  findPending,
  isPlatform,
  platformName,
  requireProvider,
  resultPage,
} from "../../../utils/social.ts";

export default defineHandler(async (event) => {
  const platform = getRouterParam(event, "platform");
  if (!isPlatform(platform)) return resultPage("Không kết nối được", "Nền tảng không hợp lệ.", false);
  const name = platformName(platform);
  const q = getQuery<Record<string, string | undefined>>(event);
  const entry = findPending(q.state);
  if (!entry || entry.platform !== platform) {
    return resultPage("Phiên kết nối đã hết hạn", "Quay lại VeyMotion và bấm Kết nối lại.", false);
  }
  if (entry.result) return resultPage(`Đã xử lý kết nối ${name}`, "Bạn có thể đóng tab này.", true);

  if (q.error || !q.code) {
    const reason = q.error_description || q.error_message || q.error || "Không nhận được mã xác thực.";
    entry.result = { error: `${name}: ${reason}` };
    return resultPage(`Chưa kết nối ${name}`, reason, false);
  }
  try {
    const tokens = await exchangeCode(platform, requireProvider(platform), q.code, entry);
    entry.result = { tokens };
    return resultPage(`Đã kết nối ${name}`, "Quay lại VeyMotion để đăng video. Bạn có thể đóng tab này.", true);
  } catch (e: any) {
    const message = e?.message || String(e);
    entry.result = { error: message };
    return resultPage(`Chưa kết nối ${name}`, message, false);
  }
});
