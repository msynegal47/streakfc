-- StreakFC v18: game day logs, EPA session planner, session ids for the console. Safe to re-run.

-- Session ids in console data (so coaches can attach film to a game log). Games visible to coaches even on "EPA only" sharing.
create or replace function public.sfc_admin_data(p_days int default 30) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  return json_build_object(
    'families', coalesce((select json_agg(json_build_object('id', f.id, 'parent_name', f.parent_name, 'email', u.email,
        'created_at', f.created_at, 'flags', f.flags) order by f.created_at)
      from public.sfc_families f left join auth.users u on u.id = f.owner), '[]'::json),
    'players', coalesce((select json_agg(to_jsonb(p) order by p.created_at) from public.sfc_players p where not p.archived), '[]'::json),
    'sessions', coalesce((select json_agg(json_build_object('id', s.id, 'player_id', s.player_id, 'family_id', s.family_id, 'date', s.date,
        'touches', s.touches, 'xp', s.xp_earned, 'mode', s.mode, 'source', s.source, 'rounds', s.rounds, 'created_at', s.created_at)
        order by s.created_at desc)
      from public.sfc_sessions s where s.date >= current_date - least(greatest(p_days, 1), 120)), '[]'::json));
end $$;

create or replace function public.sfc_coach_data(p_program text, p_days int default 60) returns json
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
             or s.mode in ('epa','checkin','weekly','film','goalsheet','speed','game','pregame'))), '[]'::json),
    'notes', coalesce((select json_object_agg(n.player_id, json_build_object('focus', n.focus, 'note', n.note, 'updated_at', n.updated_at))
      from public.sfc_coach_notes n join public.sfc_players p on p.id = n.player_id where p.programs @> jsonb_build_array(jsonb_build_object('id', p_program))), '{}'::json),
    'plans', coalesce((select json_agg(to_jsonb(x) order by x.week_start) from public.sfc_plans x where x.program = p_program and x.week_start >= current_date - 60), '[]'::json),
    'code', (select code from public.sfc_program_codes where program = p_program));
end $$;

-- Coach attaches a film link to a player's game log after the fact
create or replace function public.sfc_coach_game_film(p_id bigint, p_url text) returns void
language plpgsql security definer set search_path = public as $$
declare s public.sfc_sessions;
begin
  select * into s from public.sfc_sessions where id = p_id and mode = 'game';
  if s.id is null or not public.sfc_can_manage(s.player_id) then raise exception 'not_coach'; end if;
  if coalesce(p_url, '') <> '' and (p_url !~ '^https://' or length(p_url) > 400) then raise exception 'bad_url'; end if;
  update public.sfc_sessions set rounds = jsonb_set(coalesce(rounds, '[{"game":{}}]'::jsonb), '{0,game,coachFilm}', to_jsonb(coalesce(p_url, ''))) where id = p_id;
end $$;

-- EPA session planner: one row per program day. data = {theme, title, family, blocks:[{t, what, coach, drill, note}]}
create table if not exists public.sfc_epa_days (
  program text not null default 'epa',
  day date not null,
  data jsonb not null default '{}',
  updated_at timestamptz not null default now(),
  primary key (program, day));
alter table public.sfc_epa_days enable row level security;
revoke all on public.sfc_epa_days from public, anon, authenticated;

create or replace function public.sfc_epa_days_list(p_program text, p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  return coalesce((select json_object_agg(day, data) from public.sfc_epa_days where program = p_program and day between p_from and p_to), '{}'::json);
end $$;
create or replace function public.sfc_epa_day_save(p_program text, p_day date, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  if p_data is null or p_data = '{}'::jsonb then delete from public.sfc_epa_days where program = p_program and day = p_day; return; end if;
  if jsonb_typeof(p_data) <> 'object' or length(p_data::text) > 8000 then raise exception 'bad_day'; end if;
  insert into public.sfc_epa_days(program, day, data, updated_at) values (p_program, p_day, p_data, now())
  on conflict (program, day) do update set data = excluded.data, updated_at = now();
end $$;

-- Kid app extras: videos, IDP, and the next 3 weeks of session themes (family-facing fields only)
create or replace function public.sfc_player_extras(p_token text, p_player uuid) returns json
language plpgsql volatile security definer set search_path = public as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token); pl public.sfc_players; progs text[];
begin
  select * into pl from public.sfc_players where id = p_player and family_id = d.family_id;
  if pl.id is null then raise exception 'not_on_this_device'; end if;
  select coalesce(array_agg(e->>'id'), '{}') into progs from jsonb_array_elements(coalesce(pl.programs, '[]'::jsonb)) e;
  return json_build_object(
    -- StreakFC library ('all') first, the coach's own version overrides it
    'media', coalesce((select json_object_agg(skill, json_build_object('url', url, 'title', title, 'by', case when program = 'all' then 'StreakFC' else 'coach' end) order by (program = 'all') desc) from public.sfc_media where program = any(progs || 'all'::text)), '{}'::json),
    'idp', coalesce((select json_object_agg(program, data) from public.sfc_idp where player_id = p_player and program = any(progs)), '{}'::json),
    'days', coalesce((select json_agg(json_build_object('program', program, 'day', day, 'theme', data->>'theme', 'title', data->>'title', 'family', data->>'family') order by day)
      from public.sfc_epa_days where program = any(progs) and day between current_date and current_date + 21), '[]'::json));
end $$;

revoke execute on function public.sfc_coach_game_film(bigint,text), public.sfc_epa_days_list(text,date,date), public.sfc_epa_day_save(text,date,jsonb) from public, anon;
grant  execute on function public.sfc_coach_game_film(bigint,text), public.sfc_epa_days_list(text,date,date), public.sfc_epa_day_save(text,date,jsonb) to authenticated;
grant  execute on function public.sfc_player_extras(text,uuid) to anon, authenticated;
select 'v18 ok' as status;
