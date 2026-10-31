-- v33: academy data stays with the academy. A coach only sees another academy's data if it's their own org.
-- Academy-owned: EPA logs, pre-EPA check-ins, weekly journals, goal sheet, film reviews, coach's standard, private notes, program list, homework from other trainers.
-- Shared under the parent's "all training" setting: home sessions, touches, streak, games, speed tests.

-- Org of the cohort program(s) a player is in (e.g. 'msa' for EPA). Academy journals belong to that org.
create or replace function public.sfc_player_cohort_orgs(p_programs jsonb) returns text[]
language sql stable security definer set search_path to 'public' as $$
  select coalesce(array_agg(distinct op.org), '{}') from jsonb_array_elements(coalesce(p_programs, '[]'::jsonb)) e
    join public.sfc_org_programs op on op.id = e->>'id' where op.kind = 'cohort'
$$;

-- Private coach notes are per org (was one row per player, visible to every coach). Table is empty, safe to rekey.
alter table public.sfc_coach_notes add column if not exists org text not null default 'msa';
alter table public.sfc_coach_notes drop constraint if exists sfc_coach_notes_pkey;
alter table public.sfc_coach_notes add primary key (player_id, org);

create or replace function public.sfc_coach_data(p_program text, p_days integer default 60) returns json
language plpgsql stable security definer set search_path to 'public' as $$
declare o text := public.sfc_program_org(p_program); adm boolean := public.sfc_is_admin();
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  return json_build_object(
    'players', coalesce((select json_agg(
        ((to_jsonb(p) - 'reset_at' - 'goals' - 'programs')
          || jsonb_build_object('programs', coalesce((select jsonb_agg(e) from jsonb_array_elements(p.programs) e where adm or public.sfc_program_org(e->>'id') = o), '[]'::jsonb))
          || case when adm or o = any(public.sfc_player_cohort_orgs(p.programs)) then jsonb_build_object('goals', p.goals) else jsonb_build_object('goals', jsonb_strip_nulls(jsonb_build_object('items', p.goals->'items'))) end)
        order by p.created_at) from public.sfc_players p
       where not p.archived and p.programs @> jsonb_build_array(jsonb_build_object('id', p_program))), '[]'::json),
    'sessions', coalesce((select json_agg(json_build_object('id', s.id, 'player_id', s.player_id, 'family_id', s.family_id, 'date', s.date, 'touches', s.touches, 'xp', s.xp_earned,
        'mode', s.mode, 'source', s.source, 'rounds', s.rounds, 'created_at', s.created_at) order by s.created_at desc)
      from public.sfc_sessions s join public.sfc_players p on p.id = s.player_id
      where p.programs @> jsonb_build_array(jsonb_build_object('id', p_program)) and s.date >= current_date - least(greatest(p_days, 1), 120)
        and (coalesce((select e->>'share' from jsonb_array_elements(p.programs) e where e->>'id' = p_program limit 1), 'all') = 'all'
             or s.mode in ('epa','checkin','weekly','film','goalsheet','speed','game','pregame','homework'))
        -- academy journals: only the academy that runs the kid's cohort program
        and (adm or s.mode not in ('epa','checkin','weekly','film','goalsheet') or o = any(public.sfc_player_cohort_orgs(p.programs)))
        -- homework check-offs: only the org that assigned it
        and (adm or s.mode <> 'homework' or public.sfc_program_org(s.rounds->0->'homework'->>'program') = o)), '[]'::json),
    'notes', coalesce((select json_object_agg(n.player_id, json_build_object('focus', n.focus, 'note', n.note, 'updated_at', n.updated_at))
      from public.sfc_coach_notes n join public.sfc_players p on p.id = n.player_id
      where n.org = o and p.programs @> jsonb_build_array(jsonb_build_object('id', p_program))), '{}'::json),
    'plans', coalesce((select json_agg(to_jsonb(x) order by x.week_start) from public.sfc_plans x where x.program = p_program and x.week_start >= current_date - 60), '[]'::json),
    'code', (select code from public.sfc_program_codes where program = p_program));
end $$;

-- Notes save: scoped to the coach's program org
create or replace function public.sfc_admin_set_note(p_player uuid, p_focus text, p_note text, p_program text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare o text := public.sfc_program_org(p_program);
begin
  if o is null or not public.sfc_is_coach(p_program) or not exists (select 1 from public.sfc_players where id = p_player and programs @> jsonb_build_array(jsonb_build_object('id', p_program)))
    then raise exception 'not_coach'; end if;
  insert into public.sfc_coach_notes(player_id, org, focus, note, updated_at) values (p_player, o, left(p_focus, 200), left(p_note, 1000), now())
  on conflict (player_id, org) do update set focus = excluded.focus, note = excluded.note, updated_at = now();
end $$;
-- Old 3-arg version wrote one shared row. Keep it for admin only.
create or replace function public.sfc_admin_set_note(p_player uuid, p_focus text, p_note text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_coach'; end if;
  insert into public.sfc_coach_notes(player_id, org, focus, note, updated_at) values (p_player, 'msa', left(p_focus, 200), left(p_note, 1000), now())
  on conflict (player_id, org) do update set focus = excluded.focus, note = excluded.note, updated_at = now();
end $$;
revoke execute on function public.sfc_admin_set_note(uuid, text, text, text) from public, anon;
grant execute on function public.sfc_admin_set_note(uuid, text, text, text) to authenticated;

-- Player edits: program entries were already limited to the coach's own programs (sfc_merge_programs). The coach's standard is now cohort-academy only.
create or replace function public.sfc_admin_update_player(p_player uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path to 'public' as $$
declare myorgs text[]; pl public.sfc_players;
begin
  if not public.sfc_can_manage(p_player) then raise exception 'not_coach'; end if;
  if jsonb_typeof(p_patch) <> 'object' or length(p_patch::text) > 4000 then raise exception 'bad_patch'; end if;
  select * into pl from public.sfc_players where id = p_player;
  select coalesce(array_agg(distinct public.sfc_program_org(x)), '{}') into myorgs from unnest(public.sfc_coach_programs()) x;
  update public.sfc_players set
    programs = case when jsonb_typeof(p_patch->'programs') = 'array' then public.sfc_merge_programs(programs, p_patch->'programs') else programs end,
    pos1     = case when p_patch ? 'pos1' then left(p_patch->>'pos1', 6) else pos1 end,
    pos2     = case when p_patch ? 'pos2' then left(p_patch->>'pos2', 6) else pos2 end,
    goals    = case when p_patch ? 'goal_comment' and (public.sfc_is_admin() or public.sfc_player_cohort_orgs(pl.programs) && myorgs) then jsonb_set(goals, '{coach}', to_jsonb(left(p_patch->>'goal_comment', 300))) else goals end
  where id = p_player;
end $$;
select 'v33 ok' as status;
