-- StreakFC v13: coach role (scoped to a program), coach invites, program join codes, parent share setting. Safe to re-run.

create table if not exists public.sfc_coaches (
  user_id uuid not null references auth.users(id) on delete cascade,
  program text not null,
  role    text not null default 'coach',      -- owner | coach
  name    text,
  created_at timestamptz not null default now(),
  primary key (user_id, program)
);
create table if not exists public.sfc_coach_invites (
  code text primary key, program text not null, role text not null default 'coach',
  created_at timestamptz not null default now(), used_by uuid, used_at timestamptz
);
create table if not exists public.sfc_program_codes (program text primary key, code text unique not null);
alter table public.sfc_coaches enable row level security;
alter table public.sfc_coach_invites enable row level security;
alter table public.sfc_program_codes enable row level security;
revoke all on public.sfc_coaches, public.sfc_coach_invites, public.sfc_program_codes from public, anon, authenticated;
insert into public.sfc_program_codes values ('epa', 'EPA-' || upper(substr(md5(random()::text), 1, 4))) on conflict do nothing;

-- Helpers
create or replace function public.sfc_coach_programs() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(program), '{}') from public.sfc_coaches where user_id = auth.uid()
$$;
create or replace function public.sfc_is_coach(p_program text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.sfc_is_admin() or p_program = any(public.sfc_coach_programs())
$$;
create or replace function public.sfc_can_manage(p_player uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.sfc_is_admin() or exists (select 1 from public.sfc_players p, unnest(public.sfc_coach_programs()) cp
    where p.id = p_player and p.programs @> jsonb_build_array(jsonb_build_object('id', cp)))
$$;
-- Keep program entries the caller does not coach; take the caller's program entries from the new value
create or replace function public.sfc_merge_programs(p_old jsonb, p_new jsonb) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public.sfc_is_admin() then p_new else
    coalesce((select jsonb_agg(e) from jsonb_array_elements(p_old) e where not (e->>'id' = any(public.sfc_coach_programs()))), '[]'::jsonb)
    || coalesce((select jsonb_agg(e) from jsonb_array_elements(p_new) e where e->>'id' = any(public.sfc_coach_programs())), '[]'::jsonb) end
$$;

create or replace function public.sfc_my_roles() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('admin', public.sfc_is_admin(),
    'coach', coalesce((select json_agg(json_build_object('program', program, 'role', role, 'name', name)) from public.sfc_coaches where user_id = auth.uid()), '[]'::json))
$$;

-- Coach data: only kids in the program. Parent's share setting decides whether home sessions are included.
create or replace function public.sfc_coach_data(p_program text, p_days int default 60) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  return json_build_object(
    'players', coalesce((select json_agg((to_jsonb(p) - 'reset_at') order by p.created_at) from public.sfc_players p
       where not p.archived and p.programs @> jsonb_build_array(jsonb_build_object('id', p_program))), '[]'::json),
    'sessions', coalesce((select json_agg(json_build_object('player_id', s.player_id, 'family_id', s.family_id, 'date', s.date, 'touches', s.touches, 'xp', s.xp_earned,
        'mode', s.mode, 'source', s.source, 'rounds', s.rounds, 'created_at', s.created_at) order by s.created_at desc)
      from public.sfc_sessions s join public.sfc_players p on p.id = s.player_id
      where p.programs @> jsonb_build_array(jsonb_build_object('id', p_program)) and s.date >= current_date - least(greatest(p_days, 1), 120)
        and (coalesce((select e->>'share' from jsonb_array_elements(p.programs) e where e->>'id' = p_program limit 1), 'all') = 'all'
             or s.mode in ('epa','checkin','weekly','film','goalsheet','speed'))), '[]'::json),
    'notes', coalesce((select json_object_agg(n.player_id, json_build_object('focus', n.focus, 'note', n.note, 'updated_at', n.updated_at))
      from public.sfc_coach_notes n join public.sfc_players p on p.id = n.player_id where p.programs @> jsonb_build_array(jsonb_build_object('id', p_program))), '{}'::json),
    'plans', coalesce((select json_agg(to_jsonb(x) order by x.week_start) from public.sfc_plans x where x.program = p_program and x.week_start >= current_date - 60), '[]'::json),
    'code', (select code from public.sfc_program_codes where program = p_program));
end $$;

-- Re-guard the console functions: admin OR coach of that program / player
create or replace function public.sfc_admin_plans() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.sfc_is_admin() or cardinality(public.sfc_coach_programs()) > 0) then raise exception 'not_admin'; end if;
  return coalesce((select json_agg(to_jsonb(p) order by p.week_start, p.created_at) from public.sfc_plans p
    where p.week_start >= current_date - 60 and (public.sfc_is_admin() or p.program = any(public.sfc_coach_programs()))), '[]'::json);
end $$;
create or replace function public.sfc_admin_save_plan(p_plan jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := coalesce((p_plan->>'id')::uuid, gen_random_uuid()); v_prog text := coalesce(p_plan->>'program','epa');
begin
  if not public.sfc_is_coach(v_prog) then raise exception 'not_coach'; end if;
  if exists (select 1 from public.sfc_plans where id = v_id and not public.sfc_is_coach(program)) then raise exception 'not_coach'; end if;
  if length(p_plan::text) > 8000 then raise exception 'too_big'; end if;
  insert into public.sfc_plans(id, program, week_start, target, focus, touches, emphasis, days, note)
  values (v_id, v_prog, (p_plan->>'week_start')::date, coalesce(p_plan->'target','{"who":"all"}'),
    left(p_plan->>'focus', 40), least(greatest(coalesce((p_plan->>'touches')::int, 0), 0), 5000),
    coalesce(array(select jsonb_array_elements_text(p_plan->'emphasis')), '{}'), coalesce(p_plan->'days','{}'), left(p_plan->>'note', 300))
  on conflict (id) do update set week_start = excluded.week_start, target = excluded.target, focus = excluded.focus, touches = excluded.touches,
    emphasis = excluded.emphasis, days = excluded.days, note = excluded.note;
  return v_id;
end $$;
create or replace function public.sfc_admin_delete_plan(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.sfc_plans where id = p_id and public.sfc_is_coach(program)) then raise exception 'not_coach'; end if;
  delete from public.sfc_plans where id = p_id;
end $$;
create or replace function public.sfc_admin_epa_focus(p_focus text, p_note text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.sfc_is_coach('epa') then raise exception 'not_coach'; end if;
  update public.sfc_players set programs = (
      select jsonb_agg(case when e->>'id' = 'epa'
        then e || jsonb_build_object('focus', left(coalesce(p_focus,''), 20), 'note', left(coalesce(p_note,''), 100)) else e end)
      from jsonb_array_elements(programs) e)
    where programs @> '[{"id":"epa"}]';
  get diagnostics n = row_count;
  return n;
end $$;
create or replace function public.sfc_admin_notes() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.sfc_is_admin() or cardinality(public.sfc_coach_programs()) > 0) then raise exception 'not_admin'; end if;
  return coalesce((select json_object_agg(player_id, json_build_object('focus', focus, 'note', note, 'updated_at', updated_at))
    from public.sfc_coach_notes where public.sfc_can_manage(player_id)), '{}'::json);
end $$;
create or replace function public.sfc_admin_set_note(p_player uuid, p_focus text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_can_manage(p_player) then raise exception 'not_coach'; end if;
  insert into public.sfc_coach_notes(player_id, focus, note, updated_at) values (p_player, left(p_focus, 200), left(p_note, 1000), now())
  on conflict (player_id) do update set focus = excluded.focus, note = excluded.note, updated_at = now();
end $$;
create or replace function public.sfc_admin_set_programs(p_player uuid, p_programs jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_can_manage(p_player) then raise exception 'not_coach'; end if;
  if jsonb_typeof(p_programs) <> 'array' or length(p_programs::text) > 4000 then raise exception 'bad_programs'; end if;
  update public.sfc_players set programs = public.sfc_merge_programs(programs, p_programs) where id = p_player;
end $$;
create or replace function public.sfc_admin_update_player(p_player uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_can_manage(p_player) then raise exception 'not_coach'; end if;
  if jsonb_typeof(p_patch) <> 'object' or length(p_patch::text) > 4000 then raise exception 'bad_patch'; end if;
  update public.sfc_players set
    programs = case when jsonb_typeof(p_patch->'programs') = 'array' then public.sfc_merge_programs(programs, p_patch->'programs') else programs end,
    pos1     = case when p_patch ? 'pos1' then left(p_patch->>'pos1', 6) else pos1 end,
    pos2     = case when p_patch ? 'pos2' then left(p_patch->>'pos2', 6) else pos2 end,
    goals    = case when p_patch ? 'goal_comment' then jsonb_set(goals, '{coach}', to_jsonb(left(p_patch->>'goal_comment', 300))) else goals end
  where id = p_player;
end $$;
create or replace function public.sfc_admin_log_session(p_player uuid, p_session jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare fam uuid;
begin
  if not public.sfc_can_manage(p_player) then raise exception 'not_coach'; end if;
  select family_id into fam from public.sfc_players where id = p_player;
  if (p_session->>'mode') not in ('speed') or length(p_session::text) > 2000 then raise exception 'bad_session'; end if;
  insert into public.sfc_sessions(family_id, player_id, date, touches, xp_earned, source, mode, rounds, full_session)
  values (fam, p_player, coalesce((p_session->>'date')::date, current_date), 0, 0, 'coach', 'speed',
    case when jsonb_typeof(p_session->'rounds') = 'array' then p_session->'rounds' else null end, false);
end $$;

-- Coach invites (admin creates, coach accepts after signing in)
create or replace function public.sfc_admin_create_invite(p_program text, p_role text) returns text
language plpgsql security definer set search_path = public as $$
declare c text := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  insert into public.sfc_coach_invites(code, program, role) values (c, p_program, case when p_role = 'owner' then 'owner' else 'coach' end);
  return c;
end $$;
create or replace function public.sfc_accept_invite(p_code text, p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare i public.sfc_coach_invites;
begin
  select * into i from public.sfc_coach_invites where code = upper(p_code) and used_by is null and created_at > now() - interval '14 days';
  if i.code is null then raise exception 'invite_invalid'; end if;
  insert into public.sfc_coaches(user_id, program, role, name) values (auth.uid(), i.program, i.role, left(p_name, 40))
  on conflict (user_id, program) do update set role = excluded.role, name = excluded.name;
  update public.sfc_coach_invites set used_by = auth.uid(), used_at = now() where code = i.code;
  return i.program;
end $$;
create or replace function public.sfc_admin_coaches() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  return json_build_object(
    'coaches', coalesce((select json_agg(json_build_object('user_id', c.user_id, 'program', c.program, 'role', c.role, 'name', c.name, 'email', u.email, 'created_at', c.created_at))
      from public.sfc_coaches c left join auth.users u on u.id = c.user_id), '[]'::json),
    'invites', coalesce((select json_agg(to_jsonb(i) order by i.created_at desc) from public.sfc_coach_invites i where i.used_by is null and i.created_at > now() - interval '14 days'), '[]'::json));
end $$;
create or replace function public.sfc_admin_remove_coach(p_user uuid, p_program text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  delete from public.sfc_coaches where user_id = p_user and program = p_program;
end $$;

-- Parent: join a program with its code (kid must be in their family)
create or replace function public.sfc_join_program(p_player uuid, p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare prog text; p public.sfc_players; n int;
begin
  select program into prog from public.sfc_program_codes where code = upper(trim(p_code));
  if prog is null then raise exception 'code_invalid'; end if;
  select * into p from public.sfc_players where id = p_player and family_id = public.sfc_my_family();
  if p.id is null then raise exception 'not_your_player'; end if;
  if p.programs @> jsonb_build_array(jsonb_build_object('id', prog)) then return prog; end if;
  n := nullif(regexp_replace(coalesce(p.age_group,''), '\D', '', 'g'), '')::int;
  update public.sfc_players set programs = programs || jsonb_build_array(jsonb_build_object('id', prog,
    'group', case when n >= 13 then 'older' else 'younger' end, 'focus', '', 'note', '', 'share', 'all')) where id = p_player;
  return prog;
end $$;

do $$ declare f text; begin
  foreach f in array array['sfc_coach_programs()','sfc_is_coach(text)','sfc_can_manage(uuid)','sfc_merge_programs(jsonb,jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f); end loop;
  foreach f in array array['sfc_my_roles()','sfc_coach_data(text,int)','sfc_admin_create_invite(text,text)','sfc_accept_invite(text,text)',
      'sfc_admin_coaches()','sfc_admin_remove_coach(uuid,text)','sfc_join_program(uuid,text)','sfc_admin_plans()','sfc_admin_save_plan(jsonb)',
      'sfc_admin_delete_plan(uuid)','sfc_admin_epa_focus(text,text)','sfc_admin_notes()','sfc_admin_set_note(uuid,text,text)',
      'sfc_admin_set_programs(uuid,jsonb)','sfc_admin_update_player(uuid,jsonb)','sfc_admin_log_session(uuid,jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f); end loop;
end $$;
select 'v13 ok' as status, (select code from public.sfc_program_codes where program = 'epa') as epa_join_code;
