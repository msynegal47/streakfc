-- StreakFC v15: one EPA / check-in / goal sheet per kid per day (and one week log per week), no matter how many devices.
-- Server-side daily touch cap. Cleans up existing duplicates. Safe to re-run.
create or replace function public.sfc_log_session(p_token text, p_player uuid, p_session jsonb, p_state jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token);
  m text := left(p_session->>'mode', 20); dt date := coalesce((p_session->>'date')::date, current_date);
  have int; t int := least(greatest(coalesce((p_session->>'touches')::int, 0), 0), 20000);
begin
  if not exists (select 1 from public.sfc_players where id = p_player and family_id = d.family_id)
    then raise exception 'not_on_this_device'; end if;
  -- Duplicate from a second device: ignore it (and its XP)
  if m in ('epa','checkin','goalsheet') and exists (select 1 from public.sfc_sessions where player_id = p_player and date = dt and mode = m and source = 'kid') then return; end if;
  if m = 'weekly' and exists (select 1 from public.sfc_sessions where player_id = p_player and mode = 'weekly' and source = 'kid'
       and date_trunc('week', date) = date_trunc('week', dt::timestamp)) then return; end if;
  -- Daily touch cap (server backstop; the app caps lower by age)
  select coalesce(sum(touches), 0) into have from public.sfc_sessions where player_id = p_player and date = dt;
  t := greatest(0, least(t, 6000 - have));
  insert into public.sfc_sessions(family_id, player_id, date, touches, juggle_high, juggle_total,
    bm_skills, mv_skills, difficulty, full_session, xp_earned, source, mode, rounds)
  values (d.family_id, p_player, dt, t,
    coalesce((p_session->>'juggle_high')::int, 0), coalesce((p_session->>'juggle_total')::int, 0),
    coalesce(array(select jsonb_array_elements_text(p_session->'bm_skills')), '{}'),
    coalesce(array(select jsonb_array_elements_text(p_session->'mv_skills')), '{}'),
    p_session->>'difficulty', coalesce((p_session->>'full_session')::boolean, false),
    least(greatest(coalesce((p_session->>'xp_earned')::int, 0), 0), 1000), 'kid', m,
    case when jsonb_typeof(p_session->'rounds') = 'array' then p_session->'rounds' else null end);
  perform public.sfc_save_state(p_token, p_player, p_state);
end $$;
revoke execute on function public.sfc_log_session(text,uuid,jsonb,jsonb) from public;
grant  execute on function public.sfc_log_session(text,uuid,jsonb,jsonb) to anon, authenticated;

-- Clean up existing duplicates (keeps the first one logged)
with dup as (
  select id from (select id, row_number() over (partition by player_id, date, mode order by created_at) rn
    from public.sfc_sessions where source = 'kid' and mode in ('epa','checkin','goalsheet')) x where rn > 1)
delete from public.sfc_sessions where id in (select id from dup);

select 'v15 ok' as status, (select count(*) from public.sfc_sessions) as sessions;
