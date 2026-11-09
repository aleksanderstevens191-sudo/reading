import * as pdfjsLib from './vendor/pdf.min.mjs';

pdfjsLib.GlobalWorkerOptions.workerSrc = new URL('./vendor/pdf.worker.min.mjs', import.meta.url).href;
const docOpts = (data) => ({
  data,
  cMapUrl: new URL('./vendor/cmaps/', import.meta.url).href,
  cMapPacked: true,
  standardFontDataUrl: new URL('./vendor/standard_fonts/', import.meta.url).href,
});

const $ = (s) => document.querySelector(s);
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));

/* ======================= Storage (IndexedDB) ======================= */
let db;
function openDB() {
  return new Promise((res, rej) => {
    const r = indexedDB.open('reading', 1);
    r.onupgradeneeded = () => {
      r.result.createObjectStore('books', { keyPath: 'id' });
      r.result.createObjectStore('files');
    };
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
}
function tx(store, mode, fn) {
  return new Promise((res, rej) => {
    const t = db.transaction(store, mode);
    const req = fn(t.objectStore(store));
    t.oncomplete = () => res(req ? req.result : undefined);
    t.onerror = t.onabort = () => rej(t.error);
  });
}
const allBooks = () => tx('books', 'readonly', (s) => s.getAll());
const getBook = (id) => tx('books', 'readonly', (s) => s.get(id));
const putBook = (b) => tx('books', 'readwrite', (s) => s.put(b));
const getFile = (id) => tx('files', 'readonly', (s) => s.get(id));
const putFile = (id, buf) => tx('files', 'readwrite', (s) => s.put(buf, id));
const removeBook = async (id) => {
  await tx('books', 'readwrite', (s) => s.delete(id));
  await tx('files', 'readwrite', (s) => s.delete(id));
};

/* ======================= Small UI helpers ======================= */
let toastTimer;
function toast(msg, ms = 2400) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.add('on');
  clearTimeout(toastTimer);
  if (ms) toastTimer = setTimeout(() => t.classList.remove('on'), ms);
}

let theme = localStorage.getItem('theme') || 'dark';
function applyTheme() {
  document.documentElement.dataset.theme = theme;
  document.querySelector('meta[name=theme-color]').content = theme === 'dark' ? '#000000' : '#f2f1ed';
}
applyTheme();

/* ======================= Library ======================= */
let books = [];

async function renderLibrary() {
  books = (await allBooks()).sort((a, b) => (b.openedAt || b.addedAt) - (a.openedAt || a.addedAt));
  const grid = $('#grid');
  grid.replaceChildren();
  $('#empty').hidden = books.length > 0;
  for (const b of books) {
    const card = document.createElement('div');
    card.className = 'book';
    const pct = b.pages > 1 ? Math.round(((b.lastSeen || b.page) / b.pages) * 100) : 0;
    const isNew = !b.openedAt;
    card.innerHTML = `
      <button class="open" type="button" aria-label="Open ${escapeHtml(b.title)}">
        <div class="cover-wrap"><img alt="" src="${b.cover}"></div>
      </button>
      <div class="meta">
        ${isNew ? '<span class="new">NEW</span>' : `<div class="bar"><i style="width:${pct}%"></i></div><span class="pct">${pct}%</span>`}
      </div>
      <div class="title" title="${escapeHtml(b.title)}">${escapeHtml(b.title)}</div>
      <button class="more" type="button" aria-label="Remove book" title="Remove from Library">
        <svg viewBox="0 0 24 24" width="14" height="14"><path d="M6 6l12 12M18 6 6 18" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg>
      </button>`;
    card.querySelector('.open').onclick = () => openBook(b.id);
    card.querySelector('.more').onclick = async (e) => {
      e.stopPropagation();
      if (!confirm(`Remove “${b.title}” from this device?`)) return;
      await removeBook(b.id);
      renderLibrary();
    };
    grid.append(card);
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function cleanTitle(name) {
  return name.replace(/\.pdf$/i, '').replace(/[_]+/g, ' ').replace(/\s+/g, ' ').trim();
}

async function importFiles(fileList) {
  const files = [...fileList].filter((f) => /pdf/i.test(f.type) || /\.pdf$/i.test(f.name));
  if (!files.length) return toast('That isn’t a PDF');
  let lastId = null;
  for (const f of files) {
    const dupe = books.find((b) => b.fileName === f.name && b.size === f.size);
    if (dupe) { lastId = dupe.id; continue; }
    toast(`Adding “${cleanTitle(f.name)}”…`, 0);
    try {
      const buf = await f.arrayBuffer();
      const pdf = await pdfjsLib.getDocument(docOpts(buf.slice(0))).promise;
      let title = cleanTitle(f.name);
      try {
        const t = (await pdf.getMetadata())?.info?.Title?.trim();
        if (t && t.length > 2 && !/\.(docx?|pdf|indd)|untitled|microsoft/i.test(t)) title = t;
      } catch {}
      const cover = await renderCover(pdf);
      const id = (crypto.randomUUID && crypto.randomUUID()) || `${Date.now()}-${Math.random().toString(36).slice(2)}`;
      await putFile(id, buf);
      await putBook({ id, title, fileName: f.name, size: f.size, pages: pdf.numPages, cover, page: 1, addedAt: Date.now() });
      pdf.destroy();
      lastId = id;
    } catch (err) {
      console.error(err);
      toast(`Couldn’t open “${f.name}”`);
      return renderLibrary();
    }
  }
  navigator.storage?.persist?.().catch(() => {});
  toast('Saved to your Library — available offline');
  await renderLibrary();
  if (files.length === 1 && lastId) openBook(lastId);
}

async function renderCover(pdf) {
  const page = await pdf.getPage(1);
  const vp1 = page.getViewport({ scale: 1 });
  const vp = page.getViewport({ scale: 420 / vp1.width });
  const c = document.createElement('canvas');
  c.width = Math.round(vp.width);
  c.height = Math.round(vp.height);
  await page.render({ canvasContext: c.getContext('2d'), viewport: vp, background: 'white' }).promise;
  const url = c.toDataURL('image/jpeg', 0.82);
  c.width = c.height = 0;
  return url;
}

$('#addBtn').onclick = () => $('#file').click();
$('#empty').onclick = () => $('#file').click();
$('#file').onchange = (e) => { importFiles(e.target.files); e.target.value = ''; };

// Drag & drop anywhere
let dragDepth = 0;
const hasFiles = (e) => [...(e.dataTransfer?.types || [])].includes('Files');
addEventListener('dragenter', (e) => { if (!hasFiles(e)) return; e.preventDefault(); dragDepth++; $('#dropOverlay').classList.add('on'); });
addEventListener('dragover', (e) => { if (hasFiles(e)) e.preventDefault(); });
addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; $('#dropOverlay').classList.remove('on'); } });
addEventListener('drop', (e) => {
  if (!hasFiles(e)) return;
  e.preventDefault();
  dragDepth = 0;
  $('#dropOverlay').classList.remove('on');
  if (!$('#reader').hidden) closeReader();
  importFiles(e.dataTransfer.files);
});

/* ======================= Reader ======================= */
const R = {
  book: null, pdf: null, total: 0, aspect: 0.66,
  page: 1, L: null, cache: new Map(),
  outline: [], chapters: [], cur: null, anim: null,
};
const stage = $('#stage');
const reader = $('#reader');

async function openBook(id) {
  const book = await getBook(id);
  if (!book) return;
  toast('Opening…', 0);
  try {
    const buf = await getFile(id);
    R.pdf = await pdfjsLib.getDocument(docOpts(buf)).promise;
  } catch (err) {
    console.error(err);
    return toast('Couldn’t open this book');
  }
  $('#toast').classList.remove('on');
  R.book = book;
  R.total = R.pdf.numPages;
  const vp = (await R.pdf.getPage(1)).getViewport({ scale: 1 });
  R.aspect = vp.width / vp.height;
  // most pages share the size of page 2 better than the cover does
  if (R.total > 2) {
    const vp2 = (await R.pdf.getPage(2)).getViewport({ scale: 1 });
    R.aspect = vp2.width / vp2.height;
  }
  R.cache.clear();
  R.cur = null;
  stage.replaceChildren();
  $('#rtitle').textContent = book.title;
  document.title = book.title;
  $('#scrub').max = R.total;
  $('#library').hidden = true;
  reader.hidden = false;
  book.openedAt = Date.now();
  putBook(book);
  layout();
  show(book.page || 1, 0);
  loadOutline().then(updateInfo);
  history.pushState({ reader: id }, '');
}

function closeReader(fromPop) {
  if (reader.hidden) return;
  saveProgress(true);
  closeToc();
  reader.hidden = true;
  reader.classList.remove('ui');
  $('#library').hidden = false;
  document.title = 'Reading';
  stage.replaceChildren();
  for (const p of R.cache.values()) p.then((c) => { c.width = c.height = 0; }).catch(() => {});
  R.cache.clear();
  R.pdf?.destroy();
  R.pdf = null;
  R.book = null;
  renderLibrary();
  if (!fromPop && history.state?.reader) history.back();
}
addEventListener('popstate', () => closeReader(true));

/* ---------- outline / chapters ---------- */
async function loadOutline() {
  R.outline = [];
  R.chapters = [];
  const pdf = R.pdf;
  let ol = null;
  try { ol = await pdf.getOutline(); } catch {}
  if (!ol || pdf !== R.pdf) return renderToc();
  const walk = async (items, depth) => {
    for (const it of items) {
      let page = null;
      try {
        let dest = it.dest;
        if (typeof dest === 'string') dest = await pdf.getDestination(dest);
        if (Array.isArray(dest)) {
          const ref = dest[0];
          page = (typeof ref === 'object' && ref ? await pdf.getPageIndex(ref) : ref) + 1;
        }
      } catch {}
      R.outline.push({ title: (it.title || '').trim() || 'Untitled', page, depth });
      if (it.items?.length && depth < 2) await walk(it.items, depth + 1);
    }
  };
  await walk(ol, 0);
  if (pdf !== R.pdf) return;
  const withPage = R.outline.filter((o) => Number.isFinite(o.page));
  const top = withPage.filter((o) => o.depth === 0);
  const src = top.length >= 3 ? top : withPage;
  R.chapters = [...new Set(src.map((o) => o.page))].sort((a, b) => a - b);
  renderToc();
}

function renderToc() {
  const list = $('#tocList');
  list.replaceChildren();
  $('#tocTitle').textContent = R.book?.title || 'Contents';
  if (!R.outline.length) {
    list.innerHTML = '<li class="none">This PDF doesn’t include a table of contents. Use the slider at the bottom to jump around.</li>';
    return;
  }
  for (const o of R.outline) {
    const li = document.createElement('li');
    li.className = `d${o.depth}`;
    li.dataset.page = o.page ?? '';
    li.innerHTML = `<button type="button"><span class="t"></span><span class="n">${o.page ?? ''}</span></button>`;
    li.querySelector('.t').textContent = o.title;
    if (o.page) li.querySelector('button').onclick = () => { closeToc(); jump(o.page); };
    list.append(li);
  }
}
function markTocCurrent() {
  const vis = viewPages(R.page);
  const last = vis[vis.length - 1];
  let cur = null;
  for (const li of $('#tocList').children) {
    li.classList.remove('cur');
    const p = +li.dataset.page;
    if (p && p <= last) cur = li;
  }
  cur?.classList.add('cur');
  return cur;
}
function openToc() {
  reader.classList.add('toc-open');
  markTocCurrent()?.scrollIntoView({ block: 'center' });
}
function closeToc() { reader.classList.remove('toc-open'); }

/* ---------- layout ---------- */
function layout() {
  const vw = innerWidth, vh = innerHeight;
  const cs = getComputedStyle(stage);
  const W = stage.clientWidth || vw;
  const H = stage.clientHeight || vh - 96;
  const spread = vw > vh * 1.05 && vw >= 700;
  const side = vw < 600 ? 10 : 56;
  const avail = W - side * 2;
  const gutter = spread ? clamp(avail * 0.05, 20, 64) : 0;
  const ph = spread ? Math.min(H, (avail - gutter) / 2 / R.aspect) : Math.min(H, avail / R.aspect);
  R.L = { spread, ph: Math.floor(ph), pw: Math.floor(ph * R.aspect), gutter: Math.round(gutter), W };
  void cs;
}

// Print-style spreads: cover alone, then [2,3], [4,5], ...
const normalize = (p) => {
  p = clamp(Math.round(p) || 1, 1, R.total);
  if (R.L.spread && p > 1 && p % 2 === 1) p -= 1;
  return p;
};
const viewPages = (p) => (R.L.spread && p > 1 ? [p, p + 1].filter((n) => n <= R.total) : [p]);
const nextOf = (p) => { const n = R.L.spread ? (p === 1 ? 2 : p + 2) : p + 1; return n <= R.total ? n : null; };
const prevOf = (p) => { const n = R.L.spread ? (p <= 3 ? 1 : p - 2) : p - 1; return p > 1 && n >= 1 ? n : null; };

/* ---------- page rendering ---------- */
const CACHE_MAX = 10;
function pageCanvas(n) {
  const key = `${n}|${R.L.pw}x${R.L.ph}|${theme}`;
  let p = R.cache.get(key);
  if (p) { R.cache.delete(key); R.cache.set(key, p); return p; }
  p = renderPage(n);
  R.cache.set(key, p);
  while (R.cache.size > CACHE_MAX) {
    const [k, old] = R.cache.entries().next().value;
    R.cache.delete(k);
    // free GPU memory (important on iPad) once it's off-screen
    old.then((c) => setTimeout(() => { if (!c.isConnected) c.width = c.height = 0; }, 1500)).catch(() => {});
  }
  return p;
}

async function renderPage(n) {
  const pdf = R.pdf;
  const page = await pdf.getPage(n);
  const vp1 = page.getViewport({ scale: 1 });
  const fit = Math.min(R.L.pw / vp1.width, R.L.ph / vp1.height);
  const dpr = Math.min(devicePixelRatio || 1, 2);
  const vp = page.getViewport({ scale: fit * dpr });
  const c = document.createElement('canvas');
  c.width = Math.floor(vp.width);
  c.height = Math.floor(vp.height);
  c.style.width = `${Math.floor(vp1.width * fit)}px`;
  c.style.height = `${Math.floor(vp1.height * fit)}px`;
  const ctx = c.getContext('2d', { willReadFrequently: theme === 'dark' });
  await page.render({ canvasContext: ctx, viewport: vp, background: 'white' }).promise;
  if (theme === 'dark') darkenPage(ctx, c.width, c.height);
  return c;
}

// Night mode like Apple Books: text pages become white-on-black, while
// colour (illustrations, covers, coloured headings) is left alone.
function darkenPage(ctx, w, h) {
  const img = ctx.getImageData(0, 0, w, h);
  const d = img.data;
  let light = 0, total = 0;
  for (let i = 0; i < d.length; i += 4 * 61) {
    total++;
    if (d[i] > 225 && d[i + 1] > 225 && d[i + 2] > 225) light++;
  }
  if (light / total < 0.45) return; // mostly an image (e.g. the cover) – keep it as-is
  for (let i = 0; i < d.length; i += 4) {
    const r = d[i], g = d[i + 1], b = d[i + 2];
    const mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
    const mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
    if (mx - mn < 64) {
      d[i] = (255 - r) * 0.93;
      d[i + 1] = (255 - g) * 0.93;
      d[i + 2] = (255 - b) * 0.93;
    }
  }
  ctx.putImageData(img, 0, 0);
}

function buildView(p) {
  const el = document.createElement('div');
  el.className = 'view';
  el.dataset.page = p;
  el.style.gap = `${R.L.gutter}px`;
  for (const n of viewPages(p)) {
    const slot = document.createElement('div');
    slot.className = 'page';
    slot.style.width = `${R.L.pw}px`;
    slot.style.height = `${R.L.ph}px`;
    slot.innerHTML = `<div class="ph"></div><div class="pnum">${n} of ${R.total}</div>`;
    el.append(slot);
    const attach = (tries) => pageCanvas(n).then((c) => {
      if (!c.width && tries) return attach(tries - 1); // was freed; re-render
      slot.querySelector('.ph')?.remove();
      slot.querySelector('canvas')?.remove();
      slot.prepend(c);
    }).catch((e) => console.warn('render failed', n, e));
    attach(1);
  }
  return el;
}

/* ---------- navigation ---------- */
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

function finishAnim() {
  if (!R.anim) return;
  const a = R.anim;
  R.anim = null;
  a.cleanup();
}

function show(p, dir) {
  finishAnim();
  p = normalize(p);
  const next = buildView(p);
  const old = R.cur;
  R.cur = next;
  R.page = p;
  if (!old || !dir || reduceMotion) {
    stage.replaceChildren(next);
  } else {
    slide(old, next, dir, 0);
  }
  afterChange();
}

// Slide old view out and new view in. `from` = current drag offset in px.
function slide(old, next, dir, from) {
  const W = stage.clientWidth;
  if (!next.isConnected) stage.append(next);
  const dur = from ? 260 : 380;
  const ease = 'cubic-bezier(.22,.7,.2,1)';
  const a1 = old.animate([{ transform: `translateX(${from}px)` }, { transform: `translateX(${-dir * W}px)` }], { duration: dur, easing: ease, fill: 'forwards' });
  const a2 = next.animate([{ transform: `translateX(${from + dir * W}px)` }, { transform: 'translateX(0)' }], { duration: dur, easing: ease, fill: 'forwards' });
  const cleanup = () => {
    a1.cancel(); a2.cancel();
    old.remove();
    next.style.transform = '';
  };
  R.anim = { cleanup };
  a2.onfinish = () => { if (R.anim?.cleanup === cleanup) { R.anim = null; cleanup(); } };
}

function turn(dir) {
  if (!R.pdf) return;
  const target = dir > 0 ? nextOf(R.page) : prevOf(R.page);
  if (target == null) return;
  show(target, dir);
}
function jump(p) {
  const t = normalize(p);
  if (t === R.page) return;
  show(t, t > R.page ? 1 : -1);
}

let saveTimer;
function afterChange() {
  updateInfo();
  // prefetch neighbours
  const n = nextOf(R.page), pv = prevOf(R.page);
  setTimeout(() => {
    if (!R.pdf) return;
    if (n) viewPages(n).forEach(pageCanvas);
    if (pv) viewPages(pv).forEach(pageCanvas);
  }, 120);
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveProgress, 400);
}

function updateInfo() {
  if (!R.pdf) return;
  const vis = viewPages(R.page);
  const last = vis[vis.length - 1];
  $('#pfill').style.width = `${(last / R.total) * 100}%`;
  $('#scrub').value = R.page;
  $('#scrubLabel').textContent = `${vis.join('–')} of ${R.total}`;
  $('#prevBtn').disabled = prevOf(R.page) == null;
  $('#nextBtn').disabled = nextOf(R.page) == null;

  let info = '';
  if (R.chapters.length) {
    const nextCh = R.chapters.find((c) => c > last);
    const left = (nextCh ?? R.total + 1) - last - 1;
    if (left > 0) info = `${left} page${left === 1 ? '' : 's'} left in ${nextCh ? 'chapter' : 'book'}`;
  } else {
    const left = R.total - last;
    if (left > 0) info = `${left} page${left === 1 ? '' : 's'} left`;
  }
  $('#leftInfo').textContent = info;
  if (reader.classList.contains('toc-open')) markTocCurrent();
}

async function saveProgress() {
  const b = R.book;
  if (!b) return;
  const vis = viewPages(R.page);
  b.page = R.page;
  b.lastSeen = vis[vis.length - 1];
  b.openedAt = Date.now();
  try { await putBook(b); } catch (e) { console.warn(e); }
}
document.addEventListener('visibilitychange', () => { if (document.hidden) saveProgress(); });
addEventListener('pagehide', () => saveProgress());

/* ---------- chrome (toolbars) ---------- */
let uiTimer;
const isTouch = matchMedia('(hover: none)').matches;
function showUI(autoHide = !isTouch) {
  reader.classList.add('ui');
  clearTimeout(uiTimer);
  if (autoHide) uiTimer = setTimeout(hideUI, 2600);
}
function hideUI() {
  if (reader.matches(':has(.chrome:hover)')) { uiTimer = setTimeout(hideUI, 1200); return; }
  reader.classList.remove('ui');
}
function toggleUI() { reader.classList.contains('ui') ? hideUI() : showUI(); }

let lastMouse = '';
reader.addEventListener('pointermove', (e) => {
  if (e.pointerType !== 'mouse') return;
  const k = `${e.clientX},${e.clientY}`;
  if (k !== lastMouse) { lastMouse = k; showUI(); }
});
$('#prevBtn').onclick = (e) => { e.stopPropagation(); turn(-1); };
$('#nextBtn').onclick = (e) => { e.stopPropagation(); turn(1); };
$('#backBtn').onclick = () => closeReader();
$('#tocBtn').onclick = () => openToc();
$('#scrim').onclick = () => closeToc();
$('#themeBtn').onclick = () => {
  theme = theme === 'dark' ? 'light' : 'dark';
  localStorage.setItem('theme', theme);
  applyTheme();
  R.cache.clear();
  show(R.page, 0);
};
$('#scrub').addEventListener('input', (e) => {
  const v = normalize(+e.target.value);
  const vis = viewPages(v);
  $('#scrubLabel').textContent = `${vis.join('–')} of ${R.total}`;
  showUI(false);
});
$('#scrub').addEventListener('change', (e) => { jump(+e.target.value); showUI(); });

/* ---------- input: keys, taps, swipes, trackpad ---------- */
addEventListener('keydown', (e) => {
  if (reader.hidden) return;
  if (e.target.closest?.('input')) return;
  const k = e.key;
  if (k === 'ArrowRight' || k === 'PageDown' || (k === ' ' && !e.shiftKey)) { e.preventDefault(); turn(1); }
  else if (k === 'ArrowLeft' || k === 'PageUp' || (k === ' ' && e.shiftKey)) { e.preventDefault(); turn(-1); }
  else if (k === 'Home') jump(1);
  else if (k === 'End') jump(R.total);
  else if (k === 'Escape') reader.classList.contains('toc-open') ? closeToc() : closeReader();
});

let drag = null;
stage.addEventListener('pointerdown', (e) => {
  if (e.button > 0) return;
  finishAnim();
  drag = { id: e.pointerId, x: e.clientX, y: e.clientY, t: performance.now(), dx: 0, active: false, neighbor: null, dir: 0 };
});
stage.addEventListener('pointermove', (e) => {
  if (!drag || e.pointerId !== drag.id) return;
  const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
  if (!drag.active) {
    if (e.pointerType === 'mouse') return; // mouse: click only
    if (Math.abs(dx) < 8 || Math.abs(dx) < Math.abs(dy)) return;
    drag.active = true;
    try { stage.setPointerCapture(e.pointerId); } catch {}
  }
  const dir = dx < 0 ? 1 : -1;
  if (dir !== drag.dir) {
    drag.neighbor?.remove();
    const target = dir > 0 ? nextOf(R.page) : prevOf(R.page);
    drag.neighbor = target != null ? buildView(target) : null;
    if (drag.neighbor) { drag.neighbor.dataset.page = target; stage.append(drag.neighbor); }
    drag.dir = dir;
  }
  const W = stage.clientWidth;
  drag.dx = drag.neighbor ? dx : dx * 0.25; // rubber-band at the ends
  R.cur.style.transform = `translateX(${drag.dx}px)`;
  if (drag.neighbor) drag.neighbor.style.transform = `translateX(${drag.dx + dir * W}px)`;
});
const endDrag = (e) => {
  if (!drag || e.pointerId !== drag.id) return;
  const d = drag;
  drag = null;
  if (!d.active) {
    // a tap / click
    if (e.type === 'pointercancel') return;
    const W = stage.clientWidth;
    const x = e.clientX - stage.getBoundingClientRect().left;
    if (x < W * 0.28) turn(-1);
    else if (x > W * 0.72) turn(1);
    else toggleUI();
    return;
  }
  const W = stage.clientWidth;
  const v = d.dx / Math.max(1, performance.now() - d.t);
  const commit = d.neighbor && (Math.abs(d.dx) > W * 0.18 || Math.abs(v) > 0.5);
  if (commit) {
    const old = R.cur;
    R.cur = d.neighbor;
    R.page = +d.neighbor.dataset.page;
    old.style.transform = '';
    d.neighbor.style.transform = '';
    slide(old, d.neighbor, d.dir, d.dx);
    afterChange();
  } else {
    const cur = R.cur, nb = d.neighbor;
    const a = cur.animate([{ transform: `translateX(${d.dx}px)` }, { transform: 'translateX(0)' }], { duration: 220, easing: 'ease-out' });
    nb?.animate([{ transform: `translateX(${d.dx + d.dir * W}px)` }, { transform: `translateX(${d.dir * W}px)` }], { duration: 220, easing: 'ease-out' });
    cur.style.transform = '';
    a.onfinish = () => nb?.remove();
  }
};
stage.addEventListener('pointerup', endDrag);
stage.addEventListener('pointercancel', endDrag);

// Trackpad two-finger swipe / mouse wheel
let wheelAcc = 0, wheelLock = 0;
reader.addEventListener('wheel', (e) => {
  if (reader.classList.contains('toc-open')) return;
  e.preventDefault();
  const now = performance.now();
  if (now < wheelLock) return;
  const horiz = Math.abs(e.deltaX) > Math.abs(e.deltaY);
  wheelAcc += horiz ? e.deltaX : e.deltaY;
  const th = horiz ? 40 : 80;
  if (Math.abs(wheelAcc) > th) {
    turn(wheelAcc > 0 ? 1 : -1);
    wheelAcc = 0;
    wheelLock = now + 450;
  }
  clearTimeout(reader._wt);
  reader._wt = setTimeout(() => { wheelAcc = 0; }, 160);
}, { passive: false });

let resizeTimer;
addEventListener('resize', () => {
  if (reader.hidden || !R.pdf) return;
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    const keep = viewPages(R.page)[0];
    layout();
    R.cache.clear();
    show(keep, 0);
  }, 150);
});

/* ======================= Boot ======================= */
(async function boot() {
  db = await openDB();
  await renderLibrary();
  if ('serviceWorker' in navigator && location.protocol !== 'file:') {
    navigator.serviceWorker.register('./sw.js').catch((e) => console.warn('SW', e));
  }
})();
