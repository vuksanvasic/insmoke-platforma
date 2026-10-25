-- =====================================================================
-- Izmena 13: TEORIJSKI FOOD COST — prodaja po artiklima i poređenje
--   · uvoz prodaje po artiklima iz POS-a (Excel/CSV iz bMaster-a) ili ručni unos
--   · artikal sa POS-a se povezuje sa jelom iz normativa (ili direktno sa namirnicom, npr. piće)
--   · veza se pamti, sledeći uvoz se poveže sam
--   · teorijski utrošak = prodato × normativ; poređenje sa stvarnim utroškom iz popisa
--   · vide i unose: administrator, menadžer, šef smene
-- Može da se pokrene više puta bez štete. Pokreće se posle izmene 12.
-- =====================================================================

create table if not exists public.fc_sales_imports (
  id              uuid primary key default gen_random_uuid(),
  date_from       date not null,
  date_to         date not null,
  source          text not null default 'fajl' check (source in ('fajl','rucno')),
  file_name       text,
  note            text,
  created_by      uuid default auth.uid() references auth.users(id),
  created_by_name text,
  created_at      timestamptz not null default now(),
  constraint fc_sales_period check (date_to >= date_from)
);
create index if not exists fc_sales_imports_idx on public.fc_sales_imports (date_to desc);

create table if not exists public.fc_sales_lines (
  id         uuid primary key default gen_random_uuid(),
  import_id  uuid not null references public.fc_sales_imports(id) on delete cascade,
  pos        int not null default 0,
  pos_code   text,
  pos_name   text not null,
  qty        numeric not null,
  amount     numeric,                                                      -- iznos sa POS-a (informativno)
  dish_id    uuid references public.dishes(id) on delete set null,         -- jelo iz normativa
  item_id    uuid references public.waste_items(id) on delete set null,    -- ili direktno namirnica (piće)
  ignore     boolean not null default false,                               -- ne ulazi u teorijski trošak
  factor     numeric not null default 1 check (factor > 0)                 -- porcija (ili jedinica) po prodatom komadu
);
create index if not exists fc_sales_lines_imp_idx on public.fc_sales_lines (import_id);

create table if not exists public.fc_pos_map (
  pos_key    text primary key,
  dish_id    uuid references public.dishes(id) on delete cascade,
  item_id    uuid references public.waste_items(id) on delete cascade,
  ignore     boolean not null default false,
  factor     numeric not null default 1 check (factor > 0),
  updated_at timestamptz not null default now()
);

alter table public.fc_sales_imports enable row level security;
alter table public.fc_sales_lines   enable row level security;
alter table public.fc_pos_map       enable row level security;

drop policy if exists "prodaja: uprava" on public.fc_sales_imports;
create policy "prodaja: uprava" on public.fc_sales_imports for all to authenticated
  using (public.is_mc()) with check (public.is_mc());
drop policy if exists "stavke prodaje: uprava" on public.fc_sales_lines;
create policy "stavke prodaje: uprava" on public.fc_sales_lines for all to authenticated
  using (public.is_mc()) with check (public.is_mc());
drop policy if exists "pos veze: uprava" on public.fc_pos_map;
create policy "pos veze: uprava" on public.fc_pos_map for all to authenticated
  using (public.is_mc()) with check (public.is_mc());

do $$ begin alter publication supabase_realtime add table public.fc_sales_imports;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.fc_sales_lines;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ---------- Gotovo dimljeno meso bez ciklusa sa cenom u yield logu: nabavna ÷ ciljni yield (umesto cene sirovog) ----------
create or replace function public.fc_unit_cost(iid uuid, st text, d date)
returns numeric language sql stable security definer set search_path = public as $$
  select case
    when st = 'gotovo' and i.smoked_product_id is not null then coalesce((
      select round(sum(c.raw_kg * c.price_per_kg) / nullif(sum(coalesce(c.sellable_kg, c.cooked_kg)), 0), 2)
        from public.cooks c
       where c.product_id = i.smoked_product_id and c.price_per_kg is not null
         and c.cook_date between d - 60 and d),
      round(i.price / nullif((select p.target_yield from public.products p where p.id = i.smoked_product_id), 0) * 100, 2),
      i.price)
    else i.price end
  from public.waste_items i where i.id = iid;
$$;

-- ---------- Poređenje stvarno / teorijski za period između dva zaključena popisa (isto kao na sajtu) ----------
-- Teorijska cena jedinice: dimljeno meso po stvarnoj ceni gotovog mesa (normativ je gotovo meso), ostalo po nabavnoj.
create or replace function public.fc_theory(cid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  b public.fc_counts%rowtype; a public.fc_counts%rowtype;
  k numeric := 1 + coalesce(((select data from public.mc_settings where id = 1)->>'pdv')::numeric, 20) / 100;
  food numeric; drink numeric; covered int; days int;
  res jsonb;
begin
  select * into b from public.fc_counts where id = cid and closed;
  if not found then return null; end if;
  select * into a from public.fc_counts where closed and count_date < b.count_date order by count_date desc limit 1;
  if not found then return null; end if;
  if not exists (select 1 from public.fc_sales_imports where date_from > a.count_date and date_to <= b.count_date) then
    return jsonb_build_object('no_sales', true);
  end if;

  select coalesce(sum((select coalesce(sum(coalesce((v->>'f')::numeric,0)),0) from jsonb_each(x.channels) e(kk,v))),0) / k,
         coalesce(sum((select coalesce(sum(coalesce((v->>'d')::numeric,0)),0) from jsonb_each(x.channels) e(kk,v))),0) / k
    into food, drink
    from public.mc_sales x where x.day > a.count_date and x.day <= b.count_date and not x.closed;

  days := b.count_date - a.count_date;
  select count(distinct g::date) into covered
    from public.fc_sales_imports i, generate_series(i.date_from, i.date_to, interval '1 day') g
   where i.date_from > a.count_date and i.date_to <= b.count_date;

  with
  sl as (
    select l.* from public.fc_sales_lines l join public.fc_sales_imports i on i.id = l.import_id
     where i.date_from > a.count_date and i.date_to <= b.count_date and not l.ignore
  ),
  tq as (   -- teorijska količina po namirnici
    select dl.item_id, sum(sl.qty * sl.factor * dl.qty) q
      from sl join public.dish_lines dl on dl.dish_id = sl.dish_id
     where sl.dish_id is not null group by 1
    union all
    select sl.item_id, sum(sl.qty * sl.factor) from sl where sl.dish_id is null and sl.item_id is not null group by 1
  ),
  th as (
    select item_id, sum(q) q from tq group by 1
  ),
  act as (  -- stvarni utrošak po namirnici (isto kao fc_summary)
    select i.id item_id,
           coalesce(oa.v,0) + coalesce(pp.v,0) - coalesce(cb.v,0) v
      from public.waste_items i
      left join (select item_id, sum(qty*coalesce(unit_cost, public.fc_unit_cost(item_id, stage, a.count_date), 0)) v from public.fc_count_lines where count_id = a.id group by 1) oa on oa.item_id = i.id
      left join (select item_id, sum(qty*coalesce(unit_cost, public.fc_unit_cost(item_id, stage, b.count_date), 0)) v from public.fc_count_lines where count_id = b.id group by 1) cb on cb.item_id = i.id
      left join (select l.item_id, sum(l.net) v from public.fc_invoice_lines l join public.fc_invoices v on v.id = l.invoice_id
                  where v.doc_date > a.count_date and v.doc_date <= b.count_date and not l.ignore and l.item_id is not null group by 1) pp on pp.item_id = i.id
     where oa.item_id is not null or cb.item_id is not null or pp.item_id is not null
  ),
  wst as (
    select w.item_id, sum(w.value_rsd) v from public.waste w
     where w.waste_date > a.count_date and w.waste_date <= b.count_date group by 1
  ),
  per as (
    select i.id, i.name, i.area, i.unit,
           coalesce(th.q,0) tq,
           coalesce(th.q,0) * coalesce(public.fc_unit_cost(i.id, case when i.smoked_product_id is not null then 'gotovo' else 'sirovo' end, b.count_date), 0) tv,
           coalesce(act.v,0) av, coalesce(wst.v,0) wv,
           th.q is not null and public.fc_unit_cost(i.id, case when i.smoked_product_id is not null then 'gotovo' else 'sirovo' end, b.count_date) is null no_price
      from public.waste_items i
      left join th on th.item_id = i.id
      left join act on act.item_id = i.id
      left join wst on wst.item_id = i.id
     where th.item_id is not null or act.item_id is not null
  )
  select jsonb_build_object(
    'food_net', round(food), 'drink_net', round(drink), 'days', days, 'covered_days', covered,
    'kuhinja', jsonb_build_object('theory', round(coalesce(sum(tv) filter (where area='kuhinja'),0)), 'actual', round(coalesce(sum(av) filter (where area='kuhinja'),0)),
               'theory_pct', case when food > 0 then round(coalesce(sum(tv) filter (where area='kuhinja'),0) / food * 100, 1) end),
    'sank', jsonb_build_object('theory', round(coalesce(sum(tv) filter (where area='sank'),0)), 'actual', round(coalesce(sum(av) filter (where area='sank'),0)),
               'theory_pct', case when drink > 0 then round(coalesce(sum(tv) filter (where area='sank'),0) / drink * 100, 1) end),
    'over', (select coalesce(jsonb_agg(x order by x.diff desc), '[]'::jsonb) from (
               select name, area, unit, round(tv) theory, round(av) actual, round(av - tv) diff, round(wv) waste
                 from per where av - tv > 0 order by av - tv desc limit 6) x),
    'no_price', (select coalesce(jsonb_agg(name order by name), '[]'::jsonb) from per where no_price),
    'unmapped', (select count(*) from public.fc_sales_lines l join public.fc_sales_imports i on i.id = l.import_id
                  where i.date_from > a.count_date and i.date_to <= b.count_date and not l.ignore and l.dish_id is null and l.item_id is null),
    'no_recipe', (select coalesce(jsonb_agg(distinct d.name), '[]'::jsonb) from public.fc_sales_lines l join public.fc_sales_imports i on i.id = l.import_id
                   join public.dishes d on d.id = l.dish_id
                  where i.date_from > a.count_date and i.date_to <= b.count_date and not l.ignore
                    and not exists (select 1 from public.dish_lines x where x.dish_id = d.id))
  ) into res from per;
  return res;
end $$;
revoke execute on function public.fc_theory(uuid) from public, anon, authenticated;

-- fc_summary dobija i teorijski deo (za nedeljni mejl)
create or replace function public.fc_summary_full(cid uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select public.fc_summary(cid) || coalesce(jsonb_build_object('theory', public.fc_theory(cid)), '{}'::jsonb);
$$;
revoke execute on function public.fc_summary_full(uuid) from public, anon, authenticated;

-- ---------- Nedeljni mejl: labor + food cost + teorijski (zamenjuje verziju iz izmene 12) ----------
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
        fc := coalesce(public.fc_summary_full(poslednji.id), '{}'::jsonb);
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
