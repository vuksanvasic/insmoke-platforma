-- =====================================================================
-- In Smoke We Trust — platforma: Smoker Yield Log
-- Pokrenuti JEDNOM u Supabase → SQL Editor → New query → Run
-- =====================================================================

-- ---------- Korisnici i uloge ----------
-- uloga: 'kuvar' (upisuje cikluse) ili 'admin' (menja ciljeve, briše sve, menja uloge)
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null default '',
  role       text not null default 'kuvar' check (role in ('kuvar','admin')),
  created_at timestamptz not null default now()
);

-- Svaki novi nalog automatski dobija profil sa ulogom 'kuvar'
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- ---------- Meso koje se smokuje ----------
create table if not exists public.products (
  id           text primary key,
  name         text not null,
  sort         int  not null default 0,
  target_yield numeric check (target_yield is null or (target_yield > 0 and target_yield <= 100)),
  active       boolean not null default true
);

insert into public.products (id, name, sort) values
  ('brisket',      'Brisket (juneće grudi)',      1),
  ('burnt-ends',   'Brisket burnt ends',          2),
  ('pork-butt',    'Svinjetina (pork butt)',      3),
  ('turkey',       'Ćuretina (ćureće grudi)',     4),
  ('pork-ribs',    'Svinjska rebra',              5),
  ('beef-cheeks',  'Juneći obrazi',               6),
  ('sausage',      'Kobasice (goveđe sa sirom)',  7)
on conflict (id) do nothing;

-- ---------- Ciklusi sa smokera ----------
create table if not exists public.cooks (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  created_by    uuid not null default auth.uid() references auth.users(id),
  cook_date     date not null,
  product_id    text not null references public.products(id),
  cook_name     text,
  batch         text,
  raw_kg        numeric not null check (raw_kg > 0),
  trimmed_kg    numeric check (trimmed_kg is null or (trimmed_kg > 0 and trimmed_kg <= raw_kg)),
  cooked_kg     numeric not null check (cooked_kg > 0 and cooked_kg <= raw_kg),
  sellable_kg   numeric check (sellable_kg is null or (sellable_kg > 0 and sellable_kg <= cooked_kg)),
  price_per_kg  numeric check (price_per_kg is null or price_per_kg > 0),
  smoker_temp_c numeric,
  hours         numeric,
  wood          text,
  notes         text,
  yield_pct     numeric generated always as (round(coalesce(sellable_kg, cooked_kg) / raw_kg * 100, 1)) stored,
  constraint trimmed_ge_cooked check (trimmed_kg is null or cooked_kg <= trimmed_kg)
);
create index if not exists cooks_date_idx on public.cooks (cook_date desc);

-- ---------- Zaštita podataka (RLS) ----------
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.cooks    enable row level security;

drop policy if exists "profili: čitaju prijavljeni" on public.profiles;
create policy "profili: čitaju prijavljeni" on public.profiles
  for select to authenticated using (true);
drop policy if exists "profili: admin menja" on public.profiles;
create policy "profili: admin menja" on public.profiles
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "meso: čitaju prijavljeni" on public.products;
create policy "meso: čitaju prijavljeni" on public.products
  for select to authenticated using (true);
drop policy if exists "meso: admin menja" on public.products;
create policy "meso: admin menja" on public.products
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "ciklusi: čitaju prijavljeni" on public.cooks;
create policy "ciklusi: čitaju prijavljeni" on public.cooks
  for select to authenticated using (true);
drop policy if exists "ciklusi: upis u svoje ime" on public.cooks;
create policy "ciklusi: upis u svoje ime" on public.cooks
  for insert to authenticated with check (created_by = auth.uid());
drop policy if exists "ciklusi: admin menja" on public.cooks;
create policy "ciklusi: admin menja" on public.cooks
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "ciklusi: brisanje svojih ili admin" on public.cooks;
create policy "ciklusi: brisanje svojih ili admin" on public.cooks
  for delete to authenticated using (created_by = auth.uid() or public.is_admin());

-- ---------- Uživo osvežavanje ----------
do $$ begin
  alter publication supabase_realtime add table public.cooks;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.products;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- =====================================================================
-- Posle pravljenja naloga: postavi sebe za admina (zameni email):
--   update public.profiles set role = 'admin', full_name = 'Vuksan'
--   where id = (select id from auth.users where email = 'office@nutribox.rs');
-- =====================================================================
