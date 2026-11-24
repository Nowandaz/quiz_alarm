// Films the real app (browser build) for the promo: every step saves a
// screenshot and where the finger tapped.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const OUT = path.join(__dirname, 'shots');
const W = 412, H = 892;
const BANK = JSON.parse(fs.readFileSync('/home/user/quiz_alarm/build/web/promo_bank.json', 'utf8')).topics.flatMap((t) => t.questions);

async function start({ time, fresh = true, profile = path.join(__dirname, '.profile') }) {
  if (fresh) fs.rmSync(profile, { recursive: true, force: true });
  if (fresh) fs.rmSync(OUT, { recursive: true, force: true });
  fs.mkdirSync(OUT, { recursive: true });
  const ctx = await chromium.launchPersistentContext(profile, {
    viewport: { width: W, height: H }, deviceScaleFactor: 2.5, timezoneId: 'Africa/Nairobi', locale: 'en-GB',
    args: ['--autoplay-policy=no-user-gesture-required'],
  });
  const page = ctx.pages()[0] || (await ctx.newPage());
  // The film never talks to the real servers.
  await ctx.route(/supabase\.co|azure\.com|onrender\.com/, (r) => r.abort());
  page.on('pageerror', (e) => console.log('PAGE ERROR:', String(e).slice(0, 300)));
  if (time) await page.clock.setFixedTime(new Date(time));
  const steps = [];
  const api = {
    page, ctx, steps,
    async open() {
      await page.goto('http://localhost:8091/');
      await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 90000 });
      await page.evaluate(() => document.querySelector('flt-semantics-placeholder').click());
      for (let i = 0; i < 120 && !(await api.labels()).length; i++) await api.wait(1000);
      await api.wait(1500);
    },
    // With a clock installed, waiting must move that clock too.
    async wait(ms) { await page.waitForTimeout(ms); },
    async setTime(t) { await page.clock.setFixedTime(new Date(t)); },
    async labels() {
      return page.evaluate(() => [...document.querySelectorAll('flt-semantics')]
        .map((e) => (e.getAttribute('aria-label') || (e.querySelector('flt-semantics') ? '' : e.textContent) || '').trim()).filter(Boolean));
    },
    async find(text, { exact = false, last = false } = {}) {
      return page.evaluate(({ text, exact, last }) => {
        const want = text.toLowerCase();
        const label = (e) => (e.getAttribute('aria-label') || e.textContent || '').trim().toLowerCase();
        const area = (e) => { const r = e.getBoundingClientRect(); return r.width * r.height; };
        const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 2 && r.height > 2 && r.y < innerHeight && r.y + r.height > 0; };
        let hits = [...document.querySelectorAll('flt-semantics')].filter((e) => vis(e) &&
          (exact ? (label(e) === want || label(e).endsWith('\n' + want)) : label(e).includes(want)));
        hits.sort((a, b) => (label(a) === want ? 0 : 1) - (label(b) === want ? 0 : 1) || area(a) - area(b));
        if (!hits.length) return null;
        const r = (last ? hits[hits.length - 1] : hits[0]).getBoundingClientRect();
        return { x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height };
      }, { text, exact, last });
    },
    // Saves what is on screen now; `note` says what happens next.
    async shot(name, extra = {}) {
      if (!name) return null;   // not part of the film
      await page.mouse.move(408, 2);   // no hover effects or tooltips in the picture
      await page.waitForTimeout(120);
      const file = `${String(steps.length).padStart(3, '0')}_${name}.png`;
      await page.screenshot({ path: path.join(OUT, file) });
      const step = { file, name, ...extra };
      steps.push(step);
      return step;
    },
    async tapAt(x, y, ms = 900) { await page.mouse.click(x, y); await api.wait(ms); },
    // Photograph, then tap the thing called `text` (the tap point goes with the photo).
    async tap(text, name, opts = {}) {
      const box = await api.find(text, opts);
      if (!box) { console.log(`NOT FOUND "${text}". On screen:`, (await api.labels()).slice(0, 60)); throw new Error('not found: ' + text); }
      const x = opts.dx ? box.x + opts.dx : box.x, y = box.y;
      if (name) await api.shot(name, { tap: [Math.round(x), Math.round(y)], ...(opts.meta || {}) });
      await api.tapAt(x, y, opts.ms || 900);
      return box;
    },
    async type(text, perKey = 60) { for (const ch of text) { await page.keyboard.type(ch); await api.wait(perKey); } },
    // A slow finger drag (a real touch, no fling), for the time wheels and to scroll.
    async drag(x, y, dy, ms = 500) {
      const cdp = api._cdp || (api._cdp = await ctx.newCDPSession(page));
      const pt = (yy) => [{ x, y: yy, id: 1, radiusX: 4, radiusY: 4, force: 1 }];
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: pt(y) });
      const n = Math.max(8, Math.round(Math.abs(dy) / 8));
      for (let i = 1; i <= n; i++) { await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: pt(y + (dy * i) / n) }); await page.waitForTimeout(14); }
      await page.waitForTimeout(160);
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
      await api.wait(ms);
    },
    async scroll(dy, ms = 700) { await page.mouse.move(206, 500); await page.mouse.wheel(0, dy); await api.wait(ms); },
    // The question on screen, looked up in the bank file.
    async question() {
      const all = (await api.labels()).join(' \n ');
      const shown = (await api.labels()).filter((l) => /^[A-E]\n/.test(l)).map((l) => l.slice(2));
      const fits = (q) => q.type === 'mcq' && shown.length >= 2 && shown.every((o) => q.options.includes(o));
      // The same wording can be in two topics: the options settle which.
      const byText = BANK.filter((q) => all.includes(q.text)).sort((x, y) => y.text.length - x.text.length);
      if (shown.length >= 2) return byText.find(fits) || BANK.find(fits) || null;
      return byText.find((q) => q.type !== 'mcq') || byText[0] || null;
    },
    // Answers the question on screen right or wrong; photographs first.
    async answer(right, name, wrongText = 'prednisolone') {
      let q = await api.question();
      for (let i = 0; i < 12 && !q; i++) { await api.wait(500); q = await api.question(); }
      if (!q) { console.log('NO QUESTION. On screen:', (await api.labels()).slice(0, 30)); throw new Error('no question'); }
      if (q.type === 'mcq') {
        const pick = right ? q.answer : q.options.find((o) => o !== q.answer);
        await api.tap(pick, name, { exact: true, ms: 380, meta: { q: q.text.slice(0, 50), right } });
        if (right) await api.shot(name && name + '_correct');
        await api.wait(1500);
      } else {
        const f = await page.evaluate(() => { const e = document.querySelector('input, textarea'); if (!e) return null; const r = e.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; });
        await api.shot(name, { tap: f ? [Math.round(f.x), Math.round(f.y)] : null, q: q.text.slice(0, 50), right });
        if (f) await api.tapAt(f.x, f.y, 400);
        await api.type(right ? q.answer : wrongText, 40);
        await api.wait(300);
        const b = await api.find('Submit');
        await api.shot(name && name + '_typed', { tap: b ? [Math.round(b.x), Math.round(b.y)] : null });
        if (b) await api.tapAt(b.x, b.y, 1300); else { await page.keyboard.press('Enter'); await api.wait(1300); }
      }
      return q;
    },
    async done() { fs.writeFileSync(path.join(OUT, 'steps.json'), JSON.stringify(steps, null, 1)); await ctx.close(); },
  };
  return api;
}
module.exports = { start, OUT };
