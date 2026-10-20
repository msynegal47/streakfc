-- StreakFC v25: trainer lesson log (difficulty, how they did, work on, homework), family + kid view, connect link info, PFA org. Safe to re-run.

-- Roster row for a connected player (created on first note/lesson)
create or replace function public.sfc_roster_ensure(p_program text, p_player uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare rid uuid; pl public.sfc_players;
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  select id into rid from public.sfc_org_roster where program = p_program and player_id = p_player;
  if rid is not null then return rid; end if;
  select * into pl from public.sfc_players where id = p_player and programs @> jsonb_build_array(jsonb_build_object('id', p_program));
  if pl.id is null then raise exception 'not_in_program'; end if;
  insert into public.sfc_org_roster(org, program, nickname, age_group, claim_code, player_id, created_by)
    values (public.sfc_program_org(p_program), p_program, pl.nickname, pl.age_group, 'P-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)), p_player, auth.uid())
    returning id into rid;
  return rid;
end $$;

-- Post-session log. diff = session difficulty 1-5, rate = how they did 1-5. work + hw are shared with the family, private stays staff only.
create or replace function public.sfc_roster_lesson(p_id uuid, p_date date, p_diff int, p_rate int, p_work text, p_hw text, p_private text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.sfc_org_roster;
begin
  select * into r from public.sfc_org_roster where id = p_id;
  if r.id is null or not public.sfc_is_coach(r.program) then raise exception 'not_coach'; end if;
  if p_diff not between 1 and 5 or p_rate not between 1 and 5 then raise exception 'bad_rating'; end if;
  update public.sfc_org_roster set notes = notes || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
    'kind', 'lesson', 'date', coalesce(p_date, current_date),
    'by', coalesce((select name from public.sfc_staff where org = r.org and user_id = auth.uid()), 'Coach'),
    'diff', p_diff, 'rate', p_rate, 'work', nullif(left(trim(coalesce(p_work, '')), 300), ''),
    'hw', nullif(left(trim(coalesce(p_hw, '')), 300), ''), 'text', nullif(left(trim(coalesce(p_private, '')), 1000), '')))) where id = p_id;
end $$;

-- What the family sees: lessons only (never the private text), for programs the kid is still in
create or replace function public.sfc_lessons_json(p_player uuid) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('program', r.program, 'program_name', p.name, 'org', o.id, 'org_name', o.name, 'short', o.short, 'brand', o.brand,
      'date', n->>'date', 'by', n->>'by', 'diff', (n->>'diff')::int, 'rate', (n->>'rate')::int, 'work', n->>'work', 'hw', n->>'hw') order by n->>'date'), '[]'::json)
  from public.sfc_org_roster r join public.sfc_players pl on pl.id = r.player_id
    join public.sfc_org_programs p on p.id = r.program join public.sfc_orgs o on o.id = r.org,
    jsonb_array_elements(r.notes) n
  where r.player_id = p_player and n->>'kind' = 'lesson' and pl.programs @> jsonb_build_array(jsonb_build_object('id', r.program))
$$;
revoke execute on function public.sfc_lessons_json(uuid) from public, anon, authenticated;

create or replace function public.sfc_family_lessons() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_object_agg(id, public.sfc_lessons_json(id)), '{}'::json) from public.sfc_players where family_id = public.sfc_my_family() and not archived
$$;

create or replace function public.sfc_player_extras(p_token text, p_player uuid) returns json
language plpgsql security definer set search_path = public as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token); pl public.sfc_players; progs text[];
begin
  select * into pl from public.sfc_players where id = p_player and family_id = d.family_id;
  if pl.id is null then raise exception 'not_on_this_device'; end if;
  select coalesce(array_agg(e->>'id'), '{}') into progs from jsonb_array_elements(coalesce(pl.programs, '[]'::jsonb)) e;
  return json_build_object(
    'media', coalesce((select json_object_agg(skill, json_build_object('url', url, 'title', title, 'by', case when program = 'all' then 'StreakFC' else 'coach' end) order by (program = 'all') desc) from public.sfc_media where program = any(progs || 'all'::text)), '{}'::json),
    'idp', coalesce((select json_object_agg(program, data) from public.sfc_idp where player_id = p_player and program = any(progs)), '{}'::json),
    'days', coalesce((select json_agg(json_build_object('program', program, 'day', day, 'theme', data->>'theme', 'title', data->>'title', 'family', data->>'family') order by day)
      from public.sfc_epa_days where program = any(progs) and day between current_date and current_date + 21), '[]'::json),
    'orgs', coalesce((select json_object_agg(p.id, json_build_object('program', p.name, 'kind', p.kind, 'org', o.id, 'org_name', o.name, 'short', o.short, 'org_kind', o.kind, 'brand', o.brand))
      from public.sfc_org_programs p join public.sfc_orgs o on o.id = p.org where p.id = any(progs)), '{}'::json),
    'lessons', public.sfc_lessons_json(p_player));
end $$;

-- Connect link preview (anyone with the code): who it's for, which trainer. Nothing once claimed.
create or replace function public.sfc_claim_info(p_code text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('nickname', r.nickname, 'age_group', r.age_group, 'org_name', o.name, 'short', o.short, 'logo', o.brand->>'logo', 'program_name', p.name,
    'lessons', (select count(*) from jsonb_array_elements(r.notes) n where n->>'kind' = 'lesson'))
  from public.sfc_org_roster r join public.sfc_orgs o on o.id = r.org join public.sfc_org_programs p on p.id = r.program
  where r.claim_code = upper(trim(coalesce(p_code, ''))) and r.player_id is null
$$;

-- Roster list now says when homework was last marked done
create or replace function public.sfc_roster_list(p_program text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  return coalesce((select json_agg(json_build_object('id', id, 'nickname', nickname, 'age_group', age_group, 'notes', notes, 'claim_code', claim_code,
    'player_id', player_id, 'created_at', created_at,
    'hw_done', (select max(s.date) from public.sfc_sessions s where s.player_id = r.player_id and s.mode = 'homework')) order by created_at)
    from public.sfc_org_roster r where program = p_program), '[]'::json);
end $$;

-- Homework counts as program data (coach sees it even when the parent shares program-only)
create or replace function public.sfc_coach_data(p_program text, p_days integer default 60) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  return json_build_object(
    'players', coalesce((select json_agg((to_jsonb(p) - 'reset_at') order by p.created_at) from public.sfc_players p
       where not p.archived and p.programs @> jsonb_build_array(jsonb_build_object('id', p_program))), '[]'::json),
    'sessions', coalesce((select json_agg(json_build_object('id', s.id, 'player_id', s.player_id, 'family_id', s.family_id, 'date', s.date, 'touches', s.touches, 'xp', s.xp_earned,
        'mode', s.mode, 'source', s.source, 'rounds', s.rounds, 'created_at', s.created_at) order by s.created_at desc)
      from public.sfc_sessions s join public.sfc_players p on p.id = s.player_id
      where p.programs @> jsonb_build_array(jsonb_build_object('id', p_program)) and s.date >= current_date - least(greatest(p_days, 1), 120)
        and (coalesce((select e->>'share' from jsonb_array_elements(p.programs) e where e->>'id' = p_program limit 1), 'all') = 'all'
             or s.mode in ('epa','checkin','weekly','film','goalsheet','speed','game','pregame','homework'))), '[]'::json),
    'notes', coalesce((select json_object_agg(n.player_id, json_build_object('focus', n.focus, 'note', n.note, 'updated_at', n.updated_at))
      from public.sfc_coach_notes n join public.sfc_players p on p.id = n.player_id where p.programs @> jsonb_build_array(jsonb_build_object('id', p_program))), '{}'::json),
    'plans', coalesce((select json_agg(to_jsonb(x) order by x.week_start) from public.sfc_plans x where x.program = p_program and x.week_start >= current_date - 60), '[]'::json),
    'code', (select code from public.sfc_program_codes where program = p_program));
end $$;

-- One homework check-off per day
create or replace function public.sfc_log_session(p_token text, p_player uuid, p_session jsonb, p_state jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token);
  m text := left(p_session->>'mode', 20); dt date := coalesce((p_session->>'date')::date, current_date);
  have int; t int := least(greatest(coalesce((p_session->>'touches')::int, 0), 0), 20000);
begin
  if not exists (select 1 from public.sfc_players where id = p_player and family_id = d.family_id)
    then raise exception 'not_on_this_device'; end if;
  if m in ('epa','checkin','goalsheet','homework') and exists (select 1 from public.sfc_sessions where player_id = p_player and date = dt and mode = m and source = 'kid') then return; end if;
  if m = 'weekly' and exists (select 1 from public.sfc_sessions where player_id = p_player and mode = 'weekly' and source = 'kid'
       and date_trunc('week', date) = date_trunc('week', dt::timestamp)) then return; end if;
  select coalesce(sum(touches), 0) into have from public.sfc_sessions where player_id = p_player and date = dt;
  t := greatest(0, least(t, 6000 - have));
  insert into public.sfc_sessions(family_id, player_id, date, touches, juggle_high, juggle_total,
    bm_skills, mv_skills, difficulty, full_session, xp_earned, source, mode, rounds)
  values (d.family_id, p_player, dt, t,
    coalesce((p_session->>'juggle_high')::int, 0), coalesce((p_session->>'juggle_total')::int, 0),
    coalesce(array(select jsonb_array_elements_text(p_session->'bm_skills')), '{}'),
    coalesce(array(select jsonb_array_elements_text(p_session->'mv_skills')), '{}'),
    p_session->>'difficulty', coalesce((p_session->>'full_session')::boolean, false),
    least(greatest(coalesce((p_session->>'xp_earned')::int, 0), 0), 1000), 'kid', m,
    case when jsonb_typeof(p_session->'rounds') = 'array' then p_session->'rounds' else null end);
  perform public.sfc_save_state(p_token, p_player, p_state);
end $$;

revoke execute on function public.sfc_roster_ensure(text,uuid), public.sfc_roster_lesson(uuid,date,int,int,text,text,text), public.sfc_family_lessons() from public, anon;
grant execute on function public.sfc_roster_ensure(text,uuid), public.sfc_roster_lesson(uuid,date,int,int,text,text,text), public.sfc_family_lessons() to authenticated;
grant execute on function public.sfc_claim_info(text) to anon, authenticated;

-- PFA: Precision Futebol Academy (Ryan Flood). Purple / black / white.
insert into public.sfc_orgs(id, name, short, kind, brand) values ('pfa', 'Precision Futebol Academy', 'PFA', 'trainer',
  '{"logo":"/brand/pfa-crest.png","accent":"#a78bfa","deep":"#1a1033"}') on conflict (id) do update set brand = excluded.brand, name = excluded.name, short = excluded.short;
insert into public.sfc_org_programs(id, org, name, kind, active, sort) values ('pfa-private', 'pfa', 'Private 1:1', 'private', true, 1), ('pfa-group', 'pfa', 'Small group', 'group', true, 2) on conflict (id) do nothing;
insert into public.sfc_program_codes(program, code) values ('pfa-private', 'PFA-' || upper(substr(md5(random()::text || 'pfa-private'), 1, 4))), ('pfa-group', 'PFA-' || upper(substr(md5(random()::text || 'pfa-group'), 1, 4))) on conflict do nothing;
select 'v25 ok' as status;
