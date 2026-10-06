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
