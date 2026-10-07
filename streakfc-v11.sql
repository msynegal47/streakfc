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
