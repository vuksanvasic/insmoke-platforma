-- SQL izmena 18 (23.11.2026):
--  1) težine u yield logu preračunate iz grama u kilograme + zaštita od upisa u gramima
--  2) Brisket burnt ends spojen sa Drpanom junetinom (ciklusi, otpis, normativi, fakture, popis)
--  3) obrisan probni raspored smena
-- Pre izmena pravi rezervne kopije u šemi "private" (vidljive samo administratoru baze).

begin;

-- ---------- Rezervne kopije ----------
create table if not exists private.bk_20261123_cooks       as select * from public.cooks;
create table if not exists private.bk_20261123_mc_shifts   as select * from public.mc_shifts;
create table if not exists private.bk_20261123_waste_items as select * from public.waste_items;
create table if not exists private.bk_20261123_dish_lines  as select * from public.dish_lines;
create table if not exists private.bk_20261123_prep_lines  as select * from public.prep_lines;

-- ---------- 1) Grami -> kilogrami ----------
-- Svi dosadašnji ciklusi su upisani u gramima (npr. 26140 umesto 26,14 kg).
-- Deli se sve četiri težine istim brojem, pa yield % i cena po kg ostaju isti.
update public.cooks
   set raw_kg      = round(raw_kg / 1000, 3),
       trimmed_kg  = round(trimmed_kg / 1000, 3),
       cooked_kg   = round(cooked_kg / 1000, 3),
       sellable_kg = round(sellable_kg / 1000, 3)
 where raw_kg > 200;

-- Zaštita: jedan ciklus preko 200 kg sirovog mesa nije realan -> verovatno su upisani grami.
create or replace function public.cooks_kg_guard()
returns trigger language plpgsql as $$
begin
  if new.raw_kg > 200 or new.cooked_kg > 200 then
    raise exception 'Težina je verovatno upisana u gramima. Upiši u kilogramima, sa zarezom (npr. 26,140 umesto 26140).';
  end if;
  return new;
end $$;
drop trigger if exists cooks_kg_guard on public.cooks;
create trigger cooks_kg_guard before insert or update on public.cooks
  for each row execute function public.cooks_kg_guard();

-- ---------- 2) Brisket burnt ends -> Drpana junetina ----------
update public.cooks set product_id = 'pulled-beef' where product_id = 'burnt-ends';

do $$
declare
  stari uuid := (select id from public.waste_items where smoked_product_id = 'burnt-ends' limit 1);
  novi  uuid := (select id from public.waste_items where smoked_product_id = 'pulled-beef' limit 1);
begin
  if stari is null or novi is null then
    raise notice 'Nema namirnice za burnt ends ili drpanu junetinu — preskačem prevezivanje.';
    return;
  end if;
  update public.dish_lines       set item_id = novi where item_id = stari;
  update public.prep_lines       set item_id = novi where item_id = stari;
  update public.prep_lines       set prep_id = novi where prep_id = stari;
  update public.waste            set item_id = novi where item_id = stari;
  update public.fc_invoice_lines set item_id = novi where item_id = stari;
  update public.fc_map           set item_id = novi where item_id = stari;
  update public.fc_count_lines   set item_id = novi where item_id = stari;
  update public.fc_sales_lines   set item_id = novi where item_id = stari;
  update public.fc_pos_map       set item_id = novi where item_id = stari;
  -- cena sirovog (ako je bila upisana samo kod burnt ends) prelazi na drpanu junetinu
  update public.waste_items n set price = s.price
    from public.waste_items s
   where n.id = novi and s.id = stari and n.price is null and s.price is not null;
end $$;

-- burnt ends ostaje isključen i bez ijednog podatka (u Pregledu i Istoriji se više ne pojavljuje)
update public.products    set active = false where id = 'burnt-ends';
update public.waste_items set active = false where smoked_product_id = 'burnt-ends';

-- ---------- 3) Raspored smena ----------
delete from public.mc_shifts;

commit;

-- ---------- Provera ----------
select 'ciklusi' as sta, count(*)::text as vrednost from public.cooks
union all select 'najveći sirovo (kg)', max(raw_kg)::text from public.cooks
union all select 'ciklusi burnt ends', count(*)::text from public.cooks where product_id = 'burnt-ends'
union all select 'ciklusi drpana junetina', count(*)::text from public.cooks where product_id = 'pulled-beef'
union all select 'normativi na burnt ends', count(*)::text from public.dish_lines d join public.waste_items w on w.id = d.item_id where w.smoked_product_id = 'burnt-ends'
union all select 'normativi na drpanu junetinu', count(*)::text from public.dish_lines d join public.waste_items w on w.id = d.item_id where w.smoked_product_id = 'pulled-beef'
union all select 'raspored smena', count(*)::text from public.mc_shifts
union all select 'kopija ciklusa', count(*)::text from private.bk_20261123_cooks
union all select 'kopija rasporeda', count(*)::text from private.bk_20261123_mc_shifts;
