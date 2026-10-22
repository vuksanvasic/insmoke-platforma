-- =====================================================================
-- Izmena 07: otpis → Google tabela (list „Otpis“) i dnevni mejl u 22h
-- Koristi istu Apps Script vezu (private.integrations.sheets_webhook).
-- =====================================================================

-- ---------- Svaka promena otpisa ide u tabelu ----------
create or replace function public.waste_to_sheet()
returns trigger language plpgsql security definer set search_path = public as $$
declare hook text; zapis jsonb; stari jsonb;
begin
  select value into hook from private.integrations where key = 'sheets_webhook';
  if hook is null then return coalesce(new, old); end if;
  if tg_op <> 'DELETE' then
    select to_jsonb(new) || jsonb_build_object('item_name', i.name, 'area', i.area, 'grp', i.grp, 'unit', i.unit)
      into zapis from public.waste_items i where i.id = new.item_id;
  end if;
  if tg_op <> 'INSERT' then stari := to_jsonb(old); end if;
  perform net.http_post(
    url := hook,
    body := jsonb_build_object('kind', 'waste', 'type', tg_op, 'record', zapis, 'old_record', stari),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 30000);
  return coalesce(new, old);
end $$;
revoke execute on function public.waste_to_sheet() from public, anon, authenticated;
drop trigger if exists waste_to_sheet on public.waste;
create trigger waste_to_sheet after insert or update or delete on public.waste
  for each row execute function public.waste_to_sheet();

-- ---------- Dnevni izveštaj ----------
create table if not exists private.sent_reports (
  kind text not null,
  day  date not null,
  sent_at timestamptz not null default now(),
  primary key (kind, day)
);
revoke all on private.sent_reports from public, anon, authenticated;
alter table private.sent_reports enable row level security;

create or replace function public.waste_daily_summary(d date)
returns jsonb language sql stable security definer set search_path = public as $$
  with w as (
    select w.*, i.name as item_name, i.area, i.unit
      from public.waste w join public.waste_items i on i.id = w.item_id
     where w.waste_date = d
  )
  select jsonb_build_object(
    'date', d,
    'total_rsd', coalesce((select sum(value_rsd) from w), 0),
    'count', (select count(*) from w),
    'missing_price', (select count(*) from w where unit_cost is null),
    'by_area', coalesce((select jsonb_agg(x) from (
        select area, coalesce(sum(value_rsd),0) as rsd, count(*) as cnt from w group by area order by area) x), '[]'::jsonb),
    'by_shift', (select jsonb_agg(x order by x.shift) from (
        select s.shift,
               coalesce((select sum(value_rsd) from w where w.shift = s.shift), 0) as rsd,
               (select count(*) from w where w.shift = s.shift) as cnt,
               ws.waste_date is not null as closed,
               coalesce(ws.no_waste, false) as no_waste,
               ws.closed_by_name
          from generate_series(1,3) as s(shift)
          left join public.waste_shifts ws on ws.waste_date = d and ws.shift = s.shift) x),
    'by_reason', coalesce((select jsonb_agg(x) from (
        select reason, coalesce(sum(value_rsd),0) as rsd, count(*) as cnt from w group by reason order by 2 desc, 3 desc) x), '[]'::jsonb),
    'top_items', coalesce((select jsonb_agg(x) from (
        select item_name, unit, sum(qty) as qty, coalesce(sum(value_rsd),0) as rsd from w
         group by item_name, unit order by 4 desc, 3 desc limit 5) x), '[]'::jsonb)
  );
$$;
revoke execute on function public.waste_daily_summary(date) from public, anon;
grant execute on function public.waste_daily_summary(date) to authenticated;

-- Šalje izveštaj za današnji dan kad je u Beogradu 22h (pg_cron okida svakog sata).
-- force = true šalje odmah (za probu), bez beleženja da je poslato.
create or replace function public.waste_daily_send(force boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare
  lokalno timestamp := now() at time zone 'Europe/Belgrade';
  danas date := lokalno::date;
  hook text;
begin
  if not force then
    if extract(hour from lokalno) <> 22 then return 'nije 22h'; end if;
    if exists (select 1 from private.sent_reports where kind = 'otpis' and day = danas) then return 'već poslato'; end if;
  end if;
  select value into hook from private.integrations where key = 'sheets_webhook';
  if hook is null then return 'nema veze'; end if;
  perform net.http_post(
    url := hook,
    body := jsonb_build_object('kind', 'daily_waste', 'summary', public.waste_daily_summary(danas)),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 30000);
  if not force then
    insert into private.sent_reports (kind, day) values ('otpis', danas) on conflict do nothing;
  end if;
  return 'poslato';
end $$;
revoke execute on function public.waste_daily_send(boolean) from public, anon, authenticated;

create extension if not exists pg_cron;
select cron.schedule('otpis-dnevni-izvestaj', '0 * * * *', 'select public.waste_daily_send()');
