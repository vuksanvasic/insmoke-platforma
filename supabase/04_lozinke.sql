-- =====================================================================
-- Izmena 04: administrator postavlja novu lozinku članu tima
-- (za kuvare kojima mejl za vraćanje lozinke ne može da stigne)
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create or replace function public.admin_set_password(target uuid, new_password text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_admin() then
    raise exception 'Samo administrator može da postavi lozinku.';
  end if;
  if target = auth.uid() then
    raise exception 'Svoju lozinku menjaš preko „Promeni lozinku“.';
  end if;
  if new_password is null or length(new_password) < 8 then
    raise exception 'Lozinka mora imati najmanje 8 znakova.';
  end if;
  update auth.users
     set encrypted_password = extensions.crypt(new_password, extensions.gen_salt('bf')),
         updated_at = now()
   where id = target;
  if not found then
    raise exception 'Nalog nije pronađen.';
  end if;
end $$;

revoke execute on function public.admin_set_password(uuid, text) from public, anon;
grant execute on function public.admin_set_password(uuid, text) to authenticated;
