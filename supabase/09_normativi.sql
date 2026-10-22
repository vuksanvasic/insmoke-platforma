-- =====================================================================
-- Izmena 09: NORMATIVI i zarada po proizvodu
--   · jela sa prodajnom cenom (sa PDV-om) i stopom PDV-a
--   · normativ = namirnice i količina po porciji (namirnice su iste kao u otpisu)
--   · cilj food cost-a NIJE postavljen — upisuje ga administrator
--   · vide i menjaju: šef smene i administrator; cene jela menja samo administrator
-- Može da se pokrene više puta bez štete.
-- =====================================================================

create table if not exists public.dishes (
  id        uuid primary key default gen_random_uuid(),
  name      text not null unique,
  category  text not null default 'Ostalo',
  price     numeric check (price is null or price >= 0),   -- prodajna cena SA PDV-om
  vat       numeric not null default 20 check (vat >= 0 and vat < 100),
  active    boolean not null default true,
  sort      int not null default 0,
  note      text
);

create table if not exists public.dish_lines (
  id       uuid primary key default gen_random_uuid(),
  dish_id  uuid not null references public.dishes(id) on delete cascade,
  item_id  uuid not null references public.waste_items(id),
  qty      numeric not null check (qty > 0),               -- u jedinici namirnice (kg, l, kom, porcija)
  note     text,
  sort     int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists dish_lines_dish_idx on public.dish_lines (dish_id);

create table if not exists public.app_settings (
  key   text primary key,
  value jsonb
);

-- ---------- Pravila ----------
alter table public.dishes       enable row level security;
alter table public.dish_lines   enable row level security;
alter table public.app_settings enable row level security;

drop policy if exists "jela: čita šef" on public.dishes;
create policy "jela: čita šef" on public.dishes for select to authenticated using (public.is_sef());
drop policy if exists "jela: admin menja" on public.dishes;
create policy "jela: admin menja" on public.dishes for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "normativi: čita šef" on public.dish_lines;
create policy "normativi: čita šef" on public.dish_lines for select to authenticated using (public.is_sef());
drop policy if exists "normativi: šef menja" on public.dish_lines;
create policy "normativi: šef menja" on public.dish_lines for all to authenticated using (public.is_sef()) with check (public.is_sef());

drop policy if exists "podešavanja: čita šef" on public.app_settings;
create policy "podešavanja: čita šef" on public.app_settings for select to authenticated using (public.is_sef());
drop policy if exists "podešavanja: admin menja" on public.app_settings;
create policy "podešavanja: admin menja" on public.app_settings for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Šef sme da doda novu namirnicu (bez cene) dok piše normativ; cenu upisuje administrator
drop policy if exists "namirnice: šef dodaje bez cene" on public.waste_items;
create policy "namirnice: šef dodaje bez cene" on public.waste_items
  for insert to authenticated with check (public.is_sef() and price is null);

do $$ begin alter publication supabase_realtime add table public.dishes;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.dish_lines;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.app_settings;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ---------- Jela sa menija (cene sa PDV-om, iz menija) ----------
insert into public.dishes (name, category, price, sort) values
  ('Brisket obrok',                       'Glavna jela', 1830, 10),
  ('Prase obrok',                         'Glavna jela', 1750, 11),
  ('Ćuretina obrok',                      'Glavna jela', 1750, 12),
  ('Premium obrok',                       'Glavna jela', 1950, 13),
  ('Brisket burnt ends obrok',            'Glavna jela', 1850, 14),
  ('Brisket burger',                      'Burgeri',     1300, 20),
  ('Prase burger',                        'Burgeri',     1200, 21),
  ('Ćuretina burger',                     'Burgeri',     1200, 22),
  ('Monster burger',                      'Burgeri',     1600, 23),
  ('Sendvič sa svinjetinom',              'Sendviči',     830, 30),
  ('Sendvič sa junetinom',                'Sendviči',     900, 31),
  ('Sendvič sa ćuretinom',                'Sendviči',     830, 32),
  ('Začinjeni krompir',                   'Prilozi',      450, 40),
  ('Začinjeni krompir + cheddar',         'Prilozi',      550, 41),
  ('Batat pomfrit',                       'Prilozi',      490, 42),
  ('Batat pomfrit + cheddar',             'Prilozi',      590, 43),
  ('Kolutići od luka',                    'Prilozi',      430, 44),
  ('Coleslaw salata',                     'Prilozi',      280, 45),
  ('BBQ pasulj',                          'Prilozi',      320, 46),
  ('Specijalni burger sos',               'Prilozi',      150, 47),
  ('Domaći BBQ sos',                      'Prilozi',      170, 48),
  ('Marinirani halapenjo',                'Prilozi',      120, 49),
  ('Marinirani crveni luk',               'Prilozi',      110, 50),
  ('Džem od luka',                        'Prilozi',      180, 51),
  ('Domaći hleb',                         'Prilozi',      100, 52),
  ('Topljeni cheddar',                    'Prilozi',      150, 53),
  ('Brisket 1 kg',                        'Meso na kg',  5500, 60),
  ('Svinjetina 1 kg',                     'Meso na kg',  5100, 61),
  ('Ćuretina 1 kg',                       'Meso na kg',  5100, 62),
  ('Brisket burnt ends 1 kg',             'Meso na kg',  5700, 63),
  ('Mak kolač sa sladoledom',             'Desert',       510, 70),
  ('Juneći obrazi (100 g)',               'Specijali',    700, 80),
  ('Smokovane kobasice',                  'Specijali',   1670, 81),
  ('Svinjska rebra',                      'Specijali',   1730, 82),
  ('Holy Trinity plate za dvoje',         'Specijali',   3770, 83)
on conflict (name) do nothing;

-- ---------- Početni normativi: samo gramaže koje stoje u meniju ----------
-- (ostale sastojke — prilozi, sosevi, hleb — upisuje glavni kuvar)
insert into public.dish_lines (dish_id, item_id, qty, note, sort)
select d.id, i.id, v.qty, 'gramaža iz menija', v.sort
from (values
  ('Brisket obrok',               'Brisket (juneće grudi)',      0.220, 1),
  ('Prase obrok',                 'Svinjetina (pork butt)',      0.220, 1),
  ('Ćuretina obrok',              'Ćuretina (ćureće grudi)',     0.220, 1),
  ('Brisket burnt ends obrok',    'Brisket burnt ends',          0.220, 1),
  ('Premium obrok',               'Brisket (juneće grudi)',      0.100, 1),
  ('Premium obrok',               'Svinjetina (pork butt)',      0.100, 2),
  ('Premium obrok',               'Ćuretina (ćureće grudi)',     0.100, 3),
  ('Brisket burger',              'Brisket (juneće grudi)',      0.140, 1),
  ('Prase burger',                'Svinjetina (pork butt)',      0.140, 1),
  ('Ćuretina burger',             'Ćuretina (ćureće grudi)',     0.140, 1),
  ('Monster burger',              'Svinjetina (pork butt)',      0.100, 1),
  ('Monster burger',              'Brisket (juneće grudi)',      0.100, 2),
  ('Sendvič sa svinjetinom',      'Svinjetina (pork butt)',      0.100, 1),
  ('Sendvič sa junetinom',        'Brisket (juneće grudi)',      0.100, 1),
  ('Sendvič sa ćuretinom',        'Ćuretina (ćureće grudi)',     0.100, 1),
  ('Začinjeni krompir',           'Krompir (začinjeni / wedges)',0.250, 1),
  ('Batat pomfrit',               'Batat pomfrit',               0.200, 1),
  ('Kolutići od luka',            'Kolutići od luka',            0.200, 1),
  ('Coleslaw salata',             'Coleslaw salata',             0.150, 1),
  ('BBQ pasulj',                  'BBQ pasulj',                  0.180, 1),
  ('Topljeni cheddar',            'Cheddar (topljeni)',          0.070, 1),
  ('Domaći hleb',                 'Domaći hleb',                 1,     1),
  ('Brisket 1 kg',                'Brisket (juneće grudi)',      1,     1),
  ('Svinjetina 1 kg',             'Svinjetina (pork butt)',      1,     1),
  ('Ćuretina 1 kg',               'Ćuretina (ćureće grudi)',     1,     1),
  ('Brisket burnt ends 1 kg',     'Brisket burnt ends',          1,     1),
  ('Juneći obrazi (100 g)',       'Juneći obrazi',               0.100, 1),
  ('Smokovane kobasice',          'Kobasice (goveđe sa sirom)',  0.250, 1),
  ('Svinjska rebra',              'Svinjska rebra',              0.350, 1)
) as v(dish, item, qty, sort)
join public.dishes d on d.name = v.dish
join public.waste_items i on i.name = v.item
where not exists (select 1 from public.dish_lines x where x.dish_id = d.id);
