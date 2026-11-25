-- SQL izmena 21 (25.11.2026): KUHINJA OSOBLJE — dolazak, pauza, odlazak; ček-liste 1. i 2. smene
-- Bezbedno za ponovno pokretanje. Ne briše postojeće podatke.
-- Vreme dolaska, pauze, odlaska i čekiranja upisuje baza (now()), ne telefon — ne može da se „namesti“.

-- =====================================================================
-- 1) EVIDENCIJA RADA
-- =====================================================================
create table if not exists public.staff_shifts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id),
  work_date  date not null,
  shift      int  not null check (shift in (1,2)),
  clock_in   timestamptz not null default now(),
  clock_out  timestamptz,
  note       text,
  edited_by  uuid references auth.users(id),
  edited_at  timestamptz,
  created_at timestamptz not null default now(),
  check (clock_out is null or clock_out >= clock_in)
);
create index if not exists staff_shifts_day_idx on public.staff_shifts (work_date desc, shift);
create index if not exists staff_shifts_user_idx on public.staff_shifts (user_id, clock_in desc);
-- jedna otvorena smena po osobi
create unique index if not exists staff_shifts_open_uq on public.staff_shifts (user_id) where clock_out is null;

create table if not exists public.staff_breaks (
  id             uuid primary key default gen_random_uuid(),
  staff_shift_id uuid not null references public.staff_shifts(id) on delete cascade,
  start_at       timestamptz not null default now(),
  end_at         timestamptz,
  check (end_at is null or end_at >= start_at)
);
create index if not exists staff_breaks_shift_idx on public.staff_breaks (staff_shift_id);
create unique index if not exists staff_breaks_open_uq on public.staff_breaks (staff_shift_id) where end_at is null;

-- otvorena smena prijavljenog korisnika
create or replace function public.staff_open_shift()
returns public.staff_shifts language sql stable security definer set search_path = public as $$
  select * from public.staff_shifts where user_id = auth.uid() and clock_out is null limit 1;
$$;

create or replace function public.staff_clock_in(p_shift int)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.staff_shifts; nid uuid;
begin
  if not public.is_member() then raise exception 'Nemaš pristup.'; end if;
  if p_shift not in (1,2) then raise exception 'Smena mora biti 1 ili 2.'; end if;
  select * into r from public.staff_shifts where user_id = auth.uid() and clock_out is null;
  if found then raise exception 'Već si prijavljen/a na smenu (%). Prvo se odjavi.', r.shift; end if;
  insert into public.staff_shifts (user_id, work_date, shift, clock_in)
  values (auth.uid(), (now() at time zone 'Europe/Belgrade')::date, p_shift, now())
  returning id into nid;
  return nid;
end $$;

-- pauza: ako nije u pauzi, počinje; ako jeste, završava
create or replace function public.staff_break_toggle()
returns text language plpgsql security definer set search_path = public as $$
declare r public.staff_shifts; b public.staff_breaks;
begin
  select * into r from public.staff_shifts where user_id = auth.uid() and clock_out is null;
  if not found then raise exception 'Nisi prijavljen/a na smenu.'; end if;
  select * into b from public.staff_breaks where staff_shift_id = r.id and end_at is null;
  if found then
    update public.staff_breaks set end_at = now() where id = b.id;
    return 'kraj';
  end if;
  insert into public.staff_breaks (staff_shift_id) values (r.id);
  return 'pocetak';
end $$;

create or replace function public.staff_clock_out()
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.staff_shifts;
begin
  select * into r from public.staff_shifts where user_id = auth.uid() and clock_out is null;
  if not found then raise exception 'Nisi prijavljen/a na smenu.'; end if;
  update public.staff_breaks set end_at = now() where staff_shift_id = r.id and end_at is null;
  update public.staff_shifts set clock_out = now() where id = r.id;
  return r.id;
end $$;

-- ispravka (zaboravio odjavu i sl.) — šef smene, menadžer, administrator; beleži se ko je ispravio
create or replace function public.staff_fix(p_id uuid, p_in timestamptz, p_out timestamptz, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_sef() then raise exception 'Ispravku radi šef smene ili administrator.'; end if;
  if p_out is not null and p_out < p_in then raise exception 'Odlazak ne može biti pre dolaska.'; end if;
  update public.staff_shifts set clock_in = p_in, clock_out = p_out,
         note = nullif(trim(coalesce(p_note,'')),''), edited_by = auth.uid(), edited_at = now()
   where id = p_id;
  if not found then raise exception 'Smena nije pronađena.'; end if;
  if p_out is not null then
    update public.staff_breaks set end_at = greatest(start_at, least(p_out, now()))
     where staff_shift_id = p_id and end_at is null;
  end if;
end $$;

-- =====================================================================
-- 2) TAČKE ZA TEMPERATURU (frižideri, zamrzivači, holding)
-- =====================================================================
create table if not exists public.chk_points (
  id     uuid primary key default gen_random_uuid(),
  label  text not null unique,
  kind   text not null check (kind in ('frizider','zamrzivac','holding')),
  t_min  numeric,
  t_max  numeric,
  sort   int not null default 100,
  active boolean not null default true
);
insert into public.chk_points (label, kind, t_min, t_max, sort) values
  ('Frižider 1', 'frizider', 0, 5, 1),
  ('Frižider 2', 'frizider', 0, 5, 2),
  ('Zamrzivač', 'zamrzivac', null, -18, 3),
  ('Holding orman', 'holding', 63, null, 4)
on conflict (label) do nothing;

-- =====================================================================
-- 3) ŠABLON ČEK-LISTE
-- =====================================================================
create table if not exists public.chk_items (
  id          uuid primary key default gen_random_uuid(),
  shift       int  not null check (shift in (1,2)),
  section     text not null,
  title       text not null,
  hint        text,
  due         time,                      -- rok (lokalno vreme)
  late_close  boolean not null default false, -- petak i subota rok +1h (kuhinja radi do 23:30)
  optional    boolean not null default false, -- npr. prijem robe: može „danas nije bilo“
  need_photo  boolean not null default false,
  temp_kinds  text[]  not null default '{}',   -- npr. {frizider,zamrzivac,holding}
  text_label  text,                          -- ako traži upis teksta
  code        text check (code in ('handover_read','handover_write','requests')),
  sort        int  not null default 100,
  active      boolean not null default true,
  unique (shift, title)
);

insert into public.chk_items (shift, section, title, hint, due, late_close, optional, need_photo, temp_kinds, text_label, code, sort) values
-- ---------- 1. SMENA ----------
 (1,'Dolazak','Uniforma i higijena ruku',null,'10:15',false,false,false,'{}',null,null,10),
 (1,'Dolazak','Obilazak kuhinje','Frižideri i zamrzivači rade, nema curenja, uređaji uključeni (friteza, ploča, holding).','10:30',false,false,false,'{}',null,null,20),
 (1,'Dolazak','Temperatura frižidera, zamrzivača i holding ormana','Frižider 0–5°C, zamrzivač –18°C ili hladnije, holding iznad 63°C.','10:30',false,false,false,'{frizider,zamrzivac,holding}',null,null,30),
 (1,'Dolazak','Slika zatečenog stanja frižidera i zamrzivača','Slikaj pre nego što bilo šta pomeriš.','10:30',false,false,true,'{}',null,null,40),
 (1,'Dolazak','Posude zamenjene, prefolijavanje, dezinfekcija frižidera, novi stikeri sa datumom','Slika posle sređivanja.','11:00',false,false,true,'{}',null,null,50),
 (1,'Dolazak','Pročitana primopredaja od prethodne večeri','Šta fali, šta je otpisano, šta prvo da se potroši.','10:30',false,false,false,'{}',null,'handover_read',60),

 (1,'Mise en place','Sosevi i dipovi napravljeni i obeleženi (BBQ, dipovi, cheddar)','Svaki sos, dip i kondiment po recepturi za šaržu i postupku iz Normativa.','11:30',false,false,false,'{}',null,null,110),
 (1,'Mise en place','Coleslaw i salate pripremljeni po normativu',null,'11:30',false,false,false,'{}',null,null,120),
 (1,'Mise en place','Krompir, pomfrit, onion rings, mozzarella štapići i kroketi spremni',null,'11:45',false,false,false,'{}',null,null,130),
 (1,'Mise en place','Peciva, burger pljeskavice i sendviči spremni i adekvatno spakovani',null,'11:45',false,false,false,'{}',null,null,140),
 (1,'Mise en place','Desert (mak kolač) i prilozi dopunjeni',null,'11:45',false,false,false,'{}',null,null,150),
 (1,'Mise en place','Slika pripreme složene u frižideru','Kad se dopuni: poređano, pokriveno, obeleženo.','12:00',false,false,true,'{}',null,null,160),
 (1,'Mise en place','Slika radne stanice spremne za servis',null,'12:00',false,false,true,'{}',null,null,170),
 (1,'Mise en place','Lista pripreme za 2. smenu','Količine prema prometu istog dana prošle nedelje.','14:00',false,false,false,'{}','Šta i koliko se priprema za 2. smenu',null,180),

 (1,'Prijem robe','Roba proverena po otpremnici: količina, izgled, rok','Ako danas nije bilo robe, označi „Danas nije bilo“.',null,false,true,false,'{}',null,null,210),
 (1,'Prijem robe','Slika otpremnice','Meso se upisuje i u HACCP → Prijem mesa.',null,false,true,true,'{}',null,null,220),
 (1,'Prijem robe','Roba odložena po FIFO (staro napred, novo pozadi)',null,null,false,true,false,'{}',null,null,230),

 (1,'Primopredaja sa smokera (Maki)','Preuzeto meso sa smokera po vrsti, upisan yield u Kitchen Control','Brisket, pork, rebra, ćuretina…','12:00',false,false,true,'{}',null,null,310),
 (1,'Primopredaja sa smokera (Maki)','Upisana sledljivost: lot, kada je meso ušlo i izašlo iz smokera',null,'12:00',false,false,false,'{}',null,null,320),
 (1,'Primopredaja sa smokera (Maki)','Meso odloženo: vakum ili holding, obeleženo datumom i vrstom',null,'12:00',false,false,false,'{}',null,null,330),
 (1,'Primopredaja sa smokera (Maki)','Dogovoreno šta ide u smoker za sutra',null,'12:00',false,false,false,'{}','Šta ide u smoker za sutra',null,340),

 (1,'Servis','Porcionisanje po normativu (gramaža za plate, obroke i box)',null,'17:00',false,false,false,'{}',null,null,410),
 (1,'Servis','Holding u 12h','Temperatura i izgled mesa (da se ne suši).','12:15',false,false,false,'{holding}',null,null,420),
 (1,'Servis','Holding u 13h',null,'13:15',false,false,false,'{holding}',null,null,421),
 (1,'Servis','Holding u 14h',null,'14:15',false,false,false,'{holding}',null,null,422),
 (1,'Servis','Holding u 15h',null,'15:15',false,false,false,'{holding}',null,null,423),
 (1,'Servis','Holding u 16h',null,'16:15',false,false,false,'{holding}',null,null,424),
 (1,'Servis','Čišćenje tokom rada (clean as you go)',null,'17:00',false,false,false,'{}',null,null,430),
 (1,'Servis','Ulje u friteži provereno',null,'16:30',false,false,false,'{}','Stanje ulja, da li je menjano',null,440),

 (1,'Predaja smene','Otpis 1. smene upisan','U Kitchen Control-u, Otpis po smeni: šta je bačeno i zašto.','16:45',false,false,false,'{}',null,null,510),
 (1,'Predaja smene','Mise en place dopunjen za večernju špicu','Slika frižidera sa pripremom.','16:45',false,false,true,'{}',null,null,520),
 (1,'Predaja smene','Trebovanje: šta je potrošeno i treba da se trebuje',null,'16:45',false,false,false,'{}',null,'requests',530),
 (1,'Predaja smene','Primopredaja napisana','Šta je pripremljeno, šta fali, šta prvo da se prodaje.','17:00',false,false,false,'{}','Primopredaja za 2. smenu','handover_write',540),
 (1,'Predaja smene','Radna stanica čista','Slika čiste stanice.','17:00',false,false,true,'{}',null,null,550),

-- ---------- 2. SMENA ----------
 (2,'Preuzimanje smene','Uniforma i higijena ruku',null,'17:00',false,false,false,'{}',null,null,10),
 (2,'Preuzimanje smene','Pročitana primopredaja od 1. smene','Šta je pripremljeno, šta fali, šta prvo da se prodaje.','17:00',false,false,false,'{}',null,'handover_read',20),
 (2,'Preuzimanje smene','Mise en place proveren za špicu','Slika frižidera sa pripremom. Ako nečega fali, odmah javi Marku Karasu.','17:00',false,false,true,'{}',null,null,30),
 (2,'Preuzimanje smene','Stanje mesa po vrsti',null,'17:00',false,false,false,'{}','Koliko kg ima: brisket, pork, rebra, ćuretina…',null,40),
 (2,'Preuzimanje smene','Temperatura holding ormana',null,'17:00',false,false,false,'{holding}',null,null,50),
 (2,'Preuzimanje smene','Slika radne stanice spremne za servis',null,'17:00',false,false,true,'{}',null,null,60),

 (2,'Servis i špica','Porcionisanje po normativu (gramaža za plate, obroke i box)',null,'21:30',false,false,false,'{}',null,null,110),
 (2,'Servis i špica','Holding u 18h','Temperatura i izgled mesa.','18:15',false,false,false,'{holding}',null,null,120),
 (2,'Servis i špica','Holding u 19h',null,'19:15',false,false,false,'{holding}',null,null,121),
 (2,'Servis i špica','Holding u 20h',null,'20:15',false,false,false,'{holding}',null,null,122),
 (2,'Servis i špica','Holding u 21h',null,'21:15',false,false,false,'{holding}',null,null,123),
 (2,'Servis i špica','Prvo se prodaje starije (javljeno šankeru)',null,'21:30',false,false,false,'{}',null,null,130),
 (2,'Servis i špica','Šta je nestalo iz ponude (javljeno šankeru)','Ako ništa nije nestalo, označi „Danas nije bilo“.','21:30',false,true,false,'{}','Šta je nestalo i u koliko sati',null,140),
 (2,'Servis i špica','Čišćenje tokom rada (clean as you go)',null,'21:30',false,false,false,'{}',null,null,150),

 (2,'Zatvaranje kuhinje','Preostalo meso ohlađeno, vakumirano i obeleženo','Slika i količina po vrsti.','22:30',true,false,true,'{}','Koliko kg je ostalo po vrsti',null,210),
 (2,'Zatvaranje kuhinje','Sosevi, kondimenti i pripreme pokriveni, obeleženi i vraćeni u frižider',null,'22:30',true,false,true,'{}',null,null,220),
 (2,'Zatvaranje kuhinje','Otpis 2. smene upisan','Pre zatvaranja kuhinje — tada stiže dnevni mejl.','22:30',true,false,false,'{}',null,null,230),
 (2,'Zatvaranje kuhinje','Ulje u friteži provereno',null,'22:30',true,false,false,'{}','Stanje ulja, da li je menjano',null,240),
 (2,'Zatvaranje kuhinje','Trebovanje za sutra',null,'22:30',true,false,false,'{}',null,'requests',250),
 (2,'Zatvaranje kuhinje','Primopredaja za jutro','Šta je ostalo, šta prvo da se potroši, šta fali.','22:45',true,false,false,'{}','Primopredaja za 1. smenu','handover_write',260),

 (2,'Čišćenje i kraj','Ploča, fritezi, radne površine i podovi očišćeni',null,'23:00',true,false,false,'{}',null,null,310),
 (2,'Čišćenje i kraj','Završna temperatura frižidera i zamrzivača',null,'23:00',true,false,false,'{frizider,zamrzivac}',null,null,320),
 (2,'Čišćenje i kraj','Slika frižidera na kraju smene','Ovo stanje zatiče 1. smena ujutru.','23:00',true,false,true,'{}',null,null,330),
 (2,'Čišćenje i kraj','Slika čiste radne stanice',null,'23:00',true,false,true,'{}',null,null,340),
 (2,'Čišćenje i kraj','Uređaji isključeni (osim frižidera, zamrzivača i smokera)',null,'23:00',true,false,false,'{}',null,null,350)
on conflict (shift, title) do nothing;

-- =====================================================================
-- 4) ČEKIRANJE (jedna ček-lista po danu i smeni, zajednička za sve u smeni)
-- =====================================================================
create table if not exists public.chk_done (
  id         uuid primary key default gen_random_uuid(),
  work_date  date not null,
  shift      int  not null check (shift in (1,2)),
  item_id    uuid not null references public.chk_items(id),
  done_by    uuid not null default auth.uid() references auth.users(id),
  done_at    timestamptz not null default now(),
  skipped    boolean not null default false,
  temps      jsonb not null default '[]',   -- [{point_id,label,value,ok}]
  alarm      boolean not null default false,
  note       text,
  photos     text[] not null default '{}',
  unique (work_date, shift, item_id)
);
create index if not exists chk_done_day_idx on public.chk_done (work_date desc, shift);

create or replace function public.chk_check(p_date date, p_shift int, p_item uuid, p_temps jsonb, p_note text, p_photos text[], p_skip boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare it public.chk_items; pt public.chk_points; t jsonb; v numeric; outs jsonb := '[]'; al boolean := false; ok boolean; nid uuid; k text;
begin
  if not public.is_member() then raise exception 'Nemaš pristup.'; end if;
  select * into it from public.chk_items where id = p_item;
  if not found then raise exception 'Stavka ne postoji.'; end if;
  if it.shift <> p_shift then raise exception 'Stavka nije za ovu smenu.'; end if;
  -- kuvar čekira samo danas i juče (2. smena posle ponoći); šef i administrator i ranije dane
  if not public.is_sef() and p_date < (now() at time zone 'Europe/Belgrade')::date - 1 then
    raise exception 'Stari dan može da dopuni samo šef smene.'; end if;
  if p_date > (now() at time zone 'Europe/Belgrade')::date then raise exception 'Ne može unapred.'; end if;

  if coalesce(p_skip,false) then
    if not it.optional then raise exception 'Ova stavka mora da se uradi.'; end if;
  else
    if it.need_photo and coalesce(array_length(p_photos,1),0) = 0 then raise exception 'Potrebna je slika.'; end if;
    if (it.text_label is not null or it.code in ('handover_write')) and length(trim(coalesce(p_note,''))) = 0 then
      raise exception 'Upiši: %', coalesce(it.text_label,'tekst'); end if;
    if array_length(it.temp_kinds,1) > 0 then
      foreach k in array it.temp_kinds loop
        for pt in select * from public.chk_points where active and kind = k order by sort loop
          t := null;
          select x into t from jsonb_array_elements(coalesce(p_temps,'[]')) x where x->>'point_id' = pt.id::text limit 1;
          if t is null or (t->>'value') is null or (t->>'value') = '' then
            raise exception 'Upiši temperaturu: %', pt.label; end if;
          v := (t->>'value')::numeric;
          if v < -60 or v > 150 then raise exception 'Temperatura za % nije realna.', pt.label; end if;
          ok := (pt.t_min is null or v >= pt.t_min) and (pt.t_max is null or v <= pt.t_max);
          if not ok then al := true; end if;
          outs := outs || jsonb_build_array(jsonb_build_object('point_id',pt.id,'label',pt.label,'value',v,'ok',ok,'min',pt.t_min,'max',pt.t_max));
        end loop;
      end loop;
    end if;
  end if;

  insert into public.chk_done (work_date, shift, item_id, done_by, done_at, skipped, temps, alarm, note, photos)
  values (p_date, p_shift, p_item, auth.uid(), now(), coalesce(p_skip,false), outs, al,
          nullif(trim(coalesce(p_note,'')),''), coalesce(p_photos,'{}'))
  on conflict (work_date, shift, item_id) do update
     set done_by = excluded.done_by, done_at = excluded.done_at, skipped = excluded.skipped, temps = excluded.temps,
         alarm = excluded.alarm, note = excluded.note, photos = excluded.photos
  returning id into nid;
  return nid;
end $$;

-- poništi čekiranje: ko je čekirao (isti dan) ili šef smene / administrator
create or replace function public.chk_uncheck(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare d public.chk_done;
begin
  select * into d from public.chk_done where id = p_id;
  if not found then return; end if;
  if exists (select 1 from public.chk_signoff s where s.work_date = d.work_date and s.shift = d.shift) and not public.is_admin() then
    raise exception 'Smena je potvrđena — menja samo administrator.'; end if;
  if not (public.is_sef() or (d.done_by = auth.uid() and d.done_at > now() - interval '18 hours')) then
    raise exception 'Poništava ko je čekirao (isti dan) ili šef smene.'; end if;
  delete from public.chk_done where id = p_id;
end $$;

-- =====================================================================
-- 5) TREBOVANJE
-- =====================================================================
create table if not exists public.chk_requests (
  id            uuid primary key default gen_random_uuid(),
  work_date     date not null,
  shift         int  not null check (shift in (1,2)),
  waste_item_id uuid references public.waste_items(id),
  name          text not null check (length(trim(name)) > 0),
  qty           numeric not null check (qty > 0),
  unit          text not null default 'kom',
  note          text,
  created_by    uuid not null default auth.uid() references auth.users(id),
  created_at    timestamptz not null default now()
);
create index if not exists chk_requests_day_idx on public.chk_requests (work_date desc, shift);

-- =====================================================================
-- 6) POTVRDA ŠEFA SMENE
-- =====================================================================
create table if not exists public.chk_signoff (
  work_date date not null,
  shift     int  not null check (shift in (1,2)),
  signed_by uuid not null default auth.uid() references auth.users(id),
  signed_at timestamptz not null default now(),
  note      text,
  primary key (work_date, shift)
);

create or replace function public.chk_sign(p_date date, p_shift int, p_note text, p_undo boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_sef() then raise exception 'Smenu potvrđuje šef smene ili administrator.'; end if;
  if coalesce(p_undo,false) then
    delete from public.chk_signoff where work_date = p_date and shift = p_shift; return;
  end if;
  insert into public.chk_signoff (work_date, shift, signed_by, signed_at, note)
  values (p_date, p_shift, auth.uid(), now(), nullif(trim(coalesce(p_note,'')),''))
  on conflict (work_date, shift) do update set signed_by = excluded.signed_by, signed_at = excluded.signed_at, note = excluded.note;
end $$;

-- =====================================================================
-- 7) PRAVILA PRISTUPA
-- =====================================================================
alter table public.staff_shifts enable row level security;
alter table public.staff_breaks enable row level security;
alter table public.chk_points   enable row level security;
alter table public.chk_items    enable row level security;
alter table public.chk_done     enable row level security;
alter table public.chk_requests enable row level security;
alter table public.chk_signoff  enable row level security;

-- evidenciju rada: svako vidi svoju, šef/menadžer/administrator sve; upis samo preko funkcija
drop policy if exists "rad: svoja ili šef" on public.staff_shifts;
create policy "rad: svoja ili šef" on public.staff_shifts for select to authenticated
  using (user_id = auth.uid() or public.is_sef());
drop policy if exists "pauze: svoje ili šef" on public.staff_breaks;
create policy "pauze: svoje ili šef" on public.staff_breaks for select to authenticated
  using (public.is_sef() or exists (select 1 from public.staff_shifts s where s.id = staff_shift_id and s.user_id = auth.uid()));

-- ček-liste vide svi članovi; upis preko funkcija
drop policy if exists "ček: čitaju članovi" on public.chk_points;
create policy "ček: čitaju članovi" on public.chk_points for select to authenticated using (public.is_member());
drop policy if exists "ček: admin menja" on public.chk_points;
create policy "ček: admin menja" on public.chk_points for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "ček: čitaju članovi" on public.chk_items;
create policy "ček: čitaju članovi" on public.chk_items for select to authenticated using (public.is_member());
drop policy if exists "ček: admin menja" on public.chk_items;
create policy "ček: admin menja" on public.chk_items for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "ček: čitaju članovi" on public.chk_done;
create policy "ček: čitaju članovi" on public.chk_done for select to authenticated using (public.is_member());
drop policy if exists "ček: čitaju članovi" on public.chk_signoff;
create policy "ček: čitaju članovi" on public.chk_signoff for select to authenticated using (public.is_member());

drop policy if exists "trebovanje: čitaju članovi" on public.chk_requests;
create policy "trebovanje: čitaju članovi" on public.chk_requests for select to authenticated using (public.is_member());
drop policy if exists "trebovanje: upis članovi" on public.chk_requests;
create policy "trebovanje: upis članovi" on public.chk_requests for insert to authenticated
  with check (public.is_member() and created_by = auth.uid());
drop policy if exists "trebovanje: briše svoje ili šef" on public.chk_requests;
create policy "trebovanje: briše svoje ili šef" on public.chk_requests for delete to authenticated
  using (public.is_sef() or (created_by = auth.uid() and created_at > now() - interval '18 hours'));

do $$ declare f text; begin
  foreach f in array array['staff_open_shift()','staff_clock_in(int)','staff_break_toggle()','staff_clock_out()',
    'staff_fix(uuid, timestamptz, timestamptz, text)','chk_check(date, int, uuid, jsonb, text, text[], boolean)',
    'chk_uncheck(uuid)','chk_sign(date, int, text, boolean)'] loop
    execute 'revoke all on function public.'||f||' from public, anon';
    execute 'grant execute on function public.'||f||' to authenticated';
  end loop;
end $$;

-- ---------- Slike (privatni prostor „osoblje“) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('osoblje', 'osoblje', false, 6291456, array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do update set public = false;
drop policy if exists "osoblje slike: čitaju članovi" on storage.objects;
create policy "osoblje slike: čitaju članovi" on storage.objects for select to authenticated using (bucket_id = 'osoblje' and public.is_member());
drop policy if exists "osoblje slike: upis članovi" on storage.objects;
create policy "osoblje slike: upis članovi" on storage.objects for insert to authenticated with check (bucket_id = 'osoblje' and public.is_member());

-- ---------- Uživo osvežavanje ----------
do $$ declare t text; begin
  foreach t in array array['staff_shifts','staff_breaks','chk_done','chk_requests','chk_signoff','chk_items','chk_points'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; when undefined_object then null; end;
  end loop;
end $$;
