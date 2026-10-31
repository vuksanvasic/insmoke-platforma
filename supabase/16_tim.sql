-- =====================================================================
-- Izmena 16: administrator dodaje osobu u tim (bez čekanja na registraciju)
--   · pravi nalog (mejl + početna lozinka), odmah odobren, sa izabranom ulogom
--   · ako nalog sa tim mejlom već postoji: samo mu postavi ime i ulogu
--   · ljudi i dalje mogu i sami da se registruju (pa ih administrator odobri)
-- Može da se pokrene više puta bez štete.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create or replace function public.admin_add_member(p_name text, p_email text, p_role text, p_password text)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid;
  em text := lower(trim(coalesce(p_email,'')));
  nm text := regexp_replace(trim(coalesce(p_name,'')), '\s+', ' ', 'g');
begin
  if not public.is_admin() then raise exception 'Samo administrator dodaje ljude u tim.'; end if;
  if length(nm) < 2 then raise exception 'Upiši ime i prezime.'; end if;
  if em !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Mejl nije ispravan.'; end if;
  if p_role not in ('kuvar','sef','menadzer','admin') then raise exception 'Nepoznata uloga.'; end if;

  select id into uid from auth.users where lower(email) = em limit 1;
  if uid is null then
    if p_password is null or length(p_password) < 8 then raise exception 'Lozinka mora imati najmanje 8 znakova.'; end if;
    uid := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, recovery_token, email_change_token_new, email_change,
                            email_change_token_current, phone_change, phone_change_token, reauthentication_token)
    values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em,
            extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', nm), now(), now(),
            '', '', '', '', '', '', '', '');
    insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (uid::text, uid, jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true, 'phone_verified', false),
            'email', now(), now(), now());
  end if;

  -- profil pravi okidač na auth.users; ovde mu se postavljaju ime, mejl i uloga
  insert into public.profiles (id, full_name, email, role) values (uid, nm, em, p_role)
  on conflict (id) do update set full_name = excluded.full_name, email = excluded.email, role = excluded.role;
  return uid;
end $$;
revoke execute on function public.admin_add_member(text, text, text, text) from public, anon;
grant execute on function public.admin_add_member(text, text, text, text) to authenticated;
