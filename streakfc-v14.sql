-- StreakFC v14: touch plan presets for coaches. Safe to re-run.
create table if not exists public.sfc_plan_presets (
  id uuid primary key default gen_random_uuid(),
  program text not null default 'epa',
  name text not null,
  data jsonb not null default '{}',   -- focus, touches, emphasis, days, note, target
  created_at timestamptz not null default now()
);
alter table public.sfc_plan_presets enable row level security;
revoke all on public.sfc_plan_presets from public, anon, authenticated;

create or replace function public.sfc_presets(p_program text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  return coalesce((select json_agg(to_jsonb(x) order by x.name) from public.sfc_plan_presets x where x.program = p_program), '[]'::json);
end $$;
create or replace function public.sfc_save_preset(p_program text, p_name text, p_data jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  if length(p_data::text) > 6000 then raise exception 'too_big'; end if;
  insert into public.sfc_plan_presets(program, name, data) values (p_program, left(p_name, 40), p_data) returning id into v;
  return v;
end $$;
create or replace function public.sfc_delete_preset(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.sfc_plan_presets where id = p_id and public.sfc_is_coach(program)) then raise exception 'not_coach'; end if;
  delete from public.sfc_plan_presets where id = p_id;
end $$;
revoke execute on function public.sfc_presets(text), public.sfc_save_preset(text,text,jsonb), public.sfc_delete_preset(uuid) from public, anon;
grant  execute on function public.sfc_presets(text), public.sfc_save_preset(text,text,jsonb), public.sfc_delete_preset(uuid) to authenticated;

-- Coach attendance: mark a player present on an EPA day (0 XP, source 'coach'). Player logs still earn the XP.
create or replace function public.sfc_admin_log_session(p_player uuid, p_session jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare fam uuid; m text := p_session->>'mode'; d date := coalesce((p_session->>'date')::date, current_date);
begin
  if not public.sfc_can_manage(p_player) then raise exception 'not_coach'; end if;
  select family_id into fam from public.sfc_players where id = p_player;
  if m not in ('speed','epa') or length(p_session::text) > 2000 then raise exception 'bad_session'; end if;
  if m = 'epa' then
    if d > current_date or d < current_date - 21 then raise exception 'bad_date'; end if;
    if exists (select 1 from public.sfc_sessions where player_id = p_player and date = d and mode = 'epa') then return; end if;
    insert into public.sfc_sessions(family_id, player_id, date, touches, xp_earned, source, mode, full_session)
    values (fam, p_player, d, 0, 0, 'coach', 'epa', false);
    return;
  end if;
  insert into public.sfc_sessions(family_id, player_id, date, touches, xp_earned, source, mode, rounds, full_session)
  values (fam, p_player, d, 0, 0, 'coach', 'speed',
    case when jsonb_typeof(p_session->'rounds') = 'array' then p_session->'rounds' else null end, false);
end $$;
create or replace function public.sfc_admin_unmark_att(p_player uuid, p_date date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_can_manage(p_player) then raise exception 'not_coach'; end if;
  delete from public.sfc_sessions where player_id = p_player and date = p_date and mode = 'epa' and source = 'coach';
end $$;
revoke execute on function public.sfc_admin_log_session(uuid,jsonb), public.sfc_admin_unmark_att(uuid,date) from public, anon;
grant  execute on function public.sfc_admin_log_session(uuid,jsonb), public.sfc_admin_unmark_att(uuid,date) to authenticated;
select 'v14 ok' as status;
