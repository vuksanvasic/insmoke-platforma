-- SQL izmena 17: izmene spiska mesa (Smoker Yield Log / Kitchen Control)
-- Bezbedno za ponovno pokretanje. Ne briše nijedan podatak.

-- 1) Brisket burnt ends -> zamenjuje ga drpana junetina (vrat/podplećka).
--    Stari unosi ostaju kao "Brisket burnt ends" u istoriji, ali se više ne nudi za nove cikluse.
update public.products set active = false where id = 'burnt-ends';
update public.waste_items set active = false where smoked_product_id = 'burnt-ends';

insert into public.products (id, name, sort) values
  ('pulled-beef', 'Drpana junetina (vrat/podplećka)', 2)
on conflict (id) do update set name = excluded.name, active = true;

-- 2) Svinjetina: naziv "Svinjetina (vrat)"
update public.products set name = 'Svinjetina (vrat)' where id = 'pork-butt';
update public.waste_items set name = 'Svinjetina (vrat)'
 where smoked_product_id = 'pork-butt' and name = 'Svinjetina (pork butt)';

-- 3) Goveđe kobasice: naziv "Kobasice goveđe"
update public.products set name = 'Kobasice goveđe' where id = 'sausage';
update public.waste_items set name = 'Kobasice goveđe'
 where smoked_product_id = 'sausage' and name = 'Kobasice (goveđe sa sirom)';

-- 4) Nova mesa
insert into public.products (id, name, sort) values
  ('pork-sausage', 'Kobasice svinjske sa sirom', 8),
  ('bacon',        'Slanina',                    9),
  ('tongue',       'Jezik',                      10)
on conflict (id) do update set name = excluded.name, active = true;

-- 5) Ista mesa i u Otpisu (cena se računa iz yield loga, kao za ostala smokovana mesa)
insert into public.waste_items (name, area, grp, unit, smoked_product_id, sort) values
  ('Drpana junetina (vrat/podplećka)', 'kuhinja', 'Meso', 'kg', 'pulled-beef',  11),
  ('Kobasice svinjske sa sirom',       'kuhinja', 'Meso', 'kg', 'pork-sausage', 17),
  ('Slanina',                          'kuhinja', 'Meso', 'kg', 'bacon',        18),
  ('Jezik',                            'kuhinja', 'Meso', 'kg', 'tongue',       19)
on conflict (name) do update set smoked_product_id = excluded.smoked_product_id, active = true;

-- Provera
select id, name, active, sort from public.products order by sort, id;
