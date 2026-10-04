-- ============================================================
-- StreakFC database update v3 (weekly crew board)
-- Paste into Supabase > SQL Editor > New query > Run.
-- Read-only change: adds each kid's XP per day (last 14 days)
-- to what paired devices already receive. Safe to re-run.
-- ============================================================

create or replace function public.sfc_xp_days(p_player uuid) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_object_agg(d, x), '{}'::json) from (
    select date::text d, sum(xp_earned) x from public.sfc_sessions
    where player_id = p_player and date >= current_date - 14 group by date) t
$$;

create or replace function public.sfc_roster_json(p_family uuid) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
    'id', id, 'nickname', nickname, 'color', color, 'age_group', age_group,
    'avatar', avatar, 'unlocks', unlocks, 'xp', xp, 'streak', streak,
    'last_log', last_log, 'best_streak', best_streak, 'created_at', created_at,
    'xp_days', public.sfc_xp_days(id)
  ) order by created_at), '[]'::json)
  from public.sfc_players where family_id = p_family and not archived
$$;

create or replace function public.sfc_player_json(p_player uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'player', to_jsonb(p) - 'family_id',
    'history', coalesce((select json_object_agg(d, t) from (
        select date::text d, sum(touches) t from public.sfc_sessions
        where player_id = p.id and date >= current_date - 120 group by date) h), '{}'::json),
    'xp_days', public.sfc_xp_days(p.id)
  ) from public.sfc_players p where p.id = p_player
$$;

-- Internal helpers: not callable from the app directly
revoke execute on function public.sfc_xp_days(uuid), public.sfc_roster_json(uuid), public.sfc_player_json(uuid) from public, anon, authenticated;

-- Done.
