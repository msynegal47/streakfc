-- StreakFC v21: My Week schedule from the kid app, reward wishes, program leaderboards. Safe to re-run.

-- Family for the caller: kid device token, else the signed-in parent
create or replace function public.sfc_caller_family(p_token text) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_token, '') = '' then return public.sfc_my_family(); end if;
  return (public.sfc_device_from_token(p_token)).family_id;
end $$;

-- Kid taps My Week: {practice:[0-6], game:[0-6], dates:{'YYYY-MM-DD':'p'|'g'|'off'}}
create or replace function public.sfc_player_schedule(p_token text, p_player uuid, p_schedule jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare fam uuid := public.sfc_caller_family(p_token); s jsonb;
begin
  if fam is null or not exists (select 1 from public.sfc_players where id = p_player and family_id = fam) then raise exception 'not_on_this_device'; end if;
  if p_schedule is null or jsonb_typeof(p_schedule) <> 'object' or length(p_schedule::text) > 2000 then raise exception 'bad_schedule'; end if;
  s := jsonb_build_object(
    'practice', coalesce((select jsonb_agg(distinct v::int) from jsonb_array_elements_text(case when jsonb_typeof(p_schedule->'practice') = 'array' then p_schedule->'practice' else '[]' end) v where v ~ '^[0-6]$'), '[]'),
    'game',     coalesce((select jsonb_agg(distinct v::int) from jsonb_array_elements_text(case when jsonb_typeof(p_schedule->'game') = 'array' then p_schedule->'game' else '[]' end) v where v ~ '^[0-6]$'), '[]'),
    'dates',    coalesce((select jsonb_object_agg(k, v) from jsonb_each_text(case when jsonb_typeof(p_schedule->'dates') = 'object' then p_schedule->'dates' else '{}' end) x(k, v)
                  where k ~ '^\d{4}-\d{2}-\d{2}$' and v in ('p','g','off') and k::date >= current_date - 14), '{}'));
  update public.sfc_players set schedule = s where id = p_player;
end $$;

-- Kid asks for a reward. Parent turns it into a real one (name + days) from the parent view.
create or replace function public.sfc_player_wish(p_token text, p_player uuid, p_wish text) returns void
language plpgsql security definer set search_path = public as $$
declare fam uuid := public.sfc_caller_family(p_token); w text := left(trim(coalesce(p_wish, '')), 40);
begin
  if fam is null or not exists (select 1 from public.sfc_players where id = p_player and family_id = fam) then raise exception 'not_on_this_device'; end if;
  update public.sfc_players set reward = case when w = '' then null else jsonb_build_object('wish', w, 'at', current_date) end
   where id = p_player and (reward is null or reward->>'days' is null);
end $$;

-- Program leaderboard: kids in the same program (nickname, kit, XP, streak). Parents can opt a kid out (programs[].board = false).
create or replace function public.sfc_program_board(p_token text, p_player uuid, p_program text, p_week date, p_since date) returns json
language plpgsql volatile security definer set search_path = public as $$
declare fam uuid := public.sfc_caller_family(p_token);
begin
  if fam is null or not exists (select 1 from public.sfc_players where id = p_player and family_id = fam
      and programs @> jsonb_build_array(jsonb_build_object('id', p_program))) then raise exception 'not_in_program'; end if;
  if p_week not between current_date - 7 and current_date + 1 or p_since < current_date - 120 then raise exception 'bad_date'; end if;
  return coalesce((select json_agg(json_build_object('id', p.id, 'nickname', p.nickname, 'color', p.color, 'avatar', p.avatar,
      'has_avatar', p.unlocks @> '["avatar"]'::jsonb, 'streak', p.streak, 'last_log', p.last_log, 'me', p.id = p_player,
      'week_xp', coalesce((select sum(s.xp_earned) from public.sfc_sessions s where s.player_id = p.id and s.date >= p_week), 0),
      'season_xp', coalesce((select sum(s.xp_earned) from public.sfc_sessions s where s.player_id = p.id and s.date >= p_since), 0)))
    from public.sfc_players p
    where not p.archived and p.programs @> jsonb_build_array(jsonb_build_object('id', p_program))
      and coalesce((select e->>'board' from jsonb_array_elements(p.programs) e where e->>'id' = p_program limit 1), 'true') <> 'false'), '[]'::json);
end $$;

revoke execute on function public.sfc_caller_family(text) from public, anon, authenticated;
grant execute on function public.sfc_player_schedule(text,uuid,jsonb), public.sfc_player_wish(text,uuid,text),
  public.sfc_program_board(text,uuid,text,date,date) to anon, authenticated;
select 'v21 ok' as status;
