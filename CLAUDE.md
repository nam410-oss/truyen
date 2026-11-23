# CLAUDE.md

Hướng dẫn cho Claude Code khi làm việc trong dự án này.

## Tổng quan dự án

Website đọc truyện cá nhân: chủ site tự đăng các bộ truyện (chủ yếu là bản dịch tiếng Việt, thể loại tiên hiệp/huyền huyễn), người xem vào đọc miễn phí. **Không** có đăng ký tài khoản, bình luận hay thanh toán ở giai đoạn đầu.

- Ngôn ngữ giao diện: **tiếng Việt** (toàn bộ text UI, URL slug không dấu).
- Đối tượng: người đọc trên **điện thoại là chính** → mobile-first.
- Ưu tiên: tốc độ tải trang, trải nghiệm đọc dễ chịu, SEO tốt.

## Tech stack

- **Next.js (App Router) + TypeScript**, render tĩnh (SSG) — mọi trang truyện/chương được build sẵn.
- **Tailwind CSS** cho styling. Không dùng UI kit nặng.
- **Nội dung lưu dạng file** trong repo (Markdown + JSON), không dùng database.
- Deploy: **Vercel** (hoặc bất kỳ host static nào qua `next build` với `output: 'export'`).
- Package manager: `npm`.

> Lưu ý môi trường: máy hiện **chưa cài Node.js và Python**. Trước khi chạy lệnh, nhắc người dùng cài Node.js LTS (>= 20) từ nodejs.org.

## Bản demo tĩnh hiện tại (trước khi chuyển sang Next.js)

Chạy được ngay bằng cách mở file trong trình duyệt, không cần Node:

- `index.html` (trang chủ), `truyen.html?s=<slug>` (trang truyện), `doc.html?s=<slug>&c=<n>` (trang đọc).
- `assets/style.css` + `assets/app.js`: CSS/JS dùng chung (header, footer, ảnh bìa CSS, localStorage).
- `data/stories.js`: bundle `window.STORIES` **sinh tự động**, không sửa tay.
- Thêm/cập nhật truyện: tạo `content/truyen/<slug>/meta.json` (khai báo `sourceFiles` là các file .docx), rồi chạy:
  `powershell -ExecutionPolicy Bypass -File scripts\import-docx.ps1`
  Script sẽ ghi lại toàn bộ `chuong-XXX.md` và `data/stories.js`.
- `scripts/import-docx.ps1` **phải lưu dạng UTF-8 có BOM** (PowerShell 5.1 đọc file không BOM theo ANSI, regex "Chương" sẽ không khớp). Có chế độ `-PreviewFile <docx>` chỉ in danh sách chương dạng JSON, không ghi gì.

### Trang "Đăng chương" (chỉ dùng trên máy mình)

- Chạy server cục bộ: `powershell -ExecutionPolicy Bypass -File scripts\server.ps1` → mở `http://localhost:8080/dang-chuong.html`.
- `scripts/server.ps1` (HttpListener, chỉ nghe localhost) phục vụ web tĩnh + 2 API:
  `POST /api/preview?name=` (lưu tạm vào `.upload-tmp/`, gọi import `-PreviewFile`) và
  `POST /api/publish` (chuyển file vào `raw/`, thêm vào `sourceFiles`, cập nhật `updatedAt`, chạy import; lỗi thì khôi phục).
- Mọi POST bắt buộc header `X-Admin: 1` + Origin localhost (chống trang lạ gửi request giả). Server cũng phải lưu UTF-8 có BOM.
- Link "+ Đăng chương" trên header chỉ hiện khi chạy ở localhost/file://, không hiện trên web public. Khi deploy lên host tĩnh thì trang này không hoạt động (không có API), đó là chủ ý.
- File .docx mới được lưu vào `raw/`; import tìm trong `raw/` trước, rồi tới thư mục gốc.
- Tự đẩy lên GitHub (checkbox, mặc định bật): sau khi import thành công, server chỉ `git add/commit` **`content/` và `data/`** (không đụng file code) rồi `git push origin HEAD`. Push lỗi thì chương vẫn được lưu trên máy, trang hiện nút "Thử đẩy lại" (`POST /api/push`). Git được gọi qua `Diagnostics.Process` vì PS 5.1 coi stderr của git là lỗi.

## Deploy

- Repo: https://github.com/nam410-oss/truyen (nhánh `main`), web: https://nam410-oss.github.io/truyen/ (GitHub Pages, deploy từ `main` / root, có `.nojekyll`).
- `.gitignore` loại `*.docx`, `raw/`, `.upload-tmp/` và ảnh tham khảo — không đưa file Word gốc lên repo public.

## Lệnh thường dùng

```bash
npm install          # cài dependencies
npm run dev          # chạy dev server tại http://localhost:3000
npm run build        # build production (kiểm tra lỗi type + SSG)
npm run lint         # ESLint
npm run import       # chuyển file .docx trong raw/ thành Markdown trong content/
```

## Cấu trúc thư mục (mục tiêu)

```
raw/                         # file .docx gốc do chủ site upload (không chỉnh tay)
content/truyen/<slug>/
  meta.json                  # thông tin bộ truyện
  cover.jpg                  # ảnh bìa (tỉ lệ 3:4)
  chuong-001.md              # mỗi chương 1 file, đánh số 3 chữ số
  chuong-002.md
scripts/import-docx.ts       # script import docx → markdown
src/app/                     # route Next.js
src/components/              # component UI
src/lib/content.ts           # đọc/parse content (chỉ chạy lúc build)
public/
```

### Định dạng `meta.json`

```json
{
  "title": "Tên truyện",
  "slug": "ten-truyen",
  "author": "Tác giả",
  "translator": "Người dịch",
  "genres": ["Tiên Hiệp", "Huyền Huyễn"],
  "status": "dang-ra",          // "dang-ra" | "hoan-thanh"
  "description": "Giới thiệu ngắn...",
  "featured": true,             // hiện ở mục "Truyện đề cử"
  "updatedAt": "2026-11-23"
}
```

### Định dạng file chương

```markdown
---
number: 1
title: "Xưa kết oán bốn phương, nay tu vi mất hết"
publishedAt: "2026-11-23"
---

Nội dung chương, mỗi đoạn cách nhau 1 dòng trống.
```

## Import nội dung từ .docx

Truyện được chủ site soạn trong Word, mỗi file chứa ~10 chương (vd. `Truyen_chuong31-40_VI.docx`). Đặc điểm file hiện có:

- Có thể có dòng tiêu đề đầu file kiểu `Bản dịch tiếng Việt` / `(Chương 01 – 10)` → bỏ qua.
- Mỗi chương bắt đầu bằng dòng `Chương NN: Tên chương` → dùng làm ranh giới tách chương.
- `* * *` là dấu ngắt cảnh → giữ lại, render thành divider.
- Hội thoại dùng ngoặc kép cong `“ ”` → giữ nguyên, không đổi sang `"`.
- Một số file có nền đen (tên chứa `nen_den`) → bỏ toàn bộ màu/format nền, chỉ lấy text thuần.

Script `scripts/import-docx.ts` dùng thư viện `mammoth` để lấy raw text, tách chương theo regex `^Chương\s+(\d+)\s*[:：]\s*(.+)$`, ghi ra `chuong-XXX.md`. Script phải **idempotent** (chạy lại không tạo trùng) và báo cảnh báo nếu số chương bị nhảy/thiếu.

## Routes

| URL | Trang |
|---|---|
| `/` | Trang chủ |
| `/truyen/[slug]` | Chi tiết truyện + danh sách chương |
| `/truyen/[slug]/chuong-[n]` | Trang đọc chương |
| `/the-loai/[genre]` | Danh sách truyện theo thể loại |
| `/tim-kiem?q=` | Tìm kiếm (client-side trên index JSON build sẵn) |
| `/hoan-thanh` | Truyện đã hoàn thành |

## Design system (theo phong cách metruyenchu)

Ảnh tham khảo: `metruyenchu_nho_10x.png` (lấy bố cục, **không** lấy màu nền). Phong cách: **sạch, thoáng, NỀN ĐEN (dark mode mặc định), nội dung dày đặc dạng danh sách, nhấn màu cam**.

### Màu sắc (nền đen là mặc định cho toàn site)
- Mọi màu đi qua token CSS trên `:root` trong `assets/style.css` — **không hard-code màu sáng** (`#fff`, `#ddd`...) cho nền/viền/chữ; chỉ dùng `#fff` cho chữ nằm trên nền màu (nút cam, badge, bìa).
- Nền trang `--bg: #121212`; khối phụ `--bg-soft: #1a1a1a`; dải tiêu đề/footer `--bg-band: #222`; header `--header-bg: #181818`; ô nhập `--input-bg: #262626`.
- Màu nhấn (logo, link hover, tiêu đề section, badge, nút): **cam** `--primary: #e8792b`; nền cam nhạt `--primary-soft: #3a2616`.
- Chữ: chính `--text: #d4d4d4`, đậm/tiêu đề `--text-strong: #ededed`, phụ `--text-soft: #b0b0b0`, mờ (thời gian, thể loại, số chương) `--muted: #8c8c8c`.
- Viền mảnh `--line: #2b2b2b`, viền ô nhập `--line-strong: #3a3a3a`.
- Thông báo dùng token `--ok-*`, `--warn-*`, `--err-*` (nền tối, chữ sáng); "Full" xanh lá `--green`, "Mới/NEW" cam.
- `color-scheme: dark` để thanh cuộn và ô form cũng tối.
- Chế độ nền khác chỉ có ở trang đọc: `body.theme-white` (trắng) và `body.theme-sepia` (vàng giấy) ghi đè lại các token trên.

### Bố cục
- Container giữa trang, `max-width: 1140px`, padding ngang 16px trên mobile.
- **Header**: logo chữ màu cam bên trái, ô tìm kiếm bên phải, thanh menu thể loại bên dưới. Header gọn, không sticky lớn.
- **Tiêu đề section**: chữ đậm, có gạch dưới/viền trái màu cam, link "Xem thêm" bên phải.

### Trang chủ (theo thứ tự từ trên xuống)
1. **Truyện đề cử** – lưới ảnh bìa (desktop 6 cột × 2 hàng, mobile 3 cột), bìa tỉ lệ 3:4, bo góc nhẹ, tên truyện overlay ở đáy ảnh.
2. **Truyện mới cập nhật** – bảng/danh sách dạng dòng: tên truyện (đậm) · chương mới nhất · thể loại · thời gian ("2 giờ trước"). Các dòng ngăn bằng viền mảnh, hover đổi nền nhạt. Trên mobile ẩn cột thể loại.
3. **Thể loại** – danh sách link thể loại chia nhiều cột (desktop 4 cột, mobile 2 cột).
4. **Truyện đã hoàn thành** – lưới ảnh bìa giống mục đề cử, có badge "Full".
5. **Khối giới thiệu site** (text SEO) và **footer** đơn giản.

### Trang đọc chương (quan trọng nhất)
- Cột nội dung hẹp (`max-width: ~720px`), font serif dễ đọc, cỡ chữ mặc định 20px, `line-height: 1.8`.
- Thanh điều hướng **Chương trước / Danh sách chương / Chương sau** ở cả đầu và cuối chương.
- Cài đặt đọc (lưu `localStorage` key `reader:settings`, bọc try/catch): cỡ chữ, font, **chế độ nền**: `dark` (**mặc định**, Đen) / `sepia` (Vàng giấy) / `white` (Trắng). Giá trị cũ `"light"` từ bản nền trắng được tự chuyển thành `dark`.
- Hỗ trợ phím `←` / `→` để chuyển chương.
- Lưu vị trí "đang đọc dở" theo truyện vào `localStorage`, hiển thị "Đọc tiếp" ở trang truyện.

## Quy ước code

- TypeScript strict; không dùng `any`.
- Server Components mặc định; chỉ thêm `"use client"` cho phần cần tương tác (cài đặt đọc, tìm kiếm, phím tắt).
- Mọi việc đọc file content nằm trong `src/lib/content.ts`, chỉ chạy lúc build (`generateStaticParams`).
- Dùng `next/image` cho ảnh bìa; luôn có `alt` là tên truyện.
- Slug: chuyển tiếng Việt sang không dấu, chữ thường, nối bằng `-` (xử lý cả `đ` → `d`).
- Thời gian hiển thị tương đối bằng tiếng Việt ("5 phút trước", "3 ngày trước").
- Mỗi trang có `metadata` (title, description, Open Graph với ảnh bìa) để tốt cho SEO.
- Không thêm thư viện mới khi chưa cần; hỏi trước nếu định thêm dependency lớn.

## Không làm (trừ khi được yêu cầu)

- Không thêm backend, database, đăng nhập, bình luận, quảng cáo.
- Không sửa file trong `raw/` — đó là bản gốc của chủ site.
- Không tự ý sửa nội dung bản dịch (chính tả, câu chữ); chỉ chuẩn hoá khoảng trắng/xuống dòng.
- Không sao chép logo, tên thương hiệu hay asset của metruyenchu — chỉ lấy cảm hứng bố cục và phong cách.
