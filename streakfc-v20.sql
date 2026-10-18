-- StreakFC v20: arrival check-in from the coach's iPad (kiosk). Safe to re-run.
-- Writes an attendance row the player's parents can see ("Arrived at EPA 3:41"). No XP, no streak.
create or replace function public.sfc_coach_checkin(p_program text, p_player uuid, p_date date, p_ready jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare pl public.sfc_players; existing bigint;
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  if p_date not between current_date - 1 and current_date + 1 then raise exception 'bad_date'; end if;
  select * into pl from public.sfc_players where id = p_player and not archived and programs @> jsonb_build_array(jsonb_build_object('id', p_program));
  if pl.id is null then raise exception 'not_in_program'; end if;
  select id into existing from public.sfc_sessions where player_id = p_player and date = p_date and mode = 'checkin' and source = 'kiosk';
  if existing is not null then return json_build_object('id', existing, 'dup', true); end if;
  insert into public.sfc_sessions(family_id, player_id, date, touches, xp_earned, source, mode, rounds)
    values (pl.family_id, p_player, p_date, 0, 0, 'kiosk', 'checkin',
      jsonb_build_array(jsonb_build_object('ready', coalesce(p_ready, '{}'::jsonb) || jsonb_build_object('arrive', 2, 'program', p_program))))
    returning id into existing;
  return json_build_object('id', existing, 'dup', false);
end $$;
-- Undo a mis-tap on the board
create or replace function public.sfc_coach_checkin_undo(p_program text, p_player uuid, p_date date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  delete from public.sfc_sessions where player_id = p_player and date = p_date and mode = 'checkin' and source = 'kiosk'
    and exists (select 1 from public.sfc_players where id = p_player and programs @> jsonb_build_array(jsonb_build_object('id', p_program)));
end $$;
revoke execute on function public.sfc_coach_checkin(text,uuid,date,jsonb), public.sfc_coach_checkin_undo(text,uuid,date) from public, anon;
grant execute on function public.sfc_coach_checkin(text,uuid,date,jsonb), public.sfc_coach_checkin_undo(text,uuid,date) to authenticated;
select 'v20 ok' as status;
