-- SQL izmena 19 (23.11.2026): nabavne cene u yield logu bez PDV-a
-- Do sada su cene mesa upisivane SA PDV-om (10 %, posebna stopa za sveže/rashlađeno/smrznuto meso).
-- Preračunava se: cena bez PDV-a = cena sa PDV-om ÷ 1,10.
-- Radi se SAMO JEDNOM: ako rezervna kopija već postoji, ništa se ne menja.

do $$
begin
  if to_regclass('private.bk_20261123_pdv_cooks') is not null then
    raise notice 'Cene su već preračunate (postoji rezervna kopija) — preskačem.';
    return;
  end if;
  create table private.bk_20261123_pdv_cooks as select * from public.cooks;
  alter table private.bk_20261123_pdv_cooks enable row level security;
  update public.cooks
     set price_per_kg = round(price_per_kg / 1.10, 2)
   where price_per_kg is not null;
end $$;

-- Provera: cena po mesu pre i posle
select c.product_id,
       count(*)                          as ciklusa,
       min(b.price_per_kg)               as sa_pdv,
       min(c.price_per_kg)               as bez_pdv
  from public.cooks c
  join private.bk_20261123_pdv_cooks b on b.id = c.id
 where c.price_per_kg is not null
 group by c.product_id
 order by c.product_id;
