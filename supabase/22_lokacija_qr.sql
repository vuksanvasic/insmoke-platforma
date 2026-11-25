-- SQL izmena 22 (26.11.2026): KUHINJA OSOBLJE — provera da je radnik u lokalu
--   * GPS: dolazak, pauza, odlazak i svako čekiranje rade samo u krugu oko lokala (proverava server)
--   * QR kod na zidu: dolazak i odlazak traže skeniran QR kod
--   * kuvar čekira samo dok je prijavljen na tu smenu; šef smene i administrator mogu da dopune
-- Bezbedno za ponovno pokretanje. Posle pokretanja 21_osoblje.sql.

-- ---------- Podešavanja lokala (jedan red) ----------
create table if not exists public.staff_site (
  id           int primary key default 1 check (id = 1),
  name         text not null default 'In Smoke We Trust',
  lat          numeric not null,
  lng          numeric not null,
  radius_m     int not null default 150 check (radius_m between 30 and 2000),
  geo_required boolean not null default true,
  qr_required  boolean not null default true,
  qr_secret    text not null default replace(gen_random_uuid()::text, '-', ''),
  updated_at   timestamptz not null default now()
);
-- Žorža Klemansoa 29a, Beograd (Gastrošor, Dorćol)
insert into public.staff_site (id, lat, lng) values (1, 44.8248136, 20.4711382)
on conflict (id) do nothing;

alter table public.staff_site enable row level security;
drop policy if exists "lokal: čita admin" on public.staff_site;
create policy "lokal: čita admin" on public.staff_site for select to authenticated using (public.is_admin());
drop policy if exists "lokal: menja admin" on public.staff_site;
create policy "lokal: menja admin" on public.staff_site for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- javno za članove (bez QR tajne): da telefon zna da li treba da traži lokaciju i QR
create or replace function public.staff_site_public()
returns table (name text, lat numeric, lng numeric, radius_m int, geo_required boolean, qr_required boolean)
language sql stable security definer set search_path = public as $$
  select s.name, s.lat, s.lng, s.radius_m, s.geo_required, s.qr_required from public.staff_site s
   where s.id = 1 and public.is_member();
$$;

-- nov QR kod (stari prestaje da važi) — administrator
create or replace function public.staff_qr_new()
returns text language plpgsql security definer set search_path = public as $$
declare k text;
begin
  if not public.is_admin() then raise exception 'Samo administrator.'; end if;
  k := replace(gen_random_uuid()::text, '-', '');
  update public.staff_site set qr_secret = k, updated_at = now() where id = 1;
  return k;
end $$;

-- ---------- Udaljenost (metri, haversine) ----------
create or replace function public.geo_dist_m(lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric)
returns numeric language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians((lat2 - lat1) / 2)), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians((lng2 - lng1) / 2)), 2)
  ));
$$;

-- provera lokacije: vraća udaljenost; greška ako je van kruga.
-- Nepreciznost telefona (accuracy) se uračunava do 150 m.
create or replace function public.staff_geo_check(p_lat numeric, p_lng numeric, p_acc numeric)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare s public.staff_site; d numeric;
begin
  select * into s from public.staff_site where id = 1;
  if not found or not s.geo_required then
    return case when p_lat is null or s.lat is null then null else round(public.geo_dist_m(s.lat, s.lng, p_lat, p_lng)) end;
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Uključi lokaciju na telefonu i dozvoli je ovoj stranici.'; end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'Neispravna lokacija.'; end if;
  d := public.geo_dist_m(s.lat, s.lng, p_lat, p_lng);
  if d - least(greatest(coalesce(p_acc, 0), 0), 150) > s.radius_m then
    raise exception 'Nisi u lokalu (oko % m od lokala). Ovo se radi samo u lokalu.', round(d); end if;
  return round(d);
end $$;

create or replace function public.staff_qr_check(p_qr text)
returns void language plpgsql stable security definer set search_path = public as $$
declare s public.staff_site;
begin
  select * into s from public.staff_site where id = 1;
  if not found or not s.qr_required then return; end if;
  if p_qr is null or p_qr <> s.qr_secret then
    raise exception 'Skeniraj QR kod na zidu u kuhinji, pa klikni ponovo.'; end if;
end $$;

-- ---------- Evidencija gde je ko bio ----------
alter table public.staff_shifts add column if not exists in_dist_m  numeric;
alter table public.staff_shifts add column if not exists out_dist_m numeric;
alter table public.chk_done     add column if not exists dist_m     numeric;

-- ---------- Stare funkcije (bez lokacije) više ne smeju da se pozivaju ----------
drop function if exists public.staff_clock_in(int);
drop function if exists public.staff_break_toggle();
drop function if exists public.staff_clock_out();
drop function if exists public.chk_check(date, int, uuid, jsonb, text, text[], boolean);

create or replace function public.staff_clock_in(p_shift int, p_lat numeric, p_lng numeric, p_acc numeric, p_qr text)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.staff_shifts; nid uuid; d numeric;
begin
  if not public.is_member() then raise exception 'Nemaš pristup.'; end if;
  if p_shift not in (1,2) then raise exception 'Smena mora biti 1 ili 2.'; end if;
  select * into r from public.staff_shifts where user_id = auth.uid() and clock_out is null;
  if found then raise exception 'Već si prijavljen/a na smenu (%). Prvo se odjavi.', r.shift; end if;
  perform public.staff_qr_check(p_qr);
  d := public.staff_geo_check(p_lat, p_lng, p_acc);
  insert into public.staff_shifts (user_id, work_date, shift, clock_in, in_dist_m)
  values (auth.uid(), (now() at time zone 'Europe/Belgrade')::date, p_shift, now(), d)
  returning id into nid;
  return nid;
end $$;

create or replace function public.staff_break_toggle(p_lat numeric, p_lng numeric, p_acc numeric)
returns text language plpgsql security definer set search_path = public as $$
declare r public.staff_shifts; b public.staff_breaks;
begin
  select * into r from public.staff_shifts where user_id = auth.uid() and clock_out is null;
  if not found then raise exception 'Nisi prijavljen/a na smenu.'; end if;
  perform public.staff_geo_check(p_lat, p_lng, p_acc);
  select * into b from public.staff_breaks where staff_shift_id = r.id and end_at is null;
  if found then
    update public.staff_breaks set end_at = now() where id = b.id;
    return 'kraj';
  end if;
  insert into public.staff_breaks (staff_shift_id) values (r.id);
  return 'pocetak';
end $$;

create or replace function public.staff_clock_out(p_lat numeric, p_lng numeric, p_acc numeric, p_qr text)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.staff_shifts; d numeric;
begin
  select * into r from public.staff_shifts where user_id = auth.uid() and clock_out is null;
  if not found then raise exception 'Nisi prijavljen/a na smenu.'; end if;
  perform public.staff_qr_check(p_qr);
  d := public.staff_geo_check(p_lat, p_lng, p_acc);
  update public.staff_breaks set end_at = now() where staff_shift_id = r.id and end_at is null;
  update public.staff_shifts set clock_out = now(), out_dist_m = d where id = r.id;
  return r.id;
end $$;

create or replace function public.chk_check(p_date date, p_shift int, p_item uuid, p_temps jsonb, p_note text, p_photos text[], p_skip boolean,
                                            p_lat numeric, p_lng numeric, p_acc numeric)
returns uuid language plpgsql security definer set search_path = public as $$
declare it public.chk_items; pt public.chk_points; t jsonb; v numeric; outs jsonb := '[]'; al boolean := false; ok boolean; nid uuid; k text; dist numeric;
begin
  if not public.is_member() then raise exception 'Nemaš pristup.'; end if;
  select * into it from public.chk_items where id = p_item;
  if not found then raise exception 'Stavka ne postoji.'; end if;
  if it.shift <> p_shift then raise exception 'Stavka nije za ovu smenu.'; end if;
  if p_date > (now() at time zone 'Europe/Belgrade')::date then raise exception 'Ne može unapred.'; end if;
  if not public.is_sef() then
    -- kuvar: samo dok je prijavljen na baš ovu smenu, i samo u lokalu
    if not exists (select 1 from public.staff_shifts s where s.user_id = auth.uid() and s.clock_out is null
                    and s.work_date = p_date and s.shift = p_shift) then
      raise exception 'Čekira se samo dok si prijavljen/a na ovu smenu (Dolazak).'; end if;
    dist := public.staff_geo_check(p_lat, p_lng, p_acc);
  elsif p_lat is not null then
    dist := round(public.geo_dist_m((select lat from public.staff_site where id = 1), (select lng from public.staff_site where id = 1), p_lat, p_lng));
  end if;

  if coalesce(p_skip,false) then
    if not it.optional then raise exception 'Ova stavka mora da se uradi.'; end if;
  else
    if it.need_photo and coalesce(array_length(p_photos,1),0) = 0 then raise exception 'Potrebna je slika.'; end if;
    if (it.text_label is not null or it.code in ('handover_write')) and length(trim(coalesce(p_note,''))) = 0 then
      raise exception 'Upiši: %', coalesce(it.text_label,'tekst'); end if;
    if array_length(it.temp_kinds,1) > 0 then
      foreach k in array it.temp_kinds loop
        for pt in select * from public.chk_points where active and kind = k order by sort loop
          t := null;
          select x into t from jsonb_array_elements(coalesce(p_temps,'[]')) x where x->>'point_id' = pt.id::text limit 1;
          if t is null or (t->>'value') is null or (t->>'value') = '' then
            raise exception 'Upiši temperaturu: %', pt.label; end if;
          v := (t->>'value')::numeric;
          if v < -60 or v > 150 then raise exception 'Temperatura za % nije realna.', pt.label; end if;
          ok := (pt.t_min is null or v >= pt.t_min) and (pt.t_max is null or v <= pt.t_max);
          if not ok then al := true; end if;
          outs := outs || jsonb_build_array(jsonb_build_object('point_id',pt.id,'label',pt.label,'value',v,'ok',ok,'min',pt.t_min,'max',pt.t_max));
        end loop;
      end loop;
    end if;
  end if;

  insert into public.chk_done (work_date, shift, item_id, done_by, done_at, skipped, temps, alarm, note, photos, dist_m)
  values (p_date, p_shift, p_item, auth.uid(), now(), coalesce(p_skip,false), outs, al,
          nullif(trim(coalesce(p_note,'')),''), coalesce(p_photos,'{}'), dist)
  on conflict (work_date, shift, item_id) do update
     set done_by = excluded.done_by, done_at = excluded.done_at, skipped = excluded.skipped, temps = excluded.temps,
         alarm = excluded.alarm, note = excluded.note, photos = excluded.photos, dist_m = excluded.dist_m
  returning id into nid;
  return nid;
end $$;

-- trebovanje: kuvar samo tokom svoje smene
drop policy if exists "trebovanje: upis članovi" on public.chk_requests;
create policy "trebovanje: upis članovi" on public.chk_requests for insert to authenticated
  with check (public.is_member() and created_by = auth.uid() and (public.is_sef() or exists (
    select 1 from public.staff_shifts s where s.user_id = auth.uid() and s.clock_out is null
       and s.work_date = chk_requests.work_date and s.shift = chk_requests.shift)));

do $$ declare f text; begin
  foreach f in array array['staff_site_public()','staff_qr_new()','staff_geo_check(numeric, numeric, numeric)','staff_qr_check(text)',
    'staff_clock_in(int, numeric, numeric, numeric, text)','staff_break_toggle(numeric, numeric, numeric)',
    'staff_clock_out(numeric, numeric, numeric, text)',
    'chk_check(date, int, uuid, jsonb, text, text[], boolean, numeric, numeric, numeric)'] loop
    execute 'revoke all on function public.'||f||' from public, anon';
    execute 'grant execute on function public.'||f||' to authenticated';
  end loop;
end $$;
