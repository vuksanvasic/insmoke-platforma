-- =====================================================================
-- Izmena 02: registracija na sajtu uz odobrenje administratora
-- Uloge: 'ceka' (novi nalog, ne vidi ništa) · 'kuvar' · 'admin' · 'odbijen'
-- Može da se pokrene više puta bez štete.
-- =====================================================================

alter table public.profiles add column if not exists email text;

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('ceka','kuvar','admin','odbijen'));
alter table public.profiles alter column role set default 'ceka';

-- Novi nalog: ime iz forme, email, uloga 'ceka'
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, email)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'), ''), split_part(new.email, '@', 1)),
    new.email
  )
  on conflict (id) do nothing;
  return new;
end $$;

update public.profiles p set email = u.email from auth.users u where u.id = p.id and p.email is null;

-- Odobren član = kuvar ili admin
create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('kuvar','admin'));
$$;

-- ---------- Pravila: samo odobreni vide i upisuju ----------
drop policy if exists "profili: čitaju prijavljeni" on public.profiles;
drop policy if exists "profili: svoj ili članovi" on public.profiles;
create policy "profili: svoj ili članovi" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_admin() or (public.is_member() and role in ('kuvar','admin')));

drop policy if exists "meso: čitaju prijavljeni" on public.products;
drop policy if exists "meso: čitaju članovi" on public.products;
create policy "meso: čitaju članovi" on public.products
  for select to authenticated using (public.is_member());

drop policy if exists "ciklusi: čitaju prijavljeni" on public.cooks;
drop policy if exists "ciklusi: čitaju članovi" on public.cooks;
create policy "ciklusi: čitaju članovi" on public.cooks
  for select to authenticated using (public.is_member());

drop policy if exists "ciklusi: upis u svoje ime" on public.cooks;
create policy "ciklusi: upis u svoje ime" on public.cooks
  for insert to authenticated with check (created_by = auth.uid() and public.is_member());

drop policy if exists "ciklusi: brisanje svojih ili admin" on public.cooks;
create policy "ciklusi: brisanje svojih ili admin" on public.cooks
  for delete to authenticated using ((created_by = auth.uid() and public.is_member()) or public.is_admin());

-- Administrator ne može sam sebi da promeni ulogu (da se ne zaključa)
create or replace function public.guard_own_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.id = auth.uid() and new.role is distinct from old.role then
    raise exception 'Ne možeš da menjaš sopstvenu ulogu.';
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard_own_role on public.profiles;
create trigger profiles_guard_own_role before update on public.profiles
  for each row execute function public.guard_own_role();

-- Uživo osvežavanje liste tima
do $$ begin
  alter publication supabase_realtime add table public.profiles;
exception when duplicate_object then null; when undefined_object then null; end $$;
