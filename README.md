# Kitchen Control — In Smoke We Trust

Interna platforma kuhinje: yield sa smokera i otpis po smenama (kuhinja i šank). Statičan sajt (GitHub Pages) + Supabase baza sa prijavama.

## Sadržaj

| Fajl | Šta je |
|---|---|
| `index.html` | ceo sajt |
| `config.js` | adresa i javni ključ Supabase projekta |
| `supabase/schema.sql` | tabele, meso sa menija, uloge i zaštita podataka |
| `supabase/02_registracija.sql` | registracija na sajtu uz odobrenje administratora (pokrenuti posle schema.sql) |

## Uloge

- **čeka odobrenje** — nov nalog; ne vidi ništa dok ga administrator ne odobri
- **kuhinja** — upisuje cikluse, vidi sve, briše samo svoje unose
- **administrator** — sve to, plus postavlja ciljeve yielda, briše bilo koji unos i odobrava naloge u tabu **Tim**
- **odbijen** — nema pristup

Naloge ljudi prave sami na sajtu (**Napravi nalog**). Administrator ih odobrava u tabu **Tim**.
Administrator ne može sam sebi da promeni ulogu, da se ne bi slučajno zaključao.

---

## Postavljanje — korak po korak

### 1. Supabase projekat (5 min)

1. Na [supabase.com](https://supabase.com) → **New project**.
   - Ime: `insmoke-platforma`
   - Region: **Central EU (Frankfurt)** — najbliže Beogradu
   - Lozinku baze sačuvaj negde, ne treba za svakodnevni rad.
2. Levo **SQL Editor** → **New query** → nalepi ceo sadržaj `supabase/schema.sql` → **Run**, zatim isto za `supabase/02_registracija.sql`.
3. Levo **Authentication** → **Sign In / Providers**: **Allow new users to sign up** uključeno, **Confirm email** isključeno.
   (Svako može da napravi nalog, ali ne vidi ništa dok ga administrator ne odobri.)
4. **Authentication** → **URL Configuration** → **Site URL** = adresa sajta.
5. Levo **Project Settings** → **API Keys** → kopiraj:
   - **Project URL**
   - **anon public** ključ

   Ta dva podatka upisuju se u `config.js`. **Nikad ne kopirati `service_role` ključ.**

### 2. Nalozi za tim

1. Svako otvori sajt → **Napravi nalog** → ime, email, lozinka.
2. Prvi administrator se postavlja jednom, u **SQL Editor**:

```sql
update public.profiles set role = 'admin'
where id = (select id from auth.users where email = 'office@nutribox.rs');
```

3. Posle toga administrator sve odobrava na sajtu, u tabu **Tim**.

Ako neko zaboravi lozinku: Supabase → **Authentication → Users** → izaberi osobu → postavi novu lozinku.

### 3. Sajt na besplatnoj adresi (GitHub Pages)

1. Na GitHub-u napravi nov **public** repozitorijum `insmoke-platforma` (prazan).
2. Ubaci ova tri fajla/foldera u njega.
3. **Settings → Pages → Source: Deploy from a branch → main / (root)** → Save.
4. Posle 1–2 minuta sajt je na `https://<tvoj-github-nalog>.github.io/insmoke-platforma/`.

Repozitorijum može biti javan: u kodu je samo javni ključ, a podatke čuvaju pravila u bazi — bez prijave se ne vidi ništa.

### 4. Adresa na domenu restorana

Sajt radi na **https://insmoke.rs/aplikacija/** (hosting Telekom / Plesk, webhosting08.oblaci.rs).

- Plesk → insmoke.rs → **Git**: repozitorijum `kitchen-control.git` povlači ovaj GitHub repo u `/httpdocs/aplikacija` (stari `/httpdocs/kitchen` samo preusmerava na novu adresu).
  Posle izmene na GitHub-u: Plesk → Git → **Pull now** (ili Deploy now).
- Stara github.io adresa automatski prebacuje na novu (skripta na vrhu `index.html`).
- Supabase → Authentication → URL Configuration: Site URL = `https://insmoke.rs/aplikacija/`.
- Poddomeni `kitchen.insmoke.rs` i `app.insmoke.rs` postoje u Plesku, ali rade tek kad Telekom doda DNS zapis (`app A 212.200.255.43`). Do tada se koristi `/aplikacija`.

---

## Proračun

- **Yield** = kg za prodaju ÷ sirovih kg (ako nema „za prodaju“, koristi se težina iz smokera)
- **Gubitak na trimovanju** = (sirovo − posle trima) ÷ sirovo
- **Gubitak u smokeru** = (posle trima − iz smokera) ÷ posle trima
- **Gubitak na sečenju** = (iz smokera − za prodaju) ÷ iz smokera
- **Stvarna cena po kg** = sirovo × nabavna cena ÷ kg za prodaju
- Prosek po mesu je ponderisan kilogramima (veliki komadi teže više od malih).
- Boja kartice: zeleno do 1 pp ispod cilja, žuto do 4 pp ispod, crveno preko toga.

---

## Management Control (uprava · rad i food cost)

Stranica `management.html` (https://insmoke.rs/aplikacija/management.html), ista prijava i baza kao Kitchen Control.

| Tab | Ko | Šta |
|---|---|---|
| Pregled | svi sa pristupom | labor %, promet, sati, sektori, upozorenja (troškove vidi samo administrator) |
| Zatvaranje dana | šef smene, menadžer, administrator | promet po kanalu iz POS-a + potvrda ko je radio |
| Raspored | šef smene, menadžer, administrator | smene po nedeljama |
| Zaposleni | administrator menja, ostali vide bez plata | pozicija, sektor, angažovanje, plata, prava cena sata |
| Food cost | šef smene, menadžer, administrator | stvarni food cost (kuhinja ÷ hrana) i beverage cost (šank ÷ piće) između dva popisa, utrošak po namirnici, poskupljenja |
| Popis | šef smene, menadžer, administrator | nedeljni/mesečni popis na telefonu; dimljeno meso: sirovo, u smokeru, gotovo; zaključava se (ponovo otvara samo administrator) |
| Fakture | šef smene, menadžer, administrator | e-faktura sa SEF-a (XML) ili ručni unos; povezivanje stavki sa namirnicama (pamti se po dobavljaču); cena namirnice = poslednja faktura |
| Normativi | šef smene, menadžer, administrator | **Jela**: sastojci po porciji, trošak, food cost i marža (cenu jela menja administrator). **Šarže**: osnovne pripreme (džem od luka, sosevi, coleslaw, rub…) sa sastojcima za celu šaržu, izlazom, kalom i postupkom; cena šarže se računa sama. **Namirnice**: cene i gde se koriste |
| Prodaja artikala | šef smene, menadžer, administrator | prodaja po artiklima iz bMaster-a (Excel/CSV, kolone se biraju i pamte) ili ručno po jelu; artikal se povezuje sa jelom iz normativa ili direktno sa namirnicom (piće) |
| Obračun, Podešavanja | administrator | stvarne plate po mesecu, ciljevi (labor, food, beverage), PDV, uvećanja, kanali |

Uloge: `menadzer` (F&B menadžer) i `sef` unose, ali ne vide plate — to čuva baza (RLS), ne samo izgled stranice. `kuvar` nema pristup.

Baza: `supabase/10_management.sql` (tabele `mc_*`, uloga menadžer), `supabase/11_mc_izvestaji.sql` (proračun i mejlovi), `supabase/12_food_cost.sql` (fakture `fc_invoices`/`fc_invoice_lines`, veze `fc_map`, popis `fc_counts`/`fc_count_lines`, `fc_summary`, food cost u nedeljnom mejlu).

Food cost: utrošeno = početno stanje (prethodni popis) + nabavka (stavke faktura sa datumom isporuke posle prethodnog popisa, zaključno sa danom ovog popisa) − krajnje stanje. Nepopisana stavka preuzima količinu iz prethodnog popisa (meso u smokeru ne). Popis vredi po nabavnoj ceni; gotovo dimljeno meso po stvarnoj ceni iz yield loga (60 dana). Cilj food cost-a je isti kao u Normativima (`app_settings.fc_target`).

Teorijski food cost (`supabase/13_teorijski_food_cost.sql`, `fc_theory`): prodato po artiklima × normativ (`dish_lines`). Normativ za dimljeno meso je gotovo meso i vredi po stvarnoj ceni gotovog mesa iz yield loga; ako u poslednjih 60 dana nema ciklusa sa cenom, po nabavnoj ÷ ciljni yield (`products.target_yield`). Prodaja se uzima samo ako je ceo uvoz unutar perioda između dva popisa. Razlika stvarno − teorijski po namirnici je u Food cost tabu i u nedeljnom mejlu.

Mejlovi (Apps Script, `MC_PRIMAOCI` u `google-sheets/Code.gs`): dnevni u 9h za juče (kad postoji bar jedan zaposleni), nedeljni ponedeljkom u 9h (rad + food cost iz popisa iz noći sa nedelje na ponedeljak + poskupljenja). Proba iz SQL Editora: `select public.mc_reports_send('dnevni');`

Normativi (`supabase/14_sarze.sql`): namirnica može biti šarža (`waste_items.is_prep`, `batch_out`, `method`, sastojci u `prep_lines`). Cena šarže = Σ (količina × cena sastojka) ÷ izlaz; računa je baza (`prep_unit_cost`) i preračunava kad se promeni cena sastojka, lančano (šarža u šarži). Faktura ne prepisuje cenu šarže. Upis ide preko `prep_save`, `prep_new`, `prep_unset` i `dish_lines_save` (provera kruga, sve odjednom). Teorijski food cost razlaže šarže na sirovine. Tab „Normativi“ u Kitchen Control-u sada vodi ovde.
