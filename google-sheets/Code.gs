/**
 * In Smoke We Trust · Kitchen Control → Google Sheets
 *
 * Prima svaku promenu ciklusa iz Supabase baze i održava tabelu identičnom sajtu:
 *   nov ciklus → nov red · izmena → red se menja · brisanje → red se briše.
 *
 * Postavljanje: Extensions → Apps Script → nalepi ovaj kod → upiši TAJNI_KLJUC →
 * Deploy → New deployment → Web app (Execute as: Me, Who has access: Anyone).
 * Adresu web aplikacije + "?token=TAJNI_KLJUC" upisati u bazu (vidi supabase/03_google_sheets.sql).
 */

const TAJNI_KLJUC = 'OVDE-IDE-TAJNI-KLJUC';
const ID_KOLONA = 20; // kolona T: "ID ciklusa"
const ZONA = 'Europe/Belgrade';
const OBAVESTENJE_NA = 'office@nutribox.rs'; // ko dobija mejl za svaki nov ciklus (više adresa: odvojiti zarezom)
const ADRESA_SAJTA = 'https://insmoke.rs/aplikacija/';
const UPRAVA = 'office@nutribox.rs, ilija.nikolic.sf.bg@gmail.com'; // dnevni otpis i novi nalozi za odobrenje

function doPost(e) {
  const token = (e && e.parameter && e.parameter.token) || '';
  if (token !== TAJNI_KLJUC) return odgovor_({ ok: false, greska: 'nedozvoljeno' });

  let poruka;
  try { poruka = JSON.parse(e.postData.contents); }
  catch (err) { return odgovor_({ ok: false, greska: 'neispravan JSON' }); }

  if (poruka.kind === 'signup') {
    if (OBAVESTENJE_NA && poruka.record) posaljiNoviNalog_(poruka.record);
    return odgovor_({ ok: true });
  }
  if (poruka.kind === 'daily_waste') {
    if (OBAVESTENJE_NA && poruka.summary) posaljiDnevniOtpis_(poruka.summary);
    return odgovor_({ ok: true });
  }
  if (poruka.kind === 'mc_daily') { posaljiMcDnevni_(poruka); return odgovor_({ ok: true }); }
  if (poruka.kind === 'mc_weekly') { posaljiMcNedeljni_(poruka); return odgovor_({ ok: true }); }
  if (poruka.kind === 'waste') {
    const l = LockService.getScriptLock();
    l.waitLock(20000);
    try { otpisUTabelu_(poruka); } finally { l.releaseLock(); }
    return odgovor_({ ok: true });
  }

  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    if (ss.getSpreadsheetTimeZone() !== ZONA) ss.setSpreadsheetTimeZone(ZONA);
    const sh = ss.getSheets()[0];
    const zapis = poruka.record || null;
    const stari = poruka.old_record || null;
    const id = (zapis && zapis.id) || (stari && stari.id);
    if (!id) return odgovor_({ ok: false, greska: 'nema ID' });

    const red = nadjiRed_(sh, id);
    if (poruka.type === 'DELETE') {
      if (red) sh.deleteRow(red);
    } else {
      const vrednosti = uRed_(zapis);
      if (red) sh.getRange(red, 1, 1, vrednosti.length).setValues([vrednosti]);
      else sh.appendRow(vrednosti);
      formatiraj_(sh);
      if (poruka.type === 'INSERT' && OBAVESTENJE_NA) {
        try { posaljiObavestenje_(zapis, vrednosti, ss.getUrl()); } catch (err) { console.error(err); }
      }
    }
    return odgovor_({ ok: true });
  } finally {
    lock.releaseLock();
  }
}

function nadjiRed_(sh, id) {
  const poslednji = sh.getLastRow();
  if (poslednji < 2) return 0;
  const ids = sh.getRange(2, ID_KOLONA, poslednji - 1, 1).getValues();
  for (let i = 0; i < ids.length; i++) if (String(ids[i][0]) === String(id)) return i + 2;
  return 0;
}

function broj_(v) { return v === null || v === undefined || v === '' ? null : Number(v); }
function zaokruzi_(v, d) { return v === null || !isFinite(v) ? '' : Math.round(v * Math.pow(10, d)) / Math.pow(10, d); }

function uRed_(r) {
  const sirovo = broj_(r.raw_kg), trim = broj_(r.trimmed_kg), smoker = broj_(r.cooked_kg), prodaja = broj_(r.sellable_kg);
  const cena = broj_(r.price_per_kg);
  const izlaz = prodaja > 0 ? prodaja : smoker;
  const yieldPct = sirovo > 0 && izlaz > 0 ? izlaz / sirovo * 100 : null;
  const gTrim = trim > 0 ? (sirovo - trim) / sirovo * 100 : null;
  const gSmoker = trim > 0 ? (trim - smoker) / trim * 100 : (sirovo > 0 ? (sirovo - smoker) / sirovo * 100 : null);
  const gSecenje = prodaja > 0 ? (smoker - prodaja) / smoker * 100 : null;
  const stvarna = cena > 0 && izlaz > 0 ? sirovo * cena / izlaz : null;
  const datum = r.cook_date ? Utilities.parseDate(r.cook_date + ' 12:00', ZONA, 'yyyy-MM-dd HH:mm') : '';
  return [
    datum,
    r.product_name || r.product_id || '',
    r.cook_name || '',
    r.batch || '',
    zaokruzi_(sirovo, 3), zaokruzi_(trim, 3), zaokruzi_(smoker, 3), zaokruzi_(prodaja, 3),
    zaokruzi_(yieldPct, 1), zaokruzi_(gTrim, 1), zaokruzi_(gSmoker, 1), zaokruzi_(gSecenje, 1),
    zaokruzi_(cena, 0), zaokruzi_(stvarna, 0),
    zaokruzi_(broj_(r.smoker_temp_c), 0), zaokruzi_(broj_(r.hours), 1),
    r.wood || '', r.notes || '',
    r.created_at ? new Date(r.created_at) : '',
    r.id
  ];
}

function formatiraj_(sh) {
  const n = sh.getLastRow();
  if (n < 2) return;
  sh.setFrozenRows(1);
  sh.getRange(1, 1, 1, ID_KOLONA).setFontWeight('bold');
  sh.getRange(2, 1, n - 1, 1).setNumberFormat('dd.MM.yyyy.');
  sh.getRange(2, 19, n - 1, 1).setNumberFormat('dd.MM.yyyy. HH:mm');
  sh.getRange(2, 1, n - 1, ID_KOLONA).sort([{ column: 1, ascending: false }, { column: 19, ascending: false }]);
}

function broj_sr_(v, d) {
  return v === '' || v === null ? '—' : Number(v).toLocaleString('sr-Latn-RS', { minimumFractionDigits: d, maximumFractionDigits: d });
}

function posaljiObavestenje_(r, v, urlTabele) {
  const meso = v[1], kuvar = v[2] || 'nepoznato', yieldPct = v[8];
  const cilj = r.target_yield === null || r.target_yield === undefined ? null : Number(r.target_yield);
  let ocena = 'Za ovo meso još nema postavljenog cilja.';
  if (cilj !== null && yieldPct !== '') {
    const razlika = yieldPct - cilj;
    ocena = 'Cilj: ' + broj_sr_(cilj, 0) + ' % · ' + (razlika >= 0 ? '+' : '') + broj_sr_(razlika, 1) + ' pp ' +
      (razlika >= -1 ? '(u redu)' : razlika >= -4 ? '(malo ispod cilja)' : '(ispod cilja — proveriti)');
  }
  const datum = r.cook_date ? r.cook_date.split('-').reverse().join('.') + '.' : '';
  const redovi = [
    ['Datum', datum],
    ['Meso', meso],
    ['Ko je pekao', kuvar],
    ['Šarža / dobavljač', v[3] || '—'],
    ['Sirovo', broj_sr_(v[4], 2) + ' kg'],
    ['Posle trima', v[5] === '' ? '—' : broj_sr_(v[5], 2) + ' kg'],
    ['Iz smokera', broj_sr_(v[6], 2) + ' kg'],
    ['Za prodaju', v[7] === '' ? '—' : broj_sr_(v[7], 2) + ' kg'],
    ['Yield', broj_sr_(yieldPct, 1) + ' %'],
    ['Gubitak trim / smoker / sečenje', [v[9], v[10], v[11]].map(function (x) { return x === '' ? '—' : broj_sr_(x, 1) + ' %'; }).join(' / ')],
    ['Stvarna cena po kg', v[13] === '' ? '—' : broj_sr_(v[13], 0) + ' RSD'],
    ['Smoker', [v[14] === '' ? null : v[14] + ' °C', v[15] === '' ? null : broj_sr_(v[15], 1) + ' h', v[16] || null].filter(Boolean).join(' · ') || '—'],
    ['Napomena', v[17] || '—']
  ];
  const tekst = 'Nov ciklus sa smokera — In Smoke We Trust\n\n' +
    redovi.map(function (x) { return x[0] + ': ' + x[1]; }).join('\n') +
    '\n\n' + ocena + '\n\nPlatforma: ' + ADRESA_SAJTA + '\nTabela: ' + urlTabele;
  const esc = function (s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); };
  const html = '<div style="font-family:Arial,sans-serif;font-size:14px;color:#211c19">' +
    '<p style="margin:0 0 4px;color:#b4401e;font-size:12px;letter-spacing:1px">IN SMOKE WE TRUST · NOV CIKLUS</p>' +
    '<h2 style="margin:0 0 12px">' + esc(meso) + ' — ' + esc(broj_sr_(yieldPct, 1)) + ' %</h2>' +
    '<p style="margin:0 0 12px"><b>' + esc(ocena) + '</b></p>' +
    '<table style="border-collapse:collapse">' + redovi.map(function (x) {
      return '<tr><td style="padding:4px 16px 4px 0;color:#6d625b">' + esc(x[0]) + '</td><td style="padding:4px 0">' + esc(x[1]) + '</td></tr>';
    }).join('') + '</table>' +
    '<p style="margin:16px 0 0"><a href="' + ADRESA_SAJTA + '">Otvori platformu</a> · <a href="' + urlTabele + '">Otvori tabelu</a></p></div>';
  MailApp.sendEmail({
    to: OBAVESTENJE_NA,
    subject: 'Nov ciklus: ' + meso + ' — yield ' + broj_sr_(yieldPct, 1) + ' % (' + kuvar + ')',
    body: tekst,
    htmlBody: html,
    name: 'In Smoke We Trust · Kitchen Control'
  });
}

function posaljiNoviNalog_(r) {
  const ime = r.full_name || 'Bez imena', email = r.email || '—';
  const vreme = Utilities.formatDate(r.created_at ? new Date(r.created_at) : new Date(), ZONA, 'dd.MM.yyyy. HH:mm');
  const link = ADRESA_SAJTA + '#tim';
  const esc = function (s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); };
  MailApp.sendEmail({
    to: UPRAVA,
    subject: 'Nov nalog čeka odobrenje: ' + ime,
    body: 'Neko je napravio nalog na platformi In Smoke We Trust · Kitchen Control i čeka tvoje odobrenje.\n\n' +
      'Ime i prezime: ' + ime + '\nEmail: ' + email + '\nVreme: ' + vreme +
      '\n\nOdobri ili odbij u tabu Tim: ' + link +
      '\n\nAko ne znaš ko je ova osoba, odbij nalog.',
    htmlBody: '<div style="font-family:Arial,sans-serif;font-size:14px;color:#211c19">' +
      '<p style="margin:0 0 4px;color:#b4401e;font-size:12px;letter-spacing:1px">IN SMOKE WE TRUST · NOV NALOG</p>' +
      '<h2 style="margin:0 0 12px">' + esc(ime) + ' čeka odobrenje</h2>' +
      '<table style="border-collapse:collapse">' +
      '<tr><td style="padding:4px 16px 4px 0;color:#6d625b">Email</td><td>' + esc(email) + '</td></tr>' +
      '<tr><td style="padding:4px 16px 4px 0;color:#6d625b">Vreme</td><td>' + esc(vreme) + '</td></tr></table>' +
      '<p style="margin:16px 0"><a href="' + link + '" style="background:#b4401e;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none">Otvori tab Tim</a></p>' +
      '<p style="margin:0;color:#6d625b">Ako ne znaš ko je ova osoba, odbij nalog.</p></div>',
    name: 'In Smoke We Trust · Kitchen Control'
  });
}

// ===================== OTPIS =====================
const OTPIS_LIST = 'Otpis';
const OTPIS_ZAGLAVLJE = ['Datum', 'Smena', 'Deo', 'Grupa', 'Namirnica', 'Količina', 'Jedinica', 'Faza', 'Razlog',
  'Cena po jedinici RSD', 'Vrednost RSD', 'Ko je otpisao', 'Napomena', 'Upisano', 'ID otpisa'];
const OTPIS_ID_KOLONA = 15;
const RAZLOZI = { visak: 'Višak na kraju dana', prekuvano: 'Prekuvano / presušeno', rok: 'Istekao rok / pokvareno',
  greska: 'Greška u pripremi', vraceno: 'Vraćeno od gosta', ostecenje: 'Pad / oštećenje / razbijeno',
  osoblje: 'Osoblje / degustacija', ostalo: 'Ostalo' };
const FAZE = { sirovo: 'sirovo', pripremljeno: 'pripremljeno', gotovo: 'gotovo jelo' };
const DELOVI = { kuhinja: 'Kuhinja', sank: 'Šank' };

function otpisList_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  if (ss.getSpreadsheetTimeZone() !== ZONA) ss.setSpreadsheetTimeZone(ZONA);
  let sh = ss.getSheetByName(OTPIS_LIST);
  if (!sh) {
    sh = ss.insertSheet(OTPIS_LIST);
    sh.getRange(1, 1, 1, OTPIS_ZAGLAVLJE.length).setValues([OTPIS_ZAGLAVLJE]).setFontWeight('bold');
    sh.setFrozenRows(1);
  }
  return sh;
}

function otpisUTabelu_(poruka) {
  const sh = otpisList_();
  const z = poruka.record || null, s = poruka.old_record || null;
  const id = (z && z.id) || (s && s.id);
  if (!id) return;
  let red = 0;
  const n = sh.getLastRow();
  if (n >= 2) {
    const ids = sh.getRange(2, OTPIS_ID_KOLONA, n - 1, 1).getValues();
    for (let i = 0; i < ids.length; i++) if (String(ids[i][0]) === String(id)) { red = i + 2; break; }
  }
  if (poruka.type === 'DELETE') { if (red) sh.deleteRow(red); return; }
  const v = [
    z.waste_date ? Utilities.parseDate(z.waste_date + ' 12:00', ZONA, 'yyyy-MM-dd HH:mm') : '',
    Number(z.shift) + '.',
    DELOVI[z.area] || z.area || '',
    z.grp || '',
    z.item_name || '',
    zaokruzi_(broj_(z.qty), 3),
    z.unit || '',
    FAZE[z.stage] || z.stage,
    RAZLOZI[z.reason] || z.reason,
    zaokruzi_(broj_(z.unit_cost), 2),
    zaokruzi_(broj_(z.value_rsd), 0),
    z.cook_name || '',
    z.notes || '',
    z.created_at ? new Date(z.created_at) : '',
    z.id
  ];
  if (red) sh.getRange(red, 1, 1, v.length).setValues([v]); else sh.appendRow(v);
  const m = sh.getLastRow();
  if (m >= 2) {
    sh.getRange(2, 1, m - 1, 1).setNumberFormat('dd.MM.yyyy.');
    sh.getRange(2, 14, m - 1, 1).setNumberFormat('dd.MM.yyyy. HH:mm');
    sh.getRange(2, 1, m - 1, OTPIS_ID_KOLONA).sort([{ column: 1, ascending: false }, { column: 2, ascending: false }, { column: 14, ascending: false }]);
  }
}

function posaljiDnevniOtpis_(s) {
  const esc = function (x) { return String(x).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); };
  const datum = s.date ? String(s.date).split('-').reverse().join('.') + '.' : '';
  const ukupno = Number(s.total_rsd || 0);
  const smene = (s.by_shift || []).map(function (x) {
    const st = x.closed ? (x.no_waste ? 'zatvorena, bez otpisa' : 'zatvorena') + (x.closed_by_name ? ' (' + x.closed_by_name + ')' : '') : 'NIJE ZATVORENA';
    return { naziv: x.shift + '. smena', iznos: broj_sr_(Number(x.rsd || 0), 0) + ' RSD', opis: x.cnt + ' ' + (x.cnt == 1 ? 'unos' : 'unosa') + ' · ' + st, otvorena: !x.closed };
  });
  const otvorene = smene.filter(function (x) { return x.otvorena; }).length;
  const razlozi = (s.by_reason || []).slice(0, 3).map(function (x) { return [RAZLOZI[x.reason] || x.reason, broj_sr_(Number(x.rsd || 0), 0) + ' RSD · ' + x.cnt + '×']; });
  const artikli = (s.top_items || []).map(function (x) { return [x.item_name, broj_sr_(Number(x.qty || 0), Number(x.qty) % 1 ? 2 : 0) + ' ' + x.unit + ' · ' + broj_sr_(Number(x.rsd || 0), 0) + ' RSD']; });
  const delovi = (s.by_area || []).map(function (x) { return (DELOVI[x.area] || x.area) + ' ' + broj_sr_(Number(x.rsd || 0), 0) + ' RSD'; }).join(' · ');
  const upozorenja = [];
  if (otvorene) upozorenja.push(otvorene + (otvorene === 1 ? ' smena nije zatvorena' : ' smene nisu zatvorene') + ' — proveri da li je sve upisano.');
  if (Number(s.missing_price) > 0) upozorenja.push(s.missing_price + ' ' + (s.missing_price == 1 ? 'stavka nema cenu, pa nije' : 'stavke nemaju cenu, pa nisu') + ' u zbiru — upiši cene u „Namirnice“.');

  const subjekt = 'Otpis ' + datum + ': ' + broj_sr_(ukupno, 0) + ' RSD' + (otvorene ? ' · ' + (otvorene === 1 ? '1 smena nije zatvorena' : otvorene + ' smene nisu zatvorene') : '');
  const tekst = 'Dnevni otpis — In Smoke We Trust — ' + datum + '\n\n' +
    'Ukupno: ' + broj_sr_(ukupno, 0) + ' RSD (' + (s.count || 0) + ' unosa)' + (delovi ? '\n' + delovi : '') + '\n\n' +
    'Po smenama:\n' + smene.map(function (x) { return '  ' + x.naziv + ': ' + x.iznos + ' — ' + x.opis; }).join('\n') +
    (razlozi.length ? '\n\nNajčešći razlozi:\n' + razlozi.map(function (x) { return '  ' + x[0] + ': ' + x[1]; }).join('\n') : '') +
    (artikli.length ? '\n\nNajviše otpisano:\n' + artikli.map(function (x) { return '  ' + x[0] + ': ' + x[1]; }).join('\n') : '') +
    (upozorenja.length ? '\n\nPažnja:\n' + upozorenja.map(function (x) { return '  ' + x; }).join('\n') : '') +
    '\n\nDetalji: ' + ADRESA_SAJTA + '#otpis-pregled';
  const red2 = function (a, b) { return '<tr><td style="padding:4px 16px 4px 0;color:#6d625b">' + esc(a) + '</td><td style="padding:4px 0">' + esc(b) + '</td></tr>'; };
  const html = '<div style="font-family:Arial,sans-serif;font-size:14px;color:#211c19">' +
    '<p style="margin:0 0 4px;color:#b4401e;font-size:12px;letter-spacing:1px">IN SMOKE WE TRUST · DNEVNI OTPIS · ' + esc(datum) + '</p>' +
    '<h2 style="margin:0 0 4px">' + esc(broj_sr_(ukupno, 0)) + ' RSD</h2>' +
    '<p style="margin:0 0 14px;color:#6d625b">' + esc((s.count || 0) + ' unosa' + (delovi ? ' · ' + delovi : '')) + '</p>' +
    (upozorenja.length ? '<div style="background:#f3dfd5;border-left:4px solid #b4401e;padding:10px 12px;margin:0 0 14px">' + upozorenja.map(esc).join('<br>') + '</div>' : '') +
    '<h3 style="margin:14px 0 6px">Po smenama</h3><table style="border-collapse:collapse">' +
    smene.map(function (x) { return '<tr><td style="padding:4px 16px 4px 0">' + esc(x.naziv) + '</td><td style="padding:4px 16px 4px 0"><b>' + esc(x.iznos) + '</b></td><td style="padding:4px 0;color:' + (x.otvorena ? '#b0322a' : '#6d625b') + '">' + esc(x.opis) + '</td></tr>'; }).join('') + '</table>' +
    (razlozi.length ? '<h3 style="margin:14px 0 6px">Najčešći razlozi</h3><table style="border-collapse:collapse">' + razlozi.map(function (x) { return red2(x[0], x[1]); }).join('') + '</table>' : '') +
    (artikli.length ? '<h3 style="margin:14px 0 6px">Najviše otpisano</h3><table style="border-collapse:collapse">' + artikli.map(function (x) { return red2(x[0], x[1]); }).join('') + '</table>' : '') +
    '<p style="margin:18px 0 0"><a href="' + ADRESA_SAJTA + '#otpis-pregled" style="background:#b4401e;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none">Otvori pregled otpisa</a></p></div>';
  MailApp.sendEmail({ to: UPRAVA, subject: subjekt, body: tekst, htmlBody: html, name: 'In Smoke We Trust · Kitchen Control' });
}

function odgovor_(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}

function posaljiProbniMejl() {
  MailApp.sendEmail(OBAVESTENJE_NA, 'In Smoke We Trust · Kitchen Control — obaveštenja su uključena', 'Od sada za svaki nov ciklus sa smokera stiže mejl na ovu adresu.\n\nPlatforma: ' + ADRESA_SAJTA, { name: 'In Smoke We Trust · Kitchen Control' });
}


// ===================== MANAGEMENT CONTROL · izveštaji o radu =====================
const MC_PRIMAOCI = 'office@nutribox.rs, ilija.nikolic.sf.bg@gmail.com';
const MC_ADRESA = 'https://insmoke.rs/aplikacija/management.html';
const MC_SEKTORI = { pit: 'Pit / smoker', kuhinja: 'Kuhinja', pranje: 'Pranje', sala: 'Sala', sank: 'Šank', uprava: 'Uprava restorana' };

function mcEsc_(x) { return String(x).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
function mcDatum_(s) { return s ? String(s).split('-').reverse().join('.') + '.' : ''; }
function mcKratko_(s) { const p = String(s).split('-'); return p[2] + '.' + p[1] + '.'; }
function mcRsd_(v) { return v === null || v === undefined ? '—' : broj_sr_(Number(v), 0) + ' RSD'; }
function mcPct_(v) { return v === null || v === undefined ? '—' : broj_sr_(Number(v), 1) + ' %'; }
function mcOcena_(pct, cilj) {
  if (pct === null || pct === undefined || !cilj) return { boja: '#6d625b', tekst: '' };
  const r = Number(pct) - Number(cilj);
  if (r <= 0) return { boja: '#2f7a4b', tekst: 'u okviru cilja ' + broj_sr_(Number(cilj), 0) + ' %' };
  return { boja: r <= 2 ? '#a86a10' : '#b0322a', tekst: '+' + broj_sr_(r, 1) + ' pp iznad cilja ' + broj_sr_(Number(cilj), 0) + ' %' };
}
function mcRedovi_(s) {
  const o = mcOcena_(s.labor_pct, s.target);
  const r = [
    ['Promet bez PDV-a', mcRsd_(s.net), true],
    ['Trošak rada', mcRsd_(s.cost) + (Number(s.overtime_cost) > 0 ? ' (prekovremeni ' + mcRsd_(s.overtime_cost) + ')' : '')],
    ['Labor %', mcPct_(s.labor_pct) + (o.tekst ? ' · ' + o.tekst : ''), true, o.boja],
    ['Odrađeno sati', broj_sr_(Number(s.hours || 0), 1) + ' h (plan ' + broj_sr_(Number(s.planned_hours || 0), 1) + ' h)'],
    ['Promet po radnom satu', mcRsd_(s.sales_per_hour)]
  ];
  if (Number(s.owners_cost) > 0) r.splice(3, 0, ['Labor bez vlasnika', mcPct_(s.labor_pct_no_owners)]);
  return r;
}
function mcTabela_(redovi) {
  return '<table style="border-collapse:collapse">' + redovi.map(function (x) {
    return '<tr><td style="padding:4px 16px 4px 0;color:#6d625b">' + mcEsc_(x[0]) + '</td><td style="padding:4px 0' + (x[3] ? ';color:' + x[3] : '') + '">' + (x[2] ? '<b>' + mcEsc_(x[1]) + '</b>' : mcEsc_(x[1])) + '</td></tr>';
  }).join('') + '</table>';
}
function mcSektori_(s) {
  const net = Number(s.net || 0);
  return Object.keys(s.by_sector || {}).map(function (k) { return [k, s.by_sector[k]]; })
    .sort(function (a, b) { return Number(b[1].cost) - Number(a[1].cost); })
    .map(function (x) { return [MC_SEKTORI[x[0]] || x[0], broj_sr_(Number(x[1].hours || 0), 1) + ' h · ' + mcRsd_(x[1].cost) + (net > 0 ? ' · ' + broj_sr_(Number(x[1].cost) / net * 100, 1) + ' % prometa' : '')]; });
}
function mcUpozorenja_(s) {
  const u = [];
  const m = s.missing_sales || [], n = s.unconfirmed || [], ot = s.overtime || [];
  if (m.length) u.push('Fali promet za ' + m.length + (m.length === 1 ? ' dan: ' : ' dana: ') + m.slice(0, 10).map(mcKratko_).join(', '));
  if (n.length) u.push('Nije potvrđeno ko je radio (računa se po rasporedu): ' + n.slice(0, 10).map(mcKratko_).join(', '));
  ot.forEach(function (x) { u.push(x.name + ': ' + broj_sr_(Number(x.hours), 1) + ' h preko ugovorenih u nedelji od ' + mcKratko_(x.week)); });
  return u;
}
function mcPosalji_(subjekt, blokovi, upozorenja, naslov) {
  let tekst = naslov + '\n';
  let html = '<div style="font-family:Arial,sans-serif;font-size:14px;color:#211c19">' +
    '<p style="margin:0 0 4px;color:#b4401e;font-size:12px;letter-spacing:1px">' + mcEsc_(naslov.toUpperCase()) + '</p>';
  if (upozorenja.length) {
    html += '<div style="background:#f3dfd5;border-left:4px solid #b4401e;padding:10px 12px;margin:10px 0 4px">' + upozorenja.map(mcEsc_).join('<br>') + '</div>';
  }
  blokovi.forEach(function (b) {
    html += '<h3 style="margin:18px 0 6px">' + mcEsc_(b[0]) + '</h3>' + mcTabela_(b[1]);
    tekst += '\n' + b[0] + '\n' + b[1].map(function (x) { return '  ' + x[0] + ': ' + x[1]; }).join('\n') + '\n';
  });
  if (upozorenja.length) tekst += '\nPažnja:\n' + upozorenja.map(function (x) { return '  ' + x; }).join('\n') + '\n';
  tekst += '\nDetalji: ' + MC_ADRESA;
  html += '<p style="margin:18px 0 0"><a href="' + MC_ADRESA + '" style="background:#b4401e;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none">Otvori Management Control</a></p></div>';
  MailApp.sendEmail({ to: MC_PRIMAOCI, subject: subjekt, body: tekst, htmlBody: html, name: 'In Smoke We Trust · Management Control' });
}
function posaljiMcDnevni_(p) {
  const d = p.day || {}, m = p.mtd || {};
  const subjekt = 'Rad ' + mcDatum_(d.from) + ': labor ' + mcPct_(d.labor_pct) + ' · promet ' + mcRsd_(d.net) + ' · mesec ' + mcPct_(m.labor_pct);
  const blokovi = [['Juče, ' + mcDatum_(d.from), mcRedovi_(d)], ['Od početka meseca (' + mcKratko_(m.from) + '–' + mcKratko_(m.to) + ')', mcRedovi_(m)]];
  if (Number(m.needed_net) > 0) blokovi[1][1].push(['Promet potreban za cilj', mcRsd_(m.needed_net)]);
  mcPosalji_(subjekt, blokovi, mcUpozorenja_(m), 'In Smoke We Trust · rad · ' + mcDatum_(d.from));
}
function mcMn_(n, jedan, dva, pet) { const a = Math.abs(n) % 100, b = a % 10; return (b === 1 && a !== 11) ? jedan : (b >= 2 && b <= 4 && (a < 12 || a > 14)) ? dva : pet; }
function mcFoodCost_(fc) {
  // vraća [blokovi, upozorenja, deo naslova]
  if (!fc) return [[], [], ''];
  const blokovi = [], upoz = [];
  let naslov = '';
  if (fc.missing) {
    upoz.push(fc.open_count ? 'Popis od ' + mcDatum_(fc.open_count) + ' nije zaključen, food cost za prošlu nedelju nije izračunat.'
                            : 'Prošle nedelje nije rađen popis' + (fc.last ? ' (poslednji zaključen: ' + mcDatum_(fc.last) + ')' : '') + ', food cost nije izračunat.');
  } else if (fc.no_prev) {
    blokovi.push(['Food cost', [['Status', 'Popis od ' + mcDatum_(fc.to) + ' je početno stanje. Food cost stiže posle sledećeg popisa.']]]);
  } else if (fc.areas) {
    const k = fc.areas.kuhinja || {}, s = fc.areas.sank || {}, n = fc.areas.nepovezano || {};
    const ok = mcOcena_(k.pct, fc.food_target), os = mcOcena_(s.pct, fc.bev_target);
    blokovi.push(['Food cost (' + mcKratko_(fc.from) + '–' + mcKratko_(fc.to) + ', popis ' + mcKratko_(fc.from_count) + ' → ' + mcKratko_(fc.to) + ')', [
      ['Food cost % (kuhinja ÷ hrana)', mcPct_(k.pct) + (ok.tekst ? ' · ' + ok.tekst : ''), true, ok.boja],
      ['Beverage cost % (šank ÷ piće)', mcPct_(s.pct) + (os.tekst ? ' · ' + os.tekst : ''), true, os.boja],
      ['Ukupno roba ÷ promet', mcPct_(fc.total_pct)],
      ['Utrošeno robe', mcRsd_(fc.used) + ' (početno ' + mcRsd_(fc.open) + ' + nabavka ' + mcRsd_(fc.purchases) + ' − krajnje ' + mcRsd_(fc.close) + ')'],
      ['Otpis u periodu', mcRsd_(Number(k.waste || 0) + Number(s.waste || 0))]
    ]]);
    const th = fc.theory;
    if (th && !th.no_sales && th.kuhinja) {
      const tk = th.kuhinja, razlika = Number(tk.actual) - Number(tk.theory);
      const r = [
        ['Kuhinja po normativu', mcPct_(tk.theory_pct) + ' (' + mcRsd_(tk.theory) + ')'],
        ['Stvarno', mcPct_(k.pct) + ' (' + mcRsd_(tk.actual) + ')'],
        ['Razlika', (razlika >= 0 ? '+' : '') + mcRsd_(razlika) + ' robe koja nije prodata', true, razlika > Number(tk.theory) * 0.08 ? '#b0322a' : razlika > Number(tk.theory) * 0.03 ? '#a86a10' : '#2f7a4b']
      ];
      (th.over || []).slice(0, 5).forEach(function (x) { r.push([x.name, '+' + mcRsd_(x.diff) + ' (po normativu ' + mcRsd_(x.theory) + ', stvarno ' + mcRsd_(x.actual) + (Number(x.waste) > 0 ? ', otpis ' + mcRsd_(x.waste) : '') + ')']); });
      blokovi.push(['Stvarno ili po normativu', r]);
      if (Number(th.covered_days) < Number(th.days)) upoz.push('Prodaja po artiklima je uneta za ' + th.covered_days + ' od ' + th.days + ' dana, pa je trošak po normativu manji nego što bi trebalo.');
      if (Number(th.unmapped) > 0) upoz.push(th.unmapped + ' ' + mcMn_(Number(th.unmapped), 'artikal nije povezan', 'artikla nisu povezana', 'artikala nije povezano') + ' sa jelom.');
      if (th.no_recipe && th.no_recipe.length) upoz.push('Jela bez normativa: ' + th.no_recipe.slice(0, 6).join(', '));
    } else if (th && th.no_sales) {
      upoz.push('Nije uneta prodaja po artiklima za ovaj period, pa nema poređenja sa normativima.');
    }
    const top = (fc.top || []).filter(function (t) { return Number(t.used) > 0; }).slice(0, 5)
      .map(function (t) { return [t.name, broj_sr_(Number(t.qty), Number(t.qty) % 1 ? 1 : 0) + ' ' + t.unit + ' · ' + mcRsd_(t.used)]; });
    if (top.length) blokovi.push(['Najveći utrošak', top]);
    naslov = 'food cost ' + mcPct_(k.pct);
    if (fc.unmapped && Number(fc.unmapped.lines) > 0) upoz.push(fc.unmapped.lines + ' ' + mcMn_(Number(fc.unmapped.lines), 'stavka sa faktura nije povezana', 'stavke sa faktura nisu povezane', 'stavki sa faktura nije povezano') + ' sa namirnicom (' + mcRsd_(fc.unmapped.net) + ').');
    if (fc.no_price && fc.no_price.length) upoz.push('Bez nabavne cene: ' + fc.no_price.slice(0, 6).join(', '));
    if (Number(fc.carried) > 0) upoz.push(fc.carried + ' ' + mcMn_(Number(fc.carried), 'stavka nije popisana', 'stavke nisu popisane', 'stavki nije popisano') + ', količina je preuzeta iz prethodnog popisa.');
    if (fc.missing_sales && fc.missing_sales.length) upoz.push('Fali promet za ' + fc.missing_sales.map(mcKratko_).join(', ') + ' (food cost je zato previsok).');
  }
  const j = fc.price_jumps || [];
  if (j.length) blokovi.push(['Poskupljenja prošle nedelje', j.slice(0, 8).map(function (x) {
    return [x.name, broj_sr_(Number(x.old), 2) + ' → ' + broj_sr_(Number(x.new), 2) + ' RSD/' + x.unit + ' (+' + broj_sr_(Number(x.pct), 1) + ' %, ' + x.supplier + ')', false, Number(x.pct) >= 10 ? '#b0322a' : '#a86a10'];
  })]);
  if (Number(fc.week_invoices) > 0) blokovi.push(['Nabavka prošle nedelje', [['Fakture', fc.week_invoices + ' · roba ' + mcRsd_(fc.week_purchases) + ' bez PDV-a']]]);
  return [blokovi, upoz, naslov];
}
function posaljiMcNedeljni_(p) {
  const w = p.week, pr = p.prev || {};
  const f = mcFoodCost_(p.fc);
  let blokovi = [], upoz = [], delovi = [];
  if (w && Number(w.staff) > 0) {
    const promena = (w.labor_pct !== null && w.labor_pct !== undefined && pr.labor_pct !== null && pr.labor_pct !== undefined)
      ? (Number(w.labor_pct) - Number(pr.labor_pct) >= 0 ? '+' : '') + broj_sr_(Number(w.labor_pct) - Number(pr.labor_pct), 1) + ' pp u odnosu na nedelju ranije' : '';
    const red = mcRedovi_(w);
    if (promena) red.push(['Promena', promena]);
    if (Number(w.needed_net) > 0) red.push(['Promet potreban za cilj', mcRsd_(w.needed_net)]);
    blokovi.push(['Rad, prošla nedelja (' + mcKratko_(w.from) + '–' + mcKratko_(w.to) + ')', red]);
    const sek = mcSektori_(w);
    if (sek.length) blokovi.push(['Po sektorima', sek]);
    blokovi.push(['Nedelja pre toga (' + mcKratko_(pr.from) + '–' + mcKratko_(pr.to) + ')', [['Promet bez PDV-a', mcRsd_(pr.net)], ['Trošak rada', mcRsd_(pr.cost)], ['Labor %', mcPct_(pr.labor_pct)]]]);
    upoz = mcUpozorenja_(w);
    delovi.push('labor ' + mcPct_(w.labor_pct));
  }
  blokovi = blokovi.concat(f[0]); upoz = upoz.concat(f[1]);
  if (f[2]) delovi.push(f[2]);
  if (!blokovi.length && !upoz.length) return;
  const fc = p.fc || {};
  const od = w ? w.from : (fc.week_from || fc.from), dO = w ? w.to : (fc.week_to || fc.to);
  const promet = w ? w.net : fc.net;
  const subjekt = 'Nedelja ' + (od ? mcKratko_(od) + '–' + mcDatum_(dO) : '') + (delovi.length ? ': ' + delovi.join(' · ') : '') + (promet !== undefined && promet !== null ? ' · promet ' + mcRsd_(promet) : '');
  mcPosalji_(subjekt, blokovi, upoz, 'In Smoke We Trust · nedeljni izveštaj');
}
function probniMcIzvestaj() {
  posaljiMcDnevni_({ day: { from: '2026-10-23', to: '2026-10-23', net: 0, cost: 0, hours: 0, planned_hours: 0, target: 30 }, mtd: { from: '2026-10-01', to: '2026-10-23', net: 0, cost: 0, hours: 0, planned_hours: 0, target: 30 } });
}
