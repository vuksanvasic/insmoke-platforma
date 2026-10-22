-- =====================================================================
-- Izmena 06: OTPIS (waste) — kuhinja i šank, po smenama
--   · namirnice sa cenom po jedinici (administrator ih održava na sajtu)
--   · otpis po smeni (1, 2, 3), vrednost u RSD se računa sama
--   · dimljeno meso (pripremljeno/gotovo) vredi po STVARNOJ ceni iz yield loga
--   · šef smene i administrator zatvaraju smenu
--   · nova uloga: 'sef' (šef smene / glavni kuvar)
-- Može da se pokrene više puta bez štete.
-- =====================================================================

-- ---------- Uloga šef smene ----------
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('ceka','kuvar','sef','admin','odbijen'));

create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('kuvar','sef','admin'));
$$;

create or replace function public.is_sef()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('sef','admin'));
$$;

drop policy if exists "profili: svoj ili članovi" on public.profiles;
create policy "profili: svoj ili članovi" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_admin() or (public.is_member() and role in ('kuvar','sef','admin')));

-- ---------- Namirnice ----------
create table if not exists public.waste_items (
  id                uuid primary key default gen_random_uuid(),
  name              text not null unique,
  area              text not null check (area in ('kuhinja','sank')),
  grp               text not null default 'Ostalo',
  unit              text not null check (unit in ('kg','l','kom','porcija')),
  price             numeric check (price is null or price >= 0),
  smoked_product_id text references public.products(id),
  active            boolean not null default true,
  sort              int not null default 0
);

-- ---------- Zatvorene smene ----------
create table if not exists public.waste_shifts (
  waste_date     date not null,
  shift          smallint not null check (shift between 1 and 3),
  closed_by      uuid not null default auth.uid() references auth.users(id),
  closed_by_name text,
  closed_at      timestamptz not null default now(),
  no_waste       boolean not null default false,
  note           text,
  primary key (waste_date, shift)
);

create or replace function public.shift_closed(d date, s smallint)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.waste_shifts where waste_date = d and shift = s);
$$;

-- ---------- Otpis ----------
create table if not exists public.waste (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  created_by  uuid not null default auth.uid() references auth.users(id),
  waste_date  date not null,
  shift       smallint not null check (shift between 1 and 3),
  item_id     uuid not null references public.waste_items(id),
  qty         numeric not null check (qty > 0),
  stage       text not null check (stage in ('sirovo','pripremljeno','gotovo')),
  reason      text not null check (reason in ('visak','prekuvano','rok','greska','vraceno','ostecenje','osoblje','ostalo')),
  unit_cost   numeric,
  value_rsd   numeric generated always as (round(qty * unit_cost, 0)) stored,
  cook_name   text,
  notes       text
);
create index if not exists waste_date_idx on public.waste (waste_date desc, shift);

-- Cena po jedinici se upisuje sama u trenutku unosa (kasnija promena cene ne menja stare unose)
create or replace function public.waste_set_cost()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  it public.waste_items%rowtype;
  stvarna numeric;
begin
  if tg_op = 'UPDATE' and new.item_id = old.item_id and new.stage = old.stage then
    new.unit_cost := old.unit_cost;
    return new;
  end if;
  select * into it from public.waste_items where id = new.item_id;
  new.unit_cost := it.price;
  if it.smoked_product_id is not null and new.stage <> 'sirovo' then
    select sum(raw_kg * price_per_kg) / nullif(sum(coalesce(sellable_kg, cooked_kg)), 0)
      into stvarna
      from public.cooks
     where product_id = it.smoked_product_id
       and price_per_kg is not null
       and cook_date between new.waste_date - 60 and new.waste_date;
    if stvarna is not null then new.unit_cost := round(stvarna, 2); end if;
  end if;
  return new;
end $$;

drop trigger if exists waste_set_cost on public.waste;
create trigger waste_set_cost before insert or update on public.waste
  for each row execute function public.waste_set_cost();

-- ---------- Pravila pristupa ----------
alter table public.waste_items  enable row level security;
alter table public.waste_shifts enable row level security;
alter table public.waste        enable row level security;

drop policy if exists "namirnice: čitaju članovi" on public.waste_items;
create policy "namirnice: čitaju članovi" on public.waste_items
  for select to authenticated using (public.is_member());
drop policy if exists "namirnice: admin menja" on public.waste_items;
create policy "namirnice: admin menja" on public.waste_items
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "smene: čitaju članovi" on public.waste_shifts;
create policy "smene: čitaju članovi" on public.waste_shifts
  for select to authenticated using (public.is_member());
drop policy if exists "smene: šef zatvara" on public.waste_shifts;
create policy "smene: šef zatvara" on public.waste_shifts
  for all to authenticated using (public.is_sef()) with check (public.is_sef());

drop policy if exists "otpis: čitaju članovi" on public.waste;
create policy "otpis: čitaju članovi" on public.waste
  for select to authenticated using (public.is_member());
drop policy if exists "otpis: upis u otvorenu smenu" on public.waste;
create policy "otpis: upis u otvorenu smenu" on public.waste
  for insert to authenticated
  with check (created_by = auth.uid() and public.is_member()
              and (public.is_sef() or not public.shift_closed(waste_date, shift)));
drop policy if exists "otpis: šef menja" on public.waste;
create policy "otpis: šef menja" on public.waste
  for update to authenticated using (public.is_sef()) with check (public.is_sef());
drop policy if exists "otpis: brisanje" on public.waste;
create policy "otpis: brisanje" on public.waste
  for delete to authenticated
  using (public.is_sef() or (created_by = auth.uid() and public.is_member() and not public.shift_closed(waste_date, shift)));

do $$ begin alter publication supabase_realtime add table public.waste;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.waste_shifts;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.waste_items;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ---------- Početni spisak namirnica (iz menija; cene upisuje administrator) ----------
insert into public.waste_items (name, area, grp, unit, smoked_product_id, sort) values
  ('Brisket (juneće grudi)',          'kuhinja','Meso','kg','brisket',     10),
  ('Brisket burnt ends',              'kuhinja','Meso','kg','burnt-ends',  11),
  ('Svinjetina (pork butt)',          'kuhinja','Meso','kg','pork-butt',   12),
  ('Ćuretina (ćureće grudi)',         'kuhinja','Meso','kg','turkey',      13),
  ('Svinjska rebra',                  'kuhinja','Meso','kg','pork-ribs',   14),
  ('Juneći obrazi',                   'kuhinja','Meso','kg','beef-cheeks', 15),
  ('Kobasice (goveđe sa sirom)',      'kuhinja','Meso','kg','sausage',     16),
  ('Krompir (začinjeni / wedges)',    'kuhinja','Prilozi','kg',null,20),
  ('Batat pomfrit',                   'kuhinja','Prilozi','kg',null,21),
  ('Dip skin pomfrit',                'kuhinja','Prilozi','kg',null,22),
  ('Kolutići od luka',                'kuhinja','Prilozi','kg',null,23),
  ('Coleslaw salata',                 'kuhinja','Prilozi','kg',null,24),
  ('BBQ pasulj',                      'kuhinja','Prilozi','kg',null,25),
  ('Kiseli krastavci',                'kuhinja','Prilozi','kg',null,26),
  ('Marinirani crveni luk',           'kuhinja','Prilozi','kg',null,27),
  ('Marinirani halapenjo',            'kuhinja','Prilozi','kg',null,28),
  ('Džem od luka',                    'kuhinja','Prilozi','kg',null,29),
  ('Cheddar (topljeni)',              'kuhinja','Prilozi','kg',null,30),
  ('Domaći BBQ sos',                  'kuhinja','Sosovi','l',null,40),
  ('Specijalni burger sos',           'kuhinja','Sosovi','l',null,41),
  ('Kečap',                           'kuhinja','Sosovi','l',null,42),
  ('Senf',                            'kuhinja','Sosovi','l',null,43),
  ('Domaći hleb',                     'kuhinja','Hleb','kom',null,50),
  ('Somun',                           'kuhinja','Hleb','kom',null,51),
  ('Burger zemička',                  'kuhinja','Hleb','kom',null,52),
  ('Mak kolač',                       'kuhinja','Desert','kom',null,60),
  ('Sladoled od vanile',              'kuhinja','Desert','l',null,61),
  ('Kafa (zrno)',                     'sank','Kafa i čaj','kg',null,100),
  ('Mleko',                           'sank','Kafa i čaj','l',null,101),
  ('Čaj Milford',                     'sank','Kafa i čaj','kom',null,102),
  ('Rosa 0,75',                       'sank','Voda','kom',null,110),
  ('Rosa 0,33',                       'sank','Voda','kom',null,111),
  ('Rosa gazirana 0,75',              'sank','Voda','kom',null,112),
  ('Rosa gazirana 0,33',              'sank','Voda','kom',null,113),
  ('Roemerquelle lemongras 0,33',     'sank','Voda','kom',null,114),
  ('Coca-Cola 0,25',                  'sank','Sokovi','kom',null,120),
  ('Coca-Cola Zero 0,25',             'sank','Sokovi','kom',null,121),
  ('Coca-Cola Lime 0,25',             'sank','Sokovi','kom',null,122),
  ('Fanta 0,25',                      'sank','Sokovi','kom',null,123),
  ('Sprite 0,25',                     'sank','Sokovi','kom',null,124),
  ('Schweppes Bitter Lemon 0,25',     'sank','Sokovi','kom',null,125),
  ('Schweppes Tonic 0,25',            'sank','Sokovi','kom',null,126),
  ('Fuzetea breskva 0,33',            'sank','Sokovi','kom',null,127),
  ('Next narandža 0,20',              'sank','Sokovi','kom',null,128),
  ('Next jabuka 0,20',                'sank','Sokovi','kom',null,129),
  ('Next šumsko voće 0,20',           'sank','Sokovi','kom',null,130),
  ('Kombucha breskva 0,33',           'sank','Sokovi','kom',null,131),
  ('Kombucha malina 0,33',            'sank','Sokovi','kom',null,132),
  ('Ultra Energy 0,25',               'sank','Energetska pića','kom',null,140),
  ('Red Bull 0,25',                   'sank','Energetska pića','kom',null,141),
  ('Docker lager (točeno)',           'sank','Pivo','l',null,150),
  ('Gostujuće pivo (točeno)',         'sank','Pivo','l',null,151)
on conflict (name) do nothing;
