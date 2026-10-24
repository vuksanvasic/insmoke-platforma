-- =====================================================================
-- Izmena 11: MANAGEMENT CONTROL — mejl izveštaji o radu
--   · dnevni: svako jutro u 9h za juče (+ od početka meseca)
--   · nedeljni: ponedeljkom u 9h za prošlu nedelju
--   · šalje se preko iste Apps Script veze (kind: 'mc_daily' / 'mc_weekly')
--   · proračun je isti kao na sajtu (management.html)
-- Može da se pokrene više puta bez štete.
-- =====================================================================

-- Sati i noćni sati jedne smene ('HH:MM' – 'HH:MM', preko ponoći ako je kraj <= početak)
create or replace function public.mc_shift_span(st text, en text, out h numeric, out night numeric)
language plpgsql immutable as $$
declare a int; b int;
begin
  h := 0; night := 0;
  if st is null or en is null or st !~ '^\d{1,2}:\d{2}$' or en !~ '^\d{1,2}:\d{2}$' then return; end if;
  a := split_part(st,':',1)::int*60 + split_part(st,':',2)::int;
  b := split_part(en,':',1)::int*60 + split_part(en,':',2)::int;
  if b <= a then b := b + 1440; end if;
  h := (b - a) / 60.0;
  night := ( greatest(0, least(b,360)  - greatest(a,0))
           + greatest(0, least(b,1800) - greatest(a,1320))
           + greatest(0, least(b,3240) - greatest(a,2760)) ) / 60.0;
end $$;

-- Sati jednog zaposlenog za jedan dan: potvrđen dan → potvrda, inače raspored
create or replace function public.mc_staff_day(sid uuid, d date, out h numeric, out night numeric)
language sql stable security definer set search_path = public as $$
  select coalesce(sum(x.h),0), coalesce(sum(x.night),0) from (
    select (public.mc_shift_span(r->>'start', r->>'end')).*
      from public.mc_days md, jsonb_array_elements(md.rows) r
     where md.day = d and md.confirmed and r->>'staffId' = sid::text and r->>'status' = 'radio'
    union all
    select (public.mc_shift_span(sh.start_time, sh.end_time)).*
      from public.mc_shifts sh
     where sh.shift_date = d and sh.staff_id = sid
       and not exists (select 1 from public.mc_days m2 where m2.day = d and m2.confirmed)
  ) x;
$$;

-- Promet bez PDV-a za dan
create or replace function public.mc_sales_net(d date)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce((
    select case when s.closed then 0 else
      (select coalesce(sum(coalesce((v->>'f')::numeric,0) + coalesce((v->>'d')::numeric,0)),0) from jsonb_each(s.channels) e(k,v))
      / (1 + coalesce(((select data from public.mc_settings where id = 1)->>'pdv')::numeric, 20) / 100) end
    from public.mc_sales s where s.day = d), 0);
$$;

-- Glavni proračun za period
create or replace function public.mc_labor_summary(a date, b date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  cfg jsonb := coalesce((select data from public.mc_settings where id = 1), '{}'::jsonb);
  target numeric := coalesce((cfg->>'laborTarget')::numeric, 30);
  otp numeric := coalesce((cfg->>'otPct')::numeric, 26);
  nip numeric := coalesce((cfg->>'nightPct')::numeric, 26);
  hop numeric := coalesce((cfg->>'holidayPct')::numeric, 110);
  danas date := (now() at time zone 'Europe/Belgrade')::date;
  first_entry date := least((select min(day) from public.mc_sales), (select min(day) from public.mc_days));
  d date; st record; p record; sd record;
  dim int; act numeric; base numeric; mcost numeric; cost numeric;
  hol boolean; mh numeric; mdays int;
  ws date; we date; wk_h numeric; over numeric;
  net numeric; tot_net numeric := 0; tot_cost numeric := 0; own_cost numeric := 0; tot_h numeric := 0; ot numeric := 0;
  day_cost numeric; day_h numeric;
  sec jsonb := '{}'::jsonb; dmap jsonb := '{}'::jsonb;
  missing jsonb := '[]'::jsonb; unconf jsonb := '[]'::jsonb; otp_people jsonb := '[]'::jsonb;
  planned numeric; has_pay boolean;
begin
  d := a;
  while d <= b loop
    dim := extract(day from (date_trunc('month', d) + interval '1 month - 1 day'))::int;
    hol := coalesce((select holiday from public.mc_days where day = d), false);
    net := public.mc_sales_net(d);
    day_cost := 0; day_h := 0;
    for st in select * from public.mc_staff s
               where (s.date_from is null or s.date_from <= d) and (s.date_to is null or s.date_to >= d) loop
      sd := public.mc_staff_day(st.id, d);
      select * into p from public.mc_pay where staff_id = st.id and valid_from <= d order by valid_from desc limit 1;
      has_pay := found;
      if not has_pay then select * into p from public.mc_pay where staff_id = st.id order by valid_from limit 1; has_pay := found; end if;
      act := (select (amounts->>st.id::text)::numeric from public.mc_payroll where month = to_char(d,'YYYY-MM'));
      cost := 0;
      if act is not null then
        if st.pay_mode = 'fiksno' then cost := act / dim;
        else
          select coalesce(sum((public.mc_staff_day(st.id, g::date)).h),0),
                 count(*) filter (where (public.mc_staff_day(st.id, g::date)).h > 0)
            into mh, mdays
            from generate_series(date_trunc('month', d), date_trunc('month', d) + interval '1 month - 1 day', interval '1 day') g;
          if st.pay_mode = 'dnevnica' then cost := case when mdays > 0 and sd.h > 0 then act / mdays else 0 end;
          else cost := case when mh > 0 then act * sd.h / mh else 0 end; end if;
        end if;
      elsif has_pay then
        mcost := coalesce(p.gross2,0) + coalesce(p.meal,0) + coalesce(p.transport,0) + coalesce(p.regres,0)/12 + coalesce(p.bonus,0);
        if st.pay_mode = 'fiksno' then
          cost := mcost / dim;
          if st.type = 'ugovor' and coalesce(p.gross2,0) > 0 then
            base := p.gross2 / (coalesce(nullif(st.weekly_hours,0),40) * 52 / 12);
            cost := cost + sd.night * base * nip / 100;
            if hol then cost := cost + sd.h * base * hop / 100; end if;
          end if;
        elsif st.pay_mode = 'sat' then
          cost := sd.h * coalesce(p.rate,0) + case when sd.h > 0 then (coalesce(p.meal,0)+coalesce(p.transport,0)+coalesce(p.bonus,0)) / dim else 0 end;
        else
          cost := case when sd.h > 0 then coalesce(p.rate,0) else 0 end;
        end if;
      end if;
      day_cost := day_cost + cost; day_h := day_h + sd.h;
      if st.type = 'vlasnik' then own_cost := own_cost + cost; end if;
      sec := jsonb_set(sec, array[st.sector], jsonb_build_object(
        'cost', coalesce((sec->st.sector->>'cost')::numeric,0) + cost,
        'hours', coalesce((sec->st.sector->>'hours')::numeric,0) + sd.h));
    end loop;
    tot_cost := tot_cost + day_cost; tot_h := tot_h + day_h; tot_net := tot_net + net;
    dmap := dmap || jsonb_build_object(d::text, jsonb_build_object('net', net, 'cost', day_cost, 'hours', day_h,
              'closed', coalesce((select closed from public.mc_sales where day = d), false)));
    if d < danas and first_entry is not null and d >= first_entry then
      if not exists (select 1 from public.mc_sales where day = d) then missing := missing || to_jsonb(d); end if;
      if not exists (select 1 from public.mc_days where day = d and confirmed)
         and exists (select 1 from public.mc_shifts where shift_date = d)
         and not coalesce((select closed from public.mc_sales where day = d), false) then unconf := unconf || to_jsonb(d); end if;
    end if;
    d := d + 1;
  end loop;

  -- prekovremeni: nedelje čija nedelja (dan) pada u period, ugovor + fiksna plata
  ws := date_trunc('week', a)::date;
  while ws <= b loop
    we := ws + 6;
    if we >= a and we <= b then
      for st in select * from public.mc_staff where pay_mode = 'fiksno' and type = 'ugovor' loop
        select coalesce(sum((public.mc_staff_day(st.id, g::date)).h),0) into wk_h
          from generate_series(ws, we, interval '1 day') g
         where (st.date_from is null or st.date_from <= g::date) and (st.date_to is null or st.date_to >= g::date);
        over := wk_h - coalesce(nullif(st.weekly_hours,0),40);
        if over > 0 then
          otp_people := otp_people || jsonb_build_object('name', st.name, 'week', ws, 'hours', round(over,1));
          if (select (amounts->>st.id::text) from public.mc_payroll where month = to_char(we,'YYYY-MM')) is null then
            select * into p from public.mc_pay where staff_id = st.id and valid_from <= we order by valid_from desc limit 1;
            if found and coalesce(p.gross2,0) > 0 then
              cost := over * (p.gross2 / (coalesce(nullif(st.weekly_hours,0),40) * 52 / 12)) * (1 + otp / 100);
              ot := ot + cost; tot_cost := tot_cost + cost;
              sec := jsonb_set(sec, array[st.sector], jsonb_build_object(
                'cost', coalesce((sec->st.sector->>'cost')::numeric,0) + cost,
                'hours', coalesce((sec->st.sector->>'hours')::numeric,0)));
            end if;
          end if;
        end if;
      end loop;
    end if;
    ws := ws + 7;
  end loop;

  select coalesce(sum((public.mc_shift_span(start_time, end_time)).h),0) into planned
    from public.mc_shifts where shift_date between a and b;

  return jsonb_build_object(
    'from', a, 'to', b, 'target', target,
    'net', round(tot_net), 'cost', round(tot_cost), 'owners_cost', round(own_cost), 'overtime_cost', round(ot),
    'hours', round(tot_h,1), 'planned_hours', round(planned,1),
    'labor_pct', case when tot_net > 0 then round(tot_cost / tot_net * 100, 1) end,
    'labor_pct_no_owners', case when tot_net > 0 then round((tot_cost - own_cost) / tot_net * 100, 1) end,
    'sales_per_hour', case when tot_h > 0 then round(tot_net / tot_h) end,
    'needed_net', case when target > 0 then round(tot_cost / (target / 100)) end,
    'by_sector', sec, 'days', dmap,
    'missing_sales', missing, 'unconfirmed', unconf, 'overtime', otp_people,
    'staff', (select count(*) from public.mc_staff where (date_from is null or date_from <= b) and (date_to is null or date_to >= a))
  );
end $$;
revoke execute on function public.mc_labor_summary(date, date) from public, anon, authenticated;
revoke execute on function public.mc_staff_day(uuid, date) from public, anon, authenticated;
revoke execute on function public.mc_sales_net(date) from public, anon, authenticated;

-- Slanje: svakog sata proverava; dnevni u 9h (za juče), nedeljni ponedeljkom u 9h (prošla nedelja)
-- force = 'dnevni' ili 'nedeljni' šalje odmah (za probu), bez beleženja
create or replace function public.mc_reports_send(force text default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  lokalno timestamp := now() at time zone 'Europe/Belgrade';
  danas date := lokalno::date;
  juce date := danas - 1;
  hook text; out text := '';
begin
  select value into hook from private.integrations where key = 'sheets_webhook';
  if hook is null then return 'nema veze'; end if;
  if not exists (select 1 from public.mc_staff) and force is null then return 'nema zaposlenih'; end if;

  if force = 'dnevni' or (force is null and extract(hour from lokalno) = 9
      and not exists (select 1 from private.sent_reports where kind = 'mc_dnevni' and day = danas)) then
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
    perform net.http_post(url := hook,
      body := jsonb_build_object('kind', 'mc_weekly',
        'week', public.mc_labor_summary(danas - 7, danas - 1),
        'prev', public.mc_labor_summary(danas - 14, danas - 8)),
      headers := '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds := 30000);
    if force is null then insert into private.sent_reports (kind, day) values ('mc_nedeljni', danas) on conflict do nothing; end if;
    out := out || 'nedeljni poslat';
  end if;
  return coalesce(nullif(out,''), 'ništa za slanje');
end $$;
revoke execute on function public.mc_reports_send(text) from public, anon, authenticated;

select cron.schedule('mc-izvestaji', '5 * * * *', 'select public.mc_reports_send()');
