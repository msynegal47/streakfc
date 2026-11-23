-- v34: Team mode. Kids join a team on their own phone with the team code: pick name, set a 4-digit PIN, phone shows only them.
-- Each team kid gets a one-kid family with no owner (owner null) until a parent claims it with the kid's parent link.
-- Coaches create, rename and sort their own teams inside their org. Safe to re-run.
alter table public.sfc_families alter column owner drop not null;
alter table public.sfc_families add column if not exists parent_code text unique;
alter table public.sfc_pin_attempts alter column device_id drop not null;

create or replace function public.sfc_prog_entry(p_prog text, p_age text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('id', p_prog,
    'group', case when coalesce(nullif(regexp_replace(coalesce(p_age,''), '\D', '', 'g'), '')::int, 0) >= 13 then 'older' else 'younger' end,
    'focus', '', 'note', '', 'share', 'all',
    'name', (select coalesce(o.short, o.name) || ' · ' || p2.name from public.sfc_org_programs p2 join public.sfc_orgs o on o.id = p2.org where p2.id = p_prog))
$$;
revoke execute on function public.sfc_prog_entry(text, text) from public, anon, authenticated;

-- Team code -> team name, brand, names on the list (nickname only). Anyone with the code can see it.
create or replace function public.sfc_team_info(p_code text) returns json
language plpgsql stable security definer set search_path to 'public' as $$
declare prog text;
begin
  select program into prog from public.sfc_program_codes where code = upper(trim(coalesce(p_code,'')));
  if prog is null then raise exception 'code_invalid'; end if;
  return (select json_build_object('program', p.id, 'name', p.name, 'kind', p.kind, 'org_name', o.name, 'short', o.short, 'brand', o.brand,
    'roster', coalesce((select json_agg(json_build_object('id', r.id, 'nickname', r.nickname, 'age_group', r.age_group,
        'taken', r.player_id is not null and exists (select 1 from public.sfc_player_pins pp where pp.player_id = r.player_id)) order by lower(r.nickname))
      from public.sfc_org_roster r where r.program = p.id and p.kind in ('team','cohort')), '[]'::json))
    from public.sfc_org_programs p join public.sfc_orgs o on o.id = p.org where p.id = prog and p.active);
end $$;

-- Join (or re-link a new phone). p_roster = a name on the list, or null + p_nickname/p_age for "I'm not on the list".
create or replace function public.sfc_team_join(p_code text, p_roster uuid, p_nickname text, p_age text, p_pin text, p_label text default null) returns json
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare prog text; r public.sfc_org_roster; fam uuid; pid uuid; tok text; h text; fails int;
begin
  if coalesce(p_pin,'') !~ '^[0-9]{4}$' then raise exception 'pin_must_be_4_digits'; end if;
  select program into prog from public.sfc_program_codes where code = upper(trim(coalesce(p_code,'')));
  if prog is null then raise exception 'code_invalid'; end if;
  if p_roster is not null then
    select * into r from public.sfc_org_roster where id = p_roster and program = prog;
    if r.id is null then raise exception 'not_on_team'; end if;
  else
    if coalesce(trim(p_nickname),'') = '' then raise exception 'name_required'; end if;
    insert into public.sfc_org_roster(org, program, nickname, age_group, claim_code)
      values (public.sfc_program_org(prog), prog, left(trim(p_nickname), 20), left(coalesce(p_age,''), 8), 'P-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)))
      returning * into r;
  end if;
  if r.player_id is not null then
    pid := r.player_id;
    select pin_hash into h from public.sfc_player_pins where player_id = pid;
    if h is not null then
      select count(*) into fails from public.sfc_pin_attempts where player_id = pid and device_id is null and at > now() - interval '10 minutes';
      if fails >= 5 then return json_build_object('ok', false, 'error', 'locked'); end if;
      if extensions.crypt(p_pin, h) <> h then
        insert into public.sfc_pin_attempts(device_id, player_id) values (null, pid);
        return json_build_object('ok', false, 'error', 'wrong_pin', 'remaining', 4 - fails);
      end if;
      delete from public.sfc_pin_attempts where player_id = pid and device_id is null;
    else
      insert into public.sfc_player_pins(player_id, pin_hash) values (pid, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)));
    end if;
    select family_id into fam from public.sfc_players where id = pid;
    update public.sfc_players set archived = false,
      programs = case when programs @> jsonb_build_array(jsonb_build_object('id', prog)) then programs else programs || jsonb_build_array(public.sfc_prog_entry(prog, age_group)) end
      where id = pid;
  else
    insert into public.sfc_families(owner, parent_name, flags, parent_code)
      values (null, null, jsonb_build_object('team', prog), 'G-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8)))
      returning id into fam;
    insert into public.sfc_players(family_id, nickname, age_group, juggle_min, programs)
      values (fam, r.nickname, nullif(r.age_group, ''), case when coalesce(nullif(regexp_replace(coalesce(r.age_group,''), '\D', '', 'g'), '')::int, 12) <= 8 then 50 when coalesce(nullif(regexp_replace(coalesce(r.age_group,''), '\D', '', 'g'), '')::int, 12) <= 10 then 100 else 150 end,
              jsonb_build_array(public.sfc_prog_entry(prog, r.age_group)))
      returning id into pid;
    update public.sfc_org_roster set player_id = pid where id = r.id;
    insert into public.sfc_player_pins(player_id, pin_hash) values (pid, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)));
  end if;
  tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.sfc_devices(family_id, token_hash, label) values (fam, public.sfc_hash(tok), left(coalesce(p_label, 'Team phone'), 40));
  return json_build_object('ok', true, 'token', tok, 'player', pid, 'players', public.sfc_roster_json(fam));
end $$;
grant execute on function public.sfc_team_info(text), public.sfc_team_join(text, uuid, text, text, text, text) to anon, authenticated;

-- Kid's phone -> parent link (only for team kids nobody has claimed yet)
create or replace function public.sfc_parent_code(p_token text) returns text
language plpgsql security definer set search_path to 'public' as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token); c text;
begin
  select parent_code into c from public.sfc_families where id = d.family_id and owner is null;
  if c is null and exists (select 1 from public.sfc_families where id = d.family_id and owner is null) then
    c := 'G-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    update public.sfc_families set parent_code = c where id = d.family_id;
  end if;
  return c;
end $$;
grant execute on function public.sfc_parent_code(text) to anon, authenticated;

create or replace function public.sfc_parent_code_info(p_code text) returns json
language sql stable security definer set search_path to 'public' as $$
  select json_build_object('players', (select json_agg(nickname) from public.sfc_players where family_id = f.id and not archived))
  from public.sfc_families f where f.parent_code = upper(trim(coalesce(p_code,''))) and f.owner is null
$$;
grant execute on function public.sfc_parent_code_info(text) to anon, authenticated;

-- Signed-in parent claims the kid. Has a family already: kid moves in. No family yet: the kid's family becomes theirs.
create or replace function public.sfc_parent_claim(p_code text, p_name text default null) returns json
language plpgsql security definer set search_path to 'public' as $$
declare kf public.sfc_families; mine uuid := public.sfc_my_family(); names json;
begin
  if auth.uid() is null then raise exception 'sign_in_first'; end if;
  select * into kf from public.sfc_families where parent_code = upper(trim(coalesce(p_code,''))) and owner is null;
  if kf.id is null then raise exception 'code_invalid'; end if;
  select json_agg(nickname) into names from public.sfc_players where family_id = kf.id and not archived;
  if mine is null then
    update public.sfc_families set owner = auth.uid(), parent_name = coalesce(nullif(left(trim(coalesce(p_name,'')), 40), ''), parent_name), consent_at = now(), parent_code = null where id = kf.id;
  else
    update public.sfc_players set family_id = mine where family_id = kf.id;
    update public.sfc_sessions set family_id = mine where family_id = kf.id;
    update public.sfc_devices set family_id = mine where family_id = kf.id;
    update public.sfc_push_subs set family_id = mine where family_id = kf.id;
    update public.sfc_families set parent_code = null, flags = flags || jsonb_build_object('merged_into', mine) where id = kf.id;
  end if;
  return json_build_object('players', names);
end $$;
grant execute on function public.sfc_parent_claim(text, text) to authenticated;

-- Coaches run their own teams inside their org
create or replace function public.sfc_coach_team_new(p_org text, p_name text) returns text
language plpgsql security definer set search_path to 'public' as $$
declare pid text := p_org || '-' || lower(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
begin
  if not (public.sfc_is_admin() or exists (select 1 from public.sfc_staff where org = p_org and user_id = auth.uid() and active)) then raise exception 'not_allowed'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'name_required'; end if;
  insert into public.sfc_org_programs(id, org, name, kind, info, active, sort) values (pid, p_org, left(trim(p_name), 40), 'team', '{}'::jsonb, true,
    (select coalesce(max(sort), 0) + 1 from public.sfc_org_programs where org = p_org));
  insert into public.sfc_program_codes(program, code) values (pid, upper(left(p_org, 3)) || '-' || upper(substr(md5(random()::text || pid), 1, 4)));
  update public.sfc_staff set programs = array_append(programs, pid) where org = p_org and user_id = auth.uid() and public.sfc_role_rank(role) < 2;
  return pid;
end $$;

create or replace function public.sfc_coach_team_rename(p_program text, p_name text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'name_required'; end if;
  update public.sfc_org_programs set name = left(trim(p_name), 40) where id = p_program;
  update public.sfc_players pl set programs = (select jsonb_agg(case when e->>'id' = p_program then e || jsonb_build_object('name', public.sfc_prog_entry(p_program, pl.age_group)->>'name') else e end) from jsonb_array_elements(pl.programs) e)
    where pl.programs @> jsonb_build_array(jsonb_build_object('id', p_program));
end $$;

-- Move players (and roster-only names) from one of the coach's teams to another in the same org
create or replace function public.sfc_coach_team_move(p_from text, p_to text, p_players uuid[], p_roster uuid[]) returns int
language plpgsql security definer set search_path to 'public' as $$
declare n int := 0; m int := 0;
begin
  if not (public.sfc_is_coach(p_from) and public.sfc_is_coach(p_to)) or public.sfc_program_org(p_from) <> public.sfc_program_org(p_to) or p_from = p_to then raise exception 'not_allowed'; end if;
  update public.sfc_players pl set programs = (
      select jsonb_agg(x) from (
        select case when e->>'id' = p_from then e || jsonb_build_object('id', p_to, 'name', public.sfc_prog_entry(p_to, pl.age_group)->>'name') else e end x
        from jsonb_array_elements(pl.programs) e
        where not (e->>'id' = p_from and pl.programs @> jsonb_build_array(jsonb_build_object('id', p_to)))) q)
    where pl.id = any(coalesce(p_players, '{}')) and pl.programs @> jsonb_build_array(jsonb_build_object('id', p_from));
  get diagnostics n = row_count;
  update public.sfc_org_roster set program = p_to where id = any(coalesce(p_roster, '{}')) and program = p_from;
  get diagnostics m = row_count;
  -- names already linked to a player move with that player
  update public.sfc_org_roster set program = p_to where program = p_from and player_id = any(coalesce(p_players, '{}'));
  return n + m;
end $$;

revoke execute on function public.sfc_coach_team_new(text, text), public.sfc_coach_team_rename(text, text), public.sfc_coach_team_move(text, text, uuid[], uuid[]) from public, anon;
grant execute on function public.sfc_coach_team_new(text, text), public.sfc_coach_team_rename(text, text), public.sfc_coach_team_move(text, text, uuid[], uuid[]) to authenticated;
-- Coaches see only themselves on the staff page (Owner/Admin see everyone)
do $$ declare d text; begin
  d := pg_get_functiondef('public.sfc_org_staff(text)'::regprocedure);
  d := replace(d, 'from public.sfc_staff s left join auth.users u on u.id = s.user_id where s.org = p_org)', 'from public.sfc_staff s left join auth.users u on u.id = s.user_id where s.org = p_org and (m or s.user_id = auth.uid()))');
  execute d;
end $$;
select 'v34 ok' as status;
