-- =====================================================================
-- Izmena 05: mejl administratoru kad se neko registruje (preko iste Apps Script veze)
-- =====================================================================

create or replace function public.profiles_signup_notify()
returns trigger language plpgsql security definer set search_path = public as $$
declare hook text;
begin
  select value into hook from private.integrations where key = 'sheets_webhook';
  if hook is not null and new.role = 'ceka' then
    perform net.http_post(
      url := hook,
      body := jsonb_build_object('kind', 'signup', 'record',
        jsonb_build_object('full_name', new.full_name, 'email', new.email, 'created_at', new.created_at)),
      headers := '{"Content-Type": "application/json"}'::jsonb,
      timeout_milliseconds := 30000
    );
  end if;
  return new;
end $$;

revoke execute on function public.profiles_signup_notify() from public, anon, authenticated;

drop trigger if exists profiles_signup_notify on public.profiles;
create trigger profiles_signup_notify
  after insert on public.profiles
  for each row execute function public.profiles_signup_notify();
