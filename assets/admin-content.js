// Xử lý nội dung truyện ngay trong trình duyệt — bản JS tương đương scripts/content-lib.ps1.
// Dùng cho chế độ "đăng nhập GitHub" của trang quản lý (không cần server cục bộ).
// Định dạng file tạo ra phải GIỐNG HỆT bản PowerShell (chuong-NNN.md, meta.json) để hai cách đăng dùng chung được.

window.AdminContent = (() => {
  const W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
  const HEADING_RE = /^\s*Chương\s+(\d+)\s*[:：\-–]\s*(.+?)\s*$/;
  const SLUG_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
  const BUNDLE_HEADER = "// Tu dong tao boi scripts/content-lib.ps1 - khong sua tay.\n";

  // ---------- Đọc .docx (file zip) bằng DecompressionStream, không cần thư viện ----------
  async function unzipEntry(buf, wanted) {
    const dv = new DataView(buf);
    let eocd = -1;
    for (let i = buf.byteLength - 22; i >= Math.max(0, buf.byteLength - 65557); i--) {
      if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) throw new Error("File không phải file Word .docx hợp lệ.");
    const count = dv.getUint16(eocd + 10, true);
    let p = dv.getUint32(eocd + 16, true);
    const dec = new TextDecoder();
    for (let k = 0; k < count; k++) {
      if (dv.getUint32(p, true) !== 0x02014b50) break;
      const method = dv.getUint16(p + 10, true);
      const csize = dv.getUint32(p + 20, true);
      const nlen = dv.getUint16(p + 28, true), elen = dv.getUint16(p + 30, true), clen = dv.getUint16(p + 32, true);
      const local = dv.getUint32(p + 42, true);
      const name = dec.decode(new Uint8Array(buf, p + 46, nlen));
      if (name === wanted) {
        const start = local + 30 + dv.getUint16(local + 26, true) + dv.getUint16(local + 28, true);
        const data = new Uint8Array(buf, start, csize);
        if (method === 0) return dec.decode(data);
        if (method === 8) {
          const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
          return await new Response(stream).text();
        }
        throw new Error("File Word dùng kiểu nén không hỗ trợ (" + method + ").");
      }
      p += 46 + nlen + elen + clen;
    }
    throw new Error("File không có word/document.xml (không phải file Word .docx).");
  }

  async function readDocxParagraphs(buf) {
    const xml = await unzipEntry(buf, "word/document.xml");
    const doc = new DOMParser().parseFromString(xml, "application/xml");
    if (doc.getElementsByTagName("parsererror").length) throw new Error("Nội dung file Word bị lỗi, không đọc được.");
    const body = doc.getElementsByTagNameNS(W, "body")[0];
    if (!body) return [];
    const out = [];
    for (const p of body.getElementsByTagNameNS(W, "p")) {
      let s = "";
      for (const n of p.getElementsByTagNameNS(W, "*")) {
        if (n.localName === "t") s += n.textContent;
        else if (n.localName === "tab" || n.localName === "br") s += " ";
      }
      const t = s.replace(/[\s ]+/g, " ").trim();
      if (t) out.push(t);
    }
    return out;
  }

  // Tách thành chương theo dòng "Chương NN: Tên". Phần trước chương đầu bị bỏ qua.
  async function readDocxChapters(buf) {
    const list = [];
    let cur = null;
    for (const para of await readDocxParagraphs(buf)) {
      const m = para.match(HEADING_RE);
      if (m) { cur = { n: parseInt(m[1], 10), title: m[2], paras: [] }; list.push(cur); }
      else if (cur) cur.paras.push(para);
    }
    return list;
  }

  const wordCount = (paras) => { const s = (paras || []).join(" ").trim(); return s ? s.split(/\s+/).length : 0; };

  // ---------- File chương (giống Read-Chapter / Write-Chapter) ----------
  const pad3 = (n) => String(n).padStart(3, "0");
  const storyDir = (slug) => `content/truyen/${slug}`;
  const chapterPath = (slug, n) => `${storyDir(slug)}/chuong-${pad3(n)}.md`;
  const metaPath = (slug) => `${storyDir(slug)}/meta.json`;

  function chapterMd(n, title, publishedAt, paras) {
    const t = title.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    return `---\nnumber: ${n}\ntitle: "${t}"\npublishedAt: "${publishedAt}"\n---\n\n${paras.join("\n\n")}\n`;
  }

  function parseMd(text) {
    text = text.replace(/\r\n/g, "\n");
    let title = "", publishedAt = "", body = text;
    const m = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
    if (m) {
      body = m[2];
      for (const line of m[1].split("\n")) {
        let x;
        if ((x = line.match(/^title:\s*"(.*)"\s*$/))) title = x[1].replace(/\\"/g, '"').replace(/\\\\/g, "\\");
        else if ((x = line.match(/^publishedAt:\s*"?([^"]*)"?\s*$/))) publishedAt = x[1];
      }
    }
    const paras = body.split(/\n\s*\n/).map((s) => s.trim()).filter(Boolean);
    return { title, publishedAt, paras };
  }

  // ---------- meta.json (giống ConvertTo-PrettyJson) ----------
  const jsonStr = (s) => '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r/g, "\\r").replace(/\n/g, "\\n").replace(/\t/g, "\\t") + '"';

  function prettyJson(v, indent = "") {
    const next = indent + "  ";
    if (v === null || v === undefined) return "null";
    if (typeof v === "boolean") return v ? "true" : "false";
    if (typeof v === "number") return String(v);
    if (typeof v === "string") return jsonStr(v);
    if (Array.isArray(v)) {
      const items = v.map((x) => prettyJson(x, next));
      if (!items.length) return "[]";
      const one = "[" + items.join(", ") + "]";
      return one.length <= 70 ? one : "[\n" + next + items.join(",\n" + next) + "\n" + indent + "]";
    }
    const keys = Object.keys(v);
    if (!keys.length) return "{}";
    return "{\n" + next + keys.map((k) => jsonStr(k) + ": " + prettyJson(v[k], next)).join(",\n" + next) + "\n" + indent + "}";
  }
  const metaJson = (meta) => prettyJson(meta) + "\n";

  // ---------- data/stories.js ----------
  function parseBundle(text) {
    const m = text.match(/window\.STORIES\s*=\s*([\s\S]*?);\s*$/);
    if (!m) throw new Error("Không đọc được data/stories.js.");
    return JSON.parse(m[1]);
  }
  // Sắp theo slug như Build-Bundle (Get-ChildItem) để hai cách đăng tạo ra cùng thứ tự, đỡ diff git.
  const bundleText = (stories) => {
    const sorted = [...stories].sort((a, b) => (a.slug < b.slug ? -1 : a.slug > b.slug ? 1 : 0));
    return `${BUNDLE_HEADER}window.STORIES = ${JSON.stringify(sorted)};\n`;
  };

  // Mục truyện trong bundle từ meta.json (giống Build-Bundle): mọi trường trừ sourceFiles/cover, rồi cover (URL), chapters.
  function bundleStory(meta, chapters, coverUrl) {
    const s = {};
    for (const [k, v] of Object.entries(meta)) if (k !== "sourceFiles" && k !== "cover") s[k] = v;
    if (coverUrl) s.cover = coverUrl;
    s.chapters = chapters;
    return s;
  }

  const today = () => {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  };

  return {
    SLUG_RE, HEADING_RE, readDocxParagraphs, readDocxChapters, wordCount,
    storyDir, chapterPath, metaPath, chapterMd, parseMd, prettyJson, metaJson,
    parseBundle, bundleText, bundleStory, today,
  };
})();
