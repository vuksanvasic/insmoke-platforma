-- =====================================================================
-- Izmena 15: ZADACI — tabla zadataka za tim (zadaci.html)
--   · faze: za uraditi → u toku → follow-up → urađeno → provereno
--   · „isteklo“ se ne upisuje: zadatak je istekao kad prođe rok, a nije urađen
--   · zadatke pravi i menja administrator; svaki član tima vidi sve zadatke, štiklira korake i piše komentare
--   · kartica se pomera sama: prvi korak → u toku, svi koraci → urađeno; bez koraka: dugme „Završio sam“
--   · mejlovi (preko iste Apps Script veze): dodela, komentar, urađeno, vraćeno na doradu,
--     podsetnik dan pre roka, isteklo, nedeljni pregled ponedeljkom u 9h
-- Može da se pokrene više puta bez štete. Pokreće se posle izmene 14.
-- =====================================================================

create table if not exists public.tasks (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (length(trim(title)) > 1),
  description text,
  area        text not null default 'ostalo' check (area in ('ekonomija','proizvod','obuka','marketing','ostalo')),
  assignee    uuid references public.profiles(id) on delete set null,
  due         date,
  stage       text not null default 'todo' check (stage in ('todo','doing','followup','done','verified')),
  waiting_on  text,                                   -- šta čeka (follow-up)
  checklist   jsonb not null default '[]'::jsonb,     -- [{"t":"korak","d":false}]
  created_by  uuid default auth.uid() references auth.users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  stage_at    timestamptz not null default now(),
  done_at     timestamptz,
  archived    boolean not null default false
);
-- težina zadatka: 1 lako, 2 srednje, 3 teško
alter table public.tasks add column if not exists effort smallint not null default 1;
alter table public.tasks drop constraint if exists tasks_effort_check;
alter table public.tasks add constraint tasks_effort_check check (effort between 1 and 3);
-- follow-up: šta se čeka, od koga i do kada
alter table public.tasks add column if not exists wait_kind  text;
alter table public.tasks add column if not exists wait_for   uuid references public.profiles(id) on delete set null;
alter table public.tasks add column if not exists wait_who   text;    -- neko van tima (dobavljač, knjigovođa…)
alter table public.tasks add column if not exists wait_until date;
alter table public.tasks drop constraint if exists tasks_wait_kind_check;
alter table public.tasks add constraint tasks_wait_kind_check check (wait_kind is null or wait_kind in ('info','odobrenje','roba','druga_osoba','majstor','drugo'));
create index if not exists tasks_assignee_idx on public.tasks (assignee, stage);
create index if not exists tasks_due_idx on public.tasks (due) where stage in ('todo','doing','followup');

create table if not exists public.task_events (
  id          uuid primary key default gen_random_uuid(),
  task_id     uuid not null references public.tasks(id) on delete cascade,
  author      uuid default auth.uid() references auth.users(id),
  author_name text,
  kind        text not null check (kind in ('created','comment','move','returned','edit')),
  from_stage  text,
  to_stage    text,
  body        text,
  created_at  timestamptz not null default now()
);
create index if not exists task_events_task_idx on public.task_events (task_id, created_at);

alter table public.tasks       enable row level security;
alter table public.task_events enable row level security;
drop policy if exists "zadaci: vide članovi" on public.tasks;
create policy "zadaci: vide članovi" on public.tasks for select to authenticated using (public.is_member());
drop policy if exists "zadaci istorija: vide članovi" on public.task_events;
create policy "zadaci istorija: vide članovi" on public.task_events for select to authenticated using (public.is_member());
-- upis samo preko funkcija ispod

do $$ begin alter publication supabase_realtime add table public.tasks;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.task_events;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ---------- pomoćno ----------
create or replace function public.task_my_name()
returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(full_name,''), email, 'Neko') from public.profiles where id = auth.uid();
$$;
revoke execute on function public.task_my_name() from public, anon;

-- mejl preko Apps Script-a; adrese se čitaju iz profila (sajt ih ne šalje)
create or replace function public.task_mail(t public.tasks, ev text, to_ids uuid[], uprava boolean, note text, who text)
returns void language plpgsql security definer set search_path = public as $$
declare hook text; adrese text;
begin
  select value into hook from private.integrations where key = 'sheets_webhook';
  if hook is null then return; end if;
  select string_agg(distinct email, ', ') into adrese from public.profiles
   where id = any(coalesce(to_ids, '{}')) and email is not null and id is distinct from auth.uid();
  if adrese is null and not uprava then return; end if;
  perform net.http_post(url := hook,
    body := jsonb_build_object('kind', 'task_mail', 'event', ev, 'to', coalesce(adrese, ''), 'uprava', uprava,
      'note', note, 'who', who,
      'task', jsonb_build_object('id', t.id, 'title', t.title, 'description', t.description, 'area', t.area,
        'due', t.due, 'stage', t.stage, 'waiting_on', t.waiting_on, 'effort', t.effort,
        'assignee', (select coalesce(nullif(full_name,''), email) from public.profiles where id = t.assignee))),
    headers := '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds := 30000);
end $$;
revoke execute on function public.task_mail(public.tasks, text, uuid[], boolean, text, text) from public, anon, authenticated;

-- ---------- Administrator: nov zadatak / izmena ----------
drop function if exists public.task_save(uuid, text, text, text, uuid, date, jsonb);
create or replace function public.task_save(p_id uuid, p_title text, p_description text, p_area text,
                                            p_assignee uuid, p_due date, p_checklist jsonb, p_effort int default 1)
returns uuid language plpgsql security definer set search_path = public as $$
declare t public.tasks%rowtype; old public.tasks%rowtype; ime text := public.task_my_name();
begin
  if not public.is_admin() then raise exception 'Zadatke pravi i menja administrator.'; end if;
  if length(trim(coalesce(p_title,''))) < 2 then raise exception 'Upiši naziv zadatka.'; end if;
  if p_assignee is not null and not exists (select 1 from public.profiles where id = p_assignee and role in ('kuvar','sef','menadzer','admin')) then
    raise exception 'Izabrana osoba nema aktivan nalog.';
  end if;
  if jsonb_typeof(coalesce(p_checklist,'[]'::jsonb)) <> 'array' then raise exception 'Koraci nisu ispravni.'; end if;
  if coalesce(p_effort,1) not between 1 and 3 then raise exception 'Težina mora biti lako, srednje ili teško.'; end if;
  if p_id is null then
    insert into public.tasks (title, description, area, assignee, due, checklist, effort)
    values (trim(p_title), nullif(trim(p_description),''), coalesce(p_area,'ostalo'), p_assignee, p_due, coalesce(p_checklist,'[]'::jsonb), coalesce(p_effort,1))
    returning * into t;
    insert into public.task_events (task_id, author_name, kind, to_stage) values (t.id, ime, 'created', 'todo');
    if t.assignee is not null then perform public.task_mail(t, 'assigned', array[t.assignee], false, null, ime); end if;
  else
    select * into old from public.tasks where id = p_id for update;
    if not found then raise exception 'Zadatak ne postoji.'; end if;
    update public.tasks set title = trim(p_title), description = nullif(trim(p_description),''), area = coalesce(p_area,'ostalo'),
           assignee = p_assignee, due = p_due, checklist = coalesce(p_checklist,'[]'::jsonb), effort = coalesce(p_effort,1), updated_at = now()
     where id = p_id returning * into t;
    if old.assignee is distinct from t.assignee or old.due is distinct from t.due or old.title is distinct from t.title then
      insert into public.task_events (task_id, author_name, kind, body) values (t.id, ime, 'edit',
        concat_ws(' · ',
          case when old.title is distinct from t.title then 'naziv promenjen' end,
          case when old.assignee is distinct from t.assignee then 'dodeljeno: ' || coalesce((select coalesce(nullif(full_name,''),email) from public.profiles where id = t.assignee), 'niko') end,
          case when old.due is distinct from t.due then 'rok: ' || coalesce(to_char(t.due, 'DD.MM.YYYY.'), 'bez roka') end));
    end if;
    if t.assignee is not null and old.assignee is distinct from t.assignee then
      perform public.task_mail(t, 'assigned', array[t.assignee], false, null, ime);
    end if;
  end if;
  return t.id;
end $$;
revoke execute on function public.task_save(uuid, text, text, text, uuid, date, jsonb, int) from public, anon;
grant execute on function public.task_save(uuid, text, text, text, uuid, date, jsonb, int) to authenticated;

create or replace function public.task_archive(p_id uuid, p_archived boolean default true)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Samo administrator.'; end if;
  update public.tasks set archived = p_archived, updated_at = now() where id = p_id;
end $$;
revoke execute on function public.task_archive(uuid, boolean) from public, anon;
grant execute on function public.task_archive(uuid, boolean) to authenticated;

create or replace function public.task_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Samo administrator.'; end if;
  delete from public.tasks where id = p_id;
end $$;
revoke execute on function public.task_delete(uuid) from public, anon;
grant execute on function public.task_delete(uuid) to authenticated;

-- ---------- Pomeranje kartice ----------
-- osoba sa zadatkom: follow-up (šta čeka, od koga, do kada), nastavak posle čekanja, „Završio sam“ (zadatak bez koraka)
-- administrator: bilo koja faza; „provereno“ samo administrator; vraćanje iz urađeno/provereno = na doradu (napomena obavezna)
drop function if exists public.task_move(uuid, text, text, text);
create or replace function public.task_move(p_id uuid, p_stage text, p_note text default null,
                                            p_wait_kind text default null, p_wait_for uuid default null,
                                            p_wait_who text default null, p_wait_until date default null)
returns void language plpgsql security definer set search_path = public as $$
declare t public.tasks%rowtype; old_stage text; adm boolean := public.is_admin(); ime text := public.task_my_name(); vraceno boolean;
        opis text; kome uuid[];
begin
  if p_stage not in ('todo','doing','followup','done','verified') then raise exception 'Nepoznata faza.'; end if;
  select * into t from public.tasks where id = p_id for update;
  if not found then raise exception 'Zadatak ne postoji.'; end if;
  if not adm and t.assignee is distinct from auth.uid() then raise exception 'Možeš da menjaš samo svoje zadatke.'; end if;
  if p_stage = 'verified' and not adm then raise exception 'Proveru radi administrator.'; end if;
  if not adm and t.stage = 'verified' then raise exception 'Zadatak je već proveren. Javi se administratoru.'; end if;
  if p_stage = 'followup' then
    if p_wait_kind is null or p_wait_kind not in ('info','odobrenje','roba','druga_osoba','majstor','drugo') then raise exception 'Izaberi šta čekaš.'; end if;
    if p_wait_for is null and length(trim(coalesce(p_wait_who,''))) < 2 then raise exception 'Izaberi od koga čekaš.'; end if;
    if length(trim(coalesce(p_note,''))) < 3 then raise exception 'Napiši ukratko šta tačno čekaš.'; end if;
  end if;
  old_stage := t.stage;
  vraceno := old_stage in ('done','verified') and p_stage in ('todo','doing','followup') and adm and t.assignee is distinct from auth.uid();
  if vraceno and length(trim(coalesce(p_note,''))) < 2 then raise exception 'Napiši šta treba doraditi.'; end if;
  if old_stage = p_stage and p_stage <> 'followup' then return; end if;
  if p_stage = 'followup' then
    opis := (case p_wait_kind when 'info' then 'Informaciju ili podatak' when 'odobrenje' then 'Odobrenje' when 'roba' then 'Robu ili nabavku'
                   when 'druga_osoba' then 'Da neko završi svoj deo' when 'majstor' then 'Majstora ili popravku' else 'Nešto drugo' end)
            || ' od ' || coalesce((select coalesce(nullif(full_name,''), email) from public.profiles where id = p_wait_for), trim(p_wait_who))
            || ': ' || trim(p_note)
            || coalesce(' · očekuje do ' || to_char(p_wait_until, 'DD.MM.'), '');
  end if;
  update public.tasks set stage = p_stage, stage_at = now(), updated_at = now(),
         waiting_on = case when p_stage = 'followup' then opis end,
         wait_kind  = case when p_stage = 'followup' then p_wait_kind end,
         wait_for   = case when p_stage = 'followup' then p_wait_for end,
         wait_who   = case when p_stage = 'followup' then nullif(trim(p_wait_who),'') end,
         wait_until = case when p_stage = 'followup' then p_wait_until end,
         done_at = case when p_stage in ('done','verified') then coalesce(done_at, now()) else null end
   where id = p_id returning * into t;
  insert into public.task_events (task_id, author_name, kind, from_stage, to_stage, body)
  values (t.id, ime, case when vraceno then 'returned' else 'move' end, old_stage, p_stage,
          case when p_stage = 'followup' then opis else nullif(trim(coalesce(p_note,'')),'') end);
  if vraceno then
    perform public.task_mail(t, 'returned', array[t.assignee], false, p_note, ime);
  elsif p_stage = 'done' then
    perform public.task_mail(t, 'done', array[t.created_by], false, p_note, ime);
  elsif p_stage = 'verified' then
    perform public.task_mail(t, 'verified', array[t.assignee], false, p_note, ime);
  elsif p_stage = 'followup' then
    -- administratoru i osobi od koje se čeka (ako je u timu)
    kome := array[t.created_by] || case when p_wait_for is not null then array[p_wait_for] else '{}'::uuid[] end;
    perform public.task_mail(t, 'followup', kome, false, opis, ime);
  end if;
end $$;
revoke execute on function public.task_move(uuid, text, text, text, uuid, text, date) from public, anon;
grant execute on function public.task_move(uuid, text, text, text, uuid, text, date) to authenticated;

-- ---------- Korak (štikliranje): kartica se pomera sama ----------
-- prvi štiklirani korak → U toku; svi koraci štiklirani → Urađeno (administratoru stiže mejl za proveru);
-- odštikliran korak na urađenom (neproverenom) zadatku → nazad U toku
create or replace function public.task_check(p_id uuid, p_idx int, p_done boolean)
returns void language plpgsql security definer set search_path = public as $$
declare t public.tasks%rowtype; ukupno int; gotovo int; nova text; stara text; ime text := public.task_my_name();
begin
  select * into t from public.tasks where id = p_id for update;
  if not found then raise exception 'Zadatak ne postoji.'; end if;
  if not public.is_admin() and t.assignee is distinct from auth.uid() then raise exception 'Možeš da štikliraš samo svoje zadatke.'; end if;
  if not public.is_admin() and t.stage = 'verified' then raise exception 'Zadatak je već proveren.'; end if;
  if p_idx < 0 or p_idx >= jsonb_array_length(t.checklist) then raise exception 'Korak ne postoji.'; end if;
  update public.tasks set checklist = jsonb_set(checklist, array[p_idx::text, 'd'], to_jsonb(p_done)), updated_at = now()
   where id = p_id returning * into t;
  select count(*), count(*) filter (where (e->>'d')::boolean) into ukupno, gotovo from jsonb_array_elements(t.checklist) e;
  stara := t.stage; nova := stara;
  if gotovo = ukupno and stara in ('todo','doing','followup') then nova := 'done';
  elsif gotovo > 0 and stara = 'todo' then nova := 'doing';
  elsif gotovo < ukupno and stara = 'done' then nova := 'doing';
  end if;
  if nova <> stara then
    update public.tasks set stage = nova, stage_at = now(), waiting_on = null, wait_kind = null, wait_for = null, wait_who = null, wait_until = null,
           done_at = case when nova = 'done' then now() else null end
     where id = p_id returning * into t;
    insert into public.task_events (task_id, author_name, kind, from_stage, to_stage, body)
    values (t.id, ime, 'move', stara, nova, case when nova = 'done' then 'svi koraci štiklirani' when stara = 'todo' then 'prvi korak štikliran' else 'korak odštikliran' end);
    if nova = 'done' then perform public.task_mail(t, 'done', array[t.created_by], false, 'Svi koraci su štiklirani.', ime); end if;
  end if;
end $$;
revoke execute on function public.task_check(uuid, int, boolean) from public, anon;
grant execute on function public.task_check(uuid, int, boolean) to authenticated;

-- ---------- Komentar ----------
create or replace function public.task_comment(p_id uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare t public.tasks%rowtype; ime text := public.task_my_name(); kome uuid[];
begin
  if not public.is_member() then raise exception 'Nemaš pristup.'; end if;
  if length(trim(coalesce(p_body,''))) < 1 then raise exception 'Komentar je prazan.'; end if;
  select * into t from public.tasks where id = p_id;
  if not found then raise exception 'Zadatak ne postoji.'; end if;
  insert into public.task_events (task_id, author_name, kind, body) values (p_id, ime, 'comment', trim(p_body));
  -- piše osoba sa zadatkom → administrator koji je napravio zadatak; piše bilo ko drugi → osoba sa zadatkom
  kome := case when auth.uid() = t.assignee then array[t.created_by] else array[t.assignee, t.created_by] end;
  perform public.task_mail(t, 'comment', kome, false, trim(p_body), ime);
end $$;
revoke execute on function public.task_comment(uuid, text) from public, anon;
grant execute on function public.task_comment(uuid, text) to authenticated;

-- ---------- Dnevna obaveštenja u 9h i nedeljni pregled ponedeljkom ----------
create or replace function public.tasks_summary(a date, b date)
returns jsonb language sql stable security definer set search_path = public as $$
  with p as (
    select t.*, coalesce(nullif(pr.full_name,''), pr.email, 'Bez osobe') as who
      from public.tasks t left join public.profiles pr on pr.id = t.assignee where not t.archived
  )
  select jsonb_build_object('from', a, 'to', b,
    'people', coalesce((select jsonb_agg(x order by x.overdue desc, x.who) from (
      select who,
             count(*) filter (where stage in ('done','verified') and done_at::date between a and b) as done,
             count(*) filter (where stage = 'verified' and done_at::date between a and b) as verified,
             count(*) filter (where stage in ('todo','doing','followup') and due < current_date) as overdue,
             count(*) filter (where stage in ('todo','doing','followup') and (due is null or due >= current_date)) as open,
             count(*) filter (where stage = 'done') as to_check
        from p group by who) x), '[]'::jsonb),
    'overdue', coalesce((select jsonb_agg(jsonb_build_object('title', title, 'who', who, 'due', due, 'stage', stage) order by due)
                  from p where stage in ('todo','doing','followup') and due < current_date), '[]'::jsonb),
    'to_check', coalesce((select jsonb_agg(jsonb_build_object('title', title, 'who', who) order by stage_at)
                  from p where stage = 'done'), '[]'::jsonb),
    'this_week', coalesce((select jsonb_agg(jsonb_build_object('title', title, 'who', who, 'due', due, 'stage', stage) order by due)
                  from p where stage in ('todo','doing','followup') and due between current_date and current_date + 6), '[]'::jsonb));
$$;
revoke execute on function public.tasks_summary(date, date) from public, anon, authenticated;

create or replace function public.tasks_notify(force text default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  lokalno timestamp := now() at time zone 'Europe/Belgrade';
  danas date := lokalno::date;
  hook text; t public.tasks%rowtype; n int := 0; out text := '';
begin
  select value into hook from private.integrations where key = 'sheets_webhook';
  if hook is null then return 'nema veze'; end if;
  if force is null and extract(hour from lokalno) <> 9 then return 'nije 9h'; end if;

  if force is null or force = 'dnevni' then
    if force is null and exists (select 1 from private.sent_reports where kind = 'zadaci_dnevni' and day = danas) then return 'već poslato'; end if;
    -- podsetnik dan pre roka
    for t in select * from public.tasks where not archived and stage in ('todo','doing','followup') and due = danas + 1 and assignee is not null loop
      perform public.task_mail(t, 'reminder', array[t.assignee], false, null, null); n := n + 1;
    end loop;
    -- isteklo: prvi dan posle roka osobi + upravi, posle toga osobi svakog jutra dok ne završi
    for t in select * from public.tasks where not archived and stage in ('todo','doing','followup') and due < danas loop
      if t.due = danas - 1 then perform public.task_mail(t, 'overdue', array[t.assignee, t.created_by], true, null, null);
      else perform public.task_mail(t, 'overdue_again', array[t.assignee], false, null, null); end if;
      n := n + 1;
    end loop;
    -- čeka, a prošao je dan do kog je odgovor očekivan: podsetnik osobi i administratoru
    for t in select * from public.tasks where not archived and stage = 'followup' and wait_until < danas and (due is null or due >= danas) loop
      perform public.task_mail(t, 'wait_late', array[t.assignee, t.created_by, t.wait_for], false, t.waiting_on, null); n := n + 1;
    end loop;
    if force is null then insert into private.sent_reports (kind, day) values ('zadaci_dnevni', danas) on conflict do nothing; end if;
    out := n || ' obaveštenja ';
  end if;

  if (force is null and extract(isodow from danas) = 1 and not exists (select 1 from private.sent_reports where kind = 'zadaci_nedeljni' and day = danas))
     or force = 'nedeljni' then
    perform net.http_post(url := hook,
      body := jsonb_build_object('kind', 'task_weekly', 'summary', public.tasks_summary(danas - 7, danas - 1)),
      headers := '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds := 30000);
    if force is null then insert into private.sent_reports (kind, day) values ('zadaci_nedeljni', danas) on conflict do nothing; end if;
    out := out || 'nedeljni poslat';
  end if;
  return coalesce(nullif(trim(out),''), 'ništa');
end $$;
revoke execute on function public.tasks_notify(text) from public, anon, authenticated;

select cron.schedule('zadaci-obavestenja', '7 * * * *', 'select public.tasks_notify()');
