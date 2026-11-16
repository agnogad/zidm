/* ZIDM page logic — download manager UI over the MyZig bridge. */
(function () {
  "use strict";
  const api = window.myzig;
  const $ = (s) => document.querySelector(s);
  const el = {
    app: $("#app"), engine: $("#engineStatus"), find: $("#findInput"),
    lang: $("#langBtn"), theme: $("#themeBtn"), settings: $("#settingsBtn"),
    categories: $("#categories"), sideFoot: $("#sideFoot"), head: $("#listHead"),
    list: $("#list"), empty: $("#empty"), emptyReason: $("#emptyReason"),
    count: $("#statusCount"), selected: $("#statusSelected"), speed: $("#statusSpeed"),
    dir: $("#statusDir"), menu: $("#menu"), context: $("#context"),
    modal: $("#modal"), toasts: $("#toasts")
  };

  const ICONS = { zip:"archive", rar:"archive", "7z":"archive", tar:"archive", gz:"archive", iso:"archive",
    torrent:"magnet", mp4:"video", mkv:"video", webm:"video", avi:"video", mp3:"music", flac:"music",
    m4a:"music", pdf:"doc", txt:"doc", docx:"doc", exe:"file" };
  const CATS = [
    { id:"all", label:"All Downloads" }, { id:"unfinished", label:"Unfinished" },
    { id:"finished", label:"Finished" }, { id:"queues", label:"Queues" },
    { id:"general", label:"General" }, { id:"compressed", label:"Compressed" },
    { id:"documents", label:"Documents" }, { id:"music", label:"Music" },
    { id:"programs", label:"Programs" }, { id:"video", label:"Video" }, { id:"torrents", label:"Torrents" }
  ];
  const DEF = {
    theme:"auto", dir:"", connections:8, speed:0, global_speed:0,
    queues:["Main","Sync"], records:[], categories:[], customCats:[], lang:"tr",
    confirmDelete:true, clipboard:true, completeDialog:true, notifications:true,
    speedOn:false, scheduler:[], scale:100, columns:{}, sort:"added", sortDesc:true,
    addressHistory:[], excludeSites:[], autoTypes:"zip rar 7z exe msi iso mp4 pdf", minSize:0
  };
  const S = {
    settings: Object.assign({}, DEF), status:null, rows:[], records:[], view:"all",
    selected:new Set(), query:"", sort:"added", desc:true, ready:false,
    themeTimer:null, clipTimer:null, lastClip:"", busy:false
  };

  const ico = (n) => `<svg class="ico"><use href="#i-${n}"/></svg>`;
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
    ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c]));
  const byId = (id) => document.getElementById(id);
  function toast(msg, kind) {
    const n = document.createElement("div");
    n.className = "toast " + (kind || "");
    n.innerHTML = ico(kind === "err" ? "alert" : kind === "ok" ? "check" : "info") + "<span>" + esc(msg) + "</span>";
    el.toasts.appendChild(n);
    setTimeout(() => n.remove(), 3400);
  }
  function persist() {
    api.call("Settings.save", JSON.stringify(S.settings)).catch((e) => console.warn("zidm: settings", e));
  }
  function fmtBytes(n) {
    n = Number(n) || 0;
    const u = ["B","KB","MB","GB","TB"];
    let i = 0, v = n;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (i ? v.toFixed(v < 10 ? 1 : 0) : Math.round(v)) + " " + u[i];
  }
  function fmtSpeed(n) { return fmtBytes(n) + "/s"; }
  function fmtEta(secs) {
    if (!isFinite(secs) || secs <= 0) return "—";
    secs = Math.round(secs);
    if (secs < 60) return secs + "s";
    if (secs < 3600) return Math.floor(secs / 60) + "m " + (secs % 60) + "s";
    return Math.floor(secs / 3600) + "h " + Math.floor((secs % 3600) / 60) + "m";
  }
  function extOf(s) { const i = String(s).lastIndexOf("."); return i > 0 ? s.slice(i + 1).toLowerCase() : ""; }
  function iconFor(name) { return ICONS[extOf(name)] || "file"; }
  function basename(p) { return String(p || "").split(/[\\/]/).pop() || ""; }
  function dirname(p) { const s = String(p || "").replace(/[\\/]+$/, ""); const i = Math.max(s.lastIndexOf("/"), s.lastIndexOf("\\")); return i < 0 ? "" : (i === 0 ? "/" : s.slice(0, i)); }
  function joinPath(a, b) { return a.replace(/[\\/]+$/, "") + (a.includes("\\") ? "\\" : "/") + b; }
  function recordOf(gid) { return S.records.find((r) => r.gid === gid); }

  function applyTheme() {
    let t = S.settings.theme;
    if (t === "auto") t = S.systemTheme || "dark";
    document.documentElement.dataset.theme = t;
    el.theme.innerHTML = ico(t === "dark" ? "sun" : "moon");
  }
  function markReady() {
    if (S.ready) return;
    S.ready = true;
    try { api.emit("zidm:ready"); } catch (e) { console.warn("zidm ready", e); }
  }

  // -------------------------------------------------------------- data/render
  function refresh() {
    api.call("Dl.list").then((raw) => {
      const parsed = typeof raw === "string" ? JSON.parse(raw) : raw;
      S.rows = Array.isArray(parsed) ? parsed : [];
      render();
    }).catch((e) => { console.warn("zidm: list failed", e); render(); });
  }

  function rowName(r) {
    const files = r.files || [];
    if (files.length && files[0].path) return basename(files[0].path);
    const rec = recordOf(r.gid);
    if (rec && rec.name) return rec.name;
    const f = files[0] && (files[0].uris || [])[0];
    return f ? basename(f) : r.gid.slice(0, 12);
  }
  function rowPath(r) { return (r.files || [])[0] && r.files[0].path || ""; }
  function rowUrl(r) { return ((r.files || [])[0] && r.files[0].uris && r.files[0].uris[0]) || (recordOf(r.gid) || {}).url || ""; }
  function rowCategory(r) {
    const rec = recordOf(r.gid);
    return rec && rec.category ? rec.category : "general";
  }
  function isDone(r) { return r.status === "complete" || r.status === "removed"; }
  function isActive(r) { return r.status === "active" || r.status === "paused"; }
  function progress(r) {
    const total = Number(r.totalLength) || 0;
    const done = Number(r.completedLength) || 0;
    return total > 0 ? Math.min(100, done / total * 100) : 0;
  }

  function visibleRows() {
    let rows = S.rows.slice();
    if (S.view === "unfinished") rows = rows.filter((r) => !isDone(r));
    else if (S.view === "finished") rows = rows.filter(isDone);
    else if (S.view === "queues") rows = rows.filter((r) => (recordOf(r.gid) || {}).queue);
    else if (S.view !== "all") rows = rows.filter((r) => rowCategory(r) === S.view);
    if (S.query) {
      const q = S.query.toLocaleLowerCase("tr");
      rows = rows.filter((r) => {
        const rec = recordOf(r.gid) || {};
        return [rowName(r), rowUrl(r), rec.description || ""].some((s) => String(s).toLocaleLowerCase("tr").includes(q));
      });
    }
    const key = S.sort;
    rows.sort((a, b) => {
      let v = 0;
      if (key === "name") v = rowName(a).localeCompare(rowName(b), "tr");
      else if (key === "size") v = Number(a.totalLength || 0) - Number(b.totalLength || 0);
      else if (key === "speed") v = Number(a.downloadSpeed || 0) - Number(b.downloadSpeed || 0);
      else if (key === "status") v = String(a.status).localeCompare(String(b.status));
      else {
        const ra = recordOf(a.gid) || {}, rb = recordOf(b.gid) || {};
        v = (ra.added || 0) - (rb.added || 0);
      }
      return S.desc ? -v : v;
    });
    return rows;
  }

  function render() {
    const rows = visibleRows();
    S.selected.forEach((gid) => { if (!S.rows.some((r) => r.gid === gid)) S.selected.delete(gid); });
    el.head.innerHTML = ["File Name","Size","Status","Transfer rate","Time left"].map((h, i) =>
      `<span data-sort="${["name","size","status","speed","eta"][i]}">${h}${S.sort === ["name","size","status","speed","eta"][i] ? (S.desc ? " ↓" : " ↑") : ""}</span>`).join("");
    el.list.innerHTML = rows.map((r) => {
      const name = rowName(r), p = progress(r), done = isDone(r);
      const st = done ? "Complete" : r.status === "paused" ? "Paused" : r.status === "error" ? "Error" :
        r.status === "waiting" ? "Queued" : p.toFixed(1) + "%";
      const eta = Number(r.downloadSpeed) > 0 && Number(r.totalLength) > 0
        ? fmtEta((Number(r.totalLength) - Number(r.completedLength)) / Number(r.downloadSpeed)) : "—";
      return `<div class="row${S.selected.has(r.gid) ? " selected" : ""}" data-gid="${esc(r.gid)}" role="option">` +
        `<div class="name-cell"><span class="file-ico">${ico(iconFor(name))}</span><span style="min-width:0">` +
        `<div class="fname">${esc(name)}</div><div class="progress"><i style="transform:scaleX(${p / 100})"></i></div></span></div>` +
        `<div class="cell">${r.totalLength ? fmtBytes(r.totalLength) : "—"}</div>` +
        `<div class="status ${done ? "done" : r.status === "error" ? "error" : ""}">${st}</div>` +
        `<div class="cell">${Number(r.downloadSpeed) > 0 ? fmtSpeed(r.downloadSpeed) : "—"}</div>` +
        `<div class="cell">${eta}</div></div>`;
    }).join("");
    el.empty.hidden = rows.length > 0;
    el.emptyReason.textContent = S.query ? "No download matches your search." :
      S.view === "all" ? "Add a link to start downloading." : "Nothing in this category.";
    const active = S.rows.filter(isActive);
    const rate = active.reduce((n, r) => n + (Number(r.downloadSpeed) || 0), 0);
    el.count.textContent = `${S.rows.length} downloads · ${active.length} active`;
    el.selected.textContent = S.selected.size ? `${S.selected.size} selected` : "";
    el.speed.textContent = fmtSpeed(rate);
    el.dir.textContent = S.settings.dir || S.status?.downloads || "";
    el.sideFoot.textContent = `${S.rows.length} items · ${fmtBytes(S.rows.reduce((n,r)=>n+(Number(r.totalLength)||0),0))}`;
    renderSidebar();
  }

  function renderSidebar() {
    const counts = {};
    S.rows.forEach((r) => { counts[rowCategory(r)] = (counts[rowCategory(r)] || 0) + 1; });
    const cats = CATS.concat((S.settings.customCats || []).map((c) => ({ id:c.id, label:c.name })));
    el.categories.innerHTML = cats.map((c) =>
      `<button class="side-item${S.view === c.id ? " active" : ""}" data-view="${esc(c.id)}">` +
      ico(c.id === "queues" ? "queue" : "folder") + `<span>${esc(c.label)}</span>` +
      `<span class="count">${c.id === "all" ? S.rows.length : c.id === "unfinished" ? S.rows.filter((r)=>!isDone(r)).length : c.id === "finished" ? S.rows.filter(isDone).length : counts[c.id] || 0}</span></button>`).join("");
  }

  // ------------------------------------------------------------------- modals
  function closeModal() { el.modal.hidden = true; el.modal._submit = null; }
  function showModal(html, onSubmit, wide) {
    el.modal.innerHTML = `<div class="modal${wide ? " wide" : ""}">${html}</div>`;
    el.modal.hidden = false;
    el.modal._submit = onSubmit || null;
    const first = el.modal.querySelector("input,select,textarea");
    if (first) { first.focus(); if (first.select) first.select(); }
  }
  function modalValues() {
    const out = {};
    el.modal.querySelectorAll("[data-k]").forEach((n) => { out[n.dataset.k] = n.type === "checkbox" ? n.checked : n.value; });
    return out;
  }
  el.modal.addEventListener("click", (ev) => {
    if (ev.target === el.modal) { closeModal(); return; }
    const act = ev.target.closest("[data-act]");
    if (!act) return;
    const a = act.dataset.act;
    if (a === "cancel") { closeModal(); return; }
    const fn = el.modal._submit;
    const values = modalValues();
    closeModal();
    if (fn) fn(a, values, ev.target);
  });
  el.modal.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") { ev.preventDefault(); closeModal(); }
    if (ev.key === "Enter" && ev.target.tagName === "INPUT") {
      ev.preventDefault();
      const confirm = el.modal.querySelector('[data-act="now"]') || el.modal.querySelector('[data-act="ok"]');
      if (confirm) confirm.click();
    }
  });

  function menuShow(target, items, x, y) {
    target.innerHTML = items.map((i) => i.sep ? '<div class="sep"></div>' :
      `<button data-cmd="${esc(i.cmd)}" ${i.disabled ? "disabled" : ""}>${esc(i.label)}${i.key ? `<kbd>${esc(i.key)}</kbd>` : ""}</button>`).join("");
    target.hidden = false;
    const r = target.getBoundingClientRect();
    target.style.left = Math.max(4, Math.min(x, innerWidth - r.width - 4)) + "px";
    target.style.top = Math.max(4, Math.min(y, innerHeight - r.height - 4)) + "px";
  }
  function hideMenus() { el.menu.hidden = true; el.context.hidden = true; }
  document.addEventListener("click", (ev) => {
    if (!el.menu.hidden && !el.menu.contains(ev.target)) el.menu.hidden = true;
    if (!el.context.hidden && !el.context.contains(ev.target)) el.context.hidden = true;
  });

  // ---------------------------------------------------------------- add flows
  function addUrlDialog(prefill) {
    const url = prefill || "";
    const cats = CATS.filter((c) => !["all","unfinished","finished","queues"].includes(c.id));
    showModal(`<h2>Add URL</h2><p class="desc">Enter a web, FTP or magnet address.</p>
      <label>Address<input data-k="url" value="${esc(url)}" placeholder="https://example.com/file.zip"></label>
      <div class="row2"><label>Category<select data-k="category">${cats.map((c)=>`<option value="${c.id}">${c.label}</option>`).join("")}</select></label>
      <label>Save As<input data-k="name" placeholder="keep server name"></label></div>
      <label>Folder<input data-k="dir" value="${esc(S.settings.dir || S.status?.downloads || "")}"></label>
      <label>Description<input data-k="description"></label>
      <div class="row2"><label>User<input data-k="user"></label><label>Password<input data-k="pass" type="password"></label></div>
      <label>Referer<input data-k="referer"></label>
      <div class="actions"><button class="btn" data-act="later">Download Later</button>
      <button class="btn" data-act="cancel">Cancel</button><button class="btn primary" data-act="now">Start Download</button></div>`,
      async (act, v) => {
        if (!/^(https?:|ftp:|ftps:|ftpes:|magnet:)/i.test(v.url.trim())) { toast("Invalid address", "err"); return; }
        const opts = { name:v.name, queue:act === "later" ? "Main" : "", paused:act === "later",
          connections:S.settings.connections, user:v.user, pass:v.pass, referer:v.referer };
        try {
          const gid = await api.call("Dl.add", v.url.trim(), v.dir.trim() || S.settings.dir || S.status.downloads, JSON.stringify(opts));
          S.records.unshift({ gid, name:v.name, url:v.url.trim(), category:v.category, queue:opts.queue,
            description:v.description, added:Date.now(), dir:v.dir, status:"added" });
          if (S.settings.addressHistory.indexOf(v.url.trim()) < 0) S.settings.addressHistory.unshift(v.url.trim());
          S.settings.addressHistory = S.settings.addressHistory.slice(0, 20);
          persist(); refresh();
          toast(act === "later" ? "Added to queue" : "Download started", "ok");
        } catch (e) { toast(e.message || "Could not add", "err"); }
      });
  }

  function addTorrentDialog() {
    showModal(`<h2>Add torrent</h2><p class="desc">Paste a magnet link or a .torrent file path.</p>
      <label>Magnet / file<input data-k="payload" placeholder="magnet:?xt=urn:btih:..."></label>
      <label>Save to<input data-k="dir" value="${esc(S.settings.dir || S.status?.downloads || "")}"></label>
      <div class="actions"><button class="btn" data-act="cancel">Cancel</button><button class="btn primary" data-act="now">Download Now</button></div>`,
      async (act, v) => {
        const p = v.payload.trim();
        if (!p) return;
        try {
          const gid = p.startsWith("magnet:")
            ? await api.call("Dl.addTorrent", p, v.dir, JSON.stringify({ paused:false, connections:S.settings.connections }))
            : await api.call("Dl.addTorrentFile", p, v.dir, JSON.stringify({ paused:false, connections:S.settings.connections }));
          S.records.unshift({ gid, name:p, url:p, category:"torrents", queue:"", description:"", added:Date.now(), dir:v.dir, status:"added" });
          persist(); refresh(); toast("Torrent added", "ok");
        } catch (e) { toast(e.message || "Torrent failed", "err"); }
      });
  }

  function batchDialog() {
    showModal(`<h2>Batch download</h2><p class="desc">One * in the address, then numbers or letters.</p>
      <label>Address<input data-k="pattern" value="${esc(S.settings.dir || "")}" placeholder="https://x/ep*.mp4"></label>
      <div class="row2"><label>Replace with<select data-k="letters"><option value="0">Numbers</option><option value="1">Letters</option></select></label>
      <label>Wildcard size<input data-k="width" type="number" value="2" min="1" max="6"></label></div>
      <div class="row2"><label>From<input data-k="from" type="number" value="1"></label><label>To<input data-k="to" type="number" value="10"></label></div>
      <div class="actions"><button class="btn" data-act="cancel">Cancel</button><button class="btn primary" data-act="now">OK</button></div>`,
      async (act, v) => {
        const pattern = v.pattern.trim(), from = Number(v.from), to = Number(v.to);
        if (!pattern.includes("*") || !(to >= from) || to - from > 500) { toast("Invalid range", "err"); return; }
        const urls = [];
        for (let i = from; i <= to; i++) {
          let token = v.letters === "1" ? String.fromCharCode(96 + i) : String(i).padStart(Number(v.width) || 1, "0");
          urls.push(pattern.replace("*", token));
        }
        try {
          const gids = JSON.parse(await api.call("Dl.batch", JSON.stringify(urls), S.settings.dir || S.status.downloads));
          gids.forEach((gid) => S.records.unshift({ gid, name:basename(urls[gids.indexOf(gid)]), url:urls[gids.indexOf(gid)], category:"general", queue:"Main", added:Date.now(), description:"" }));
          persist(); refresh(); toast(`${gids.length} downloads added`, "ok");
        } catch (e) { toast(e.message || "Batch failed", "err"); }
      });
  }

  function linkGrabber(text) {
    const found = [];
    const re = /(?:https?|ftps?|ftpes|magnet):[^\s<>"']+/gi;
    let m;
    while ((m = re.exec(text || ""))) {
      const u = m[0].replace(/[.,;:!?]+$/, "");
      if (found.indexOf(u) < 0) found.push(u);
    }
    showModal(`<h2>Link grabber</h2><p class="desc">${found.length} link(s) found. Untick what you do not want.</p>
      <div id="grabList">${found.map((u,i)=>`<label style="display:flex;gap:8px;align-items:center"><input type="checkbox" data-link="${i}" checked style="width:auto;margin:0"><span class="mono" style="font-size:11px;overflow-wrap:anywhere">${esc(u)}</span></label>`).join("") || "No links found"}</div>
      <div class="actions"><button class="btn" data-act="cancel">Cancel</button><button class="btn primary" data-act="ok">Add to queue</button></div>`,
      async (act) => {
        const picked = Array.from(el.modal.querySelectorAll("[data-link]:checked")).map((n) => found[Number(n.dataset.link)]);
        if (!picked.length) return;
        try {
          const gids = JSON.parse(await api.call("Dl.batch", JSON.stringify(picked), S.settings.dir || S.status.downloads));
          gids.forEach((gid, i) => S.records.unshift({ gid, name:basename(picked[i]), url:picked[i], category:"general", queue:"Main", added:Date.now() }));
          persist(); refresh(); toast(`${gids.length} downloads added`, "ok");
        } catch (e) { toast(e.message || "Failed", "err"); }
      }, true);
  }

  // ---------------------------------------------------------------- selection
  function selectedRows() { return S.rows.filter((r) => S.selected.has(r.gid)); }
  function selectedGids() { return Array.from(S.selected); }
  async function control(method, gids) {
    for (const gid of gids) {
      try { await api.call("Dl.control", method, gid); } catch (e) { toast(e.message || method, "err"); }
    }
    setTimeout(refresh, 250);
  }

  el.list.addEventListener("click", (ev) => {
    const row = ev.target.closest(".row");
    if (!row) { S.selected.clear(); render(); return; }
    const gid = row.dataset.gid;
    if (ev.ctrlKey || ev.metaKey) { S.selected.has(gid) ? S.selected.delete(gid) : S.selected.add(gid); }
    else if (ev.shiftKey && S.selected.size) {
      const rows = visibleRows();
      const last = Array.from(S.selected).pop();
      const a = rows.findIndex((r) => r.gid === last), b = rows.findIndex((r) => r.gid === gid);
      if (a >= 0 && b >= 0) rows.slice(Math.min(a,b), Math.max(a,b)+1).forEach((r) => S.selected.add(r.gid));
    } else { S.selected.clear(); S.selected.add(gid); }
    render();
  });
  el.list.addEventListener("dblclick", (ev) => {
    const row = ev.target.closest(".row");
    if (row) { S.selected.clear(); S.selected.add(row.dataset.gid); properties(); }
  });
  el.list.addEventListener("contextmenu", (ev) => {
    const row = ev.target.closest(".row");
    if (row) {
      if (!S.selected.has(row.dataset.gid)) { S.selected.clear(); S.selected.add(row.dataset.gid); render(); }
      menuShow(el.context, rowMenu(), ev.clientX, ev.clientY);
    } else menuShow(el.context, blankMenu(), ev.clientX, ev.clientY);
    ev.preventDefault();
  });
  el.head.addEventListener("click", (ev) => {
    const s = ev.target.dataset.sort;
    if (!s) return;
    if (S.sort === s) S.desc = !S.desc; else { S.sort = s; S.desc = true; }
    S.settings.sort = S.sort; persist(); render();
  });
  el.categories.addEventListener("click", (ev) => {
    const b = ev.target.closest("[data-view]");
    if (!b) return;
    S.view = b.dataset.view; S.selected.clear(); render();
  });
  el.find.addEventListener("input", () => { S.query = el.find.value.trim(); render(); });

  function rowMenu() {
    const one = selectedGids().length === 1;
    return [
      { cmd:"open", label:"Open" }, { cmd:"folder", label:"Open folder" },
      { cmd:"props", label:"Properties", key:"Alt+Enter" }, { sep:true },
      { cmd:"resume", label:"Resume Download" }, { cmd:"pause", label:"Pause Download" },
      { cmd:"stop", label:"Stop Download" }, { cmd:"redownload", label:"Redownload", disabled:!one },
      { sep:true },
      { cmd:"rename", label:"Move/Rename", key:"F2", disabled:!one },
      { cmd:"checksum", label:"Verify checksum...", disabled:!one },
      { cmd:"queue", label:"Add to queue" }, { cmd:"address", label:"Refresh download address", disabled:!one },
      { sep:true }, { cmd:"remove", label:"Remove", key:"Del" }
    ];
  }
  function blankMenu() {
    return [
      { cmd:"addurl", label:"Add new download", key:"Ctrl+N" },
      { cmd:"batch", label:"Add batch download", key:"Ctrl+B" },
      { cmd:"grabber", label:"Link grabber" },
      { cmd:"import", label:"Import list" }, { cmd:"export", label:"Export list" },
      { sep:true }, { cmd:"selectall", label:"Select all", key:"Ctrl+A" },
      { cmd:"clearfilters", label:"Clear all filters" },
      { cmd:"deletecompleted", label:"Delete All Completed" }
    ];
  }

  const commands = {
    open: () => { const r = selectedRows()[0]; if (r) api.openExternal(rowPath(r) || rowUrl(r)); },
    folder: () => { const r = selectedRows()[0]; if (r) api.openExternal(dirname(rowPath(r)) || S.settings.dir || S.status.downloads); },
    props: properties, resume: () => control("aria2.unpause", selectedGids()),
    pause: () => control("aria2.pause", selectedGids()),
    stop: () => control("aria2.remove", selectedGids()),
    redownload: () => {
      const r = selectedRows()[0]; if (!r) return;
      control("aria2.removeDownloadResult", [r.gid]).then(() => addUrlDialog(rowUrl(r)));
    },
    rename: renameDialog, checksum: checksumDialog, queue: queueDialog,
    address: () => addUrlDialog(rowUrl(selectedRows()[0] || {})),
    remove: removeDialog, addurl: () => addUrlDialog(), batch: batchDialog,
    grabber: () => linkGrabber(""), import: importList, export: exportList,
    selectall: () => { S.rows.forEach((r) => S.selected.add(r.gid)); render(); },
    clearfilters: () => { S.query = ""; el.find.value = ""; render(); },
    deletecompleted: deleteCompleted
  };
  el.context.addEventListener("click", (ev) => {
    const b = ev.target.closest("[data-cmd]");
    if (!b) return;
    hideMenus();
    const fn = commands[b.dataset.cmd];
    if (fn) fn();
  });

  // ---------------------------------------------------------------- properties
  async function properties() {
    const r = selectedRows()[0];
    if (!r) return;
    const rec = recordOf(r.gid) || {};
    const name = rowName(r), path = rowPath(r);
    showModal(`<h2>Properties</h2><p class="desc">${esc(name)}</p>
      <table><tr><th>Status</th><td>${esc(r.status)}</td></tr>
      <tr><th>Size</th><td>${r.totalLength ? fmtBytes(r.totalLength) : "—"}</td></tr>
      <tr><th>Downloaded</th><td>${fmtBytes(r.completedLength)}</td></tr>
      <tr><th>Connections</th><td>${esc(r.connections || 0)}</td></tr>
      <tr><th>Saved</th><td class="mono">${esc(path || "—")}</td></tr>
      <tr><th>Address</th><td class="mono">${esc(rowUrl(r))}</td></tr>
      <tr><th>Category</th><td>${esc(rec.category || "general")}</td></tr>
      <tr><th>Queue</th><td>${esc(rec.queue || "—")}</td></tr>
      <tr><th>Description</th><td>${esc(rec.description || "")}</td></tr></table>
      <label>Description<input data-k="description" value="${esc(rec.description || "")}"></label>
      <div class="actions"><button class="btn" data-act="cancel">Close</button><button class="btn primary" data-act="ok">Save</button></div>`,
      (act, v) => {
        if (act === "ok") { rec.description = v.description; persist(); render(); toast("Saved", "ok"); }
      });
  }

  async function renameDialog() {
    const r = selectedRows()[0]; if (!r) return;
    const path = rowPath(r);
    showModal(`<h2>Move / Rename</h2><p class="desc">Finished or not-yet-started downloads only.</p>
      <label>New path<input data-k="path" value="${esc(path)}"></label>
      <div class="actions"><button class="btn" data-act="cancel">Cancel</button><button class="btn primary" data-act="ok">Move</button></div>`,
      async (act, v) => {
        if (!v.path || v.path === path) return;
        try { await api.call("Fs.rename", path, v.path); toast("Moved", "ok"); refresh(); }
        catch (e) { toast(e.message || "Rename failed", "err"); }
      });
  }

  async function checksumDialog() {
    const r = selectedRows()[0]; if (!r) return;
    showModal(`<h2>Verify checksum</h2><p class="desc">MD5, SHA-1, SHA-256, SHA-512 or CRC32.</p>
      <label>Checksum<input data-k="value" placeholder="paste checksum"></label>
      <div class="actions"><button class="btn" data-act="cancel">Cancel</button><button class="btn primary" data-act="ok">Verify</button></div>`,
      async (act, v) => {
        const given = (v.value || "").trim().toLowerCase().replace(/^0x/, "");
        const algo = given.length === 8 ? "crc32" : given.length === 32 ? "md5" : given.length === 40 ? "sha1" : given.length === 64 ? "sha256" : "sha512";
        try {
          const actual = await api.call("Tools.checksum", rowPath(r), algo);
          toast(actual === given ? "The file matches" : "The file does NOT match", actual === given ? "ok" : "err");
        } catch (e) { toast(e.message || "Verification failed", "err"); }
      });
  }

  function removeDialog() {
    const gids = selectedGids();
    if (!gids.length) return;
    const running = selectedRows().some((r) => r.status === "active");
    if (running) { toast("Stop the download first", "err"); return; }
    showModal(`<h2>Remove ${gids.length} download(s)</h2><p class="desc">The download list entry is always removed.</p>
      <label style="display:flex;gap:8px;align-items:center"><input type="checkbox" data-k="disk" style="width:auto;margin:0"> Also delete the file from disk</label>
      <div class="actions"><button class="btn" data-act="cancel">No</button><button class="btn primary" data-act="ok">Yes</button></div>`,
      async (act, v) => {
        for (const gid of gids) {
          const r = S.rows.find((x) => x.gid === gid);
          if (v.disk && r && rowPath(r)) { try { await api.call("Fs.delete", rowPath(r)); } catch (e) {} }
          try { await api.call("Dl.control", "aria2.removeDownloadResult", gid); } catch (e) {}
        }
        S.records = S.records.filter((rec) => !gids.includes(rec.gid));
        S.selected.clear(); persist(); refresh(); toast("Removed", "ok");
      });
  }

  async function deleteCompleted() {
    const done = S.rows.filter(isDone);
    if (!done.length) return;
    for (const r of done) { try { await api.call("Dl.control", "aria2.removeDownloadResult", r.gid); } catch (e) {} }
    S.records = S.records.filter((rec) => !done.some((r) => r.gid === rec.gid));
    persist(); refresh(); toast(`${done.length} completed downloads removed`, "ok");
  }

  // ---------------------------------------------------------------- queues etc
  function queueDialog() {
    showModal(`<h2>Add to queue</h2>
      <label>Queue<select data-k="queue">${S.settings.queues.map((q)=>`<option>${esc(q)}</option>`).join("")}</select></label>
      <label style="display:flex;gap:8px;align-items:center"><input type="checkbox" data-k="start" style="width:auto;margin:0"> Start the queue now</label>
      <div class="actions"><button class="btn" data-act="cancel">Cancel</button><button class="btn primary" data-act="ok">OK</button></div>`,
      async (act, v) => {
        selectedGids().forEach((gid) => { const rec = recordOf(gid); if (rec) rec.queue = v.queue; });
        persist(); render();
        if (v.start) startQueue(v.queue);
        toast("Queue updated", "ok");
      });
  }
  async function startQueue(name) {
    const q = name || S.settings.queues[0] || "Main";
    let n = 0;
    for (const rec of S.records.filter((r) => r.queue === q)) {
      try { await api.call("Dl.control", "aria2.unpause", rec.gid); n++; } catch (e) {}
    }
    if (n) toast(`${n} downloads started from ${q}`, "ok");
    refresh();
  }
  async function stopQueue(name) {
    const q = name || S.settings.queues[0] || "Main";
    for (const rec of S.records.filter((r) => r.queue === q)) {
      try { await api.call("Dl.control", "aria2.pause", rec.gid); } catch (e) {}
    }
    refresh();
  }

  function speedDialog() {
    showModal(`<h2>Speed Limiter</h2><p class="desc">Limits are in KB/s. 0 means unlimited.</p>
      <label>Maximum download speed for one file<input data-k="speed" type="number" min="0" value="${S.settings.speed || 0}"></label>
      <label>Limit all downloads together to<input data-k="global" type="number" min="0" value="${S.settings.global_speed || 0}"></label>
      <label style="display:flex;gap:8px;align-items:center"><input type="checkbox" data-k="on" ${S.settings.speedOn ? "checked" : ""} style="width:auto;margin:0"> Turn on Speed Limiter</label>
      <div class="actions"><button class="btn" data-act="cancel">Cancel</button><button class="btn primary" data-act="ok">Apply</button></div>`,
      async (act, v) => {
        S.settings.speed = Number(v.speed) || 0;
        S.settings.global_speed = Number(v.global) || 0;
        S.settings.speedOn = !!v.on;
        persist();
        try {
          await api.call("Dl.global", JSON.stringify({ "max-overall-download-limit": v.on && v.global ? v.global + "K" : "0" }));
          if (S.selected.size === 1) await api.call("Dl.option", selectedGids()[0], JSON.stringify({ "max-download-limit": v.on && v.speed ? v.speed + "K" : "0" }));
          toast("Speed limits applied", "ok");
        } catch (e) { toast(e.message || "Speed limit failed", "err"); }
      });
  }

  function categoryDialog() {
    showModal(`<h2>Add category</h2><p class="desc">Give it a name, file types and a folder.</p>
      <label>Name<input data-k="name" placeholder="Books"></label>
      <label>File types<input data-k="types" placeholder="epub mobi"></label>
      <label>Folder<input data-k="folder" value="${esc(S.settings.dir || S.status?.downloads || "")}"></label>
      <div class="actions"><button class="btn" data-act="cancel">Cancel</button><button class="btn primary" data-act="ok">OK</button></div>`,
      (act, v) => {
        if (act !== "ok" || !v.name.trim()) return;
        const id = "custom-" + Date.now();
        S.settings.customCats.push({ id, name:v.name.trim(), extensions:v.types, folder:v.folder });
        persist(); renderSidebar(); toast("Category added", "ok");
      });
  }

  function schedulerDialog() {
    const rows = S.settings.scheduler || [];
    showModal(`<h2>Scheduler</h2><p class="desc">Queues run on time. MDM/ZIDM must stay open.</p>
      <table><thead><tr><th>Queue</th><th>Start</th><th>Stop</th><th>Concurrent</th><th></th></tr></thead><tbody>
      ${rows.map((s,i)=>`<tr><td>${esc(s.queue)}</td><td>${esc(s.start || "—")}</td><td>${esc(s.stop || "—")}</td><td>${esc(s.concurrent || 4)}</td><td><button class="btn" data-remove="${i}">Remove</button></td></tr>`).join("") || '<tr><td colspan="5">No schedules</td></tr>'}</tbody></table>
      <div class="row2"><label>Queue<select data-k="queue">${S.settings.queues.map((q)=>`<option>${esc(q)}</option>`).join("")}</select></label>
      <label>Concurrent<input data-k="concurrent" type="number" value="4" min="1" max="16"></label></div>
      <div class="row2"><label>Start at<input data-k="start" type="time"></label><label>Stop at<input data-k="stop" type="time"></label></div>
      <div class="actions"><button class="btn" data-act="cancel">Close</button><button class="btn primary" data-act="ok">Apply</button></div>`,
      (act, v, target) => {
        const rem = target && target.closest("[data-remove]");
        if (rem) { rows.splice(Number(rem.dataset.remove), 1); persist(); schedulerDialog(); return; }
        if (act === "ok") {
          rows.push({ queue:v.queue, start:v.start, stop:v.stop, concurrent:Number(v.concurrent) || 4 });
          S.settings.scheduler = rows; persist(); toast("Schedule added", "ok"); schedulerDialog();
        }
      }, true);
  }

  function optionsDialog() {
    showModal(`<h2>Options</h2><p class="desc">Settings are saved when you press OK.</p>
      <div class="row2"><label>Theme<select data-k="theme"><option value="auto">Follow system</option><option value="dark">Always dark</option><option value="light">Always light</option></select></label>
      <label>Language<select data-k="lang"><option value="tr">Türkçe</option><option value="en">English</option></select></label></div>
      <label>Default folder<input data-k="dir" value="${esc(S.settings.dir || S.status?.downloads || "")}"></label>
      <label>Connections per file<input data-k="connections" type="number" min="1" max="128" value="${S.settings.connections}"></label>
      <label style="display:flex;gap:8px;align-items:center"><input type="checkbox" data-k="clipboard" ${S.settings.clipboard ? "checked" : ""} style="width:auto;margin:0"> Offer to download links copied to the clipboard</label>
      <label style="display:flex;gap:8px;align-items:center"><input type="checkbox" data-k="confirmDelete" ${S.settings.confirmDelete ? "checked" : ""} style="width:auto;margin:0"> Confirm before deleting downloads</label>
      <label style="display:flex;gap:8px;align-items:center"><input type="checkbox" data-k="notifications" ${S.settings.notifications ? "checked" : ""} style="width:auto;margin:0"> Show completion notifications</label>
      <div class="actions"><button class="btn" data-act="cancel">Cancel</button><button class="btn primary" data-act="ok">OK</button></div>`,
      (act, v) => {
        if (act !== "ok") return;
        Object.assign(S.settings, { theme:v.theme, lang:v.lang, dir:v.dir, connections:Number(v.connections) || 8,
          clipboard:!!v.clipboard, confirmDelete:!!v.confirmDelete, notifications:!!v.notifications });
        el.lang.textContent = S.settings.lang.toUpperCase();
        applyTheme(); persist(); toast("Options saved", "ok");
      });
    const sel = el.modal.querySelector('[data-k="theme"]'); if (sel) sel.value = S.settings.theme;
    const lang = el.modal.querySelector('[data-k="lang"]'); if (lang) lang.value = S.settings.lang;
  }

  // ---------------------------------------------------------------- media/video
  function videoDialog() {
    showModal(`<h2>Download video from a page</h2><p class="desc">yt-dlp looks up the page; pick a quality.</p>
      <label>Page address<input data-k="url" placeholder="https://www.youtube.com/watch?v=..."></label>
      <div class="actions"><button class="btn" data-act="cancel">Cancel</button><button class="btn primary" data-act="ok">Look up</button></div>`,
      async (act, v) => {
        if (!v.url.trim()) return;
        try {
          const raw = await api.call("Video.lookup", v.url.trim());
          const info = typeof raw === "string" ? JSON.parse(raw) : raw;
          const formats = (info.formats || []).filter((f) => f.url || f.format_id).slice(-16).reverse();
          showModal(`<h2>${esc(info.title || "Video")}</h2><p class="desc">Choose a quality and download.</p>
            <label>Quality<select data-k="format">${formats.map((f)=>`<option value="${esc(f.format_id)}">${esc((f.format || f.format_id) + (f.height ? " · " + f.height + "p" : ""))}</option>`).join("") || '<option value="best">Best</option>'}</select></label>
            <label>Save to<input data-k="dir" value="${esc(S.settings.dir || S.status?.downloads || "")}"></label>
            <div class="actions"><button class="btn" data-act="cancel">Cancel</button><button class="btn primary" data-act="ok">Download Now</button></div>`,
            async (a2, v2) => {
              try {
                await api.call("Video.download", v.url.trim(), v2.format, v2.dir);
                toast("Video download started", "ok");
              } catch (e) { toast(e.message || "Video failed", "err"); }
            }, true);
        } catch (e) { toast("Lookup failed: " + (e.message || "yt-dlp missing"), "err"); }
      });
  }

  function galleryDialog() {
    showModal(`<h2>Download a gallery</h2><p class="desc">Uses gallery-dl if installed.</p>
      <label>Gallery address<input data-k="url"></label>
      <label>Save to<input data-k="dir" value="${esc(S.settings.dir || S.status?.downloads || "")}"></label>
      <div class="actions"><button class="btn" data-act="cancel">Cancel</button><button class="btn primary" data-act="ok">Download Now</button></div>`,
      async (act, v) => {
        try { await api.call("Gallery.download", v.url.trim(), v.dir.trim()); toast("Gallery download started", "ok"); }
        catch (e) { toast(e.message || "Gallery failed", "err"); }
      });
  }

  async function importList() {
    try {
      const paths = await api.dialog.open({ title:"Import links" });
      if (!Array.isArray(paths) || !paths.length) return;
      const text = await api.call("Fs.read", paths[0]);
      if (text.length > 64 * 1024 * 1024) { toast("File too large", "err"); return; }
      linkGrabber(text);
    } catch (e) { toast("Import failed", "err"); }
  }
  async function exportList() {
    try {
      const path = await api.dialog.save({ title:"Export links", suggestedName:"zidm-links.txt" });
      if (!path) return;
      const text = S.rows.map((r) => rowUrl(r)).filter(Boolean).join("\n") + "\n";
      await api.call("Fs.write", path, text);
      toast("List exported", "ok");
    } catch (e) { toast("Export failed", "err"); }
  }

  // ------------------------------------------------------------------- menus
  const MENUS = {
    tasks: [ ["addurl","Add new download","Ctrl+N"], ["batch","Add batch download","Ctrl+B"], ["grabber","Link grabber..."], ["torrent","Add torrent..."], ["video","Download video from a page..."], ["gallery","Download a gallery..."], ["sep"], ["import","Import list"], ["export","Export list"] ],
    file: [ ["resume","Resume Download"], ["pause","Stop Download"], ["remove","Remove","Del"], ["sep"], ["props","Properties","Alt+Enter"], ["rename","Move/Rename","F2"], ["checksum","Verify checksum..."] ],
    downloads: [ ["startqueue","Start Queue"], ["stopqueue","Stop Queue"], ["scheduler","Scheduler"], ["speed","Speed Limiter"], ["sep"], ["pauseall","Pause All"], ["stopall","Stop All"], ["deletecompleted","Delete All Completed"], ["find","Find","Ctrl+F"] ],
    view: [ ["theme","Toggle theme"], ["options","Options"], ["hideSidebar","Hide categories"] ],
    help: [ ["about","About ZIDM"], ["shortcuts","Keyboard shortcuts"] ]
  };
  document.querySelectorAll("[data-menu]").forEach((b) => {
    b.addEventListener("click", (ev) => {
      const name = b.dataset.menu;
      const items = MENUS[name].map((i) => i[0] === "sep" ? { sep:true } : { cmd:i[0], label:i[1], key:i[2] });
      menuShow(el.menu, items, b.getBoundingClientRect().left, b.getBoundingClientRect().bottom + 2);
      document.querySelectorAll("[data-menu]").forEach((x) => x.classList.toggle("active", x === b));
      ev.stopPropagation();
    });
  });
  const extraCommands = {
    torrent:addTorrentDialog, video:videoDialog, gallery:galleryDialog, category:categoryDialog,
    startqueue: () => startQueue(), stopqueue: () => stopQueue(),
    scheduler:schedulerDialog, speed:speedDialog, options:optionsDialog,
    pauseall: () => control("aria2.pause", S.rows.filter(isActive).map((r)=>r.gid)),
    stopall: () => control("aria2.remove", S.rows.filter(isActive).map((r)=>r.gid)),
    find: () => { el.find.focus(); },
    theme: () => { S.settings.theme = S.settings.theme === "dark" ? "light" : "dark"; applyTheme(); persist(); },
    hideSidebar: () => { el.app.classList.toggle("hide-sidebar"); },
    about: () => toast("ZIDM — MyZig download manager"),
    shortcuts: () => toast("Ctrl+N add · Ctrl+B batch · Ctrl+F find · Ctrl+A select all · F2 rename · Del remove")
  };
  el.menu.addEventListener("click", (ev) => {
    const b = ev.target.closest("[data-cmd]");
    if (!b) return;
    hideMenus();
    const cmd = b.dataset.cmd;
    const fn = commands[cmd] || extraCommands[cmd];
    if (fn) fn();
  });

  // ------------------------------------------------------------------- toolbar
  byId("addUrlBtn").onclick = () => addUrlDialog();
  byId("addTorrentBtn").onclick = addTorrentDialog;
  byId("resumeBtn").onclick = () => control("aria2.unpause", selectedGids());
  byId("pauseBtn").onclick = () => control("aria2.pause", selectedGids());
  byId("stopBtn").onclick = () => control("aria2.remove", selectedGids());
  byId("removeBtn").onclick = removeDialog;
  byId("deleteCompletedBtn").onclick = deleteCompleted;
  byId("schedulerBtn").onclick = schedulerDialog;
  byId("speedBtn").onclick = speedDialog;
  byId("startQueueBtn").onclick = () => startQueue();
  byId("stopQueueBtn").onclick = () => stopQueue();
  el.settings.onclick = optionsDialog;
  el.theme.onclick = extraCommands.theme;
  el.lang.onclick = () => {
    S.settings.lang = S.settings.lang === "tr" ? "en" : "tr";
    el.lang.textContent = S.settings.lang.toUpperCase();
    persist(); toast("Language: " + S.settings.lang.toUpperCase(), "ok");
  };

  // ------------------------------------------------------------------ shortcuts
  document.addEventListener("keydown", (ev) => {
    const mod = ev.ctrlKey || ev.metaKey;
    const k = ev.key.toLowerCase();
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName);
    if (!el.modal.hidden) return;
    if (mod && k === "n") { ev.preventDefault(); addUrlDialog(); }
    else if (mod && k === "b") { ev.preventDefault(); batchDialog(); }
    else if (mod && k === "f") { ev.preventDefault(); el.find.focus(); }
    else if (mod && k === "a") { ev.preventDefault(); S.rows.forEach((r)=>S.selected.add(r.gid)); render(); }
    else if (ev.key === "F2") { ev.preventDefault(); renameDialog(); }
    else if (ev.altKey && ev.key === "Enter") { ev.preventDefault(); properties(); }
    else if (ev.key === "Delete" && !typing) { ev.preventDefault(); removeDialog(); }
    else if (mod && (ev.key === "=" || ev.key === "+")) { ev.preventDefault(); setScale(S.settings.scale + 10); }
    else if (mod && ev.key === "-") { ev.preventDefault(); setScale(S.settings.scale - 10); }
    else if (mod && ev.key === "0") { ev.preventDefault(); setScale(100); }
    else if (ev.key === "F3" && !typing) { ev.preventDefault(); el.find.focus(); }
    else if (ev.key === "Escape") { hideMenus(); if (!typing) { S.selected.clear(); render(); } }
  });

  // ------------------------------------------------------------------- timers
  function startScheduler() {
    setInterval(() => {
      const now = new Date();
      const hhmm = String(now.getHours()).padStart(2,"0") + ":" + String(now.getMinutes()).padStart(2,"0");
      (S.settings.scheduler || []).forEach((s) => {
        if (s.start === hhmm) startQueue(s.queue);
        if (s.stop === hhmm) stopQueue(s.queue);
      });
    }, 30000);
  }
  function startClipboardWatch() {
    if (!S.settings.clipboard) return;
    S.clipTimer = setInterval(async () => {
      try {
        const text = await api.clipboard.readText();
        if (!text || text === S.lastClip) return;
        S.lastClip = text;
        const re = /(?:https?|ftp):[^\s<>"']+\.(zip|rar|7z|exe|msi|iso|mp4|pdf|mp3|gz)(\?\S*)?/i;
        if (re.test(text)) addUrlDialog(text.match(re)[0]);
      } catch (e) {}
    }, 1500);
  }

  function setScale(value) {
    S.settings.scale = Math.max(90, Math.min(200, value));
    document.documentElement.style.zoom = (S.settings.scale / 100).toString();
    persist();
    toast("Interface size " + S.settings.scale + "%", "ok");
  }

  // --------------------------------------------------------------------- boot
  async function boot() {
    if (!api) { el.list.innerHTML = '<div class="empty"><h2>MyZig bridge missing</h2></div>'; return; }
    api.on("dl:update", (raw) => {
      try {
        const parsed = typeof raw === "string" ? JSON.parse(raw) : raw;
        S.rows = Array.isArray(parsed) ? parsed : [];
        render();
      } catch (e) {}
    });
    api.on("video:progress", (line) => toast(String(line).slice(0, 100)));
    api.on("video:done", () => toast("Video download complete", "ok"));
    api.on("video:error", (e) => toast("Video error: " + String(e).slice(0, 100), "err"));
    api.on("gallery:done", () => toast("Gallery complete", "ok"));
    api.on("gallery:error", (e) => toast("Gallery error: " + String(e).slice(0, 100), "err"));
    api.on("theme:changed", (t) => { S.systemTheme = t === "dark" ? "dark" : "light"; applyTheme(); });

    try {
      const saved = await api.call("Settings.load");
      if (saved && typeof saved === "object") {
        S.settings = Object.assign({}, DEF, saved);
        if (!Array.isArray(S.settings.records)) S.settings.records = [];
        if (!Array.isArray(S.settings.queues)) S.settings.queues = ["Main","Sync"];
      }
    } catch (e) { console.warn("zidm: settings", e); }
    S.records = S.settings.records;
    S.sort = S.settings.sort || "added";
    if (S.settings.scale && S.settings.scale !== 100) document.documentElement.style.zoom = (S.settings.scale / 100).toString();
    el.lang.textContent = S.settings.lang.toUpperCase();
    applyTheme();

    try {
      S.status = await api.call("App.status");
      el.engine.textContent = S.status.engine ? "engine ready" : "engine unavailable";
      el.engine.classList.toggle("ready", !!S.status.engine);
      if (!S.status.engine) toast("aria2 is not installed", "err");
      if (!S.settings.dir) S.settings.dir = S.status.downloads || "";
    } catch (e) { el.engine.textContent = "status failed"; }
    el.dir.textContent = S.settings.dir || "";
    render();
    refresh();
    startScheduler();
    startClipboardWatch();
    setTimeout(markReady, 32);

    if (new URLSearchParams(location.search).get("selftest") === "1") {
      setTimeout(runFullTest, 400);
    }
  }
  // Full feature check driven by ZIDM_SELFTEST=1. The test harness serves a
  // small video at this address and isolates HOME/Downloads.
  const TEST_URL = "http://127.0.0.1:8765/clip.mp4";
  const TEST_URL2 = "http://127.0.0.1:8765/clip2.mp4";
  function waitFor(fn, timeout) {
    return new Promise((resolve) => {
      const start = Date.now();
      const tick = () => {
        if (fn()) return resolve(true);
        if (Date.now() - start > timeout) return resolve(false);
        setTimeout(tick, 200);
      };
      tick();
    });
  }

  async function runFullTest() {
    const out = [];
    const check = (name, ok) => out.push(name + "=" + (ok ? "ok" : "FAIL"));
    try {
      const dir = (S.status && S.status.downloads) || S.settings.dir;
      check("engine", !!(S.status && S.status.engine));
      check("ui", el.categories.children.length >= 11 && !!el.head.children.length);

      const gid = await api.call("Dl.add", TEST_URL, dir, JSON.stringify({ name: "selftest.mp4", paused: true }));
      check("add", typeof gid === "string" && gid.length > 4);
      check("list", await waitFor(() => S.rows.some((r) => r.gid === gid), 5000));

      const pausedRow = S.rows.find((r) => r.gid === gid) || {};
      check("pause", pausedRow.status === "paused" || pausedRow.status === "waiting");
      await api.call("Dl.control", "aria2.unpause", gid);
      check("resume", await waitFor(() => (S.rows.find((r) => r.gid === gid) || {}).status !== "paused", 5000));
      check("complete", await waitFor(() => (S.rows.find((r) => r.gid === gid) || {}).status === "complete", 20000));

      const sum = await api.call("Tools.checksum", dir + "/selftest.mp4", "sha256");
      check("checksum", /^[0-9a-f]{64}$/.test(sum));
      await api.call("Dl.option", gid, JSON.stringify({ "max-download-limit": "64K" }));
      check("option", true);
      await api.call("Dl.global", JSON.stringify({ "max-overall-download-limit": "0" }));
      check("global", true);

      const batchRaw = await api.call("Dl.batch", JSON.stringify([TEST_URL2, TEST_URL2]), dir);
      const gids = Array.isArray(batchRaw) ? batchRaw : JSON.parse(batchRaw);
      check("batch", gids.length === 2);
      for (const g of gids) {
        await api.call("Dl.control", "aria2.remove", g);
        await api.call("Dl.control", "aria2.removeDownloadResult", g);
      }
      await api.call("Dl.control", "aria2.removeDownloadResult", gid);

      const videoRaw = await api.call("Video.lookup", TEST_URL);
      const info = typeof videoRaw === "string" ? JSON.parse(videoRaw) : videoRaw;
      check("video", !!(info && info.title));
      const saved = await api.call("Settings.load");
      check("settings", !!(saved && saved.queues));
      check("shortcuts", typeof MENUS.tasks[0][0] === "string" && typeof commands.addurl === "function");
      check("modals", typeof addUrlDialog === "function" && typeof schedulerDialog === "function" &&
        typeof batchDialog === "function" && typeof videoDialog === "function");
    } catch (e) {
      out.push("error=" + String(e.message || e).slice(0, 80));
    }
    const failed = out.filter((x) => x.endsWith("FAIL") || x.startsWith("error="));
    console.log("ZIDM FULLTEST " + (failed.length ? "FAIL " : "PASS ") + out.join(" "));
  }

  boot().catch((e) => { console.error("zidm boot failed", e); markReady(); });
})();
