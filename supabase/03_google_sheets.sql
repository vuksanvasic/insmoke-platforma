-- =====================================================================
-- Izmena 03: svaka promena ciklusa ide u Google Sheet (dodavanje, izmena, brisanje)
-- Adresa skripte čuva se u privatnoj šemi koju sajt ne može da čita.
-- =====================================================================

create extension if not exists pg_net with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.integrations (
  key   text primary key,
  value text not null
);
revoke all on private.integrations from public, anon, authenticated;

-- Adresa web aplikacije iz Apps Script-a + ?token=TAJNI_KLJUC (isti kao u Code.gs)
insert into private.integrations (key, value)
values ('sheets_webhook', 'https://script.google.com/macros/s/ID-SKRIPTE/exec?token=TAJNI_KLJUC')
on conflict (key) do update set value = excluded.value;

create or replace function public.cooks_to_sheet()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  hook text;
  zapis jsonb;
  stari jsonb;
begin
  select value into hook from private.integrations where key = 'sheets_webhook';
  if hook is null then
    return coalesce(new, old);
  end if;

  if tg_op <> 'DELETE' then
    zapis := to_jsonb(new) || jsonb_build_object(
      'product_name', (select name from public.products where id = new.product_id),
      'target_yield', (select target_yield from public.products where id = new.product_id));
  end if;
  if tg_op <> 'INSERT' then
    stari := to_jsonb(old);
  end if;

  perform net.http_post(
    url := hook,
    body := jsonb_build_object('type', tg_op, 'record', zapis, 'old_record', stari),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 30000
  );
  return coalesce(new, old);
end $$;

revoke execute on function public.cooks_to_sheet() from public, anon, authenticated;

drop trigger if exists cooks_to_sheet on public.cooks;
create trigger cooks_to_sheet
  after insert or update or delete on public.cooks
  for each row execute function public.cooks_to_sheet();
