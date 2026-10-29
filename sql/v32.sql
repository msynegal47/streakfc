-- v32: trainer credits + weekly slots on roster rows. A pack can be split across players (siblings), credits can move between players,
-- each logged lesson uses 1 credit once a player has credits set up. Parents see their kid's balance and next session. Safe to re-run.
alter table public.sfc_org_roster add column if not exists credits int not null default 0;
alter table public.sfc_org_roster add column if not exists credit_log jsonb not null default '[]'::jsonb;
alter table public.sfc_org_roster add column if not exists slot jsonb;

-- internal: one ledger entry + balance change. Not callable by clients.
create or replace function public.sfc_credit_add(p_id uuid, p_delta int, p_kind text, p_note text, p_extra jsonb default '{}'::jsonb) returns int
language plpgsql security definer set search_path to 'public' as $$
declare r public.sfc_org_roster; bal int;
begin
  select * into r from public.sfc_org_roster where id = p_id;
  update public.sfc_org_roster set credits = credits + p_delta,
    credit_log = credit_log || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('at', now(), 'date', current_date, 'delta', p_delta, 'kind', p_kind,
      'note', nullif(left(trim(coalesce(p_note, '')), 200), ''),
      'by', coalesce((select name from public.sfc_staff where org = r.org and user_id = auth.uid()), 'Coach')) || coalesce(p_extra, '{}'::jsonb)))
  where id = p_id returning credits into bal;
  return bal;
end $$;
revoke execute on function public.sfc_credit_add(uuid, int, text, text, jsonb) from public, anon, authenticated;

-- New pack, split across one or more players: p_rows = [{"id": roster uuid, "n": 5}, ...]
create or replace function public.sfc_roster_pack(p_rows jsonb, p_note text, p_paid boolean) returns text
language plpgsql security definer set search_path to 'public' as $$
declare e jsonb; r public.sfc_org_roster; org0 text; n int; tot int := 0; k text := 'K' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'no_players'; end if;
  for e in select * from jsonb_array_elements(p_rows) loop
    select * into r from public.sfc_org_roster where id = (e->>'id')::uuid;
    if r.id is null or not public.sfc_is_coach(r.program) then raise exception 'not_coach'; end if;
    if org0 is null then org0 := r.org; elsif org0 <> r.org then raise exception 'mixed_orgs'; end if;
    n := coalesce((e->>'n')::int, 0); if n not between 0 and 100 then raise exception 'bad_amount'; end if;
    tot := tot + n;
  end loop;
  if tot < 1 then raise exception 'bad_amount'; end if;
  for e in select * from jsonb_array_elements(p_rows) loop
    n := (e->>'n')::int;
    if n > 0 then perform public.sfc_credit_add((e->>'id')::uuid, n, 'pack', p_note, jsonb_build_object('pack', k, 'of', tot, 'paid', coalesce(p_paid, false))); end if;
  end loop;
  return k;
end $$;

-- Mark a pack paid (every split row of it)
create or replace function public.sfc_roster_pack_paid(p_pack text, p_paid boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  update public.sfc_org_roster set credit_log = (select jsonb_agg(case when x->>'pack' = p_pack and x->>'kind' = 'pack' then x || jsonb_build_object('paid', coalesce(p_paid, true)) else x end order by o) from jsonb_array_elements(credit_log) with ordinality t(x, o))
  where credit_log @> jsonb_build_array(jsonb_build_object('pack', p_pack)) and public.sfc_is_coach(program);
end $$;

-- Move credits between two players at the same trainer/academy (injury, time off, sibling)
create or replace function public.sfc_roster_move(p_from uuid, p_to uuid, p_n int) returns void
language plpgsql security definer set search_path to 'public' as $$
declare a public.sfc_org_roster; b public.sfc_org_roster;
begin
  select * into a from public.sfc_org_roster where id = p_from; select * into b from public.sfc_org_roster where id = p_to;
  if a.id is null or b.id is null or a.id = b.id or not public.sfc_is_coach(a.program) or not public.sfc_is_coach(b.program) then raise exception 'not_coach'; end if;
  if a.org <> b.org then raise exception 'mixed_orgs'; end if;
  if p_n not between 1 and 100 then raise exception 'bad_amount'; end if;
  perform public.sfc_credit_add(a.id, -p_n, 'move', 'to ' || b.nickname);
  perform public.sfc_credit_add(b.id, p_n, 'move', 'from ' || a.nickname);
end $$;

-- Manual fix (+/-), e.g. starting balance or a comp session
create or replace function public.sfc_roster_adjust(p_id uuid, p_delta int, p_note text) returns int
language plpgsql security definer set search_path to 'public' as $$
declare r public.sfc_org_roster;
begin
  select * into r from public.sfc_org_roster where id = p_id;
  if r.id is null or not public.sfc_is_coach(r.program) then raise exception 'not_coach'; end if;
  if p_delta = 0 or p_delta not between -100 and 100 then raise exception 'bad_amount'; end if;
  return public.sfc_credit_add(p_id, p_delta, 'adjust', p_note);
end $$;

-- Weekly slot: {"dow": 2, "time": "09:00", "mins": 60}. null clears.
create or replace function public.sfc_roster_slot(p_id uuid, p_slot jsonb) returns void
language plpgsql security definer set search_path to 'public' as $$
declare r public.sfc_org_roster;
begin
  select * into r from public.sfc_org_roster where id = p_id;
  if r.id is null or not public.sfc_is_coach(r.program) then raise exception 'not_coach'; end if;
  if p_slot is not null and jsonb_typeof(p_slot) <> 'null' then
    if (p_slot->>'dow')::int not between 0 and 6 or (p_slot->>'time') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce((p_slot->>'mins')::int, 60) not between 15 and 240 then raise exception 'bad_slot'; end if;
    update public.sfc_org_roster set slot = jsonb_build_object('dow', (p_slot->>'dow')::int, 'time', p_slot->>'time', 'mins', coalesce((p_slot->>'mins')::int, 60)) where id = p_id;
  else
    update public.sfc_org_roster set slot = null where id = p_id;
  end if;
end $$;

-- Lesson log: same as v25, plus uses 1 credit once the player has credits set up
create or replace function public.sfc_roster_lesson(p_id uuid, p_date date, p_diff int, p_rate int, p_work text, p_hw text, p_private text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare r public.sfc_org_roster;
begin
  select * into r from public.sfc_org_roster where id = p_id;
  if r.id is null or not public.sfc_is_coach(r.program) then raise exception 'not_coach'; end if;
  if p_diff not between 1 and 5 or p_rate not between 1 and 5 then raise exception 'bad_rating'; end if;
  update public.sfc_org_roster set notes = notes || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
    'kind', 'lesson', 'date', coalesce(p_date, current_date),
    'by', coalesce((select name from public.sfc_staff where org = r.org and user_id = auth.uid()), 'Coach'),
    'diff', p_diff, 'rate', p_rate, 'work', nullif(left(trim(coalesce(p_work, '')), 300), ''),
    'hw', nullif(left(trim(coalesce(p_hw, '')), 300), ''), 'text', nullif(left(trim(coalesce(p_private, '')), 1000), '')))) where id = p_id;
  if jsonb_array_length(r.credit_log) > 0 then
    perform public.sfc_credit_add(p_id, -1, 'use', 'Session ' || to_char(coalesce(p_date, current_date), 'MM/DD'), jsonb_build_object('lesson', coalesce(p_date, current_date)));
  end if;
end $$;

create or replace function public.sfc_roster_list(p_program text) returns json
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  return coalesce((select json_agg(json_build_object('id', id, 'nickname', nickname, 'age_group', age_group, 'notes', notes, 'claim_code', claim_code,
    'player_id', player_id, 'created_at', created_at, 'credits', credits, 'credit_log', credit_log, 'slot', slot,
    'hw_done', (select max(s.date) from public.sfc_sessions s where s.player_id = r.player_id and s.mode = 'homework')) order by created_at)
    from public.sfc_org_roster r where program = p_program), '[]'::json);
end $$;

-- Parent: credits left + weekly slot per kid, per trainer program. Only where the trainer set credits or a slot up.
create or replace function public.sfc_family_credits() returns json
language sql stable security definer set search_path to 'public' as $$
  select coalesce(json_object_agg(x.pid, x.items), '{}'::json) from (
    select pl.id pid, json_agg(json_build_object('program', r.program, 'program_name', p.name, 'org_name', o.name, 'short', o.short, 'brand', o.brand,
      'credits', case when jsonb_array_length(r.credit_log) > 0 then r.credits end, 'slot', r.slot,
      'last_pack', (select max(e->>'date') from jsonb_array_elements(r.credit_log) e where e->>'kind' = 'pack'))) items
    from public.sfc_players pl join public.sfc_org_roster r on r.player_id = pl.id
      join public.sfc_org_programs p on p.id = r.program join public.sfc_orgs o on o.id = r.org
    where pl.family_id = public.sfc_my_family() and not pl.archived and pl.programs @> jsonb_build_array(jsonb_build_object('id', r.program))
      and (jsonb_array_length(r.credit_log) > 0 or r.slot is not null)
    group by pl.id) x
$$;

revoke execute on function public.sfc_roster_pack(jsonb, text, boolean), public.sfc_roster_pack_paid(text, boolean), public.sfc_roster_move(uuid, uuid, int),
  public.sfc_roster_adjust(uuid, int, text), public.sfc_roster_slot(uuid, jsonb), public.sfc_family_credits() from public, anon;
grant execute on function public.sfc_roster_pack(jsonb, text, boolean), public.sfc_roster_pack_paid(text, boolean), public.sfc_roster_move(uuid, uuid, int),
  public.sfc_roster_adjust(uuid, int, text), public.sfc_roster_slot(uuid, jsonb), public.sfc_family_credits() to authenticated;
select 'v32 ok' as status;
