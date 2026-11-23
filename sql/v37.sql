-- v37: coach homework can assign specific drills (MSA library + app drills). Additive.
alter table public.sfc_plans add column if not exists drills text[] not null default '{}';

CREATE OR REPLACE FUNCTION public.sfc_admin_save_plan(p_plan jsonb)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_id uuid := coalesce((p_plan->>'id')::uuid, gen_random_uuid()); v_prog text := coalesce(p_plan->>'program','epa');
begin
  if not public.sfc_is_coach(v_prog) then raise exception 'not_coach'; end if;
  if exists (select 1 from public.sfc_plans where id = v_id and not public.sfc_is_coach(program)) then raise exception 'not_coach'; end if;
  if length(p_plan::text) > 8000 then raise exception 'too_big'; end if;
  insert into public.sfc_plans(id, program, week_start, target, focus, touches, emphasis, days, note, drills)
  values (v_id, v_prog, (p_plan->>'week_start')::date, coalesce(p_plan->'target','{"who":"all"}'),
    left(p_plan->>'focus', 40), least(greatest(coalesce((p_plan->>'touches')::int, 0), 0), 5000),
    coalesce(array(select jsonb_array_elements_text(p_plan->'emphasis')), '{}'), coalesce(p_plan->'days','{}'), left(p_plan->>'note', 300),
    coalesce(array(select left(x, 40) from jsonb_array_elements_text(coalesce(p_plan->'drills','[]')) x limit 12), '{}'))
  on conflict (id) do update set week_start = excluded.week_start, target = excluded.target, focus = excluded.focus, touches = excluded.touches,
    emphasis = excluded.emphasis, days = excluded.days, note = excluded.note, drills = excluded.drills;
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.sfc_player_plans(p_token text, p_player uuid)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare d public.sfc_devices := public.sfc_device_from_token(p_token); pl public.sfc_players; grp text;
begin
  select * into pl from public.sfc_players where id = p_player and family_id = d.family_id;
  if pl.id is null then raise exception 'not_on_this_device'; end if;
  select e->>'group' into grp from jsonb_array_elements(pl.programs) e where e->>'id' = 'epa' limit 1;
  if grp is null then return '[]'::json; end if;
  return coalesce((select json_agg(json_build_object('week_start', p.week_start, 'focus', p.focus, 'touches', p.touches, 'emphasis', p.emphasis, 'days', p.days, 'note', p.note, 'drills', p.drills) order by p.week_start)
    from public.sfc_plans p
    where p.program = 'epa' and p.week_start between date_trunc('week', current_date)::date - 7 and date_trunc('week', current_date)::date + 7
      and (p.target->>'who' = 'all' or p.target->>'who' = grp
        or (p.target->>'who' = 'pos' and (p.target->'pos' ? coalesce(pl.pos1,'') or p.target->'pos' ? coalesce(pl.pos2,'')))
        or (p.target->>'who' = 'players' and p.target->'players' ? pl.id::text))), '[]'::json);
end $function$;
