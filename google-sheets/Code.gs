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

function doPost(e) {
  const token = (e && e.parameter && e.parameter.token) || '';
  if (token !== TAJNI_KLJUC) return odgovor_({ ok: false, greska: 'nedozvoljeno' });

  let poruka;
  try { poruka = JSON.parse(e.postData.contents); }
  catch (err) { return odgovor_({ ok: false, greska: 'neispravan JSON' }); }

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

function odgovor_(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
