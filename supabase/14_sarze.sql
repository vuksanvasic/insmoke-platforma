-- =====================================================================
-- Izmena 14: NORMATIVI U MANAGEMENT CONTROL-U — šarže (osnovne pripreme)
--   · namirnica može biti ŠARŽA: džem od luka, BBQ sos, coleslaw, rub…
--   · šarža ima sastojke (prep_lines), izlaz (koliko gotovog se dobije) i postupak
--   · cena šarže = zbir sastojaka ÷ izlaz; računa se sama i prati promene cena sastojaka
--   · jela u normativu mogu da koriste šarže, sirovine i dimljeno meso
--   · teorijski food cost razlaže šarže na sirovine (da se poredi sa fakturama)
--   · menjaju: šef smene, menadžer i administrator (preko funkcija ispod)
-- Može da se pokrene više puta bez štete. Pokreće se posle izmene 13.
-- =====================================================================

alter table public.waste_items add column if not exists is_prep   boolean not null default false;
alter table public.waste_items add column if not exists batch_out numeric;
alter table public.waste_items add column if not exists method    text;
alter table public.waste_items drop constraint if exists waste_items_batch_out_check;
alter table public.waste_items add constraint waste_items_batch_out_check check (batch_out is null or batch_out > 0);

create table if not exists public.prep_lines (
  id       uuid primary key default gen_random_uuid(),
  prep_id  uuid not null references public.waste_items(id) on delete cascade,
  item_id  uuid not null references public.waste_items(id),
  qty      numeric not null check (qty > 0),           -- u jedinici sastojka, za CELU šaržu
  note     text,
  sort     int not null default 0,
  constraint prep_lines_self check (prep_id <> item_id)
);
create index if not exists prep_lines_prep_idx on public.prep_lines (prep_id);
create index if not exists prep_lines_item_idx on public.prep_lines (item_id);

alter table public.prep_lines enable row level security;
drop policy if exists "šarže: čitaju članovi" on public.prep_lines;
create policy "šarže: čitaju članovi" on public.prep_lines for select to authenticated using (public.is_member());
-- upis samo preko prep_save (provera kruga i preračun cene)

do $$ begin alter publication supabase_realtime add table public.prep_lines;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ---------- Cena jedinice (šarža: iz sastojaka; dimljeno meso: gotovo; ostalo: nabavna) ----------
create or replace function public.prep_unit_cost(iid uuid, depth int default 0)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare it public.waste_items%rowtype; total numeric := 0; c numeric; r record; n int := 0;
begin
  select * into it from public.waste_items where id = iid;
  if not found then return null; end if;
  if not it.is_prep then
    if it.smoked_product_id is not null then return public.fc_unit_cost(iid, 'gotovo', current_date); end if;
    return it.price;
  end if;
  if depth > 6 or it.batch_out is null then return null; end if;
  for r in select item_id, qty from public.prep_lines where prep_id = iid loop
    c := public.prep_unit_cost(r.item_id, depth + 1);
    if c is null then return null; end if;   -- sastojak bez cene: cena šarže nije poznata
    total := total + r.qty * c; n := n + 1;
  end loop;
  if n = 0 then return null; end if;
  return round(total / it.batch_out, 2);
end $$;
revoke execute on function public.prep_unit_cost(uuid, int) from public, anon;
grant execute on function public.prep_unit_cost(uuid, int) to authenticated;

create or replace function public.prep_recalc(iid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c numeric;
begin
  if not exists (select 1 from public.waste_items where id = iid and is_prep) then return; end if;
  c := public.prep_unit_cost(iid);
  update public.waste_items set price = c, price_date = current_date, price_src = 'šarža'
   where id = iid and is_prep and (price is distinct from c or price_src is distinct from 'šarža');
end $$;
revoke execute on function public.prep_recalc(uuid) from public, anon, authenticated;

-- promena cene sastojka → preračun šarži koje ga koriste (i dalje uz lanac)
create or replace function public.prep_items_trg()
returns trigger language plpgsql security definer set search_path = public as $$
declare p uuid;
begin
  if pg_trigger_depth() > 8 then return new; end if;
  if new.is_prep and (new.batch_out is distinct from old.batch_out or new.is_prep is distinct from old.is_prep) then
    perform public.prep_recalc(new.id);
  end if;
  if new.price is distinct from old.price then
    for p in select distinct prep_id from public.prep_lines where item_id = new.id loop
      perform public.prep_recalc(p);
    end loop;
  end if;
  return new;
end $$;
revoke execute on function public.prep_items_trg() from public, anon, authenticated;
drop trigger if exists prep_items on public.waste_items;
create trigger prep_items after update of price, batch_out, is_prep on public.waste_items
  for each row execute function public.prep_items_trg();

-- cena iz fakture ne prepisuje cenu šarže
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
     where id = iid and not is_prep;
  end if;
end $$;
revoke execute on function public.fc_refresh_price(uuid) from public, anon, authenticated;

-- ---------- Upis šarže: izlaz, postupak i svi sastojci odjednom ----------
create or replace function public.prep_save(p_item uuid, p_batch_out numeric, p_method text, p_lines jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare x jsonb; i int := 0;
begin
  if not public.is_sef() then raise exception 'Nemaš pravo da menjaš normative.'; end if;
  if not exists (select 1 from public.waste_items where id = p_item) then raise exception 'Šarža ne postoji.'; end if;
  if p_batch_out is not null and p_batch_out <= 0 then raise exception 'Izlaz šarže mora biti veći od nule.'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e
              where (e->>'item') is null or coalesce((e->>'qty')::numeric, 0) <= 0) then
    raise exception 'Svaki sastojak mora imati količinu veću od nule.';
  end if;
  if exists (
    with recursive t(id, d) as (
      select (e->>'item')::uuid, 1 from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e
      union
      select pl.item_id, t.d + 1 from t join public.prep_lines pl on pl.prep_id = t.id
       where t.d < 10 and t.id <> p_item
    ) select 1 from t where id = p_item) then
    raise exception 'Šarža ne može da sadrži samu sebe (ni preko druge šarže).';
  end if;
  delete from public.prep_lines where prep_id = p_item;
  for x in select * from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) loop
    i := i + 1;
    insert into public.prep_lines (prep_id, item_id, qty, note, sort)
    values (p_item, (x->>'item')::uuid, (x->>'qty')::numeric, nullif(trim(x->>'note'),''), i);
  end loop;
  update public.waste_items set is_prep = true, batch_out = p_batch_out, method = nullif(trim(p_method),'') where id = p_item;
  perform public.prep_recalc(p_item);
end $$;
revoke execute on function public.prep_save(uuid, numeric, text, jsonb) from public, anon;
grant execute on function public.prep_save(uuid, numeric, text, jsonb) to authenticated;

-- nova šarža (ili postojeća namirnica postaje šarža)
create or replace function public.prep_new(p_name text, p_unit text, p_grp text default 'Pripreme', p_area text default 'kuhinja')
returns uuid language plpgsql security definer set search_path = public as $$
declare iid uuid; nm text := regexp_replace(trim(coalesce(p_name,'')), '\s+', ' ', 'g');
begin
  if not public.is_sef() then raise exception 'Nemaš pravo da menjaš normative.'; end if;
  if length(nm) < 2 then raise exception 'Upiši naziv šarže.'; end if;
  select id into iid from public.waste_items where lower(name) = lower(nm);
  if iid is not null then
    update public.waste_items set is_prep = true, active = true where id = iid;
    return iid;
  end if;
  if p_unit not in ('kg','l','kom','porcija') then raise exception 'Nepoznata jedinica.'; end if;
  insert into public.waste_items (name, area, grp, unit, is_prep, sort)
  values (nm, coalesce(nullif(p_area,''),'kuhinja'), coalesce(nullif(trim(p_grp),''),'Pripreme'), p_unit, true, 700)
  returning id into iid;
  return iid;
end $$;
revoke execute on function public.prep_new(text, text, text, text) from public, anon;
grant execute on function public.prep_new(text, text, text, text) to authenticated;

-- šarža ponovo postaje obična namirnica (sastojci se brišu, cena ostaje poslednja izračunata)
create or replace function public.prep_unset(p_item uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_sef() then raise exception 'Nemaš pravo da menjaš normative.'; end if;
  delete from public.prep_lines where prep_id = p_item;
  update public.waste_items set is_prep = false, batch_out = null,
         price_src = case when price_src = 'šarža' then 'ručno' else price_src end
   where id = p_item;
end $$;
revoke execute on function public.prep_unset(uuid) from public, anon;
grant execute on function public.prep_unset(uuid) to authenticated;

-- ---------- Normativ jela: svi sastojci odjednom ----------
create or replace function public.dish_lines_save(p_dish uuid, p_lines jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare x jsonb; i int := 0;
begin
  if not public.is_sef() then raise exception 'Nemaš pravo da menjaš normative.'; end if;
  if not exists (select 1 from public.dishes where id = p_dish) then raise exception 'Jelo ne postoji.'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e
              where (e->>'item') is null or coalesce((e->>'qty')::numeric, 0) <= 0) then
    raise exception 'Svaki sastojak mora imati količinu veću od nule.';
  end if;
  delete from public.dish_lines where dish_id = p_dish;
  for x in select * from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) loop
    i := i + 1;
    insert into public.dish_lines (dish_id, item_id, qty, note, sort)
    values (p_dish, (x->>'item')::uuid, (x->>'qty')::numeric, nullif(trim(x->>'note'),''), i);
  end loop;
end $$;
revoke execute on function public.dish_lines_save(uuid, jsonb) from public, anon;
grant execute on function public.dish_lines_save(uuid, jsonb) to authenticated;

-- ---------- Pripreme sa menija postaju šarže (samo one bez ručno upisane cene) ----------
update public.waste_items set is_prep = true
 where not is_prep and price is null
   and name in ('Coleslaw salata','BBQ pasulj','Marinirani crveni luk','Marinirani halapenjo','Džem od luka',
                'Domaći BBQ sos','Specijalni burger sos','Domaći hleb');

-- ---------- Teorijski food cost: šarže se razlažu na sirovine (zamenjuje verziju iz izmene 13) ----------
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

  with recursive
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
  th0 as (
    select item_id, sum(q) q from tq group by 1
  ),
  ex(item_id, q, depth) as (   -- šarže se razlažu na sirovine (i šarža u šarži), po normativu šarže
    select item_id, q, 0 from th0
    union all
    select pl.item_id, ex.q * pl.qty / w.batch_out, ex.depth + 1
      from ex join public.waste_items w on w.id = ex.item_id and w.is_prep and w.batch_out > 0
      join public.prep_lines pl on pl.prep_id = w.id
     where ex.depth < 6
  ),
  th as (
    select ex.item_id, sum(ex.q) q from ex
     where not exists (select 1 from public.waste_items w where w.id = ex.item_id and w.is_prep and w.batch_out > 0
                         and exists (select 1 from public.prep_lines pl where pl.prep_id = w.id))
     group by 1
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
