-- StreakFC v22: the kid's journals, game logs and check-ins come back with the player (any device). Safe to re-run.
create or replace function public.sfc_player_json(p_player uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'player', to_jsonb(p) - 'family_id',
    'history', coalesce((select json_object_agg(d, t) from (
        select date::text d, sum(touches) t from public.sfc_sessions
        where player_id = p.id and date >= current_date - 120 group by date) h), '{}'::json),
    'xp_days', public.sfc_xp_days(p.id),
    'speed', coalesce((select json_agg(json_build_object('date', s.date, 'test', s.rounds->0->'speed'->>'test',
        'val', (s.rounds->0->'speed'->>'val')::numeric, 'by', s.rounds->0->'speed'->>'by') order by s.date, s.created_at)
      from public.sfc_sessions s where s.player_id = p.id and s.mode = 'speed' and jsonb_typeof(s.rounds->0->'speed') = 'object'), '[]'::json),
    'logs', coalesce((select json_agg(json_build_object('date', s.date, 'mode', s.mode, 'source', s.source, 'r', s.rounds->0) order by s.date, s.created_at)
      from public.sfc_sessions s where s.player_id = p.id and s.date >= current_date - 90
        and s.mode in ('epa','checkin','weekly','film','pregame','game')), '[]'::json)
  ) from public.sfc_players p where p.id = p_player
$$;
select 'v22 ok' as status;
