# So sánh tính năng: macOS → Windows

Tick ở cột Windows khi tính năng đã được triển khai đầy đủ trên bản Windows.

| STT | Feature name | Windows | macOS |
|---|---|---|---|
| 1 | Cửa sổ chính, canvas xem trước | ✅ | ✅ |
| 2 | Play/Pause, thanh tua, phát theo từng frame, tự lặp | ✅ | ✅ |
| 3 | Undo/Redo (300 bước, nhãn "Agent: …" cho thay đổi của Claude) | ✅ | ✅ |
| 4 | Open / Save / Save As | ✅ | ✅ |
| 5 | Project (thư mục có `scene.json` + `assets/`) | ✅ | ✅ |
| 6 | New Scene (⌘N) | ✅ | ✅ |
| 7 | Return = Play, ←/→ = frame trước/sau, ⌘⇧← = về đầu | ✅ | ✅ |
| 8 | RAM preview (`FrameCache`: dải xanh trên thước, render nền khi rảnh, Purge) | ✅ | ✅ |
| 9 | Render xem trước trên luồng nền, giảm độ phân giải khi phát | ✅ | ✅ |
| 10 | Panel Layers (sidebar) | ✅ | ✅ |
| 11 | Panel Assets (+ tab Shared) | ✅ | ✅ |
| 12 | Inspector (trường số, trường animate, nút keyframe, Particles inspector) | ✅ | ✅ |
| 13 | Timeline (keyframe, easing, kéo thả, zoom, vạch beat, dạng sóng) | ✅ | ✅ |
| 14 | Thanh trạng thái | ✅ | ✅ |
| 15 | Ẩn/hiện và nhớ trạng thái panel (⌃⌘S, ⌥⌘I, ⌃⌘T) | ✅ | ✅ |
| 16 | Chọn layer trên canvas, kéo để sửa (mỗi lần kéo là một bước undo) | ✅ | ✅ |
| 17 | Menu Add: Rectangle, Ellipse, Path, Text, Image, Video/Image Sequence, Audio | ✅ | ✅ |
| 18 | Menu Layer: Duplicate, Group, Ungroup, Delete, Bring Forward / Send Backward | ✅ | ✅ |
| 19 | Show in Finder (→ Explorer) | ✅ | ✅ |
| 20 | Sheet Export Video | ✅ | ✅ |
| 21 | Sheet Publish Video (YouTube, TikTok, Facebook Pages, X; OAuth, ảnh thumbnail, "Write with Claude") | ✅ | ✅ |
| 22 | Sheet Voice-over | ✅ | ✅ |
| 23 | Sheet Sound effect | ✅ | ✅ |
| 24 | Trình duyệt stock (ảnh, video, nhạc, âm thanh, icon, font) | ✅ | ✅ |
| 25 | Vẽ ghi chú lên frame (⇧⌘A) rồi gửi vào chat | ✅ | ✅ |
| 26 | Nghe âm thanh khi phát (`AudioPreview` / `AudioMixer`) | ✅ | ✅ |
| 27 | Đường dẫn tương đối trong project (`relativizingPaths` / `resolvePaths`) | ✅ | ✅ |
| 28 | Theo dõi thư mục asset để cập nhật trực tiếp (FSEvents) | ✅ | ✅ |
| 29 | Khung chat, câu trả lời hiện dần khi stream | ✅ | ✅ |
| 30 | Lần gọi tool: trạng thái ✓/✗, bấm để xem chi tiết | ✅ | ✅ |
| 31 | Ảnh frame Claude render, nhãn thời gian, bấm để nhảy playhead | ✅ | ✅ |
| 32 | Dòng trạng thái + số giây đã chạy, dòng chi phí khi xong | ✅ | ✅ |
| 33 | Markdown inline (đậm, nghiêng, code, link) | ✅ | ✅ |
| 34 | Bộ chọn model và effort, danh sách lấy từ `claude` | ✅ | ✅ |
| 35 | Đính kèm ảnh: dán, chọn file, tự thu nhỏ ≤ 2000 px | ✅ | ✅ |
| 36 | Kéo thả / dán file để chèn đường dẫn (Claude được quyền Read) | ✅ | ✅ |
| 37 | Enter để gửi, Shift+Enter xuống dòng, không gửi khi bộ gõ đang soạn | ✅ | ✅ |
| 38 | Phiên bản scene sau mỗi prompt, khôi phục được | ✅ | ✅ |
| 39 | Cuộc trò chuyện mới | ✅ | ✅ |
| 40 | Mỗi project một cuộc trò chuyện, resume phiên, fork khi là bản sao | ✅ | ✅ |
| 41 | Tự mở phiên mới khi không resume được | ✅ | ✅ |
| 42 | Dừng agent khi đổi project | ✅ | ✅ |
| 43 | Dòng `[VeyMotion context: …]` | ✅ | ✅ |
| 44 | Đính kèm frame có ghi chú (annotation) | ✅ | ✅ |
| 45 | `vmotion chat` (một lượt Claude trong terminal) | ✅ | ✅ |
| 46 | Layer `rect` | ✅ | ✅ |
| 47 | Layer `ellipse` | ✅ | ✅ |
| 48 | Layer `text` | ✅ | ✅ |
| 49 | Layer `path` (SVG path, hình như `star(…)`, morph) | ✅ | ✅ |
| 50 | Layer `image` (kể cả SVG) | ✅ | ✅ |
| 51 | Layer `video` / chuỗi ảnh | ✅ | ✅ |
| 52 | Layer `particles` (preset, turbulence, trail, sprite, phát từ chữ) | ✅ | ✅ |
| 53 | Layer `generator` (spectrum, waveform, noise, lightning, grid, chart, flare) | ✅ | ✅ |
| 54 | Layer `group` (sub-scene) | ✅ | ✅ |
| 55 | x, y, scale, scaleX/Y, rotation, skewX/Y | ✅ | ✅ |
| 56 | Layer cha (`parent`) | ✅ | ✅ |
| 57 | opacity | ✅ | ✅ |
| 58 | Fill / stroke màu đơn | ✅ | ✅ |
| 59 | Keyframe + mọi kiểu easing | ✅ | ✅ |
| 60 | `loop` (cycle, pingpong, offset) | ✅ | ✅ |
| 61 | anchorX/Y | ✅ | ✅ |
| 62 | Motion path + `pathProgress` | ✅ | ✅ |
| 63 | Camera (pan/zoom/xoay, `depth`, `fixed`, focus/aperture) | ✅ | ✅ |
| 64 | 2.5D: rotationX/Y, perspective, `hideBackface` | ✅ | ✅ |
| 65 | Corner pin, puppet pins | ✅ | ✅ |
| 66 | `blendMode` | ✅ | ✅ |
| 67 | Track matte (alpha/luma, đảo ngược) | ✅ | ✅ |
| 68 | Gradient (linear/radial, stops, shift) | ✅ | ✅ |
| 69 | Dash, lineCap, lineJoin, fillRule | ✅ | ✅ |
| 70 | Trim path (start/end/offset, `trimSequential`) | ✅ | ✅ |
| 71 | Path ops: offsetPath, zigzag, wigglePath, pucker, taper | ✅ | ✅ |
| 72 | Chữ: weight, italic, căn lề, maxWidth, reveal | ✅ | ✅ |
| 73 | Chữ: viền (stroke) | ✅ | ✅ |
| 74 | Chữ: `fontName` | ✅ | ✅ |
| 75 | Chữ: letterSpacing | ✅ | ✅ |
| 76 | Chữ: textAnimators (theo ký tự / từ / dòng) | ✅ | ✅ |
| 77 | Chữ: `{n}` counter, scramble | ✅ | ✅ |
| 78 | Chữ chạy theo đường (`textPath`) | ✅ | ✅ |
| 79 | blur | ✅ | ✅ |
| 80 | shadow | ✅ | ✅ |
| 81 | glow | ✅ | ✅ |
| 82 | motionBlur (góc màn trập) | ✅ | ✅ |
| 83 | repeater | ✅ | ✅ |
| 84 | Chỉnh màu: brightness, contrast, saturation, hue, tint | ✅ | ✅ |
| 85 | Wipe (linear, iris, blinds, blocks, radial; có feather) | ✅ | ✅ |
| 86 | Keying (keyColor, tolerance, softness) | ✅ | ✅ |
| 87 | Distort: waveWarp, ripple, twirl, bulge, turbulence | ✅ | ✅ |
| 88 | Stylize: posterize, pixelate, rgbSplit, glitch, grain, scanlines, vignette | ✅ | ✅ |
| 89 | directionalBlur, zoomBlur | ✅ | ✅ |
| 90 | Ánh sáng: shine, rays, outline, innerGlow | ✅ | ✅ |
| 91 | Grading: levels, curves, gradient map, LUT `.cube` | ✅ | ✅ |
| 92 | posterizeTime | ✅ | ✅ |
| 93 | wiggle | ✅ | ✅ |
| 94 | audioReact | ✅ | ✅ |
| 95 | links (liên kết thuộc tính giữa các layer) | ✅ | ✅ |
| 96 | Trộn và phát âm thanh (volume, fadeIn/Out, trimIn) | ✅ | ✅ |
| 97 | Ducking (nhạc nhỏ lại khi có giọng nói) | ✅ | ✅ |
| 98 | Phân tích nhạc: tempo, beat, downbeat, onset, loudness | ✅ | ✅ |
| 99 | Giải mã video (movie và chuỗi ảnh) | ✅ | ✅ |
| 100 | Tiếng của layer video | ✅ | ✅ |
| 101 | timeRemap, speed, playback (once/hold/loop) | ✅ | ✅ |
| 102 | frameBlend (blend / optical flow) | ✅ | ✅ |
| 103 | Chống rung (`stabilize`) | ✅ | ✅ |
| 104 | Bám theo vật thể (`track_motion`) | ✅ | ✅ |
| 105 | Tự reframe theo vùng chú ý (`auto_reframe`) | ✅ | ✅ |
| 106 | Tách nền người / vật thể (`removeBackground`) |  | ✅ |
| 107 | Đọc văn bản bằng giọng của hệ điều hành (có thời điểm từng từ) | ✅ | ✅ |
| 108 | Đọc văn bản bằng VieNeu (qua server Nitro) | ✅ | ✅ |
| 109 | Nhận diện giọng nói → transcript + thời điểm từng từ | ✅ | ✅ |
| 110 | Tự tạo phụ đề, thay chữ phụ đề (bản dịch) | ✅ | ✅ |
| 111 | Tổng hợp hiệu ứng âm thanh (`SoundSynth`) | ✅ | ✅ |
| 112 | Phân tích file hiệu ứng âm thanh (`SoundProfile`, `hitAt`) | ✅ | ✅ |
| 113 | Export MP4 (H.264), MOV (ProRes 4444 có alpha), preset nền tảng, fit/fill | ✅ | ✅ |
| 114 | Thư viện asset (thư mục con, đổi tên/di chuyển cập nhật layer, xóa vào Thùng rác) | ✅ | ✅ |
| 115 | Thư viện dùng chung (tab Shared) | ✅ | ✅ |
| 116 | Ghi credit / giấy phép (`.credits.json`) | ✅ | ✅ |
| 117 | Ảnh, nhạc, âm thanh miễn phí: Openverse, Jamendo, Freesound | ✅ | ✅ |
| 118 | Icon Iconify | ✅ | ✅ |
| 119 | Video stock Pexels / Pixabay (qua server Nitro) | ✅ | ✅ |
| 120 | Đăng ký font trong thư viện (.ttf/.otf/.ttc) | ✅ | ✅ |
| 121 | Google Fonts (tìm, xem trước, import) | ✅ | ✅ |
| 122 | Cảnh báo font thiếu / thiếu chữ (ví dụ chữ tiếng Việt) | ✅ | ✅ |
| 123 | Kênh điều khiển CLI ↔ app | ✅ | ✅ |
| 124 | MCP qua stdio (`vmotion mcp <scene.json>`) | ✅ | ✅ |
| 125 | `vmotion <tool> '<json>'` vào app hoặc `--scene` | ✅ | ✅ |
| 126 | `vmotion tools`, `vmotion docs`, `vmotion sample` | ✅ | ✅ |
| 127 | Tool schema dùng chung một nguồn (`Docs.swift`) | ✅ | ✅ |
| 128 | MCP qua HTTP `127.0.0.1:19790/mcp` (+ `VEYMOTION_TOKEN`) | ✅ | ✅ |
| 129 | `vmotion serve` (MCP HTTP cho một file) | ✅ | ✅ |
| 130 | `vmotion daemon` (kênh điều khiển cho một file, không cần app) | ✅ | ✅ |
| 131 | `vmotion frame` (render một frame ra PNG) | ✅ | ✅ |
| 132 | `vmotion render` (export video) | ✅ | ✅ |
| 133 | `vmotion chat` | ✅ | ✅ |
| 134 | Tool `get_scene` | ✅ | ✅ |
| 135 | Tool `update_scene` | ✅ | ✅ |
| 136 | Tool `reorder_layer` | ✅ | ✅ |
| 137 | Tool `set_scene` | ✅ | ✅ |
| 138 | Tool `add_layer` | ✅ | ✅ |
| 139 | Tool `add_layers` | ✅ | ✅ |
| 140 | Tool `update_layer` | ✅ | ✅ |
| 141 | Tool `remove_layer` | ✅ | ✅ |
| 142 | Tool `set_keyframes` | ✅ | ✅ |
| 143 | Tool `apply_preset` | ✅ | ✅ |
| 144 | Tool `render_frame` | ✅ | ✅ |
| 145 | Tool `transition` | ✅ | ✅ |
| 146 | Tool `group_layers` | ✅ | ✅ |
| 147 | Tool `ungroup` | ✅ | ✅ |
| 148 | Tool `set_parent` | ✅ | ✅ |
| 149 | Tool `add_template` | ✅ | ✅ |
| 150 | Tool `sync_to_beats` | ✅ | ✅ |
| 151 | Tool `shatter_image` | ✅ | ✅ |
| 152 | Tool `text_to_path` | ✅ | ✅ |
| 153 | Tool `combine_paths` | ✅ | ✅ |
| 154 | Tool `stabilize` | ✅ | ✅ |
| 155 | Tool `track_motion` | ✅ | ✅ |
| 156 | Tool `auto_reframe` | ✅ | ✅ |
| 157 | Tool `list_voices` | ✅ | ✅ |
| 158 | Tool `generate_voice` | ✅ | ✅ |
| 159 | Tool `generate_sfx` | ✅ | ✅ |
| 160 | Tool `add_audio` | ✅ | ✅ |
| 161 | Tool `get_audio_info` | ✅ | ✅ |
| 162 | Tool `analyze_audio` | ✅ | ✅ |
| 163 | Tool `add_captions` | ✅ | ✅ |
| 164 | Tool `transcribe` | ✅ | ✅ |
| 165 | Tool `set_caption_texts` | ✅ | ✅ |
| 166 | Tool `list_captions` | ✅ | ✅ |
| 167 | Tool `list_assets` | ✅ | ✅ |
| 168 | Tool `import_asset` | ✅ | ✅ |
| 169 | Tool `write_asset` | ✅ | ✅ |
| 170 | Tool `read_asset` | ✅ | ✅ |
| 171 | Tool `rename_asset` | ✅ | ✅ |
| 172 | Tool `delete_asset` | ✅ | ✅ |
| 173 | Tool `create_folder` | ✅ | ✅ |
| 174 | Tool `rename_folder` | ✅ | ✅ |
| 175 | Tool `delete_folder` | ✅ | ✅ |
| 176 | Tool `search_stock` | ✅ | ✅ |
| 177 | Tool `import_stock` | ✅ | ✅ |
| 178 | Tool `list_fonts` | ✅ | ✅ |
| 179 | Tool `get_credits` | ✅ | ✅ |
| 180 | Tool `export_video` | ✅ | ✅ |
