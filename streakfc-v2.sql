-- ============================================================
-- StreakFC database update v2 (session engine)
-- Paste into Supabase > SQL Editor > New query > Run.
-- Additive only. Safe to re-run. Keeps all existing data.
-- ============================================================

alter table public.sfc_players  add column if not exists schedule jsonb not null default '{}';   -- {"practice":[2,4],"game":[6]} weekday 0=Sun
alter table public.sfc_players  add column if not exists pbs      jsonb not null default '{}';   -- {"toe_taps_60": 112, ...}
alter table public.sfc_players  add column if not exists growing  boolean not null default false;
alter table public.sfc_sessions add column if not exists mode     text;                          -- timed | goal | recovery | parent
alter table public.sfc_sessions add column if not exists rounds   jsonb;                         -- [{"skill":"toe_taps","secs":60,"count":112}, ...]

-- Save kid progress (whitelisted fields only, with sanity limits). Now includes PBs.
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
    pbs           = case when jsonb_typeof(p_state->'pbs') = 'object' then p_state->'pbs' else pbs end
  where id = p_player;
end $$;

create or replace function public.sfc_log_session(p_token text, p_player uuid, p_session jsonb, p_state jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token);
begin
  if not exists (select 1 from public.sfc_players where id = p_player and family_id = d.family_id)
    then raise exception 'not_on_this_device'; end if;
  insert into public.sfc_sessions(family_id, player_id, date, touches, juggle_high, juggle_total,
    bm_skills, mv_skills, difficulty, full_session, xp_earned, source, mode, rounds)
  values (d.family_id, p_player, coalesce((p_session->>'date')::date, current_date),
    least(greatest(coalesce((p_session->>'touches')::int, 0), 0), 20000),
    coalesce((p_session->>'juggle_high')::int, 0), coalesce((p_session->>'juggle_total')::int, 0),
    coalesce(array(select jsonb_array_elements_text(p_session->'bm_skills')), '{}'),
    coalesce(array(select jsonb_array_elements_text(p_session->'mv_skills')), '{}'),
    p_session->>'difficulty', coalesce((p_session->>'full_session')::boolean, false),
    least(greatest(coalesce((p_session->>'xp_earned')::int, 0), 0), 1000), 'kid',
    left(p_session->>'mode', 20),
    case when jsonb_typeof(p_session->'rounds') = 'array' then p_session->'rounds' else null end);
  perform public.sfc_save_state(p_token, p_player, p_state);
end $$;

-- Re-assert permissions on the replaced functions
revoke execute on function public.sfc_save_state(text,uuid,jsonb), public.sfc_log_session(text,uuid,jsonb,jsonb) from public;
grant  execute on function public.sfc_save_state(text,uuid,jsonb), public.sfc_log_session(text,uuid,jsonb,jsonb) to anon, authenticated;

-- Done.
