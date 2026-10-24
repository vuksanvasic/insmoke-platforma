-- =====================================================================
-- Izmena 10: MANAGEMENT CONTROL — labor (zaposleni, raspored, zatvaranje dana, obračun)
--   · nova uloga: 'menadzer' (F&B menadžer: raspored, promet, potvrda dana; NE vidi plate)
--   · plate (mc_pay) i mesečni obračun (mc_payroll) vidi i menja samo administrator
--   · raspored, promet i potvrdu dana unose: šef smene, menadžer, administrator
-- Može da se pokrene više puta bez štete.
-- =====================================================================

-- ---------- Uloga menadžer ----------
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('ceka','kuvar','sef','menadzer','admin','odbijen'));

-- menadžer je član Kitchen Control-a i ima prava šefa smene
create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('kuvar','sef','menadzer','admin'));
$$;

create or replace function public.is_sef()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('sef','menadzer','admin'));
$$;

-- pristup Management Control-u: šef smene, menadžer, administrator
create or replace function public.is_mc()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('sef','menadzer','admin'));
$$;

drop policy if exists "profili: svoj ili članovi" on public.profiles;
create policy "profili: svoj ili članovi" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_admin() or (public.is_member() and role in ('kuvar','sef','menadzer','admin')));

-- ---------- Podešavanja ----------
create table if not exists public.mc_settings (
  id         int primary key default 1 check (id = 1),
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- ---------- Zaposleni (bez plata) ----------
create table if not exists public.mc_staff (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  position     text,
  sector       text not null default 'kuhinja' check (sector in ('pit','kuhinja','pranje','sala','sank','uprava')),
  type         text not null default 'ugovor' check (type in ('ugovor','zadruga','honorar','vlasnik','kes')),
  pay_mode     text not null default 'fiksno' check (pay_mode in ('fiksno','sat','dnevnica')),
  weekly_hours numeric not null default 40 check (weekly_hours >= 0 and weekly_hours <= 84),
  date_from    date,
  date_to      date,
  created_at   timestamptz not null default now(),
  constraint mc_staff_dates check (date_to is null or date_from is null or date_to >= date_from)
);

-- ---------- Plate (samo administrator) ----------
create table if not exists public.mc_pay (
  id         uuid primary key default gen_random_uuid(),
  staff_id   uuid not null references public.mc_staff(id) on delete cascade,
  valid_from date not null,
  gross2     numeric check (gross2 is null or gross2 >= 0),
  rate       numeric check (rate is null or rate >= 0),
  meal       numeric check (meal is null or meal >= 0),
  transport  numeric check (transport is null or transport >= 0),
  regres     numeric check (regres is null or regres >= 0),
  bonus      numeric check (bonus is null or bonus >= 0),
  updated_at timestamptz not null default now(),
  unique (staff_id, valid_from)
);

-- ---------- Raspored smena ----------
create table if not exists public.mc_shifts (
  id         uuid primary key default gen_random_uuid(),
  staff_id   uuid not null references public.mc_staff(id) on delete cascade,
  shift_date date not null,
  start_time text not null check (start_time ~ '^[0-2][0-9]:[0-5][0-9]$'),
  end_time   text not null check (end_time ~ '^[0-2][0-9]:[0-5][0-9]$'),
  note       text,
  created_by uuid default auth.uid() references auth.users(id),
  created_at timestamptz not null default now()
);
create index if not exists mc_shifts_date_idx on public.mc_shifts (shift_date);

-- ---------- Potvrda dana (ko je radio) ----------
create table if not exists public.mc_days (
  day        date primary key,
  holiday    boolean not null default false,
  confirmed  boolean not null default false,
  rows       jsonb not null default '[]'::jsonb,
  updated_by uuid default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now()
);

-- ---------- Dnevni promet ----------
create table if not exists public.mc_sales (
  day        date primary key,
  closed     boolean not null default false,
  channels   jsonb not null default '{}'::jsonb,
  receipts   numeric check (receipts is null or receipts >= 0),
  guests     numeric check (guests is null or guests >= 0),
  note       text,
  updated_by uuid default auth.uid() references auth.users(id),
  updated_at timestamptz not null default now()
);

-- ---------- Mesečni obračun (samo administrator) ----------
create table if not exists public.mc_payroll (
  month      text primary key check (month ~ '^[0-9]{4}-[0-9]{2}$'),
  amounts    jsonb not null default '{}'::jsonb,
  locked     boolean not null default false,
  updated_at timestamptz not null default now()
);

-- ---------- Zaštita podataka (RLS) ----------
alter table public.mc_settings enable row level security;
alter table public.mc_staff    enable row level security;
alter table public.mc_pay      enable row level security;
alter table public.mc_shifts   enable row level security;
alter table public.mc_days     enable row level security;
alter table public.mc_sales    enable row level security;
alter table public.mc_payroll  enable row level security;

drop policy if exists "mc podešavanja: čita tim" on public.mc_settings;
create policy "mc podešavanja: čita tim" on public.mc_settings for select to authenticated using (public.is_mc());
drop policy if exists "mc podešavanja: admin menja" on public.mc_settings;
create policy "mc podešavanja: admin menja" on public.mc_settings for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "mc zaposleni: čita tim" on public.mc_staff;
create policy "mc zaposleni: čita tim" on public.mc_staff for select to authenticated using (public.is_mc());
drop policy if exists "mc zaposleni: admin menja" on public.mc_staff;
create policy "mc zaposleni: admin menja" on public.mc_staff for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "mc plate: samo admin" on public.mc_pay;
create policy "mc plate: samo admin" on public.mc_pay for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "mc smene: tim" on public.mc_shifts;
create policy "mc smene: tim" on public.mc_shifts for all to authenticated using (public.is_mc()) with check (public.is_mc());

drop policy if exists "mc dani: tim" on public.mc_days;
create policy "mc dani: tim" on public.mc_days for all to authenticated using (public.is_mc()) with check (public.is_mc());

drop policy if exists "mc promet: tim" on public.mc_sales;
create policy "mc promet: tim" on public.mc_sales for all to authenticated using (public.is_mc()) with check (public.is_mc());

drop policy if exists "mc obračun: samo admin" on public.mc_payroll;
create policy "mc obračun: samo admin" on public.mc_payroll for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------- Uživo osvežavanje ----------
do $$ begin alter publication supabase_realtime add table public.mc_settings; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.mc_staff;    exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.mc_pay;      exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.mc_shifts;   exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.mc_days;     exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.mc_sales;    exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.mc_payroll;  exception when duplicate_object then null; when undefined_object then null; end $$;
