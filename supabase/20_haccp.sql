-- SQL izmena 20 (25.11.2026): HACCP — prijem mesa, lotovi, sledljivost, ciklus u dva koraka
-- Bezbedno za ponovno pokretanje. Ne briše postojeće podatke.

-- ---------- Oznake mesa za kod lota ----------
alter table public.products add column if not exists lot_prefix text;
update public.products set lot_prefix = v.p from (values
  ('brisket','BR'),('pulled-beef','DJ'),('pork-butt','SV'),('turkey','CU'),('pork-ribs','RB'),
  ('beef-cheeks','JO'),('sausage','KG'),('pork-sausage','KS'),('bacon','SL'),('tongue','JZ'),('burnt-ends','BE')
) as v(id,p) where products.id = v.id and products.lot_prefix is null;

-- ---------- Dobavljači ----------
create table if not exists public.suppliers (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  active     boolean not null default true,
  sort       int not null default 100,
  created_at timestamptz not null default now()
);
insert into public.suppliers (name, sort) values
  ('Marlen mesara', 1), ('Jovo Krivokuća PR „Joja“', 2), ('Metro Cash & Carry', 3)
on conflict (name) do nothing;

-- ---------- Prijem (otpremnica) ----------
create table if not exists public.receipts (
  id          uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.suppliers(id),
  doc_no      text not null check (length(trim(doc_no)) > 0),
  received_at timestamptz not null default now(),
  received_by text,
  photos      text[] not null default '{}',
  note        text,
  created_by  uuid not null default auth.uid() references auth.users(id),
  created_at  timestamptz not null default now()
);
create index if not exists receipts_at_idx on public.receipts (received_at desc);

-- ---------- Lot (jedna stavka otpremnice) ----------
create table if not exists public.lots (
  id           uuid primary key default gen_random_uuid(),
  receipt_id   uuid not null references public.receipts(id) on delete cascade,
  product_id   text not null references public.products(id),
  code         text not null default '',
  code_year    int  not null default 0,
  kg           numeric not null check (kg > 0 and kg <= 500),
  supplier_lot text,
  expiry       date,
  temp_c       numeric check (temp_c is null or (temp_c between -40 and 40)),
  photos       text[] not null default '{}',
  closed_at    timestamptz,
  close_note   text,
  created_by   uuid not null default auth.uid() references auth.users(id),
  created_at   timestamptz not null default now()
);
create unique index if not exists lots_code_uq on public.lots (code, code_year);

-- kod lota: OZNAKA-DDMM-RB (npr. BR-2511-01), redni broj po mesu i danu prijema
create or replace function public.lots_set_code()
returns trigger language plpgsql security definer set search_path = public as $$
declare d date; pfx text; n int;
begin
  if new.code <> '' and tg_op = 'UPDATE' then return new; end if;
  select (r.received_at at time zone 'Europe/Belgrade')::date into d from public.receipts r where r.id = new.receipt_id;
  select coalesce(p.lot_prefix, upper(left(p.id,2))) into pfx from public.products p where p.id = new.product_id;
  perform pg_advisory_xact_lock(hashtext('lot:'||pfx||to_char(d,'YYYYMMDD')));
  select count(*) + 1 into n from public.lots
   where code_year = extract(year from d)::int and code like pfx||'-'||to_char(d,'DDMM')||'-%';
  new.code := pfx||'-'||to_char(d,'DDMM')||'-'||lpad(n::text, 2, '0');
  new.code_year := extract(year from d)::int;
  return new;
end $$;
drop trigger if exists lots_set_code on public.lots;
create trigger lots_set_code before insert on public.lots for each row execute function public.lots_set_code();

-- ---------- Ciklus u smokeru (započet, još nije gotov) ----------
create table if not exists public.smoker_runs (
  id            uuid primary key default gen_random_uuid(),
  code          text not null,
  product_id    text not null references public.products(id),
  cook_name     text,
  smoker_in     timestamptz not null,
  raw_kg        numeric not null check (raw_kg > 0 and raw_kg <= 200),
  trimmed_kg    numeric check (trimmed_kg is null or (trimmed_kg > 0 and trimmed_kg <= raw_kg)),
  price_per_kg  numeric check (price_per_kg is null or price_per_kg > 0),
  smoker_temp_c numeric,
  wood          text,
  notes         text,
  created_by    uuid not null default auth.uid() references auth.users(id),
  created_at    timestamptz not null default now()
);

-- ---------- Gotov ciklus: nova polja ----------
alter table public.cooks add column if not exists code        text;
alter table public.cooks add column if not exists smoker_in   timestamptz;
alter table public.cooks add column if not exists smoker_out  timestamptz;
alter table public.cooks add column if not exists core_temp_c numeric;

-- ---------- Koliko je iz kog lota otišlo u smoker ----------
create table if not exists public.lot_uses (
  id         uuid primary key default gen_random_uuid(),
  lot_id     uuid not null references public.lots(id),
  run_id     uuid references public.smoker_runs(id) on delete cascade,
  cook_id    uuid references public.cooks(id) on delete cascade,
  kg         numeric not null check (kg > 0),
  created_at timestamptz not null default now(),
  check (run_id is not null or cook_id is not null)
);
create index if not exists lot_uses_lot_idx on public.lot_uses (lot_id);

-- kod ciklusa: C-DDMM-OZNAKA+RB (npr. C-2511-BR1)
create or replace function public.haccp_cook_code(pid text, ts timestamptz)
returns text language plpgsql security definer set search_path = public as $$
declare d date := (ts at time zone 'Europe/Belgrade')::date; pfx text; base text; n int;
begin
  select coalesce(p.lot_prefix, upper(left(p.id,2))) into pfx from public.products p where p.id = pid;
  base := 'C-'||to_char(d,'DDMM')||'-'||pfx;
  perform pg_advisory_xact_lock(hashtext('cook:'||base||extract(year from d)));
  select greatest(
    (select count(*) from public.smoker_runs where code like base||'%' and extract(year from smoker_in at time zone 'Europe/Belgrade') = extract(year from d)),
    0) + (select count(*) from public.cooks where code like base||'%' and extract(year from cook_date) = extract(year from d)) + 1 into n;
  return base||n;
end $$;

-- provera i upis lotova za ciklus
create or replace function public.haccp_use_lots(p_lots jsonb, p_product text, p_day date, p_run uuid, p_cook uuid)
returns void language plpgsql security definer set search_path = public as $$
declare x jsonb; l public.lots%rowtype; used numeric; k numeric;
begin
  for x in select * from jsonb_array_elements(coalesce(p_lots,'[]'::jsonb)) loop
    k := (x->>'kg')::numeric;
    if k is null or k <= 0 then raise exception 'Upiši koliko kg je uzeto iz lota.'; end if;
    select * into l from public.lots where id = (x->>'lot_id')::uuid for update;
    if not found then raise exception 'Lot nije pronađen.'; end if;
    if l.product_id <> p_product then raise exception 'Lot % nije za ovo meso.', l.code; end if;
    if l.closed_at is not null then raise exception 'Lot % je zatvoren.', l.code; end if;
    if l.expiry is not null and l.expiry < p_day then raise exception 'Lotu % je istekao rok (%). Ne sme u smoker.', l.code, to_char(l.expiry,'DD.MM.YYYY.'); end if;
    select coalesce(sum(u.kg),0) into used from public.lot_uses u where u.lot_id = l.id;
    if used + k > l.kg + 0.05 then raise exception 'U lotu % je ostalo samo % kg.', l.code, replace(round(l.kg - used, 2)::text, '.', ','); end if;
    insert into public.lot_uses (lot_id, run_id, cook_id, kg) values (l.id, p_run, p_cook, k);
  end loop;
end $$;

-- 1) meso ulazi u smoker
create or replace function public.haccp_start(p jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare r public.smoker_runs%rowtype; ts timestamptz := coalesce((p->>'smoker_in')::timestamptz, now());
begin
  if not public.is_member() then raise exception 'Nemaš pristup.'; end if;
  insert into public.smoker_runs (code, product_id, cook_name, smoker_in, raw_kg, trimmed_kg, price_per_kg, smoker_temp_c, wood, notes, created_by)
  values (public.haccp_cook_code(p->>'product_id', ts), p->>'product_id', nullif(p->>'cook_name',''), ts,
          (p->>'raw_kg')::numeric, nullif(p->>'trimmed_kg','')::numeric, nullif(p->>'price_per_kg','')::numeric,
          nullif(p->>'smoker_temp_c','')::numeric, nullif(p->>'wood',''), nullif(p->>'notes',''), auth.uid())
  returning * into r;
  perform public.haccp_use_lots(p->'lots', r.product_id, (ts at time zone 'Europe/Belgrade')::date, r.id, null);
  return r.code;
end $$;

-- 2) meso izlazi iz smokera -> gotov ciklus
create or replace function public.haccp_finish(p_run uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.smoker_runs%rowtype; cid uuid; ts timestamptz := coalesce((p->>'smoker_out')::timestamptz, now()); lots text;
begin
  select * into r from public.smoker_runs where id = p_run for update;
  if not found then raise exception 'Ciklus nije pronađen (možda ga je neko već završio).'; end if;
  if not public.is_member() then raise exception 'Nemaš pristup.'; end if;
  if ts < r.smoker_in then raise exception 'Vreme izlaska je pre vremena ulaska u smoker.'; end if;
  select string_agg(l.code, ', ' order by l.code) into lots from public.lot_uses u join public.lots l on l.id = u.lot_id where u.run_id = r.id;
  insert into public.cooks (created_by, cook_date, product_id, cook_name, batch, raw_kg, trimmed_kg, cooked_kg, sellable_kg,
                            price_per_kg, smoker_temp_c, hours, wood, notes, code, smoker_in, smoker_out, core_temp_c)
  values (r.created_by, (r.smoker_in at time zone 'Europe/Belgrade')::date, r.product_id, coalesce(nullif(p->>'cook_name',''), r.cook_name), lots,
          r.raw_kg, r.trimmed_kg, (p->>'cooked_kg')::numeric, nullif(p->>'sellable_kg','')::numeric,
          r.price_per_kg, r.smoker_temp_c, round(extract(epoch from ts - r.smoker_in)/3600.0, 1), r.wood,
          nullif(concat_ws(' · ', r.notes, nullif(p->>'notes','')), ''), r.code, r.smoker_in, ts, nullif(p->>'core_temp_c','')::numeric)
  returning id into cid;
  update public.lot_uses set cook_id = cid, run_id = null where run_id = r.id;
  delete from public.smoker_runs where id = r.id;
  return cid;
end $$;

-- 3) ceo ciklus odjednom (kao ranije), sa lotovima
create or replace function public.haccp_direct(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; tin timestamptz := nullif(p->>'smoker_in','')::timestamptz; tout timestamptz := nullif(p->>'smoker_out','')::timestamptz;
        d date := coalesce(nullif(p->>'cook_date','')::date, (tin at time zone 'Europe/Belgrade')::date, (now() at time zone 'Europe/Belgrade')::date);
        lots text;
begin
  if not public.is_member() then raise exception 'Nemaš pristup.'; end if;
  if tin is not null and tout is not null and tout < tin then raise exception 'Vreme izlaska je pre vremena ulaska u smoker.'; end if;
  insert into public.cooks (created_by, cook_date, product_id, cook_name, raw_kg, trimmed_kg, cooked_kg, sellable_kg,
                            price_per_kg, smoker_temp_c, hours, wood, notes, code, smoker_in, smoker_out, core_temp_c)
  values (auth.uid(), d, p->>'product_id', nullif(p->>'cook_name',''), (p->>'raw_kg')::numeric, nullif(p->>'trimmed_kg','')::numeric,
          (p->>'cooked_kg')::numeric, nullif(p->>'sellable_kg','')::numeric, nullif(p->>'price_per_kg','')::numeric,
          nullif(p->>'smoker_temp_c','')::numeric,
          coalesce(nullif(p->>'hours','')::numeric, case when tin is not null and tout is not null then round(extract(epoch from tout - tin)/3600.0, 1) end),
          nullif(p->>'wood',''), nullif(p->>'notes',''), public.haccp_cook_code(p->>'product_id', coalesce(tin, d::timestamptz)), tin, tout,
          nullif(p->>'core_temp_c','')::numeric)
  returning id into cid;
  perform public.haccp_use_lots(p->'lots', p->>'product_id', d, null, cid);
  select string_agg(l.code, ', ' order by l.code) into lots from public.lot_uses u join public.lots l on l.id = u.lot_id where u.cook_id = cid;
  if lots is not null then update public.cooks set batch = lots where id = cid; end if;
  return cid;
end $$;

-- otkazivanje započetog ciklusa (greška) — lotovi se vraćaju
create or replace function public.haccp_cancel(p_run uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r public.smoker_runs%rowtype;
begin
  select * into r from public.smoker_runs where id = p_run;
  if not found then return; end if;
  if not (public.is_sef() or (public.is_member() and r.created_by = auth.uid())) then raise exception 'Otkazati može samo onaj ko je započeo ciklus ili šef smene.'; end if;
  delete from public.smoker_runs where id = p_run;
end $$;

-- prijem: otpremnica + stavke odjednom; vraća kodove lotova
create or replace function public.haccp_receive(p jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare rid uuid := coalesce(nullif(p->>'id','')::uuid, gen_random_uuid()); x jsonb; codes text := ''; c text;
begin
  if not public.is_member() then raise exception 'Nemaš pristup.'; end if;
  if jsonb_array_length(coalesce(p->'items','[]'::jsonb)) = 0 then raise exception 'Dodaj bar jednu stavku (meso i kg).'; end if;
  if exists (select 1 from public.receipts where supplier_id = (p->>'supplier_id')::uuid and lower(trim(doc_no)) = lower(trim(p->>'doc_no'))) then
    raise exception 'Otpremnica % od ovog dobavljača je već upisana.', trim(p->>'doc_no');
  end if;
  insert into public.receipts (id, supplier_id, doc_no, received_at, received_by, photos, note, created_by)
  values (rid, (p->>'supplier_id')::uuid, trim(p->>'doc_no'), coalesce(nullif(p->>'received_at','')::timestamptz, now()),
          nullif(p->>'received_by',''), coalesce(array(select jsonb_array_elements_text(p->'photos')), '{}'), nullif(p->>'note',''), auth.uid());
  for x in select * from jsonb_array_elements(p->'items') loop
    insert into public.lots (receipt_id, product_id, kg, supplier_lot, expiry, temp_c, photos, created_by)
    values (rid, x->>'product_id', (x->>'kg')::numeric, nullif(x->>'supplier_lot',''), nullif(x->>'expiry','')::date,
            nullif(x->>'temp_c','')::numeric, coalesce(array(select jsonb_array_elements_text(x->'photos')), '{}'), auth.uid())
    returning code into c;
    codes := codes || case when codes = '' then '' else ', ' end || c;
  end loop;
  return codes;
end $$;

-- naknadno dodavanje slika (otpremnica ili deklaracija)
create or replace function public.haccp_add_photos(p_kind text, p_id uuid, p_paths text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'Nemaš pristup.'; end if;
  if p_kind = 'receipt' then update public.receipts set photos = photos || p_paths where id = p_id;
  elsif p_kind = 'lot' then update public.lots set photos = photos || p_paths where id = p_id;
  else raise exception 'Nepoznata vrsta.'; end if;
end $$;

-- zatvaranje lota (ostatak u otpis) i ponovno otvaranje
create or replace function public.haccp_close_lot(p_id uuid, p_note text, p_open boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'Nemaš pristup.'; end if;
  if p_open then
    if not public.is_sef() then raise exception 'Lot ponovo otvara šef smene.'; end if;
    update public.lots set closed_at = null, close_note = null where id = p_id;
  else
    update public.lots set closed_at = now(), close_note = nullif(p_note,'') where id = p_id;
  end if;
end $$;

-- brisanje pogrešno upisanog prijema (samo dok meso nije ušlo u smoker)
create or replace function public.haccp_delete_receipt(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r public.receipts%rowtype;
begin
  select * into r from public.receipts where id = p_id;
  if not found then return; end if;
  if not (public.is_sef() or (public.is_member() and r.created_by = auth.uid())) then raise exception 'Prijem briše onaj ko ga je upisao ili šef smene.'; end if;
  if exists (select 1 from public.lot_uses u join public.lots l on l.id = u.lot_id where l.receipt_id = p_id) then
    raise exception 'Meso sa ove otpremnice je već u smokeru — prijem ne može da se obriše.';
  end if;
  delete from public.receipts where id = p_id;
end $$;

-- novi dobavljač (svi članovi)
create or replace function public.haccp_add_supplier(p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  if not public.is_member() then raise exception 'Nemaš pristup.'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'Upiši naziv dobavljača.'; end if;
  insert into public.suppliers (name) values (trim(p_name)) on conflict (name) do update set active = true returning id into sid;
  return sid;
end $$;

do $$ declare f text; begin
  foreach f in array array['haccp_cook_code(text,timestamptz)','haccp_use_lots(jsonb,text,date,uuid,uuid)','lots_set_code()'] loop
    execute 'revoke execute on function public.'||f||' from public, anon, authenticated';
  end loop;
  foreach f in array array['haccp_start(jsonb)','haccp_finish(uuid,jsonb)','haccp_direct(jsonb)','haccp_cancel(uuid)','haccp_receive(jsonb)',
                           'haccp_add_photos(text,uuid,text[])','haccp_close_lot(uuid,text,boolean)','haccp_delete_receipt(uuid)','haccp_add_supplier(text)'] loop
    execute 'revoke execute on function public.'||f||' from public, anon';
    execute 'grant execute on function public.'||f||' to authenticated';
  end loop;
end $$;

-- ---------- Pristup (RLS): čitaju članovi, upis samo preko funkcija iznad ----------
alter table public.suppliers   enable row level security;
alter table public.receipts    enable row level security;
alter table public.lots        enable row level security;
alter table public.smoker_runs enable row level security;
alter table public.lot_uses    enable row level security;
drop policy if exists "haccp: čitaju članovi" on public.suppliers;
create policy "haccp: čitaju članovi" on public.suppliers   for select to authenticated using (public.is_member());
drop policy if exists "haccp: admin menja" on public.suppliers;
create policy "haccp: admin menja" on public.suppliers for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "haccp: čitaju članovi" on public.receipts;
create policy "haccp: čitaju članovi" on public.receipts    for select to authenticated using (public.is_member());
drop policy if exists "haccp: čitaju članovi" on public.lots;
create policy "haccp: čitaju članovi" on public.lots        for select to authenticated using (public.is_member());
drop policy if exists "haccp: čitaju članovi" on public.smoker_runs;
create policy "haccp: čitaju članovi" on public.smoker_runs for select to authenticated using (public.is_member());
drop policy if exists "haccp: čitaju članovi" on public.lot_uses;
create policy "haccp: čitaju članovi" on public.lot_uses    for select to authenticated using (public.is_member());

-- ---------- Slike (privatni prostor „haccp“) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('haccp', 'haccp', false, 6291456, array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do update set public = false;
drop policy if exists "haccp slike: čitaju članovi" on storage.objects;
create policy "haccp slike: čitaju članovi" on storage.objects for select to authenticated using (bucket_id = 'haccp' and public.is_member());
drop policy if exists "haccp slike: upis članovi" on storage.objects;
create policy "haccp slike: upis članovi" on storage.objects for insert to authenticated with check (bucket_id = 'haccp' and public.is_member());

-- ---------- Uživo osvežavanje ----------
do $$ declare t text; begin
  foreach t in array array['suppliers','receipts','lots','smoker_runs','lot_uses'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; when undefined_object then null; end;
  end loop;
end $$;

-- Provera
select (select count(*) from public.suppliers) as dobavljaca,
       (select string_agg(id||'='||lot_prefix, ', ' order by sort) from public.products) as oznake;
