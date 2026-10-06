-- ============================================================
-- StreakFC database update v5 (seasons)
-- Paste into Supabase > SQL Editor > New query > Run. Safe to re-run.
-- ============================================================

-- Season trophies per player: {"0":{"xp":1800,"peak":"REC 2ND TEAM","idx":4}, "1":{...}}
alter table public.sfc_players add column if not exists seasons jsonb not null default '{}';

-- Daily XP history long enough to cover a full 8-week season
create or replace function public.sfc_xp_days(p_player uuid) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_object_agg(d, x), '{}'::json) from (
    select date::text d, sum(xp_earned) x from public.sfc_sessions
    where player_id = p_player and date >= current_date - 70 group by date) t
$$;

-- Save kid progress: now also keeps season trophies
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
                         then seasons || (p_state->'seasons') else seasons end
  where id = p_player;
end $$;

revoke execute on function public.sfc_xp_days(uuid) from public, anon, authenticated;
revoke execute on function public.sfc_save_state(text,uuid,jsonb) from public;
grant  execute on function public.sfc_save_state(text,uuid,jsonb) to anon, authenticated;

-- Done.
