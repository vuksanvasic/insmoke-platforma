-- =====================================================================
-- Izmena 12: MANAGEMENT CONTROL — FOOD COST
--   · ulazne fakture (e-faktura sa SEF-a kao XML ili ručni unos)
--   · povezivanje stavke sa fakture sa namirnicom; alat pamti vezu po dobavljaču
--   · cena namirnice se sama ažurira iz poslednje fakture (cena bez PDV-a)
--   · nedeljni / mesečni popis; dimljeno meso: sirovo, u smokeru, gotovo
--   · stvarni food cost = početno stanje + nabavka − krajnje stanje
--   · vide i unose: administrator, menadžer, šef smene
-- Može da se pokrene više puta bez štete.
-- =====================================================================

-- ---------- Namirnice: odakle je cena ----------
alter table public.waste_items add column if not exists price_date date;
alter table public.waste_items add column if not exists price_src  text;

-- ---------- Fakture ----------
create table if not exists public.fc_invoices (
  id              uuid primary key default gen_random_uuid(),
  supplier_name   text not null,
  supplier_pib    text,
  number          text not null,
  issue_date      date not null,
  doc_date        date not null,              -- datum isporuke (ako ga nema, datum fakture)
  net             numeric,                    -- ukupno bez PDV-a
  vat             numeric,
  gross           numeric,
  source          text not null default 'rucno' check (source in ('xml','rucno')),
  note            text,
  created_by      uuid default auth.uid() references auth.users(id),
  created_by_name text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index if not exists fc_invoices_uniq
  on public.fc_invoices ((coalesce(supplier_pib, lower(supplier_name))), lower(number));
create index if not exists fc_invoices_date_idx on public.fc_invoices (doc_date desc);

create table if not exists public.fc_invoice_lines (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references public.fc_invoices(id) on delete cascade,
  pos         int not null default 0,
  code        text,                           -- šifra artikla kod dobavljača
  name        text not null,
  qty         numeric not null,               -- u jedinici sa fakture (minus kod knjižnog odobrenja)
  unit_code   text,                           -- KGM, LTR, H87…
  net         numeric not null,               -- iznos stavke bez PDV-a (sa popustima)
  vat_pct     numeric,
  item_id     uuid references public.waste_items(id) on delete set null,
  ignore      boolean not null default false, -- nije namirnica (sredstva za čišćenje, ambalaža…)
  factor      numeric not null default 1 check (factor > 0), -- 1 jedinica sa fakture = factor jedinica namirnice
  item_qty    numeric generated always as (qty * factor) stored,
  unit_price  numeric generated always as (case when qty * factor <> 0 then round(net / (qty * factor), 4) end) stored
);
create index if not exists fc_lines_inv_idx  on public.fc_invoice_lines (invoice_id);
create index if not exists fc_lines_item_idx on public.fc_invoice_lines (item_id);

-- zapamćene veze: dobavljač + šifra (ili naziv) → namirnica
create table if not exists public.fc_map (
  supplier_key text not null,
  code         text not null,
  item_id      uuid references public.waste_items(id) on delete cascade,
  ignore       boolean not null default false,
  factor       numeric not null default 1 check (factor > 0),
  updated_at   timestamptz not null default now(),
  primary key (supplier_key, code)
);

-- ---------- Cena namirnice = cena iz poslednje fakture ----------
create or replace function public.fc_refresh_price(iid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if iid is null then return; end if;
  select l.unit_price, i.doc_date, i.supplier_name into r
    from public.fc_invoice_lines l join public.fc_invoices i on i.id = l.invoice_id
   where l.item_id = iid and not l.ignore and l.qty > 0 and l.net > 0 and l.unit_price is not null
   order by i.doc_date desc, i.created_at desc, l.pos desc
   limit 1;
  if found then
    update public.waste_items
       set price = round(r.unit_price, 2), price_date = r.doc_date, price_src = 'faktura · ' || r.supplier_name
     where id = iid;
  end if;
end $$;
revoke execute on function public.fc_refresh_price(uuid) from public, anon, authenticated;

create or replace function public.fc_lines_price_trg()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' or (tg_op = 'UPDATE' and old.item_id is distinct from new.item_id) then
    perform public.fc_refresh_price(old.item_id);
  end if;
  if tg_op <> 'DELETE' then perform public.fc_refresh_price(new.item_id); end if;
  return coalesce(new, old);
end $$;
revoke execute on function public.fc_lines_price_trg() from public, anon, authenticated;
drop trigger if exists fc_lines_price on public.fc_invoice_lines;
create trigger fc_lines_price after insert or update or delete on public.fc_invoice_lines
  for each row execute function public.fc_lines_price_trg();

-- promena datuma fakture menja i redosled cena
create or replace function public.fc_inv_price_trg()
returns trigger language plpgsql security definer set search_path = public as $$
declare x uuid;
begin
  if new.doc_date is distinct from old.doc_date then
    for x in select distinct item_id from public.fc_invoice_lines where invoice_id = new.id and item_id is not null loop
      perform public.fc_refresh_price(x);
    end loop;
  end if;
  return new;
end $$;
revoke execute on function public.fc_inv_price_trg() from public, anon, authenticated;
drop trigger if exists fc_inv_price on public.fc_invoices;
create trigger fc_inv_price after update on public.fc_invoices
  for each row execute function public.fc_inv_price_trg();

-- ---------- Popis ----------
create table if not exists public.fc_counts (
  id              uuid primary key default gen_random_uuid(),
  count_date      date not null unique,       -- dan posle čijeg zatvaranja je popis rađen
  kind            text not null default 'nedeljni' check (kind in ('nedeljni','mesecni')),
  closed          boolean not null default false,
  closed_at       timestamptz,
  closed_by_name  text,
  note            text,
  created_by      uuid default auth.uid() references auth.users(id),
  created_at      timestamptz not null default now()
);

create table if not exists public.fc_count_lines (
  count_id    uuid not null references public.fc_counts(id) on delete cascade,
  item_id     uuid not null references public.waste_items(id) on delete cascade,
  stage       text not null default 'sirovo' check (stage in ('sirovo','smoker','gotovo')),
  qty         numeric not null check (qty >= 0),
  unit_cost   numeric,                        -- upisuje se pri zaključavanju
  carried     boolean not null default false, -- nije brojano, preuzeto iz prethodnog popisa
  counted_by  text,
  updated_at  timestamptz not null default now(),
  primary key (count_id, item_id, stage)
);

create or replace function public.fc_count_open(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.fc_counts where id = cid and not closed);
$$;

-- vrednost jedinice za popis: sirovo i u smokeru po nabavnoj ceni, gotovo dimljeno meso po stvarnoj ceni iz yield loga (60 dana)
create or replace function public.fc_unit_cost(iid uuid, st text, d date)
returns numeric language sql stable security definer set search_path = public as $$
  select case
    when st = 'gotovo' and i.smoked_product_id is not null then coalesce((
      select round(sum(c.raw_kg * c.price_per_kg) / nullif(sum(coalesce(c.sellable_kg, c.cooked_kg)), 0), 2)
        from public.cooks c
       where c.product_id = i.smoked_product_id and c.price_per_kg is not null
         and c.cook_date between d - 60 and d), i.price)
    else i.price end
  from public.waste_items i where i.id = iid;
$$;

-- zaključavanje: nebrojane stavke preuzimaju količinu iz prethodnog popisa (osim mesa u smokeru), upisuju se cene
create or replace function public.fc_close_count(cid uuid, who text default null)
returns text language plpgsql security definer set search_path = public as $$
declare c public.fc_counts%rowtype; prev uuid; n int := 0;
begin
  if not public.is_mc() then raise exception 'nema pravo' using errcode = '42501'; end if;
  select * into c from public.fc_counts where id = cid for update;
  if not found then raise exception 'popis ne postoji'; end if;
  if c.closed then return 'već zaključen'; end if;
  select id into prev from public.fc_counts where closed and count_date < c.count_date order by count_date desc limit 1;
  if prev is not null then
    insert into public.fc_count_lines (count_id, item_id, stage, qty, carried)
    select cid, p.item_id, p.stage, p.qty, true
      from public.fc_count_lines p join public.waste_items i on i.id = p.item_id
     where p.count_id = prev and p.stage <> 'smoker' and p.qty > 0 and i.active
       and not exists (select 1 from public.fc_count_lines x where x.count_id = cid and x.item_id = p.item_id and x.stage = p.stage);
    get diagnostics n = row_count;
  end if;
  update public.fc_count_lines set unit_cost = public.fc_unit_cost(item_id, stage, c.count_date) where count_id = cid;
  update public.fc_counts set closed = true, closed_at = now(),
         closed_by_name = coalesce(who, (select full_name from public.profiles where id = auth.uid()))
   where id = cid;
  return 'zaključen, preuzeto ' || n;
end $$;
revoke execute on function public.fc_close_count(uuid, text) from public, anon;
grant execute on function public.fc_close_count(uuid, text) to authenticated;

-- ponovno otvaranje (samo administrator): brišu se preuzete stavke i cene
create or replace function public.fc_reopen_count(cid uuid)
returns text language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'samo administrator' using errcode = '42501'; end if;
  delete from public.fc_count_lines where count_id = cid and carried;
  update public.fc_count_lines set unit_cost = null where count_id = cid;
  update public.fc_counts set closed = false, closed_at = null, closed_by_name = null where id = cid;
  return 'otvoren';
end $$;
revoke execute on function public.fc_reopen_count(uuid) from public, anon;
grant execute on function public.fc_reopen_count(uuid) to authenticated;

-- ---------- Pravila pristupa ----------
alter table public.fc_invoices      enable row level security;
alter table public.fc_invoice_lines enable row level security;
alter table public.fc_map           enable row level security;
alter table public.fc_counts        enable row level security;
alter table public.fc_count_lines   enable row level security;

drop policy if exists "fakture: uprava" on public.fc_invoices;
create policy "fakture: uprava" on public.fc_invoices for all to authenticated
  using (public.is_mc()) with check (public.is_mc());
drop policy if exists "stavke faktura: uprava" on public.fc_invoice_lines;
create policy "stavke faktura: uprava" on public.fc_invoice_lines for all to authenticated
  using (public.is_mc()) with check (public.is_mc());
drop policy if exists "veze: uprava" on public.fc_map;
create policy "veze: uprava" on public.fc_map for all to authenticated
  using (public.is_mc()) with check (public.is_mc());

drop policy if exists "popis: čita uprava" on public.fc_counts;
create policy "popis: čita uprava" on public.fc_counts for select to authenticated using (public.is_mc());
drop policy if exists "popis: otvara uprava" on public.fc_counts;
create policy "popis: otvara uprava" on public.fc_counts for insert to authenticated
  with check (public.is_mc() and not closed);
drop policy if exists "popis: menja otvoren" on public.fc_counts;
create policy "popis: menja otvoren" on public.fc_counts for update to authenticated
  using (public.is_admin() or (public.is_mc() and not closed))
  with check (public.is_admin() or (public.is_mc() and not closed));
drop policy if exists "popis: briše" on public.fc_counts;
create policy "popis: briše" on public.fc_counts for delete to authenticated
  using (public.is_admin() or (public.is_mc() and not closed));

drop policy if exists "stavke popisa: čita uprava" on public.fc_count_lines;
create policy "stavke popisa: čita uprava" on public.fc_count_lines for select to authenticated using (public.is_mc());
drop policy if exists "stavke popisa: upis u otvoren" on public.fc_count_lines;
create policy "stavke popisa: upis u otvoren" on public.fc_count_lines for all to authenticated
  using (public.is_admin() or (public.is_mc() and public.fc_count_open(count_id)))
  with check (public.is_admin() or (public.is_mc() and public.fc_count_open(count_id)));

-- menadžer i šef smene mogu da dodaju namirnicu bez cene (iz fakture); cenu upisuje faktura
-- (pravilo „namirnice: šef dodaje bez cene“ iz izmene 09 već to dozvoljava, is_sef uključuje menadžera)

do $$ begin alter publication supabase_realtime add table public.fc_invoices;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.fc_invoice_lines;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.fc_counts;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.fc_count_lines;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ---------- Obračun za period između dva zaključena popisa (isto kao na sajtu) ----------
create or replace function public.fc_summary(cid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  b public.fc_counts%rowtype; a public.fc_counts%rowtype;
  k numeric := 1 + coalesce(((select data from public.mc_settings where id = 1)->>'pdv')::numeric, 20) / 100;
  fct numeric := (select case when jsonb_typeof(value) = 'number' then (value)::text::numeric end from public.app_settings where key = 'fc_target');
  bvt numeric := ((select data from public.mc_settings where id = 1)->>'bevTarget')::numeric;
  food numeric; drink numeric; res jsonb := '{}'::jsonb; ar text; o numeric; p numeric; c numeric; u numeric; w numeric; s numeric;
  tot_o numeric := 0; tot_p numeric := 0; tot_c numeric := 0;
begin
  select * into b from public.fc_counts where id = cid and closed;
  if not found then return null; end if;
  select * into a from public.fc_counts where closed and count_date < b.count_date order by count_date desc limit 1;
  if not found then return jsonb_build_object('to', b.count_date, 'no_prev', true); end if;

  select coalesce(sum((select coalesce(sum(coalesce((v->>'f')::numeric,0)),0) from jsonb_each(x.channels) e(kk,v))),0) / k,
         coalesce(sum((select coalesce(sum(coalesce((v->>'d')::numeric,0)),0) from jsonb_each(x.channels) e(kk,v))),0) / k
    into food, drink
    from public.mc_sales x where x.day > a.count_date and x.day <= b.count_date and not x.closed;

  foreach ar in array array['kuhinja','sank','nepovezano'] loop
    select coalesce(sum(l.qty * coalesce(l.unit_cost, public.fc_unit_cost(l.item_id, l.stage, a.count_date), 0)),0) into o
      from public.fc_count_lines l join public.waste_items i on i.id = l.item_id where l.count_id = a.id and i.area = ar;
    select coalesce(sum(l.qty * coalesce(l.unit_cost, public.fc_unit_cost(l.item_id, l.stage, b.count_date), 0)),0) into c
      from public.fc_count_lines l join public.waste_items i on i.id = l.item_id where l.count_id = b.id and i.area = ar;
    select coalesce(sum(l.net),0) into p
      from public.fc_invoice_lines l join public.fc_invoices v on v.id = l.invoice_id
      left join public.waste_items i on i.id = l.item_id
     where v.doc_date > a.count_date and v.doc_date <= b.count_date and not l.ignore
       and coalesce(i.area, 'nepovezano') = ar;
    select coalesce(sum(w2.value_rsd),0) into w
      from public.waste w2 join public.waste_items i on i.id = w2.item_id
     where w2.waste_date > a.count_date and w2.waste_date <= b.count_date and i.area = ar;
    u := o + p - c;
    s := case ar when 'kuhinja' then food when 'sank' then drink else null end;
    tot_o := tot_o + o; tot_p := tot_p + p; tot_c := tot_c + c;
    res := res || jsonb_build_object(ar, jsonb_build_object('open', round(o), 'purchases', round(p), 'close', round(c),
             'used', round(u), 'waste', round(w), 'sales', round(s),
             'pct', case when s > 0 then round(u / s * 100, 1) end));
  end loop;

  return jsonb_build_object(
    'from', a.count_date + 1, 'to', b.count_date, 'from_count', a.count_date, 'kind', b.kind,
    'food_target', fct, 'bev_target', bvt,
    'net', round(food + drink), 'food_net', round(food), 'drink_net', round(drink),
    'open', round(tot_o), 'purchases', round(tot_p), 'close', round(tot_c), 'used', round(tot_o + tot_p - tot_c),
    'total_pct', case when food + drink > 0 then round((tot_o + tot_p - tot_c) / (food + drink) * 100, 1) end,
    'areas', res,
    'unmapped', jsonb_build_object(
      'lines', (select count(*) from public.fc_invoice_lines l join public.fc_invoices v on v.id = l.invoice_id
                 where v.doc_date > a.count_date and v.doc_date <= b.count_date and not l.ignore and l.item_id is null),
      'net', (select round(coalesce(sum(l.net),0)) from public.fc_invoice_lines l join public.fc_invoices v on v.id = l.invoice_id
                 where v.doc_date > a.count_date and v.doc_date <= b.count_date and not l.ignore and l.item_id is null)),
    'no_price', (select coalesce(jsonb_agg(distinct i.name), '[]'::jsonb) from public.fc_count_lines l join public.waste_items i on i.id = l.item_id
                  where l.count_id in (a.id, b.id) and l.qty > 0 and l.unit_cost is null
                    and public.fc_unit_cost(l.item_id, l.stage, (select count_date from public.fc_counts where id = l.count_id)) is null),
    'carried', (select count(*) from public.fc_count_lines where count_id = b.id and carried),
    'missing_sales', (select coalesce(jsonb_agg(g::date order by g), '[]'::jsonb)
                        from generate_series(a.count_date + 1, b.count_date, interval '1 day') g
                       where not exists (select 1 from public.mc_sales x where x.day = g::date)),
    'top', (select coalesce(jsonb_agg(t order by t.used desc), '[]'::jsonb) from (
              select i.name, i.area, i.unit,
                     round(coalesce(oa.q,0) + coalesce(pp.q,0) - coalesce(cb.q,0), 2) as qty,
                     round(coalesce(oa.v,0) + coalesce(pp.v,0) - coalesce(cb.v,0)) as used
                from public.waste_items i
                left join (select item_id, sum(qty) q, sum(qty*coalesce(unit_cost, public.fc_unit_cost(item_id, stage, a.count_date), 0)) v from public.fc_count_lines where count_id = a.id group by 1) oa on oa.item_id = i.id
                left join (select item_id, sum(qty) q, sum(qty*coalesce(unit_cost, public.fc_unit_cost(item_id, stage, b.count_date), 0)) v from public.fc_count_lines where count_id = b.id group by 1) cb on cb.item_id = i.id
                left join (select l.item_id, sum(l.item_qty) q, sum(l.net) v from public.fc_invoice_lines l join public.fc_invoices v on v.id = l.invoice_id
                            where v.doc_date > a.count_date and v.doc_date <= b.count_date and not l.ignore and l.item_id is not null group by 1) pp on pp.item_id = i.id
               where oa.item_id is not null or cb.item_id is not null or pp.item_id is not null
               order by 5 desc limit 8) t)
  );
end $$;
revoke execute on function public.fc_summary(uuid) from public, anon, authenticated;

-- skokovi cena u periodu (≥ 5 % u odnosu na prethodnu fakturu za istu namirnicu)
create or replace function public.fc_price_jumps(a date, b date)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.pct desc), '[]'::jsonb) from (
    select i.name, i.unit, s.supplier_name as supplier, s.doc_date as date,
           round(s.prev_price, 2) as old, round(s.unit_price, 2) as new,
           round((s.unit_price / s.prev_price - 1) * 100, 1) as pct
      from (
        select l.item_id, l.unit_price, v.doc_date, v.supplier_name,
               lag(l.unit_price) over (partition by l.item_id order by v.doc_date, v.created_at, l.pos) as prev_price
          from public.fc_invoice_lines l join public.fc_invoices v on v.id = l.invoice_id
         where l.item_id is not null and not l.ignore and l.qty > 0 and l.net > 0
      ) s join public.waste_items i on i.id = s.item_id
     where s.doc_date between a and b and s.prev_price > 0 and s.unit_price >= s.prev_price * 1.05
  ) x;
$$;
revoke execute on function public.fc_price_jumps(date, date) from public, anon, authenticated;

-- ---------- Nedeljni mejl: labor + food cost ----------
-- Food cost ide iz poslednjeg zaključenog popisa iz prošle nedelje (popis se radi u noći sa nedelje na ponedeljak).
create or replace function public.mc_reports_send(force text default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  lokalno timestamp := now() at time zone 'Europe/Belgrade';
  danas date := lokalno::date;
  juce date := danas - 1;
  hook text; out text := '';
  ima_rad boolean := exists (select 1 from public.mc_staff);
  ima_fc boolean := exists (select 1 from public.fc_counts);
  poslednji public.fc_counts%rowtype; fc jsonb;
begin
  select value into hook from private.integrations where key = 'sheets_webhook';
  if hook is null then return 'nema veze'; end if;
  if not ima_rad and not ima_fc and force is null then return 'nema podataka'; end if;

  if ima_rad and (force = 'dnevni' or (force is null and extract(hour from lokalno) = 9
      and not exists (select 1 from private.sent_reports where kind = 'mc_dnevni' and day = danas))) then
    perform net.http_post(url := hook,
      body := jsonb_build_object('kind', 'mc_daily',
        'day', public.mc_labor_summary(juce, juce),
        'mtd', public.mc_labor_summary(date_trunc('month', juce)::date, juce)),
      headers := '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds := 30000);
    if force is null then insert into private.sent_reports (kind, day) values ('mc_dnevni', danas) on conflict do nothing; end if;
    out := out || 'dnevni poslat ';
  end if;

  if force = 'nedeljni' or (force is null and extract(hour from lokalno) = 9 and extract(isodow from danas) = 1
      and not exists (select 1 from private.sent_reports where kind = 'mc_nedeljni' and day = danas)) then
    if ima_fc then
      select * into poslednji from public.fc_counts where closed and count_date between danas - 8 and danas order by count_date desc limit 1;
      if found then
        fc := coalesce(public.fc_summary(poslednji.id), '{}'::jsonb);
      else
        fc := jsonb_build_object('missing', true,
          'open_count', (select count_date from public.fc_counts where not closed order by count_date desc limit 1),
          'last', (select max(count_date) from public.fc_counts where closed));
      end if;
      fc := fc || jsonb_build_object('week_from', danas - 7, 'week_to', danas - 1,
        'price_jumps', public.fc_price_jumps(danas - 7, danas - 1),
        'week_purchases', (select round(coalesce(sum(l.net),0)) from public.fc_invoice_lines l join public.fc_invoices v on v.id = l.invoice_id
                            where v.doc_date between danas - 7 and danas - 1 and not l.ignore),
        'week_invoices', (select count(*) from public.fc_invoices where doc_date between danas - 7 and danas - 1));
    end if;
    perform net.http_post(url := hook,
      body := jsonb_build_object('kind', 'mc_weekly',
        'week', case when ima_rad then public.mc_labor_summary(danas - 7, danas - 1) end,
        'prev', case when ima_rad then public.mc_labor_summary(danas - 14, danas - 8) end,
        'fc', fc),
      headers := '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds := 30000);
    if force is null then insert into private.sent_reports (kind, day) values ('mc_nedeljni', danas) on conflict do nothing; end if;
    out := out || 'nedeljni poslat';
  end if;
  return coalesce(nullif(out,''), 'ništa za slanje');
end $$;
revoke execute on function public.mc_reports_send(text) from public, anon, authenticated;
