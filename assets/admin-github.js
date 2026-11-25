// Chế độ "đăng nhập GitHub" cho trang quản lý: ghi truyện thẳng vào repo qua GitHub API,
// dùng khi không có server cục bộ (vd. mở trang trên https://<user>.github.io/<repo>/dang-truyen.html).
//
// Đăng nhập bằng fine-grained personal access token (chỉ cấp cho 1 repo, quyền Contents: Read and write).
// Token chỉ lưu trong trình duyệt (sessionStorage, hoặc localStorage nếu chọn "Ghi nhớ") và chỉ gửi tới api.github.com.
// Mỗi thao tác = 1 commit (Git Data API: blobs -> tree -> commit -> cập nhật ref), ghi cả file chương/meta.json
// lẫn data/stories.js. Nếu nhánh vừa có commit khác chen vào thì tự làm lại trên bản mới nhất.

window.GitHubBackend = (() => {
  const C = window.AdminContent;
  const API = "https://api.github.com";
  const TOKEN_KEY = "admin:ghToken";
  const MAX_COVER = 8 * 1024 * 1024;

  // Repo lấy từ địa chỉ trang khi chạy trên GitHub Pages, còn lại dùng repo mặc định của dự án.
  const repo = (() => {
    const host = location.hostname;
    if (host.endsWith(".github.io")) {
      const owner = host.split(".")[0];
      const first = location.pathname.split("/").filter(Boolean)[0];
      return { owner, repo: first && !first.includes(".") ? first : `${owner}.github.io`, branch: "main" };
    }
    return { owner: "nam410-oss", repo: "truyen", branch: "main" };
  })();
  const pagesUrl = repo.repo === `${repo.owner}.github.io` ? `https://${repo.owner}.github.io/` : `https://${repo.owner}.github.io/${repo.repo}/`;
  const R = `/repos/${repo.owner}/${repo.repo}`;

  let token = null, user = null;
  let cache = null;               // { sha, stories } — data/stories.js ở commit gần nhất đã đọc/ghi
  const parsed = new Map();       // token preview -> { name, chapters }

  // ---------- Token ----------
  function loadToken() { try { return sessionStorage.getItem(TOKEN_KEY) || localStorage.getItem(TOKEN_KEY); } catch { return null; } }
  function isRemembered() { try { return !!localStorage.getItem(TOKEN_KEY); } catch { return false; } }
  function saveToken(t, remember) {
    try {
      sessionStorage.setItem(TOKEN_KEY, t);
      if (remember) localStorage.setItem(TOKEN_KEY, t); else localStorage.removeItem(TOKEN_KEY);
    } catch { /* bỏ qua */ }
  }
  function clearToken() { try { sessionStorage.removeItem(TOKEN_KEY); localStorage.removeItem(TOKEN_KEY); } catch { /* bỏ qua */ } }

  // ---------- Gọi API ----------
  function ghError(status, msg) {
    if (status === 401) return "Token GitHub không hợp lệ hoặc đã hết hạn. Hãy đăng nhập lại bằng token mới.";
    if (status === 403 && /rate limit/i.test(msg)) return "GitHub đang tạm giới hạn số lần gọi. Đợi vài phút rồi thử lại.";
    if (status === 403) return `Token không có quyền ghi vào repo ${repo.owner}/${repo.repo}. Khi tạo token, hãy chọn repo "${repo.repo}" và quyền "Contents: Read and write".`;
    if (status === 404) return `Không tìm thấy repo ${repo.owner}/${repo.repo}, hoặc token chưa được cấp quyền vào repo này.`;
    if (status === 409 || status === 422) return `GitHub từ chối thay đổi (${status}): ${msg}`;
    return `GitHub báo lỗi ${status}${msg ? ": " + msg : ""}`;
  }

  async function gh(path, { method = "GET", body, raw = false } = {}) {
    const headers = {
      Authorization: `Bearer ${token}`,
      Accept: raw ? "application/vnd.github.raw+json" : "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
    };
    if (body) headers["Content-Type"] = "application/json";
    let res;
    try {
      res = await fetch(API + path, { method, headers, cache: "no-store", body: body ? JSON.stringify(body) : undefined });
    } catch {
      throw new Error("Không kết nối được GitHub. Kiểm tra mạng rồi thử lại.");
    }
    if (raw && res.status === 404) return null;
    if (!res.ok) {
      let msg = "";
      try { msg = (await res.json()).message || ""; } catch { /* bỏ qua */ }
      const err = new Error(ghError(res.status, msg));
      err.status = res.status;
      throw err;
    }
    if (raw) return res.text();
    return res.status === 204 ? null : res.json();
  }

  const encPath = (p) => p.split("/").map(encodeURIComponent).join("/");
  const headSha = async () => (await gh(`${R}/git/ref/heads/${repo.branch}`)).object.sha;
  const readRaw = (path, ref) => gh(`${R}/contents/${encPath(path)}?ref=${ref}`, { raw: true });

  async function readStories(ref) {
    if (cache && cache.sha === ref) return structuredClone(cache.stories);
    const text = await readRaw("data/stories.js", ref);
    const stories = text ? C.parseBundle(text) : [];
    cache = { sha: ref, stories: structuredClone(stories) };
    return stories;
  }
  async function readMeta(slug, ref) {
    const t = await readRaw(C.metaPath(slug), ref);
    if (!t) throw new Error(`Không tìm thấy truyện: ${slug}`);
    return JSON.parse(t);
  }
  function findStory(stories, slug) {
    const s = stories.find((x) => x.slug === slug);
    if (!s) throw new Error(`Không tìm thấy truyện: ${slug}`);
    return s;
  }
  const sortChapters = (chs) => chs.sort((a, b) => a.n - b.n);

  // ---------- Commit nhiều file một lần ----------
  // build(ref, treeSha) trả về { commitMsg, changes:[{path, content, base64?, delete?}], stories?, result }
  async function commit(build) {
    for (let attempt = 1; ; attempt++) {
      const sha = await headSha();
      const base = await gh(`${R}/git/commits/${sha}`);
      const { commitMsg: message, changes, stories, result } = await build(sha, base.tree.sha);
      const tree = [];
      for (const ch of changes) {
        if (ch.delete) { tree.push({ path: ch.path, mode: "100644", type: "blob", sha: null }); continue; }
        const blob = await gh(`${R}/git/blobs`, { method: "POST", body: { content: ch.content, encoding: ch.base64 ? "base64" : "utf-8" } });
        tree.push({ path: ch.path, mode: "100644", type: "blob", sha: blob.sha });
      }
      const newTree = await gh(`${R}/git/trees`, { method: "POST", body: { base_tree: base.tree.sha, tree } });
      const newCommit = await gh(`${R}/git/commits`, { method: "POST", body: { message, tree: newTree.sha, parents: [sha] } });
      try {
        await gh(`${R}/git/refs/heads/${repo.branch}`, { method: "PATCH", body: { sha: newCommit.sha, force: false } });
      } catch (e) {
        if ((e.status === 422 || e.status === 409) && attempt < 3) continue;   // nhánh vừa đổi: làm lại trên bản mới nhất
        throw e;
      }
      if (stories) cache = { sha: newCommit.sha, stories: structuredClone(stories) };
      return { ...result, push: { ok: true, message: "Đã lưu lên GitHub.", pagesUrl } };
    }
  }

  // ---------- Kiểm tra dữ liệu (giống server.ps1) ----------
  function storyFields(b) {
    const title = String(b.title || "").trim();
    if (!title) throw new Error("Tên truyện không được để trống.");
    if (title.length > 200) throw new Error("Tên truyện quá dài (tối đa 200 ký tự).");
    const description = String(b.description || "").trim();
    if (description.length > 5000) throw new Error("Phần giới thiệu quá dài (tối đa 5000 ký tự).");
    const genres = [...new Set((b.genres || []).map((g) => String(g).trim()).filter((g) => g && g.length <= 40))].slice(0, 20);
    return {
      title,
      author: String(b.author || "").trim().slice(0, 120),
      translator: String(b.translator || "").trim().slice(0, 120),
      genres,
      status: b.status === "hoan-thanh" ? "hoan-thanh" : "dang-ra",
      description,
      featured: !!b.featured,
    };
  }
  function chapterNumber(v) {
    const n = Number(v);
    if (!Number.isInteger(n) || n < 1 || n > 99999) throw new Error(`Số chương không hợp lệ: '${v}' (phải là số nguyên từ 1 đến 99999).`);
    return n;
  }
  function toBase64(buf) {
    const bytes = new Uint8Array(buf);
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
  }
  const coverUrl = (slug, file) => `content/truyen/${slug}/${file}?v=${Date.now()}`;

  // ================= Giao diện chung với LocalBackend =================
  return {
    mode: "github",
    repo, pagesUrl,
    get user() { return user; },
    tokenSettingsUrl: "https://github.com/settings/personal-access-tokens/new",

    async login(t, remember) {
      token = String(t || "").trim();
      if (!token) throw new Error("Hãy dán token GitHub vào ô.");
      const u = await gh("/user");
      const r = await gh(R);
      if (r.permissions && !r.permissions.push) throw new Error(`Tài khoản @${u.login} không có quyền ghi vào repo ${repo.owner}/${repo.repo}.`);
      user = u.login;
      saveToken(token, remember);
      return user;
    },
    async resume() {
      const t = loadToken();
      if (!t) return null;
      try { return await this.login(t, isRemembered()); }
      catch (e) { if (e.status === 401) clearToken(); token = null; throw e; }
    },
    logout() { clearToken(); token = null; user = null; cache = null; parsed.clear(); },

    async listStories() {
      const stories = await readStories(await headSha());
      return stories.map((s) => ({
        slug: s.slug, title: s.title, status: s.status, updatedAt: s.updatedAt, genres: s.genres || [],
        chapters: s.chapters.length, last: s.chapters.length ? s.chapters[s.chapters.length - 1].n : 0, cover: s.cover || "",
      })).sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
    },

    async getStory(slug) {
      const s = findStory(await readStories(await headSha()), slug);
      return {
        story: {
          slug: s.slug, title: s.title, author: s.author || "", translator: s.translator || "", genres: s.genres || [],
          status: s.status, description: s.description || "", featured: !!s.featured, updatedAt: s.updatedAt, cover: s.cover || "",
        },
        chapters: s.chapters.map((c) => ({ n: c.n, title: c.title, words: C.wordCount(c.paras) })),
      };
    },

    async saveStory(body) {
      const slug = String(body.slug || "").trim().toLowerCase();
      if (!C.SLUG_RE.test(slug) || slug.length > 80) throw new Error("Đường dẫn (slug) chỉ gồm chữ thường không dấu, số và dấu gạch ngang, tối đa 80 ký tự.");
      const fields = storyFields(body);
      const isNew = !!body.isNew;
      return commit(async (ref) => {
        const stories = await readStories(ref);
        const old = stories.find((x) => x.slug === slug);
        let meta;
        if (isNew) {
          if (old) throw new Error(`Đã có truyện dùng đường dẫn '${slug}'. Hãy đổi đường dẫn khác.`);
          meta = { title: "", slug, author: "", translator: "", genres: [], status: "dang-ra", description: "", featured: true, updatedAt: C.today(), sourceFiles: [] };
        } else {
          if (!old) throw new Error(`Không tìm thấy truyện: ${slug}`);
          meta = await readMeta(slug, ref);
        }
        Object.assign(meta, fields);
        const changes = [];
        let cover = old && old.cover ? old.cover : "";
        if (body.removeCover && meta.cover) {
          changes.push({ path: `${C.storyDir(slug)}/${meta.cover}`, delete: true });
          delete meta.cover;
          cover = "";
        }
        changes.push({ path: C.metaPath(slug), content: C.metaJson(meta) });
        const entry = C.bundleStory(meta, old ? old.chapters : [], cover);
        if (old) stories[stories.indexOf(old)] = entry; else stories.push(entry);
        changes.push({ path: "data/stories.js", content: C.bundleText(stories) });
        return {
          commitMsg: isNew ? `Tạo truyện: ${fields.title}` : `Cập nhật thông tin truyện: ${fields.title}`,
          changes, stories, result: { message: isNew ? `Đã tạo truyện "${fields.title}".` : "Đã lưu thông tin truyện.", slug },
        };
      });
    },

    async saveCover(slug, file) {
      const ext = ((file.name.split(".").pop() || "").toLowerCase()).replace("jpeg", "jpg");
      if (!["jpg", "png", "webp"].includes(ext)) throw new Error("Ảnh bìa chỉ nhận file .jpg, .png hoặc .webp.");
      if (file.size > MAX_COVER) throw new Error("File quá lớn (tối đa 8 MB).");
      const buf = await file.arrayBuffer();
      const b = new Uint8Array(buf.slice(0, 12));
      const ascii = (i, n) => String.fromCharCode(...b.slice(i, i + n));
      const isImg = (b[0] === 0xff && b[1] === 0xd8) || (b[0] === 0x89 && ascii(1, 3) === "PNG") || (ascii(0, 4) === "RIFF" && ascii(8, 4) === "WEBP");
      if (!isImg) throw new Error("File không phải ảnh JPG/PNG/WEBP hợp lệ.");
      const content = toBase64(buf);
      const name = `cover.${ext}`;
      return commit(async (ref) => {
        const stories = await readStories(ref);
        const st = findStory(stories, slug);
        const meta = await readMeta(slug, ref);
        const changes = [];
        if (meta.cover && meta.cover !== name) changes.push({ path: `${C.storyDir(slug)}/${meta.cover}`, delete: true });
        changes.push({ path: `${C.storyDir(slug)}/${name}`, content, base64: true });
        meta.cover = name;
        changes.push({ path: C.metaPath(slug), content: C.metaJson(meta) });
        const url = coverUrl(slug, name);
        stories[stories.indexOf(st)] = C.bundleStory(meta, st.chapters, url);
        changes.push({ path: "data/stories.js", content: C.bundleText(stories) });
        return { commitMsg: `Đổi ảnh bìa: ${meta.title}`, changes, stories, result: { message: "Đã cập nhật ảnh bìa.", cover: url } };
      });
    },

    async deleteStory(slug) {
      return commit(async (ref, treeSha) => {
        const stories = await readStories(ref);
        const st = findStory(stories, slug);
        const tree = await gh(`${R}/git/trees/${treeSha}?recursive=1`);
        if (tree.truncated) throw new Error("Repo quá lớn để xoá truyện từ trình duyệt. Hãy xoá bằng server cục bộ.");
        const prefix = C.storyDir(slug) + "/";
        const changes = tree.tree.filter((e) => e.type === "blob" && e.path.startsWith(prefix)).map((e) => ({ path: e.path, delete: true }));
        stories.splice(stories.indexOf(st), 1);
        changes.push({ path: "data/stories.js", content: C.bundleText(stories) });
        return { commitMsg: `Xoá truyện: ${st.title}`, changes, stories, result: { message: `Đã xoá truyện "${st.title}".` } };
      });
    },

    async updateChapter(slug, n, newN, title) {
      n = chapterNumber(n); newN = chapterNumber(newN);
      title = String(title || "").replace(/[\r\n\t]+/g, " ").trim();
      if (!title) throw new Error("Tên chương không được để trống.");
      if (title.length > 200) throw new Error("Tên chương quá dài (tối đa 200 ký tự).");
      const what = newN !== n ? `chương ${n} → chương ${newN}` : `chương ${n}`;
      return commit(async (ref) => {
        const stories = await readStories(ref);
        const st = findStory(stories, slug);
        const ch = st.chapters.find((c) => c.n === n);
        if (!ch) throw new Error(`Không tìm thấy chương ${n}.`);
        if (newN !== n && st.chapters.some((c) => c.n === newN)) throw new Error(`Đã có chương ${newN}. Hãy xoá hoặc đổi số chương ${newN} trước.`);
        const md = await readRaw(C.chapterPath(slug, n), ref);
        if (md === null) throw new Error(`Không tìm thấy file của chương ${n}.`);
        const p = C.parseMd(md);
        const changes = [{ path: C.chapterPath(slug, newN), content: C.chapterMd(newN, title, p.publishedAt, p.paras) }];
        if (newN !== n) changes.push({ path: C.chapterPath(slug, n), delete: true });
        ch.n = newN; ch.title = title;
        sortChapters(st.chapters);
        changes.push({ path: "data/stories.js", content: C.bundleText(stories) });
        return { commitMsg: `Sửa ${what}: ${st.title}`, changes, stories, result: { message: `Đã lưu ${what}: ${title}`, n: newN } };
      });
    },

    async deleteChapter(slug, n) {
      n = chapterNumber(n);
      return commit(async (ref) => {
        const stories = await readStories(ref);
        const st = findStory(stories, slug);
        const i = st.chapters.findIndex((c) => c.n === n);
        if (i < 0) throw new Error(`Không tìm thấy chương ${n}.`);
        st.chapters.splice(i, 1);
        return {
          commitMsg: `Xoá chương ${n}: ${st.title}`,
          changes: [{ path: C.chapterPath(slug, n), delete: true }, { path: "data/stories.js", content: C.bundleText(stories) }],
          stories, result: { message: `Đã xoá chương ${n}.` },
        };
      });
    },

    async preview(file) {
      let chapters;
      try { chapters = await C.readDocxChapters(await file.arrayBuffer()); }
      catch (e) { throw new Error(`Không đọc được file ${file.name} (có phải file Word .docx hợp lệ?): ${e.message}`); }
      const id = crypto.randomUUID().replace(/-/g, "");
      parsed.set(id, { name: file.name, chapters });
      return {
        token: id, name: file.name,
        chapters: chapters.map((c) => {
          let first = c.paras[0] || "";
          if (first.length > 140) first = first.slice(0, 140) + "…";
          return { n: c.n, title: c.title, paras: c.paras.length, words: C.wordCount(c.paras), first };
        }),
      };
    },

    async publish(slug, files, touchDate) {
      const items = files.map((f) => {
        const p = parsed.get(f.token);
        if (!p) throw new Error(`File ${f.name} đã hết hạn, hãy chọn lại file.`);
        return p;
      });
      const nums = [...new Set(items.flatMap((p) => p.chapters.map((c) => c.n)))].sort((a, b) => a - b);
      if (!nums.length) throw new Error("Không có chương nào để đăng.");
      const range = nums.length === 1 ? `chương ${nums[0]}` : `chương ${nums[0]}-${nums[nums.length - 1]}`;
      const res = await commit(async (ref) => {
        const stories = await readStories(ref);
        const st = findStory(stories, slug);
        const meta = await readMeta(slug, ref);
        const day = C.today();
        const byPath = new Map();
        for (const p of items) {
          for (const c of p.chapters) {
            byPath.set(C.chapterPath(slug, c.n), C.chapterMd(c.n, c.title, day, c.paras));   // chương trùng: bản sau thắng
            const entry = { n: c.n, title: c.title, paras: c.paras };
            const i = st.chapters.findIndex((x) => x.n === c.n);
            if (i >= 0) st.chapters[i] = entry; else st.chapters.push(entry);
          }
          meta.sourceFiles = [...(meta.sourceFiles || []).filter(Boolean)];
          if (!meta.sourceFiles.includes(p.name)) meta.sourceFiles.push(p.name);
        }
        sortChapters(st.chapters);
        if (touchDate) meta.updatedAt = day;
        stories[stories.indexOf(st)] = C.bundleStory(meta, st.chapters, st.cover || "");
        const changes = [...byPath].map(([path, content]) => ({ path, content }));
        changes.push({ path: C.metaPath(slug), content: C.metaJson(meta) });
        changes.push({ path: "data/stories.js", content: C.bundleText(stories) });
        const all = st.chapters.map((c) => c.n);
        return {
          commitMsg: `Đăng ${range}: ${meta.title}`,
          changes, stories,
          result: {
            message: `Đã đăng ${nums.length} chương (${range}). Truyện hiện có ${all.length} chương.`,
            total: all.length, last: all[all.length - 1], first: nums[0],
          },
        };
      });
      files.forEach((f) => parsed.delete(f.token));
      return res;
    },

    async push() {
      return { ok: true, message: "Mọi thay đổi đã được lưu thẳng lên GitHub.", pagesUrl };
    },
  };
})();
