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

### 4. Kad se kupi domen

1. U repozitorijum dodaj fajl `CNAME` sa jednim redom, npr. `yield.insmoke.rs`.
2. Kod registra domena dodaj DNS zapis:
   - poddomen (`yield.insmoke.rs`): **CNAME** → `<tvoj-github-nalog>.github.io`
   - ceo domen (`insmoke.rs`): četiri **A** zapisa → `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`
3. **Settings → Pages → Custom domain** → upiši domen → uključi **Enforce HTTPS**.

Stara github.io adresa automatski preusmerava na novu.

---

## Proračun

- **Yield** = kg za prodaju ÷ sirovih kg (ako nema „za prodaju“, koristi se težina iz smokera)
- **Gubitak na trimovanju** = (sirovo − posle trima) ÷ sirovo
- **Gubitak u smokeru** = (posle trima − iz smokera) ÷ posle trima
- **Gubitak na sečenju** = (iz smokera − za prodaju) ÷ iz smokera
- **Stvarna cena po kg** = sirovo × nabavna cena ÷ kg za prodaju
- Prosek po mesu je ponderisan kilogramima (veliki komadi teže više od malih).
- Boja kartice: zeleno do 1 pp ispod cilja, žuto do 4 pp ispod, crveno preko toga.
