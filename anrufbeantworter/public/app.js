// Weboberfläche des Anrufbeantworters (ohne Framework).

const state = { meta: null, config: null, user: null, tab: 'status', nachrichten: [], statusDraft: null, sim: null };
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const view = $('#view');

const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

async function api(method, url, body) {
  const res = await fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.fehler || `HTTP ${res.status}`);
  return data;
}

function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(toast.t);
  toast.t = setTimeout(() => t.classList.remove('show'), 2600);
}

async function guarded(fn) {
  try { await fn(); } catch (e) { toast('Fehler: ' + e.message); }
}

// ---------- Sprachausgabe (Browser-TTS als Ersatz für die spätere Telefonie-Stimme) ----------
function speak(text, onEnd) {
  if (!('speechSynthesis' in window)) { toast('Sprachausgabe wird von diesem Browser nicht unterstützt'); return; }
  speechSynthesis.cancel();
  const u = new SpeechSynthesisUtterance(text);
  u.lang = state.user?.optionen?.stimme || 'de-DE';
  const voice = speechSynthesis.getVoices().find((v) => v.lang?.startsWith('de'));
  if (voice) u.voice = voice;
  u.rate = 0.97;
  if (onEnd) u.onend = onEnd;
  speechSynthesis.speak(u);
}
const stopSpeaking = () => 'speechSynthesis' in window && speechSynthesis.cancel();

// ---------- Hilfen ----------
// Immer Berliner Zeit, unabhängig von der Zeitzone des Browsers (wie der Server).
const berlinFmt = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Berlin', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false });
function localStamp(d = new Date()) {
  const p = Object.fromEntries(berlinFmt.formatToParts(d).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day}T${p.hour === '24' ? '00' : p.hour}:${p.minute}`;
}
function fmtStamp(s) {
  if (!s) return '';
  const [d, t] = s.split('T');
  const [y, m, day] = d.split('-');
  return `${day}.${m}.${y}${t ? ' ' + t : ''}`;
}
const modusLabel = (m) => state.meta.modi[m]?.label || m;
const vertretungName = (id) => state.user.vertretungen.find((v) => v.id === id)?.name || '';

function speechHtml(antwort) {
  return `<div class="speech">${antwort.ansage.abschnitte
    .map((a) => `<span class="part"><span class="tag">${esc(a.teil)}</span><br>${esc(a.text)}</span>`)
    .join('')}</div>`;
}

function vertretungOptions(selected) {
  const std = vertretungName(state.user.standardVertretungId);
  return [
    `<option value="__std" ${selected === undefined || selected === '__std' ? 'selected' : ''}>Automatisch${std ? ` (${esc(std)})` : ''}</option>`,
    `<option value="" ${selected === '' ? 'selected' : ''}>Keine Vertretung nennen</option>`,
    ...state.user.vertretungen.map((v) => `<option value="${esc(v.id)}" ${selected === v.id ? 'selected' : ''}>${esc(v.name)} (${esc(v.telefon)})</option>`),
  ].join('');
}
const readVertretung = (v) => (v === '__std' ? undefined : v);

function artOptions(modus, selected) {
  const map = modus === 'termin' ? state.meta.terminArten : modus === 'abwesend' ? state.meta.abwesendArten : null;
  if (!map) return '';
  return Object.entries(map).map(([k, v]) => `<option value="${k}" ${k === selected ? 'selected' : ''}>${esc(v.label)}</option>`).join('');
}

// ---------- Laden ----------
async function load(userId) {
  state.meta ??= await api('GET', '/api/meta');
  state.config = await api('GET', '/api/config');
  const id = userId || state.user?.id || localStorageGet('userId') || state.config.users[0].id;
  state.user = state.config.users.find((u) => u.id === id) || state.config.users[0];
  localStorageSet('userId', state.user.id);
  $('#userSelect').innerHTML =
    state.config.users.map((u) => `<option value="${esc(u.id)}" ${u.id === state.user.id ? 'selected' : ''}>${esc(u.profil.vorname)} ${esc(u.profil.nachname)} (${esc(u.id)})</option>`).join('') +
    '<option value="__neu">+ Mitarbeiter anlegen …</option>';
  await refreshMessages();
  await refreshBadge();
  render();
}

function localStorageGet(k) { try { return localStorage.getItem('ab.' + k); } catch { return null; } }
function localStorageSet(k, v) { try { localStorage.setItem('ab.' + k, v); } catch { /* egal */ } }

async function refreshBadge() {
  const a = await api('POST', '/api/vorschau', { userId: state.user.id });
  const b = $('#statusBadge');
  b.className = 'badge ' + a.status.modus;
  b.textContent = state.meta.modi[a.status.modus].kurz + (a.status.quelle === 'manuell' ? ' · manuell' : a.status.quelle === 'kalender' ? ' · Kalender' : '');
  return a;
}

async function refreshMessages() {
  state.nachrichten = await api('GET', '/api/nachrichten?userId=' + encodeURIComponent(state.user.id));
  const offen = state.nachrichten.filter((n) => !n.erledigt).length;
  $('#msgCount').textContent = offen || '';
}

async function saveUser(patch, msg = 'Gespeichert') {
  const u = await api('PUT', `/api/users/${state.user.id}`, patch);
  Object.assign(state.user, u);
  await refreshBadge();
  toast(msg);
}

// ---------- Tabs ----------
$('#tabs').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-tab]');
  if (!b) return;
  stopSpeaking();
  state.tab = b.dataset.tab;
  $$('#tabs button').forEach((x) => x.classList.toggle('active', x === b));
  render();
});

$('#userSelect').addEventListener('change', (e) => guarded(async () => {
  if (e.target.value === '__neu') {
    const id = prompt('Kürzel des neuen Mitarbeiters (z. B. tmueller):');
    if (!id) { e.target.value = state.user.id; return; }
    const vorname = prompt('Vorname:') || '';
    const nachname = prompt('Nachname:') || '';
    const u = await api('POST', '/api/users', { id, vorname, nachname });
    await load(u.id);
    toast('Mitarbeiter angelegt – bitte Profil vervollständigen');
    return;
  }
  state.statusDraft = null;
  await load(e.target.value);
}));

function render() {
  const fn = { status: renderStatus, kalender: renderKalender, ansagen: renderAnsagen, regeln: renderRegeln, profil: renderProfil, integration: renderIntegration, simulator: renderSimulator, nachrichten: renderNachrichten }[state.tab];
  guarded(fn);
}

// ---------- Status ----------
async function renderStatus() {
  const a = await refreshBadge();
  const s = a.status;
  const manuell = state.user.status;
  const aktiv = manuell ? manuell.modus : 'auto';
  const draft = state.statusDraft;
  const quelleText = { manuell: 'manuell gesetzt', kalender: 'aus dem Kalender', geschaeftszeiten: 'außerhalb der Geschäftszeiten', standard: 'automatisch' }[s.quelle];
  const kommend = state.user.kalender.filter((e) => e.bis >= localStamp().slice(0, e.bis.length)).slice(0, 4);

  const modeBtn = (key, title, sub) => `<button class="mode ${(draft?.modus ?? aktiv) === key ? 'active' : ''}" data-mode="${key}"><strong>${title}</strong><span>${sub}</span></button>`;

  view.innerHTML = `
    <h2>Mein Status</h2>
    <p class="lead">Wähle, was Anrufer hören sollen. Ein manueller Status hat Vorrang vor Kalender und Geschäftszeiten.</p>
    <div class="card">
      <div class="row"><span class="badge ${s.modus}">${esc(s.label)}</span><span class="meta">${esc(quelleText)}${s.bis ? ' · ' + esc(s.bis) : ''}</span>
        <span class="spacer"></span><button class="btn small" id="play">▶ Anhören</button></div>
      <p class="hint" style="margin:10px 0 0">So hört es ein <b>unbekannter</b> Anrufer gerade. Mit Namen begrüßte Anrufer siehst du im Simulator.</p>
      ${speechHtml(a)}
    </div>
    <div class="card">
      <h3>Status ändern</h3>
      <div class="modes">
        ${modeBtn('auto', 'Automatisch', 'Kalender & Geschäftszeiten')}
        ${modeBtn('standard', 'Nicht erreichbar', 'kurz nicht am Platz')}
        ${modeBtn('termin', 'Im Termin', 'Präsentation, Schulung …')}
        ${modeBtn('abwesend', 'Unterwegs', 'Dienstreise, Messe …')}
        ${modeBtn('urlaub', 'Urlaub', 'mit Vertretung')}
        ${modeBtn('krank', 'Krank', 'mit Vertretung')}
      </div>
      <div id="statusForm"></div>
    </div>
    <div class="card">
      <h3>Nächste Kalendereinträge</h3>
      ${kommend.length ? `<div class="list">${kommend.map(calItem).join('')}</div>` : '<p class="hint">Keine geplanten Abwesenheiten.</p>'}
    </div>`;

  $('#play').onclick = () => speak(a.ansage.text);
  bindCalDelete(renderStatus);
  $$('.mode').forEach((b) => (b.onclick = () => {
    const m = b.dataset.mode;
    if (m === 'auto') return guarded(async () => {
      await api('PUT', `/api/users/${state.user.id}/status`, { modus: null });
      state.user.status = null; state.statusDraft = null; toast('Status: automatisch'); renderStatus();
    });
    const nextHour = new Date(Date.now() + 60 * 60_000);
    state.statusDraft = {
      modus: m,
      art: m === 'termin' ? 'online-praesentation' : m === 'abwesend' ? 'dienstreise' : '',
      bis: ['urlaub', 'krank', 'abwesend'].includes(m) ? localStamp().slice(0, 10) : m === 'termin' ? localStamp(nextHour).slice(0, 14) + '00' : '',
      ...(manuell?.modus === m ? manuell : {}),
    };
    renderStatus();
  }));
  if (draft) renderStatusForm(draft);
}

function renderStatusForm(d) {
  const ganztags = ['urlaub', 'krank', 'abwesend'].includes(d.modus);
  const hatArt = ['termin', 'abwesend'].includes(d.modus);
  const el = $('#statusForm');
  el.innerHTML = `
    <div class="grid">
      ${hatArt ? `<label class="field">Art<select name="art">${artOptions(d.modus, d.art)}</select></label>` : ''}
      ${hatArt ? `<label class="field">Freitext (bei „Sonstiges“)<input name="freitext" value="${esc(d.freitext)}" placeholder="z. B. in einem Workshop"></label>` : ''}
      <label class="field">${ganztags ? 'Bis einschließlich' : 'Voraussichtlich bis'} (optional)
        <input name="bis" type="${ganztags ? 'date' : 'datetime-local'}" value="${esc(ganztags ? (d.bis || '').slice(0, 10) : d.bis)}"></label>
      <label class="field">Vertretung<select name="vertretungId">${vertretungOptions(d.vertretungId)}</select></label>
    </div>
    <div class="row" style="margin-top:12px">
      <button class="btn" id="previewStatus">Vorschau</button>
      <button class="btn primary" id="setStatus">Status setzen</button>
      <span class="hint">Nach Ablauf von „bis“ schaltet der Anrufbeantworter automatisch zurück.</span>
    </div>
    <div id="statusPreview"></div>`;
  const read = () => {
    const f = Object.fromEntries($$('[name]', el).map((i) => [i.name, i.value]));
    return { modus: d.modus, art: f.art || '', freitext: f.freitext || '', bis: f.bis || '', ganztags, vertretungId: readVertretung(f.vertretungId) };
  };
  $('#previewStatus').onclick = () => guarded(async () => {
    const a = await api('POST', '/api/vorschau', { userId: state.user.id, override: { status: read() } });
    $('#statusPreview').innerHTML = speechHtml(a);
    speak(a.ansage.text);
  });
  $('#setStatus').onclick = () => guarded(async () => {
    const r = await api('PUT', `/api/users/${state.user.id}/status`, read());
    state.user.status = r.status; state.statusDraft = null;
    toast('Status gesetzt: ' + modusLabel(r.status.modus));
    renderStatus();
  });
}

function calItem(e) {
  const art = e.modus === 'termin' ? state.meta.terminArten[e.art]?.label : e.modus === 'abwesend' ? state.meta.abwesendArten[e.art]?.label : '';
  const v = e.vertretungId === '' ? 'keine Vertretung' : e.vertretungId ? 'Vertretung: ' + vertretungName(e.vertretungId) : '';
  return `<div class="item"><div><span class="badge ${e.modus}">${esc(modusLabel(e.modus))}</span> <strong>${esc(e.titel || art || '')}</strong>
    <div class="meta">${esc(fmtStamp(e.von))} – ${esc(fmtStamp(e.bis))}${e.ganztags ? ' (ganztägig)' : ''}${v ? ' · ' + esc(v) : ''}${e.freitext ? ' · „' + esc(e.freitext) + '“' : ''}</div></div>
    <button class="btn small danger" data-del="${esc(e.id)}">Löschen</button></div>`;
}

// ---------- Kalender ----------
async function renderKalender() {
  const today = localStamp().slice(0, 10);
  view.innerHTML = `
    <h2>Kalender</h2>
    <p class="lead">Geplante Termine und Abwesenheiten schalten die Ansage automatisch um und danach zurück. Später: Abgleich mit Outlook/Exchange bzw. dem ZSWork-Kalender.</p>
    <div class="card">
      <h3>Neuer Eintrag</h3>
      <div class="grid" id="calForm">
        <label class="field">Art des Eintrags<select name="modus">
          ${['termin', 'abwesend', 'urlaub', 'krank'].map((m) => `<option value="${m}">${esc(modusLabel(m))}</option>`).join('')}</select></label>
        <label class="field" data-art>Termin-Art<select name="art">${artOptions('termin')}</select></label>
        <label class="field">Titel (nur intern)<input name="titel" placeholder="z. B. Präsentation Praxis Neumann"></label>
        <label class="field">Freitext für die Ansage<input name="freitext" placeholder="nur bei „Sonstiges“"></label>
        <label class="check"><input type="checkbox" name="ganztags"> ganztägig</label>
        <label class="field">Von<input name="von" type="datetime-local" value="${today}T09:00"></label>
        <label class="field">Bis<input name="bis" type="datetime-local" value="${today}T10:00"></label>
        <label class="field">Vertretung<select name="vertretungId">${vertretungOptions()}</select></label>
      </div>
      <div class="row" style="margin-top:12px"><button class="btn primary" id="addCal">Eintragen</button></div>
    </div>
    <div class="card"><h3>Einträge</h3>
      ${state.user.kalender.length ? `<div class="list" id="calList">${state.user.kalender.map(calItem).join('')}</div>` : '<p class="hint">Noch keine Einträge.</p>'}
    </div>`;

  const form = $('#calForm');
  const sync = () => {
    const modus = $('[name=modus]', form).value;
    const g = $('[name=ganztags]', form);
    const artWrap = $('[data-art]', form);
    artWrap.style.display = ['termin', 'abwesend'].includes(modus) ? '' : 'none';
    $('select', artWrap).innerHTML = artOptions(modus);
    artWrap.firstChild.textContent = modus === 'abwesend' ? 'Grund' : 'Termin-Art';
    for (const n of ['von', 'bis']) {
      const i = $(`[name=${n}]`, form);
      const want = g.checked ? 'date' : 'datetime-local';
      if (i.type !== want) { const v = i.value; i.type = want; i.value = g.checked ? v.slice(0, 10) : v.slice(0, 10) + (n === 'von' ? 'T09:00' : 'T17:00'); }
    }
  };
  $('[name=modus]', form).onchange = () => {
    $('[name=ganztags]', form).checked = ['urlaub', 'krank', 'abwesend'].includes($('[name=modus]', form).value);
    sync();
  };
  $('[name=ganztags]', form).onchange = sync;
  $('#addCal').onclick = () => guarded(async () => {
    const f = Object.fromEntries($$('[name]', form).map((i) => [i.name, i.type === 'checkbox' ? i.checked : i.value]));
    f.vertretungId = readVertretung(f.vertretungId);
    if (!['termin', 'abwesend'].includes(f.modus)) f.art = '';
    const e = await api('POST', `/api/users/${state.user.id}/kalender`, f);
    state.user.kalender.push(e);
    state.user.kalender.sort((a, b) => a.von.localeCompare(b.von));
    await refreshBadge();
    toast('Eingetragen');
    renderKalender();
  });
  bindCalDelete(renderKalender);
}

function bindCalDelete(after) {
  $$('[data-del]').forEach((b) => (b.onclick = () => guarded(async () => {
    await api('DELETE', `/api/users/${state.user.id}/kalender/${b.dataset.del}`);
    state.user.kalender = state.user.kalender.filter((e) => e.id !== b.dataset.del);
    await refreshBadge();
    after();
  })));
}

// ---------- Ansagen ----------
const TEXT_FELDER = [
  ['intro', 'Begrüßung & Vorstellung'],
  ['introDu', 'Begrüßung für Kollegen (Du)'],
  ['modi.standard', 'Status: nicht erreichbar'],
  ['modi.termin', 'Status: im Termin'],
  ['modi.abwesend', 'Status: unterwegs'],
  ['modi.urlaub', 'Status: Urlaub'],
  ['modi.krank', 'Status: krank'],
  ['modi.feierabend', 'Status: außerhalb der Geschäftszeiten'],
  ['vertretung', 'Hinweis auf Vertretung'],
  ['weiterleitung', 'Angebot: Weiterleitung per Taste'],
  ['supportHinweis', 'Hinweis auf den Support'],
  ['abschluss', 'Abschluss (unbekannter Anrufer)'],
  ['abschlussBekannt', 'Abschluss (erkannter Anrufer)'],
  ['abschlussOhneAufnahme', 'Abschluss ohne Aufnahme'],
];
const PLATZHALTER = ['begruessung', 'ich.name', 'ich.vorname', 'ich.funktion', 'ich.team', 'firma.name', 'firma.produkt', 'firma.supportAnsage', 'grund', 'bis', 'naechsteErreichbarkeit', 'vertretung.name', 'vertretung.telefonAnsage', 'weiterleitung.name', 'weiterleitung.taste', 'anrufer.organisation', 'anrufer.kundennummer'];
const getPath = (o, p) => p.split('.').reduce((x, k) => x?.[k], o);
function setPath(o, p, v) { const ks = p.split('.'); const last = ks.pop(); ks.reduce((x, k) => (x[k] ??= {}), o)[last] = v; }

async function renderAnsagen() {
  const t = state.user.texte;
  const std = state.meta.standardTexte;
  view.innerHTML = `
    <h2>Ansagetexte</h2>
    <p class="lead">Die Ansage wird aus Bausteinen zusammengesetzt. Platzhalter in <code>{{…}}</code> werden beim Anruf ersetzt; <code>{{#x}}…{{/x}}</code> erscheint nur, wenn <code>x</code> gesetzt ist.</p>
    <div class="card">
      <h3>Platzhalter</h3><p class="hint">Klick fügt den Platzhalter in das zuletzt gewählte Textfeld ein.</p>
      <div class="chips">${PLATZHALTER.map((p) => `<button class="chip" data-ph="${p}">{{${p}}}</button>`).join('')}</div>
    </div>
    <div class="card" id="texte">
      ${TEXT_FELDER.map(([k, label]) => `
        <label class="field" style="margin-bottom:12px">${esc(label)}
          <textarea data-key="${k}" rows="2">${esc(getPath(t, k) ?? getPath(std, k))}</textarea>
          <span class="row"><button class="btn small" data-reset="${k}">Standard</button></span>
        </label>`).join('')}
      <div class="row"><button class="btn primary" id="saveTexte">Speichern</button></div>
    </div>
    <div class="card">
      <h3>Vorschau</h3>
      <div class="grid">
        <label class="field">Anrufer<select id="pvCaller"><option value="">Unbekannte Nummer</option>${state.meta.testAnrufer.map((a) => `<option value="${esc(a.nummer)}">${esc(a.label)}</option>`).join('')}</select></label>
        <label class="field">Status<select id="pvMode"><option value="">aktueller Status</option>${['standard', 'termin', 'abwesend', 'urlaub', 'krank'].map((m) => `<option value="${m}">${esc(modusLabel(m))}</option>`).join('')}</select></label>
      </div>
      <div class="row" style="margin-top:12px"><button class="btn" id="pv">▶ Vorschau anhören</button></div>
      <div id="pvOut"></div>
    </div>`;

  let lastTa = null;
  $$('#texte textarea').forEach((ta) => ta.addEventListener('focus', () => (lastTa = ta)));
  $$('[data-ph]').forEach((b) => (b.onclick = () => {
    if (!lastTa) return toast('Erst ein Textfeld anklicken');
    const ins = `{{${b.dataset.ph}}}`;
    const { selectionStart: s, selectionEnd: e, value } = lastTa;
    lastTa.value = value.slice(0, s) + ins + value.slice(e);
    lastTa.focus();
    lastTa.selectionStart = lastTa.selectionEnd = s + ins.length;
  }));
  $$('[data-reset]').forEach((b) => (b.onclick = (ev) => {
    ev.preventDefault();
    $(`textarea[data-key="${b.dataset.reset}"]`).value = getPath(std, b.dataset.reset);
  }));
  const collect = () => {
    const texte = structuredClone(state.user.texte);
    $$('#texte textarea').forEach((ta) => setPath(texte, ta.dataset.key, ta.value));
    return texte;
  };
  $('#saveTexte').onclick = () => guarded(() => saveUser({ texte: collect() }, 'Ansagen gespeichert'));
  $('#pv').onclick = () => guarded(async () => {
    const m = $('#pvMode').value;
    const override = { texte: collect() };
    if (m) override.status = { modus: m, art: m === 'termin' ? 'schulung' : m === 'abwesend' ? 'messe' : '', bis: m === 'termin' ? localStamp(new Date(Date.now() + 2 * 3600_000)) : localStamp(new Date(Date.now() + 5 * 86400_000)).slice(0, 10), ganztags: m !== 'termin' };
    const a = await api('POST', '/api/vorschau', { userId: state.user.id, from: $('#pvCaller').value || '+4930999888777', override });
    $('#pvOut').innerHTML = speechHtml(a);
    speak(a.ansage.text);
  });
}

// ---------- Regeln ----------
async function renderRegeln() {
  const regeln = structuredClone(state.user.regeln);
  const B = state.meta.regelBedingungen;
  const AKT = [
    ['weiterleitungAnbieten', 'Weiterleitung zur Vertretung anbieten (Taste)'],
    ['direktWeiterleiten', 'Sofort zur Vertretung durchstellen'],
    ['supportHinweis', 'Support-Hinweis ansagen'],
    ['sperren', 'Sperren (keine Aufnahme, auflegen)'],
  ];
  const draw = () => {
    view.innerHTML = `
      <h2>Anrufer-Regeln</h2>
      <p class="lead">Regeln greifen nach der Erkennung des Anrufers in Qto/ZSWork. Alle passenden Regeln werden von oben nach unten angewendet; spätere überschreiben frühere.</p>
      ${regeln.map((r, i) => `
        <div class="rule ${r.aktiv ? '' : 'off'}" data-i="${i}">
          <div class="row"><label class="check"><input type="checkbox" data-f="aktiv" ${r.aktiv ? 'checked' : ''}> aktiv</label>
            <input data-f="name" value="${esc(r.name)}" style="flex:1;min-width:200px">
            <button class="btn small" data-up="${i}" ${i === 0 ? 'disabled' : ''}>↑</button>
            <button class="btn small danger" data-rm="${i}">Entfernen</button></div>
          <div class="grid" style="margin-top:10px">
            <label class="field">Wenn<select data-f="bedingung.typ">${Object.entries(B).map(([k, v]) => `<option value="${k}" ${r.bedingung.typ === k ? 'selected' : ''}>${esc(v)}</option>`).join('')}</select></label>
            ${r.bedingung.typ === 'nummern' ? `<label class="field">Rufnummern (eine pro Zeile)<textarea data-f="bedingung.nummern">${esc((r.bedingung.nummern || []).join('\n'))}</textarea></label>` : ''}
            <label class="field">Priorität der Rückruf-Aufgabe<select data-f="aktion.prioritaet"><option value="">unverändert</option><option value="normal" ${r.aktion.prioritaet === 'normal' ? 'selected' : ''}>normal</option><option value="hoch" ${r.aktion.prioritaet === 'hoch' ? 'selected' : ''}>hoch</option></select></label>
          </div>
          <p class="hint" style="margin:10px 0 4px">Nur in diesen Status (nichts gewählt = immer):</p>
          <div class="row">${Object.keys(state.meta.modi).map((m) => `<label class="check"><input type="checkbox" data-modus="${m}" ${(r.bedingung.modi || []).includes(m) ? 'checked' : ''}> ${esc(state.meta.modi[m].kurz)}</label>`).join('')}</div>
          <p class="hint" style="margin:10px 0 4px">Dann:</p>
          <div class="row">
            ${AKT.map(([k, l]) => `<label class="check"><input type="checkbox" data-f="aktion.${k}" ${r.aktion[k] ? 'checked' : ''}> ${esc(l)}</label>`).join('')}
            <label class="check"><input type="checkbox" data-f="aktion.nameNennen" data-invert ${r.aktion.nameNennen === false ? 'checked' : ''}> Anrufer nicht mit Namen ansprechen</label>
          </div>
          <label class="field" style="margin-top:10px">Zusätzlicher Ansagetext<input data-f="aktion.zusatzText" value="${esc(r.aktion.zusatzText)}" placeholder="z. B. Zu Ihrem offenen Ticket melde ich mich heute noch."></label>
        </div>`).join('')}
      <div class="row"><button class="btn" id="addRule">+ Regel</button><span class="spacer"></span><button class="btn primary" id="saveRules">Speichern</button></div>`;

    $$('.rule').forEach((el) => {
      const r = regeln[el.dataset.i];
      $$('[data-f]', el).forEach((inp) => inp.addEventListener('change', () => {
        const f = inp.dataset.f;
        let v;
        if (inp.type === 'checkbox') v = inp.hasAttribute('data-invert') ? (inp.checked ? false : undefined) : inp.checked || undefined;
        else if (f === 'bedingung.nummern') v = inp.value.split(/\n|,/).map((s) => s.trim()).filter(Boolean);
        else v = inp.value || undefined;
        if (f === 'aktiv') r.aktiv = inp.checked;
        else setPath(r, f, v);
        if (f === 'bedingung.typ' || f === 'aktiv') draw();
      }));
      $$('[data-modus]', el).forEach((cb) => cb.addEventListener('change', () => {
        r.bedingung.modi = $$('[data-modus]', el).filter((c) => c.checked).map((c) => c.dataset.modus);
      }));
    });
    $$('[data-rm]').forEach((b) => (b.onclick = () => { regeln.splice(+b.dataset.rm, 1); draw(); }));
    $$('[data-up]').forEach((b) => (b.onclick = () => { const i = +b.dataset.up; [regeln[i - 1], regeln[i]] = [regeln[i], regeln[i - 1]]; draw(); }));
    $('#addRule').onclick = () => { regeln.push({ id: 'r-' + Date.now().toString(36), aktiv: true, name: 'Neue Regel', bedingung: { typ: 'alle' }, aktion: {} }); draw(); };
    $('#saveRules').onclick = () => guarded(() => saveUser({ regeln }, 'Regeln gespeichert'));
  };
  draw();
}

// ---------- Profil ----------
const TAGE = [['mo', 'Mo'], ['di', 'Di'], ['mi', 'Mi'], ['do', 'Do'], ['fr', 'Fr'], ['sa', 'Sa'], ['so', 'So']];
async function renderProfil() {
  const u = state.user;
  const vertretungen = structuredClone(u.vertretungen);
  const o = u.optionen;
  const field = (name, label, value, attrs = '') => `<label class="field">${label}<input name="${name}" value="${esc(value)}" ${attrs}></label>`;
  view.innerHTML = `
    <h2>Profil &amp; Einstellungen</h2>
    <p class="lead">Wer bin ich, wann bin ich erreichbar, wer vertritt mich?</p>
    <form id="pf">
    <div class="card"><h3>Ich</h3><div class="grid">
      ${field('profil.vorname', 'Vorname', u.profil.vorname)}
      ${field('profil.nachname', 'Nachname', u.profil.nachname)}
      ${field('profil.funktion', 'Funktion (wird angesagt)', u.profil.funktion, 'placeholder="z. B. Kundenberater"')}
      ${field('profil.team', 'Team', u.profil.team)}
      ${field('profil.durchwahl', 'Meine Rufnummer / Durchwahl', u.profil.durchwahl)}
      ${field('profil.email', 'E-Mail (Benachrichtigung)', u.profil.email, 'type="email"')}
    </div></div>
    <div class="card"><h3>Unternehmen</h3><div class="grid">
      ${field('firma.name', 'Firma', u.firma.name)}
      ${field('firma.produkt', 'Produkt', u.firma.produkt)}
      ${field('firma.support', 'Support-Rufnummer (optional)', u.firma.support, 'placeholder="für den Support-Hinweis"')}
    </div></div>
    <div class="card"><h3>Geschäftszeiten</h3><p class="hint">Format: <code>08:00-12:00, 13:00-17:00</code>. Leer = nicht erreichbar.</p>
      <div class="days">${TAGE.map(([k, l]) => `<span>${l}</span><input name="gz.${k}" value="${esc((u.geschaeftszeiten[k] || []).map((s) => s.join('-')).join(', '))}">`).join('')}</div>
    </div>
    <div class="card"><h3>Vertretungen</h3><div id="vtList"></div>
      <div class="row" style="margin-top:8px"><button class="btn" type="button" id="addVt">+ Vertretung</button></div>
      <label class="field" style="margin-top:12px">Standard-Vertretung<select name="standardVertretungId" id="stdVt"></select></label>
      <p class="hint">Automatisch genannt im Status:</p>
      <div class="row">${['termin', 'abwesend', 'urlaub', 'krank', 'feierabend', 'standard'].map((m) => `<label class="check"><input type="checkbox" name="vnIn.${m}" ${o.vertretungNennenIn.includes(m) ? 'checked' : ''}> ${esc(state.meta.modi[m].kurz)}</label>`).join('')}</div>
    </div>
    <div class="card"><h3>Verhalten</h3><div class="grid">
      <label class="check"><input type="checkbox" name="o.anruferErkennung" ${o.anruferErkennung ? 'checked' : ''}> Anrufer über Qto/ZSWork erkennen</label>
      <label class="field">Anrufer mit Namen ansprechen<select name="o.nameNennen">
        <option value="immer" ${o.nameNennen === 'immer' ? 'selected' : ''}>immer, wenn erkannt</option>
        <option value="nurKunden" ${o.nameNennen === 'nurKunden' ? 'selected' : ''}>nur Kunden und Kollegen</option>
        <option value="nie" ${o.nameNennen === 'nie' ? 'selected' : ''}>nie</option></select></label>
      <label class="check"><input type="checkbox" name="o.aufnehmen" ${o.aufnehmen ? 'checked' : ''}> Nachrichten aufnehmen</label>
      ${field('o.maxNachrichtSekunden', 'Max. Nachrichtenlänge (Sek.)', o.maxNachrichtSekunden, 'type="number" min="10" max="600"')}
      <label class="check"><input type="checkbox" name="o.transkription" ${o.transkription ? 'checked' : ''}> Nachricht transkribieren</label>
      <label class="check"><input type="checkbox" name="o.rueckrufAufgabe" ${o.rueckrufAufgabe ? 'checked' : ''}> Rückruf-Aufgabe in Qto/ZSWork anlegen</label>
      ${field('o.weiterleitungTaste', 'Taste für Weiterleitung', o.weiterleitungTaste, 'maxlength="1"')}
      <label class="check"><input type="checkbox" name="o.email" ${o.benachrichtigung.email ? 'checked' : ''}> Per E-Mail benachrichtigen</label>
      ${field('o.webhookUrl', 'Webhook (Teams/Slack/Mattermost)', o.benachrichtigung.webhookUrl, 'placeholder="https://…"')}
    </div></div>
    <div class="row"><span class="spacer"></span><button class="btn primary" type="submit">Speichern</button></div>
    </form>`;

  const drawVt = () => {
    $('#vtList').innerHTML = vertretungen.map((v, i) => `
      <div class="row" style="margin-bottom:6px" data-vi="${i}">
        <input data-k="name" value="${esc(v.name)}" placeholder="Name" style="flex:2;min-width:140px">
        <input data-k="telefon" value="${esc(v.telefon)}" placeholder="Telefon" style="flex:2;min-width:140px">
        <input data-k="email" value="${esc(v.email)}" placeholder="E-Mail" style="flex:2;min-width:140px">
        <button class="btn small danger" type="button" data-vrm="${i}">✕</button></div>`).join('') || '<p class="hint">Keine Vertretung hinterlegt.</p>';
    $$('[data-vi] input').forEach((inp) => (inp.oninput = () => { vertretungen[inp.parentElement.dataset.vi][inp.dataset.k] = inp.value; drawStd(); }));
    $$('[data-vrm]').forEach((b) => (b.onclick = () => { vertretungen.splice(+b.dataset.vrm, 1); drawVt(); }));
    drawStd();
  };
  const drawStd = () => {
    const cur = $('#stdVt').value || u.standardVertretungId;
    $('#stdVt').innerHTML = '<option value="">– keine –</option>' + vertretungen.map((v) => `<option value="${esc(v.id)}" ${v.id === cur ? 'selected' : ''}>${esc(v.name || '(ohne Namen)')}</option>`).join('');
  };
  $('#addVt').onclick = () => { vertretungen.push({ id: 'v-' + Date.now().toString(36), name: '', telefon: '', email: '' }); drawVt(); };
  drawVt();

  $('#pf').onsubmit = (ev) => guarded(async () => {
    ev.preventDefault();
    const f = (n) => $(`[name="${n}"]`);
    const geschaeftszeiten = {};
    for (const [k, l] of TAGE) {
      const raw = f('gz.' + k).value.trim();
      geschaeftszeiten[k] = raw ? raw.split(',').map((s) => s.trim().split('-').map((x) => x.trim())) : [];
      for (const slot of geschaeftszeiten[k]) {
        if (slot.length !== 2 || !slot.every((x) => /^\d{2}:\d{2}$/.test(x))) throw new Error(`Geschäftszeit ${l}: Format HH:MM-HH:MM`);
      }
    }
    await saveUser({
      profil: Object.fromEntries(['vorname', 'nachname', 'funktion', 'team', 'durchwahl', 'email'].map((k) => [k, f('profil.' + k).value.trim()])),
      firma: Object.fromEntries(['name', 'produkt', 'support'].map((k) => [k, f('firma.' + k).value.trim()])),
      geschaeftszeiten,
      vertretungen: vertretungen.filter((v) => v.name.trim()),
      standardVertretungId: f('standardVertretungId').value,
      optionen: {
        ...o,
        anruferErkennung: f('o.anruferErkennung').checked,
        nameNennen: f('o.nameNennen').value,
        aufnehmen: f('o.aufnehmen').checked,
        maxNachrichtSekunden: Number(f('o.maxNachrichtSekunden').value) || 120,
        transkription: f('o.transkription').checked,
        rueckrufAufgabe: f('o.rueckrufAufgabe').checked,
        weiterleitungTaste: f('o.weiterleitungTaste').value || '1',
        vertretungNennenIn: $$('[name^="vnIn."]').filter((c) => c.checked).map((c) => c.name.slice(5)),
        benachrichtigung: { email: f('o.email').checked, webhookUrl: f('o.webhookUrl').value.trim() },
      },
    });
    await load(state.user.id);
  });
}

// ---------- Integration ----------
async function renderIntegration() {
  const c = state.config.crm;
  const sys = (k, title, note) => `
    <div class="card" data-sys="${k}"><h3>${title}</h3><p class="hint">${note}</p><div class="grid">
      <label class="field">Basis-URL<input name="baseUrl" value="${esc(c[k].baseUrl)}" placeholder="https://…"></label>
      <label class="field">API-Token<input name="apiToken" type="password" value="${esc(c[k].apiToken)}" placeholder="oder Umgebungsvariable ${k.toUpperCase()}_API_TOKEN"></label>
      <label class="field">Pfad Rufnummernsuche<input name="lookupPath" value="${esc(c[k].lookupPath)}"></label>
      <label class="field">Pfad Rückruf-Aufgabe<input name="taskPath" value="${esc(c[k].taskPath)}"></label>
    </div></div>`;
  view.innerHTML = `
    <h2>Anbindung Qto / ZSWork</h2>
    <p class="lead">Über diese Schnittstelle wird die Rufnummer des Anrufers einem Kontakt (Praxis, Interessent, Kollege) zugeordnet, und Rückrufe landen als Aufgabe im System.</p>
    <div class="card"><div class="grid">
      <label class="field">Aktive Datenquelle<select id="adapter">
        <option value="mock" ${c.adapter === 'mock' ? 'selected' : ''}>Testdaten (Prototyp)</option>
        <option value="qto" ${c.adapter === 'qto' ? 'selected' : ''}>Qto</option>
        <option value="zswork" ${c.adapter === 'zswork' ? 'selected' : ''}>ZSWork</option></select></label>
      <label class="field">Zeitlimit für die Suche (ms)<input id="timeoutMs" type="number" value="${c.timeoutMs}"></label>
      <label class="field">Cache (Minuten)<input id="cacheMinuten" type="number" value="${c.cacheMinuten}"></label>
    </div><p class="hint">Antwortet das System nicht rechtzeitig, wird neutral begrüßt; der Anruf wird nie blockiert.</p></div>
    ${sys('qto', 'Qto', 'Pfade und Feldnamen sind Annahmen und müssen mit der echten Qto-API abgeglichen werden. <code>{nummer}</code> wird durch die E.164-Nummer ersetzt.')}
    ${sys('zswork', 'ZSWork', 'Vorbereitet für die Umstellung: Umschalten der Datenquelle genügt, die Ansage-Logik bleibt gleich.')}
    <div class="row"><span class="spacer"></span><button class="btn primary" id="saveCrm">Speichern</button></div>
    <div class="card" style="margin-top:16px"><h3>Verbindung testen</h3>
      <div class="row"><input id="testNr" placeholder="Rufnummer, z. B. 040 1234567" style="max-width:280px"><button class="btn" id="testCrm">Suchen</button></div>
      <div id="testOut"></div></div>`;

  $('#saveCrm').onclick = () => guarded(async () => {
    const body = { adapter: $('#adapter').value, timeoutMs: Number($('#timeoutMs').value), cacheMinuten: Number($('#cacheMinuten').value) };
    for (const el of $$('[data-sys]')) body[el.dataset.sys] = Object.fromEntries($$('input', el).map((i) => [i.name, i.value.trim()]));
    state.config.crm = await api('PUT', '/api/crm', body);
    toast('Anbindung gespeichert');
  });
  $('#testCrm').onclick = () => guarded(async () => {
    const r = await api('POST', '/api/crm/test', { nummer: $('#testNr').value });
    const k = r.suche?.kontakt;
    $('#testOut').innerHTML = `<p class="${r.health.ok ? '' : 'error'}">${esc(r.adapter)}: ${esc(r.health.info)}</p>` +
      (r.nummer ? (k ? kontaktHtml(k) : `<p>${esc(r.nummer)}: ${r.suche.fehler ? '<span class="error">' + esc(r.suche.fehler) + '</span>' : 'kein Kontakt gefunden'}</p>`) : '');
  });
}

function kontaktHtml(k) {
  const name = [k.anrede, k.titel, k.vorname, k.nachname].filter(Boolean).join(' ');
  return `<dl class="kv">
    ${name ? `<dt>Name</dt><dd>${esc(name)}</dd>` : ''}
    <dt>Organisation</dt><dd>${esc(k.organisation || '–')}</dd>
    <dt>Typ</dt><dd>${esc(k.typ)}${k.vip ? ' · <b>VIP</b>' : ''}${k.duzen ? ' · per Du' : ''}</dd>
    ${k.kundennummer ? `<dt>Kundennummer</dt><dd>${esc(k.kundennummer)}</dd>` : ''}
    ${k.betreuerId ? `<dt>Betreuer</dt><dd>${esc(k.betreuerId)}</dd>` : ''}
    ${k.offeneTickets?.length ? `<dt>Offene Tickets</dt><dd>${k.offeneTickets.map((t) => esc(t.id + ' ' + t.titel)).join('<br>')}</dd>` : ''}
    <dt>Quelle</dt><dd>${esc(k.quelle)}</dd></dl>`;
}

// ---------- Simulator ----------
async function renderSimulator() {
  view.innerHTML = `
    <h2>Anruf-Simulator</h2>
    <p class="lead">Spielt einen eingehenden Anruf durch, genau so, wie ihn später die Telefonanlage über die Telefonie-API auslöst.</p>
    <div class="card"><div class="grid">
      <label class="field">Testanrufer<select id="simCaller"><option value="">– eigene Nummer –</option>${state.meta.testAnrufer.map((a) => `<option value="${esc(a.nummer)}">${esc(a.label)}</option>`).join('')}<option value="anonym">Rufnummer unterdrückt</option></select></label>
      <label class="field">Rufnummer<input id="simNr" placeholder="z. B. 0171 1112233"></label>
      <label class="field">Zeitpunkt (leer = jetzt)<input id="simZeit" type="datetime-local"></label>
    </div>
    <div class="row" style="margin-top:12px"><button class="btn primary" id="simCall">📞 Anruf starten</button></div></div>
    <div id="simOut"></div>`;
  $('#simCaller').onchange = () => { $('#simNr').value = $('#simCaller').value === 'anonym' ? '' : $('#simCaller').value; };
  $('#simCall').onclick = () => guarded(async () => {
    const from = $('#simCaller').value === 'anonym' ? null : $('#simNr').value;
    const r = await api('POST', '/api/telephony/incoming', { userId: state.user.id, from, zeit: $('#simZeit').value || undefined });
    state.sim = r;
    drawSim(r);
  });
}

function drawSim(r) {
  const ansage = r.ablauf.find((s) => s.typ === 'ansage')?.text || '';
  const auswahl = r.ablauf.find((s) => s.typ === 'auswahl');
  const aufnahme = r.ablauf.find((s) => s.typ === 'aufnahme');
  const direkt = r.ablauf.find((s) => s.typ === 'weiterleiten');
  const k = r.anrufer.kontakt;
  const canDictate = 'webkitSpeechRecognition' in window || 'SpeechRecognition' in window;
  $('#simOut').innerHTML = `
    <div class="card"><h3>1 · Erkennung</h3>
      <p>${r.anrufer.anonym ? 'Rufnummer unterdrückt' : esc(r.anrufer.nummer)} → ${r.anrufer.erkannt ? '<b>erkannt</b>' : 'nicht in Qto/ZSWork gefunden'}</p>
      ${k ? kontaktHtml(k) : ''}
      <p class="meta">Status: ${esc(r.status.label)} (${esc(r.status.quelle)})</p></div>
    <div class="card"><h3>2 · Ansage</h3>
      <div class="speech">${esc(ansage)}</div>
      <div class="row"><button class="btn" id="simPlay">▶ Abspielen</button><button class="btn" id="simStop">■ Stopp</button></div></div>
    ${direkt ? `<div class="card"><h3>3 · Weiterleitung</h3><p>Der Anruf wird direkt zu <b>${esc(direkt.ziel.name)}</b> (${esc(direkt.ziel.telefon)}) durchgestellt.</p></div>` : ''}
    ${auswahl ? `<div class="card"><h3>3 · Tastenwahl</h3><button class="btn" id="simDtmf">Taste ${esc(auswahl.taste)} drücken → ${esc(auswahl.ziel.name)}</button><p id="dtmfOut" class="meta"></p></div>` : ''}
    ${aufnahme ? `<div class="card"><h3>${auswahl ? '4' : '3'} · Nachricht hinterlassen</h3>
      <p class="hint">Im Prototyp wird die Sprachnachricht als Text (Transkript) erfasst${canDictate ? ' oder diktiert' : ''}. Max. ${aufnahme.maxSekunden} Sekunden.</p>
      <textarea id="simMsg" rows="3" placeholder="z. B. Hallo Herr Meyer, wir haben eine Frage zur Abrechnung, bitte rufen Sie zurück."></textarea>
      <div class="row" style="margin-top:8px">${canDictate ? '<button class="btn" id="simDictate">🎙 Diktieren</button>' : ''}
        <span class="spacer"></span><button class="btn primary" id="simSave">Auflegen &amp; Nachricht speichern</button></div>
      <div id="simSaved"></div></div>` : ''}`;
  $('#simPlay').onclick = () => speak(ansage);
  $('#simStop').onclick = stopSpeaking;
  speak(ansage);
  if (auswahl) $('#simDtmf').onclick = () => guarded(async () => {
    const d = await api('POST', '/api/telephony/dtmf', { callId: r.callId, taste: auswahl.taste });
    $('#dtmfOut').textContent = d.aktion === 'weiterleiten' ? `${d.ansage} → Verbindung zu ${d.ziel.telefon}` : 'Taste ignoriert';
    speak(d.ansage || '');
  });
  if ($('#simDictate')) $('#simDictate').onclick = () => {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    const rec = new SR();
    rec.lang = 'de-DE';
    rec.onresult = (e) => { $('#simMsg').value = [...e.results].map((x) => x[0].transcript).join(' '); };
    rec.onerror = (e) => toast('Diktat: ' + e.error);
    rec.start();
    toast('Sprich jetzt …');
  };
  if (aufnahme) $('#simSave').onclick = () => guarded(async () => {
    const text = $('#simMsg').value.trim();
    const n = await api('POST', '/api/telephony/recording', { callId: r.callId, transkript: text, dauerSekunden: Math.max(3, Math.round(text.length / 14)) });
    stopSpeaking();
    $('#simSaved').innerHTML = `<p>✔ Nachricht gespeichert${n.aufgabe?.id ? `, Rückruf-Aufgabe <b>${esc(n.aufgabe.id)}</b> in ${esc(n.aufgabe.system)} angelegt` : n.aufgabe?.fehler ? `, <span class="error">Aufgabe fehlgeschlagen: ${esc(n.aufgabe.fehler)}</span>` : ''}.</p>
      <pre class="hint" style="white-space:pre-wrap">${esc(n.benachrichtigung?.text || '')}</pre>`;
    $('#simSave').disabled = true;
    await refreshMessages();
  });
}

// ---------- Nachrichten ----------
async function renderNachrichten() {
  await refreshMessages();
  const list = state.nachrichten;
  view.innerHTML = `
    <h2>Nachrichten</h2>
    <p class="lead">Hinterlassene Nachrichten mit erkanntem Anrufer. Rückrufe werden zusätzlich als Aufgabe in Qto/ZSWork angelegt.</p>
    ${list.length ? `<div class="list">${list.map((n) => {
      const k = n.kontakt;
      const name = k ? [k.anrede, k.titel, k.vorname, k.nachname].filter(Boolean).join(' ') : '';
      return `<div class="item ${n.erledigt ? 'done' : ''}">
        <div style="flex:1;min-width:220px">
          <strong>${esc(name || k?.organisation || n.nummer || 'Rufnummer unterdrückt')}</strong>
          ${n.prioritaet === 'hoch' ? '<span class="badge urlaub">hohe Priorität</span>' : ''}
          <div class="meta">${esc(k?.organisation && name ? k.organisation + ' · ' : '')}${esc(n.nummer || '')} · ${new Date(n.zeit).toLocaleString('de-DE')} · Status damals: ${esc(n.status)}</div>
          ${n.transkript ? `<p style="margin:6px 0 0">„${esc(n.transkript)}“</p>` : '<p class="hint">(keine Nachricht gesprochen)</p>'}
          ${n.aufgabe?.id ? `<div class="meta">Aufgabe ${esc(n.aufgabe.id)} in ${esc(n.aufgabe.system)}</div>` : ''}
        </div>
        <div class="row">
          ${n.nummer ? `<a class="btn small" href="tel:${esc(n.nummer)}" style="text-decoration:none">📞 Zurückrufen</a>` : ''}
          <button class="btn small" data-done="${esc(n.id)}">${n.erledigt ? 'Wieder öffnen' : 'Erledigt'}</button>
          <button class="btn small danger" data-mdel="${esc(n.id)}">Löschen</button>
        </div></div>`;
    }).join('')}</div>` : '<div class="card"><p class="hint">Noch keine Nachrichten. Probiere den Simulator aus.</p></div>'}`;
  $$('[data-done]').forEach((b) => (b.onclick = () => guarded(async () => {
    const n = state.nachrichten.find((x) => x.id === b.dataset.done);
    await api('PATCH', '/api/nachrichten/' + n.id, { erledigt: !n.erledigt });
    renderNachrichten();
  })));
  $$('[data-mdel]').forEach((b) => (b.onclick = () => guarded(async () => {
    await api('DELETE', '/api/nachrichten/' + b.dataset.mdel);
    renderNachrichten();
  })));
}

guarded(() => load());
