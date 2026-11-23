// Helper dùng chung cho index.html, truyen.html, doc.html.
// Dữ liệu truyện đến từ data/stories.js (sinh bởi scripts/import-docx.ps1).

const SITE_NAME = "ĐọcTruyệnChữ";
const STORIES = window.STORIES || [];

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const $ = (sel) => document.querySelector(sel);
const params = new URLSearchParams(location.search);

// localStorage có thể bị chặn (chế độ riêng tư...), nên luôn bọc try/catch.
const store = {
  get(key, fallback) {
    try { const v = localStorage.getItem(key); return v == null ? fallback : JSON.parse(v); } catch { return fallback; }
  },
  set(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* bỏ qua */ }
  },
};

const storyUrl = (s) => `truyen.html?s=${encodeURIComponent(s.slug)}`;
const chapterUrl = (s, n) => `doc.html?s=${encodeURIComponent(s.slug)}&c=${n}`;
const findStory = (slug) => STORIES.find((s) => s.slug === slug) || null;
const getProgress = (s) => store.get(`progress:${s.slug}`, null);
const statusText = (s) => (s.status === "hoan-thanh" ? "Hoàn thành" : "Đang ra");

// "Hôm nay", "Hôm qua", "3 ngày trước"...
function relTime(dateStr) {
  const d = new Date(dateStr + "T00:00:00");
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const days = Math.round((today - d) / 86400000);
  if (isNaN(days)) return "";
  if (days <= 0) return "Hôm nay";
  if (days === 1) return "Hôm qua";
  if (days < 30) return `${days} ngày trước`;
  return d.toLocaleDateString("vi-VN");
}

// Ảnh bìa tạm tạo bằng CSS (khi chưa có ảnh bìa thật).
const PALETTES = [
  ["linear-gradient(180deg,#0e1630 0%,#2b2d6b 38%,#8a4fa3 68%,#f2b27a 100%)", "#ffe6a8", "#2a0f3a", "#c0392b"],
  ["linear-gradient(180deg,#9fc3e6 0%,#c9a77a 32%,#1d4f7d 55%,#0b2944 100%)", "#ffd36b", "#5a2a00", "#d35400"],
  ["linear-gradient(180deg,#1a0a00 0%,#7a1d00 35%,#e8641b 60%,#ffb43a 80%,#3a0f00 100%)", "#ffe082", "#4a0d00", "#b71c1c"],
  ["linear-gradient(200deg,#0d1b2a 0%,#1b3a5c 40%,#3d6b8a 70%,#0d1b2a 100%)", "#9fd3ff", "#001b33", "#1f6fb2"],
];
const hashStr = (s) => [...s].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7);

function coverHTML(story, { badge = "" } = {}) {
  if (story.cover) return `<img class="cover" src="${esc(story.cover)}" alt="${esc(story.title)}" style="width:100%;height:100%;object-fit:cover;padding:0">`;
  const [art, tc, ts, sb] = PALETTES[hashStr(story.slug) % PALETTES.length];
  // Tách tên dài thành dòng chính + dòng phụ tại dấu phẩy/hai chấm hoặc sau 3 chữ đầu.
  let main = story.title, sub = "";
  const cut = story.title.search(/[,:]/);
  if (cut > 0) { main = story.title.slice(0, cut); sub = story.title.slice(cut + 1).trim(); }
  const words = main.split(" ");
  if (words.length > 4) { sub = words.slice(3).join(" ") + (sub ? ", " + sub : ""); main = words.slice(0, 3).join(" "); }
  return `<div class="cover" style="--art:${art};--tc:${tc};--ts:${ts};--sb:${sb}">
    <span class="t">${esc(main)}</span>${sub ? `<span class="st">${esc(sub)}</span>` : ""}${badge ? `<span class="s">${esc(badge)}</span>` : ""}</div>`;
}

// Link "Đăng chương" chỉ hiện khi chạy trên máy mình (server cục bộ hoặc mở file trực tiếp).
const isLocal = location.protocol === "file:" || ["localhost", "127.0.0.1"].includes(location.hostname);

// Header + tagline + footer dùng chung.
function renderChrome(tagline) {
  const header = document.createElement("div");
  header.innerHTML = `
  <header class="header">
    <div class="container">
      <a class="logo" href="index.html" aria-label="Trang chủ ${SITE_NAME}">
        <svg viewBox="0 0 40 40" aria-hidden="true">
          <circle cx="20" cy="20" r="19" fill="#e8792b"/>
          <path d="M10 13c4-1 7 0 10 2 3-2 6-3 10-2v15c-4-1-7 0-10 2-3-2-6-3-10-2z" fill="#fff"/>
          <path d="M20 15v15" stroke="#e8792b" stroke-width="1.6"/>
        </svg>${SITE_NAME}
      </a>
      <form class="search" role="search" id="search-form">
        <input type="search" name="q" placeholder="Tìm kiếm truyện..." aria-label="Tìm kiếm truyện">
        <button type="submit" aria-label="Tìm">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/></svg>
        </button>
      </form>
      ${isLocal ? `<a class="admin-link" href="dang-chuong.html">+ Đăng chương</a>` : ""}
      <a class="menu-btn" href="index.html" aria-label="Menu">
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M4 6h16M4 12h16M4 18h16"/></svg>
      </a>
    </div>
  </header>
  <div class="tagline"><div class="container">${tagline || `${SITE_NAME} - Đọc Truyện Chữ Miễn Phí, Không Quảng Cáo`}</div></div>`;
  document.body.prepend(...header.children);

  if (!document.querySelector(".footer")) {
    document.body.insertAdjacentHTML("beforeend", `
    <footer class="footer">
      <div class="container">
        <div class="left">
          <p><b>${SITE_NAME}</b> - Trang <a href="index.html">đọc truyện online</a> cá nhân, cập nhật các bộ truyện dịch tiên hiệp, huyền huyễn hay nhất. Hỗ trợ đọc trên điện thoại và máy tính.</p>
          <p>Mọi nội dung truyện đều do chủ trang biên dịch. Vui lòng không sao chép khi chưa được cho phép.</p>
        </div>
        <div class="right"><a href="#">Liên hệ</a> | <a href="#">Điều khoản</a></div>
      </div>
    </footer>`);
  }

  // Tìm kiếm đơn giản: so khớp tên truyện không phân biệt dấu.
  const plain = (s) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/đ/gi, "d").toLowerCase();
  $("#search-form").addEventListener("submit", (e) => {
    e.preventDefault();
    const q = plain(e.target.q.value.trim());
    if (!q) return;
    const hit = STORIES.find((s) => plain(s.title).includes(q));
    if (hit) location.href = storyUrl(hit);
    else alert("Không tìm thấy truyện phù hợp.");
  });
}
