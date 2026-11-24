// The whole film: every screen the promo shows, taken from the real app.
const { start } = require('./film_lib');
(async () => { const a = await start({ time: '2026-11-25T22:42:00+03:00' });
  const dump = async (t) => console.log(t, JSON.stringify((await a.labels()).slice(0, 30)).slice(0, 1400));
  const chapter = (name) => a.steps.push({ chapter: name });
  const field = async () => (await a.find('Search sections and topics')) || (await a.find('Search units, sections and topics')) || (await a.find('Search topics')) ||
    a.page.evaluate(() => { const e = document.querySelector('input, textarea'); if (!e) return null; const r = e.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; });
  try {
  await a.open(); await a.tap('Skip', null);
  // ------------------------------------------- earlier days (not filmed)
  // A few practice sessions on the days before, so Reports has a history.
  const past = [
    ['2026-11-16T20:20:00+03:00', 'nitric', 'Nitric oxide', [1, 0, 0, 1, 1]],
    ['2026-11-17T21:40:00+03:00', 'eicosa', 'Eicosanoids', [0, 1, 1, 0, 1]],
    ['2026-11-19T20:10:00+03:00', 'adrenoceptor', 'Adrenoceptor blockers', [1, 1, 0, 1, 1]],
    ['2026-11-20T21:05:00+03:00', 'anti-tb', 'Anti-TB drugs', [1, 0, 1, 0, 1]],
    ['2026-11-22T19:40:00+03:00', 'anticoag', 'Anticoagulant Drugs', [1, 1, 1, 1, 0]],
    ['2026-11-23T20:30:00+03:00', 'drug inter', 'Drug Interactions', [1, 1, 0, 1, 1]],
    ['2026-11-24T21:15:00+03:00', 'antidiab', 'Oral Antidiabetic Drugs', [1, 1, 1, 1, 1]],
  ];
  let tutorOff = false;
  for (const [when, term, topic, marks] of past) {
    await a.setTime(when); await a.open();
    await a.tap('Banks', null, { exact: true }); await a.wait(900);
    await a.tap('Pharmacology', null); await a.wait(1000);
    const f = await field(); await a.tapAt(f.x, f.y, 400); await a.type(term, 20); await a.wait(800);
    await a.tap(topic, null); await a.wait(1000);
    await a.tap('Practise this topic', null); await a.wait(1000);
    await a.tap('5', null, { exact: true }); await a.wait(300);
    if (!tutorOff) { await a.tap('AI tutor', null, { dx: 150 }); await a.wait(400); tutorOff = true; }
    await a.tap('Start', null, { exact: true }); await a.wait(1300);
    for (let i = 0; i < 3 && (await a.labels()).includes('Set up practice'); i++) { console.log('start: again'); await a.tap('Start', null, { exact: true }); await a.wait(1300); }
    for (const m of marks) {
      await a.answer(!!m, null); await a.wait(500);
      for (const t of ['Next question', 'See results', 'Finish']) { const b = await a.find(t, { exact: true }); if (b) { await a.tapAt(b.x, b.y, 900); break; } }
    }
    for (let i = 0; i < 6 && !(await a.labels()).includes('Question banks'); i++) {
      for (const t of ['Done', 'Back']) { const b = await a.find(t, { exact: true }); if (b) { await a.tapAt(b.x, b.y, 900); break; } }
    }
    console.log('past session done:', topic, (await a.labels()).includes('Question banks'));
  }
  await a.setTime('2026-11-25T22:42:00+03:00'); await a.open(); await a.wait(1000);
  // ---------------------------------------------------------- set the alarm
  chapter('alarm');
  await a.tap('Add your first alarm', 'home'); await a.wait(800);
  await a.shot('edit_new', { drag: [128, 165, 76] });
  await a.drag(128, 165, 76, 600);
  await a.shot('edit_hour', { drag: [212, 200, -238] });
  for (let i = 0; i < 3; i++) await a.drag(212, 200, -238, 400);
  await a.shot('edit_min1', { drag: [212, 200, -238] });
  for (let i = 0; i < 3; i++) await a.drag(212, 200, -238, 400);
  await a.wait(600);
  chapter('topic');
  await a.tap('Topics', 'edit_time'); await a.wait(900);
  let box = await field();
  await a.shot('picker', { tap: [Math.round(box.x), Math.round(box.y)] });
  await a.tapAt(box.x, box.y, 500); await a.type('cor'); await a.wait(500); await a.shot('picker_typing', { hold: 0.35 });
  await a.type('tico'); await a.wait(800);
  await a.tap('Corticosteroids - Immunosuppressant', 'picker_search'); await a.wait(600);
  await a.tap('Done', 'picker_ticked', { exact: true }); await a.wait(900);
  await a.tap('Done', 'edit_ready', { exact: true }); await a.wait(1500);
  await a.shot('home_alarm', { hold: 1.6 });
  // ------------------------------------------------------------ it rings
  chapter('ring');
  await a.setTime('2026-11-26T05:30:00+03:00'); await a.open(); await a.wait(1500);
  const wrong = async (n) => { await a.answer(false, 'ring_q' + n); await a.tap('Next question', 'ring_why' + n, { ms: 1200, meta: { read: true } }); };
  const right = async (n) => { await a.answer(true, 'ring_q' + n); };
  await wrong(1);
  chapter('reset');
  await right(2); await wrong(3); await wrong(4);
  chapter('streak');
  await a.setTime('2026-11-26T05:31:20+03:00');
  await right(5);
  await a.setTime('2026-11-26T05:31:50+03:00');
  await right(6);
  await a.wait(1500);
  chapter('review');
  await a.tap('Review', 'alarm_off', { meta: { hold: 1.4 } }); await a.wait(1200);
  await a.shot('results', { drag: [206, 700, -330], hold: 1.2 });
  await a.drag(206, 700, -330, 700);
  await a.tap('Practise the 3 you missed', 'results2', { meta: { read: true } }); await a.wait(1500);
  await a.answer(true, 'retry_q'); await a.wait(700);
  await a.tap('Finish', 'retry_after', { meta: { read: true } }); await a.wait(1200);
  await a.shot('after_finish'); await dump('finish');
  // -------------------------------------------------------- question bank
  chapter('bank');
  for (const t of ['Done', 'Back']) { const b = await a.find(t, { exact: true }); if (b) { await a.tapAt(b.x, b.y, 900); } }
  await dump('home?');
  await a.wait(2500);
  await a.tap('Banks', 'home_after', { exact: true }); await a.wait(1200);
  if (!(await a.labels()).includes('Question banks')) { console.log('banks: second try'); await a.tap('Banks', null, { exact: true }); await a.wait(1200); }
  await a.tap('Pharmacology', 'banks', { meta: { hold: 1.2 } }); await a.wait(1200);
  box = await field();
  await a.shot('unit', { tap: [Math.round(box.x), Math.round(box.y)], hold: 1.2 });
  await a.tapAt(box.x, box.y, 500); await a.type('cor'); await a.wait(500); await a.shot('unit_typing', { hold: 0.35 });
  await a.type('tico'); await a.wait(900);
  await a.tap('Corticosteroids - Immunosuppressant', 'unit_search'); await a.wait(1200);
  chapter('practice');
  await a.tap('Practise this topic', 'topic', { meta: { hold: 1.3 } }); await a.wait(1200);
  await a.tap('5', 'setup', { exact: true }); await a.wait(500);
  await a.tap('Start', 'setup5', { exact: true }); await a.wait(1500);
  for (let i = 0; i < 3 && (await a.labels()).includes('Set up practice'); i++) { console.log('start: again'); await a.tap('Start', null, { exact: true }); await a.wait(1300); }
  await a.answer(false, 'prac_q1'); await a.wait(700);
  await a.tap('Next question', 'prac_why1', { meta: { read: true } }); await a.wait(1200);
  await a.answer(true, 'prac_q2'); await a.wait(700);
  await a.tap('Finish', 'prac_why2', { meta: { read: true } }); await a.wait(1200);
  await a.shot('prac_results', { hold: 1.6 }); await dump('prac results');
  for (const t of ['Done', 'Back', 'Back', 'Back']) { const b = await a.find(t, { exact: true }); if (b) await a.tapAt(b.x, b.y, 1000); }
  await dump('after practice');
  // --------------------------------------------------------------- reports
  chapter('reports');
  await a.tap('Reports', 'back_home', { exact: true }); await a.wait(1500);
  if (!(await a.labels()).some((l) => l.startsWith('Reports') && l !== 'Reports')) { await dump('reports?'); }
  await a.shot('reports', { drag: [206, 700, -380], hold: 2 }); await dump('reports');
  await a.drag(206, 700, -380, 800);
  await a.shot('reports2', { drag: [206, 700, -380], hold: 1.8 });
  await a.drag(206, 700, -380, 800);
  await a.shot('reports3', { hold: 2 });
  } catch (e) { console.log('ERR', e.message); }
  await a.done(); })();
