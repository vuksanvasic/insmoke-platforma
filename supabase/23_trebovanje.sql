-- SQL izmena 23 (26.11.2026): KUHINJA OSOBLJE — trebovanje ide menadžeru kuhinje
--   * stavka trebovanja ima status: novo → poslato → naručeno → stiglo (ili odbijeno), i oznaku „hitno“
--   * kuvar šalje sve nove stavke svoje smene menadžeru (WhatsApp poruka + status u aplikaciji)
--   * menadžer (šef smene / menadžer / administrator) menja status i ostavlja napomenu
-- Bezbedno za ponovno pokretanje. Posle 21 i 22.

alter table public.chk_requests add column if not exists status     text not null default 'novo';
alter table public.chk_requests add column if not exists urgent     boolean not null default false;
alter table public.chk_requests add column if not exists sent_at    timestamptz;
alter table public.chk_requests add column if not exists sent_by    uuid references auth.users(id);
alter table public.chk_requests add column if not exists handled_at timestamptz;
alter table public.chk_requests add column if not exists handled_by uuid references auth.users(id);
alter table public.chk_requests add column if not exists mgr_note   text;
do $$ begin
  alter table public.chk_requests add constraint chk_requests_status_ck
    check (status in ('novo','poslato','naruceno','stiglo','odbijeno'));
exception when duplicate_object then null; end $$;
create index if not exists chk_requests_status_idx on public.chk_requests (status, created_at desc);

-- menadžer kuhinje kome ide trebovanje
alter table public.staff_site add column if not exists treb_user  uuid references auth.users(id);
alter table public.staff_site add column if not exists treb_phone text;

-- javni podaci lokala za članove (bez QR tajne) — sada i ime i telefon menadžera za trebovanje
drop function if exists public.staff_site_public();
create or replace function public.staff_site_public()
returns table (name text, lat numeric, lng numeric, radius_m int, geo_required boolean, qr_required boolean,
               treb_user uuid, treb_name text, treb_phone text)
language sql stable security definer set search_path = public as $$
  select s.name, s.lat, s.lng, s.radius_m, s.geo_required, s.qr_required,
         s.treb_user, p.full_name, s.treb_phone
    from public.staff_site s left join public.profiles p on p.id = s.treb_user
   where s.id = 1 and public.is_member();
$$;

-- pošalji: sve „nove“ stavke te smene postaju „poslate“; vraća broj
create or replace function public.treb_send(p_date date, p_shift int)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_member() then raise exception 'Nemaš pristup.'; end if;
  if not public.is_sef() and not exists (select 1 from public.staff_shifts s where s.user_id = auth.uid()
       and s.clock_out is null and s.work_date = p_date and s.shift = p_shift) then
    raise exception 'Trebovanje šalje neko ko je na ovoj smeni.'; end if;
  update public.chk_requests set status = 'poslato', sent_at = now(), sent_by = auth.uid()
   where work_date = p_date and shift = p_shift and status = 'novo';
  get diagnostics n = row_count;
  return n;
end $$;

-- menadžer menja status (naručeno / stiglo / odbijeno / vrati na poslato)
create or replace function public.treb_set_status(p_ids uuid[], p_status text, p_note text)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_sef() then raise exception 'Status trebovanja menja menadžer kuhinje / šef smene.'; end if;
  if p_status not in ('poslato','naruceno','stiglo','odbijeno') then raise exception 'Nepoznat status.'; end if;
  update public.chk_requests
     set status = p_status, handled_at = now(), handled_by = auth.uid(),
         mgr_note = coalesce(nullif(trim(coalesce(p_note,'')),''), mgr_note),
         sent_at = coalesce(sent_at, now())
   where id = any(p_ids);
  get diagnostics n = row_count;
  return n;
end $$;

-- kuvar može da doda stavku i da je obriše dok je još „nova“
drop policy if exists "trebovanje: briše svoje ili šef" on public.chk_requests;
create policy "trebovanje: briše svoje ili šef" on public.chk_requests for delete to authenticated
  using (public.is_sef() or (created_by = auth.uid() and status = 'novo'));

do $$ declare f text; begin
  foreach f in array array['staff_site_public()','treb_send(date, int)','treb_set_status(uuid[], text, text)'] loop
    execute 'revoke all on function public.'||f||' from public, anon';
    execute 'grant execute on function public.'||f||' to authenticated';
  end loop;
end $$;
