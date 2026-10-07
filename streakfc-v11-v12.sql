-- StreakFC v11: coach can log results for a player (speed/agility test day). Safe to re-run.
create or replace function public.sfc_admin_log_session(p_player uuid, p_session jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare fam uuid;
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  select family_id into fam from public.sfc_players where id = p_player;
  if fam is null then raise exception 'no_player'; end if;
  if (p_session->>'mode') not in ('speed') or length(p_session::text) > 2000 then raise exception 'bad_session'; end if;
  insert into public.sfc_sessions(family_id, player_id, date, touches, xp_earned, source, mode, rounds, full_session)
  values (fam, p_player, coalesce((p_session->>'date')::date, current_date), 0, 0, 'coach', 'speed',
    case when jsonb_typeof(p_session->'rounds') = 'array' then p_session->'rounds' else null end, false);
end $$;
revoke execute on function public.sfc_admin_log_session(uuid,jsonb) from public, anon;
grant  execute on function public.sfc_admin_log_session(uuid,jsonb) to authenticated;
select 'v11 ok' as status;

-- StreakFC v12: speed tests come back to every device (kid + coach-entered). Safe to re-run.
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
      from public.sfc_sessions s where s.player_id = p.id and s.mode = 'speed' and jsonb_typeof(s.rounds->0->'speed') = 'object'), '[]'::json)
  ) from public.sfc_players p where p.id = p_player
$$;
revoke execute on function public.sfc_player_json(uuid) from public, anon, authenticated;
select 'v12 ok' as status;
