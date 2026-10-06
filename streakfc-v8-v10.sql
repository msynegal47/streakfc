-- StreakFC v8: positions, season goals, private coach notes. Safe to re-run.
alter table public.sfc_players add column if not exists pos1  text;                          -- preferred position
alter table public.sfc_players add column if not exists pos2  text;                          -- secondary position
alter table public.sfc_players add column if not exists goals jsonb not null default '{}';   -- {"items":[{"t":"..","done":false}],"coach":"comment"}

-- Private coach notes: no direct access for anyone; admin/coach functions only. Kids and parents never see these.
create table if not exists public.sfc_coach_notes (
  player_id  uuid primary key references public.sfc_players(id) on delete cascade,
  focus      text,
  note       text,
  updated_at timestamptz not null default now()
);
alter table public.sfc_coach_notes enable row level security;
revoke all on public.sfc_coach_notes from public, anon, authenticated;

-- Admin: update a few player fields (programs, positions, goals coach comment)
create or replace function public.sfc_admin_update_player(p_player uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  if jsonb_typeof(p_patch) <> 'object' or length(p_patch::text) > 4000 then raise exception 'bad_patch'; end if;
  update public.sfc_players set
    programs = case when jsonb_typeof(p_patch->'programs') = 'array' then p_patch->'programs' else programs end,
    pos1     = case when p_patch ? 'pos1' then left(p_patch->>'pos1', 6) else pos1 end,
    pos2     = case when p_patch ? 'pos2' then left(p_patch->>'pos2', 6) else pos2 end,
    goals    = case when p_patch ? 'goal_comment' then jsonb_set(goals, '{coach}', to_jsonb(left(p_patch->>'goal_comment', 300))) else goals end
  where id = p_player;
end $$;

create or replace function public.sfc_admin_notes() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  return coalesce((select json_object_agg(player_id, json_build_object('focus', focus, 'note', note, 'updated_at', updated_at)) from public.sfc_coach_notes), '{}'::json);
end $$;

create or replace function public.sfc_admin_set_note(p_player uuid, p_focus text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  insert into public.sfc_coach_notes(player_id, focus, note, updated_at) values (p_player, left(p_focus, 200), left(p_note, 1000), now())
  on conflict (player_id) do update set focus = excluded.focus, note = excluded.note, updated_at = now();
end $$;

revoke execute on function public.sfc_admin_update_player(uuid,jsonb), public.sfc_admin_notes(), public.sfc_admin_set_note(uuid,text,text) from public, anon;
grant  execute on function public.sfc_admin_update_player(uuid,jsonb), public.sfc_admin_notes(), public.sfc_admin_set_note(uuid,text,text) to authenticated;
select 'v8 ok' as status;

-- StreakFC v9: kid goal worksheet syncs to the server (goals.sheet). Safe to re-run.
create or replace function public.sfc_save_state(p_token text, p_player uuid, p_state jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token); old public.sfc_players;
begin
  select * into old from public.sfc_players where id = p_player and family_id = d.family_id;
  if old.id is null then raise exception 'not_on_this_device'; end if;
  update public.sfc_players set
    xp            = greatest(0, least(coalesce((p_state->>'xp')::int, xp), xp + 2000)),
    streak        = greatest(0, coalesce((p_state->>'streak')::int, streak)),
    best_streak   = greatest(best_streak, coalesce((p_state->>'best_streak')::int, 0)),
    last_log      = coalesce((p_state->>'last_log')::date, last_log),
    total_touches = greatest(0, least(coalesce((p_state->>'total_touches')::int, total_touches), total_touches + 20000)),
    sessions      = greatest(0, coalesce((p_state->>'sessions')::int, sessions)),
    juggle_pb     = greatest(0, least(coalesce((p_state->>'juggle_pb')::int, juggle_pb), 10000)),
    avatar        = coalesce(p_state->'avatar', avatar),
    unlocks       = coalesce(p_state->'unlocks', unlocks),
    badges        = coalesce(p_state->'badges', badges),
    pbs           = case when jsonb_typeof(p_state->'pbs') = 'object' then p_state->'pbs' else pbs end,
    seasons       = case when jsonb_typeof(p_state->'seasons') = 'object' and length(p_state->>'seasons') < 4000
                         then seasons || (p_state->'seasons') else seasons end,
    -- kid can only write their own worksheet; parent goals and coach comments are untouched
    goals         = case when jsonb_typeof(p_state->'goals'->'sheet') = 'object' and length(p_state->'goals'->>'sheet') < 4000
                         then jsonb_set(goals, '{sheet}', p_state->'goals'->'sheet') else goals end
  where id = p_player;
end $$;
revoke execute on function public.sfc_save_state(text,uuid,jsonb) from public;
grant  execute on function public.sfc_save_state(text,uuid,jsonb) to anon, authenticated;
select 'v9 ok' as status;

-- StreakFC v10: coach touch plans (assign to all, a group, positions or specific players). Safe to re-run.
create table if not exists public.sfc_plans (
  id         uuid primary key default gen_random_uuid(),
  program    text not null default 'epa',
  week_start date not null,                         -- Monday
  target     jsonb not null default '{"who":"all"}', -- {"who":"all|younger|older|pos|players","pos":["CM"],"players":["uuid"]}
  focus      text,
  touches    int,                                   -- daily home touch target
  emphasis   text[] not null default '{}',
  days       jsonb not null default '{}',           -- {"1":"Juggling ladder","3":"Light, EPA day"} weekday 0=Sun
  note       text,
  created_at timestamptz not null default now()
);
alter table public.sfc_plans enable row level security;
revoke all on public.sfc_plans from public, anon, authenticated;

create or replace function public.sfc_admin_plans() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  return coalesce((select json_agg(to_jsonb(p) order by p.week_start, p.created_at) from public.sfc_plans p where p.week_start >= current_date - 60), '[]'::json);
end $$;

create or replace function public.sfc_admin_save_plan(p_plan jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := coalesce((p_plan->>'id')::uuid, gen_random_uuid());
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  if length(p_plan::text) > 8000 then raise exception 'too_big'; end if;
  insert into public.sfc_plans(id, program, week_start, target, focus, touches, emphasis, days, note)
  values (v_id, coalesce(p_plan->>'program','epa'), (p_plan->>'week_start')::date, coalesce(p_plan->'target','{"who":"all"}'),
    left(p_plan->>'focus', 40), least(greatest(coalesce((p_plan->>'touches')::int, 0), 0), 5000),
    coalesce(array(select jsonb_array_elements_text(p_plan->'emphasis')), '{}'), coalesce(p_plan->'days','{}'), left(p_plan->>'note', 300))
  on conflict (id) do update set week_start = excluded.week_start, target = excluded.target, focus = excluded.focus, touches = excluded.touches,
    emphasis = excluded.emphasis, days = excluded.days, note = excluded.note;
  return v_id;
end $$;

create or replace function public.sfc_admin_delete_plan(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  delete from public.sfc_plans where id = p_id;
end $$;

-- Kid device: plans for this week and next that apply to this player
drop function if exists public.sfc_player_plans(text,uuid);
create or replace function public.sfc_player_plans(p_token text, p_player uuid) returns json
language plpgsql volatile security definer set search_path = public as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token); pl public.sfc_players; grp text;
begin
  select * into pl from public.sfc_players where id = p_player and family_id = d.family_id;
  if pl.id is null then raise exception 'not_on_this_device'; end if;
  select e->>'group' into grp from jsonb_array_elements(pl.programs) e where e->>'id' = 'epa' limit 1;
  if grp is null then return '[]'::json; end if;
  return coalesce((select json_agg(json_build_object('week_start', p.week_start, 'focus', p.focus, 'touches', p.touches, 'emphasis', p.emphasis, 'days', p.days, 'note', p.note) order by p.week_start)
    from public.sfc_plans p
    where p.program = 'epa' and p.week_start between date_trunc('week', current_date)::date - 7 and date_trunc('week', current_date)::date + 7
      and (p.target->>'who' = 'all' or p.target->>'who' = grp
        or (p.target->>'who' = 'pos' and (p.target->'pos' ? coalesce(pl.pos1,'') or p.target->'pos' ? coalesce(pl.pos2,'')))
        or (p.target->>'who' = 'players' and p.target->'players' ? pl.id::text))), '[]'::json);
end $$;

revoke execute on function public.sfc_admin_plans(), public.sfc_admin_save_plan(jsonb), public.sfc_admin_delete_plan(uuid), public.sfc_player_plans(text,uuid) from public, anon, authenticated;
grant  execute on function public.sfc_admin_plans(), public.sfc_admin_save_plan(jsonb), public.sfc_admin_delete_plan(uuid) to authenticated;
grant  execute on function public.sfc_player_plans(text,uuid) to anon, authenticated;
select 'v10 ok' as status;
