-- StreakFC v10: coach touch plans (assign to all, a group, positions or specific players). Safe to re-run.
create table if not exists public.sfc_plans (
  id         uuid primary key default gen_random_uuid(),
  program    text not null default 'epa',
  week_start date not null,                         -- Monday
  target     jsonb not null default '{"who":"all"}', -- {"who":"all|younger|older|pos|players","pos":["CM"],"players":["uuid"]}
  focus      text,
  touches    int,                                   -- daily home touch target
  emphasis   text[] not null default '{}',
  days       jsonb not null default '{}',           -- {"1":"Juggling ladder","3":"Light, EPA day"} weekday 0=Sun
  note       text,
  created_at timestamptz not null default now()
);
alter table public.sfc_plans enable row level security;
revoke all on public.sfc_plans from public, anon, authenticated;

create or replace function public.sfc_admin_plans() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  return coalesce((select json_agg(to_jsonb(p) order by p.week_start, p.created_at) from public.sfc_plans p where p.week_start >= current_date - 60), '[]'::json);
end $$;

create or replace function public.sfc_admin_save_plan(p_plan jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := coalesce((p_plan->>'id')::uuid, gen_random_uuid());
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  if length(p_plan::text) > 8000 then raise exception 'too_big'; end if;
  insert into public.sfc_plans(id, program, week_start, target, focus, touches, emphasis, days, note)
  values (v_id, coalesce(p_plan->>'program','epa'), (p_plan->>'week_start')::date, coalesce(p_plan->'target','{"who":"all"}'),
    left(p_plan->>'focus', 40), least(greatest(coalesce((p_plan->>'touches')::int, 0), 0), 5000),
    coalesce(array(select jsonb_array_elements_text(p_plan->'emphasis')), '{}'), coalesce(p_plan->'days','{}'), left(p_plan->>'note', 300))
  on conflict (id) do update set week_start = excluded.week_start, target = excluded.target, focus = excluded.focus, touches = excluded.touches,
    emphasis = excluded.emphasis, days = excluded.days, note = excluded.note;
  return v_id;
end $$;

create or replace function public.sfc_admin_delete_plan(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  delete from public.sfc_plans where id = p_id;
end $$;

-- Kid device: plans for this week and next that apply to this player
drop function if exists public.sfc_player_plans(text,uuid);
create or replace function public.sfc_player_plans(p_token text, p_player uuid) returns json
language plpgsql volatile security definer set search_path = public as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token); pl public.sfc_players; grp text;
begin
  select * into pl from public.sfc_players where id = p_player and family_id = d.family_id;
  if pl.id is null then raise exception 'not_on_this_device'; end if;
  select e->>'group' into grp from jsonb_array_elements(pl.programs) e where e->>'id' = 'epa' limit 1;
  if grp is null then return '[]'::json; end if;
  return coalesce((select json_agg(json_build_object('week_start', p.week_start, 'focus', p.focus, 'touches', p.touches, 'emphasis', p.emphasis, 'days', p.days, 'note', p.note) order by p.week_start)
    from public.sfc_plans p
    where p.program = 'epa' and p.week_start between date_trunc('week', current_date)::date - 7 and date_trunc('week', current_date)::date + 7
      and (p.target->>'who' = 'all' or p.target->>'who' = grp
        or (p.target->>'who' = 'pos' and (p.target->'pos' ? coalesce(pl.pos1,'') or p.target->'pos' ? coalesce(pl.pos2,'')))
        or (p.target->>'who' = 'players' and p.target->'players' ? pl.id::text))), '[]'::json);
end $$;

revoke execute on function public.sfc_admin_plans(), public.sfc_admin_save_plan(jsonb), public.sfc_admin_delete_plan(uuid), public.sfc_player_plans(text,uuid) from public, anon, authenticated;
grant  execute on function public.sfc_admin_plans(), public.sfc_admin_save_plan(jsonb), public.sfc_admin_delete_plan(uuid) to authenticated;
grant  execute on function public.sfc_player_plans(text,uuid) to anon, authenticated;
select 'v10 ok' as status;
