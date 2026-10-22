/**
 * In Smoke We Trust — Smoker Yield Log → Google Sheets
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
const ADRESA_SAJTA = 'https://vuksanvasic.github.io/insmoke-platforma/';

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
    name: 'Smoker Yield Log'
  });
}

function posaljiNoviNalog_(r) {
  const ime = r.full_name || 'Bez imena', email = r.email || '—';
  const vreme = Utilities.formatDate(r.created_at ? new Date(r.created_at) : new Date(), ZONA, 'dd.MM.yyyy. HH:mm');
  const link = ADRESA_SAJTA + '#tim';
  const esc = function (s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); };
  MailApp.sendEmail({
    to: OBAVESTENJE_NA,
    subject: 'Nov nalog čeka odobrenje: ' + ime,
    body: 'Neko je napravio nalog na platformi Smoker Yield Log i čeka tvoje odobrenje.\n\n' +
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
    name: 'Smoker Yield Log'
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
  MailApp.sendEmail({ to: OBAVESTENJE_NA, subject: subjekt, body: tekst, htmlBody: html, name: 'Smoker Yield Log' });
}

function odgovor_(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}

function posaljiProbniMejl() {
  MailApp.sendEmail(OBAVESTENJE_NA, 'Smoker Yield Log — obaveštenja su uključena', 'Od sada za svaki nov ciklus sa smokera stiže mejl na ovu adresu.\n\nPlatforma: ' + ADRESA_SAJTA, { name: 'Smoker Yield Log' });
}
